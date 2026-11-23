import AppKit
import ImageIO
import SwiftUI

// MARK: - Artwork store

/// In-memory embedded-artwork caches, keyed by stable version ID: one for
/// the cover and one for the playlist rows' thumbnails. Like
/// `WaveformStore`, they are process-lifetime runtime state: nothing is
/// persisted or written to disk.
///
/// Cover: loaded only for the version on display, downsampled to
/// `maximumPixelSize`, at most `capacity` decoded images (least recently
/// shown first out). SwiftUI observes it.
///
/// Thumbnails: loaded only for item rows the playlist table reports as
/// visible (`requestThumbnails(_:)` replaces the queue, so rows scrolled
/// away before their turn are never decoded), at most
/// `maximumConcurrentThumbnailLoads` at a time, downsampled to
/// `thumbnailPixelSize`, at most `thumbnailCapacity` decoded images. A
/// version whose cover is decoded, or decoding, is scaled down from that
/// image instead of reading the file again. Not observed: the table is
/// told through `onThumbnailLoaded`.
@MainActor
@Observable
final class PlaylistArtworkStore {
    /// Twice the 360 pt cover, for Retina.
    nonisolated static let maximumPixelSize = 720
    static let capacity = 12
    /// Twice the 34 pt row thumbnail, for Retina.
    nonisolated static let thumbnailPixelSize = 68
    /// About 18 KB each, so a few megabytes at most; covers a 100-item
    /// playlist scrolled end to end.
    static let thumbnailCapacity = 160
    static let maximumConcurrentThumbnailLoads = 2

    /// Reads a file's embedded artwork, downsampled to the given pixel size.
    typealias ArtworkLoader = @Sendable (URL, Int) async -> CGImage?

    enum Thumbnail: Equatable {
        /// Not loaded yet (or loaded for a different file).
        case unknown
        /// Loaded; the file has no artwork.
        case none
        case image(NSImage)
    }

    /// `.some(nil)` records a finished load that found no art, so it is not
    /// retried every time the version is shown again. Misses cost nothing and
    /// are never evicted.
    private var images: [PlaylistVersion.ID: NSImage?] = [:]
    @ObservationIgnored private var inFlight: Set<PlaylistVersion.ID> = []
    /// Versions holding a decoded image, least recently requested first.
    @ObservationIgnored private var recency: [PlaylistVersion.ID] = []

    private struct ThumbnailEntry {
        let url: URL
        let image: NSImage?
    }

    @ObservationIgnored private let loadArtwork: ArtworkLoader
    @ObservationIgnored private var thumbnails: [PlaylistVersion.ID: ThumbnailEntry] = [:]
    @ObservationIgnored private var thumbnailRecency: [PlaylistVersion.ID] = []
    @ObservationIgnored private var thumbnailQueue: [(id: PlaylistVersion.ID, url: URL)] = []
    @ObservationIgnored private var thumbnailsLoading: [PlaylistVersion.ID: URL] = [:]
    /// Called on the main actor when a thumbnail finishes loading, with or
    /// without art.
    @ObservationIgnored var onThumbnailLoaded: ((PlaylistVersion.ID) -> Void)?

    init(loadArtwork: @escaping ArtworkLoader = { url, size in await PlaylistArtworkStore.embeddedArtwork(for: url, maximumPixelSize: size) }) {
        self.loadArtwork = loadArtwork
    }

    // MARK: Cover

    /// Cached artwork, or `nil` until `load(for:)` resolves (or when the
    /// file has none).
    func artwork(for versionID: PlaylistVersion.ID?) -> NSImage? {
        guard let versionID, let cached = images[versionID] else { return nil }
        return cached
    }

    /// Whether the version's cover has finished loading: decoded, or known to
    /// have no artwork.
    func hasResolvedArtwork(for versionID: PlaylistVersion.ID?) -> Bool {
        guard let versionID else { return false }
        return images[versionID] != nil
    }

    /// Starts loading the version's embedded artwork if it isn't cached or
    /// loading already. Safe to call on every navigation.
    func load(for version: PlaylistVersion) {
        let id = version.id
        if images[id] != nil {
            markRecent(id)
            return
        }
        guard !inFlight.contains(id) else { return }
        guard case let .available(url) = PlaylistWorkspaceStore.resolveFileReference(version.file) else {
            images[id] = .some(nil)
            return
        }
        inFlight.insert(id)
        let loadArtwork = loadArtwork
        Task { [weak self] in
            let image = await loadArtwork(url, Self.maximumPixelSize)
            guard let self else { return }
            self.inFlight.remove(id)
            self.images[id] = .some(image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) })
            if image != nil { self.markRecent(id) }
            self.pumpThumbnails()
        }
    }

    private func markRecent(_ id: PlaylistVersion.ID) {
        guard case .some(.some) = images[id] else { return }
        recency.removeAll { $0 == id }
        recency.append(id)
        while recency.count > Self.capacity {
            images[recency.removeFirst()] = nil
        }
    }

    // MARK: Thumbnails

    /// The cached thumbnail for this version's file. Marks it recently used.
    func thumbnail(for versionID: PlaylistVersion.ID, url: URL) -> Thumbnail {
        guard let entry = thumbnails[versionID], entry.url == url else { return .unknown }
        guard let image = entry.image else { return .none }
        markThumbnailRecent(versionID)
        return .image(image)
    }

    /// Replaces the pending queue with these versions (the visible rows, in
    /// display order) and starts loading. Requests from rows no longer
    /// visible are dropped; loads already running finish and are cached.
    func requestThumbnails(_ requests: [(id: PlaylistVersion.ID, url: URL)]) {
        thumbnailQueue = requests.filter { thumbnails[$0.id]?.url != $0.url }
        pumpThumbnails()
    }

    /// Number of thumbnails currently being read or scaled. For tests.
    var thumbnailLoadsInFlight: Int { thumbnailsLoading.count }

    private func pumpThumbnails() {
        // Leave requests waiting on a cover in the visible queue. Other rows
        // can start while they wait, and scrolling replaces the whole queue.
        while thumbnailsLoading.count < Self.maximumConcurrentThumbnailLoads,
              let index = thumbnailQueue.firstIndex(where: { !inFlight.contains($0.id) && thumbnailsLoading[$0.id] == nil }) {
            let (id, url) = thumbnailQueue.remove(at: index)
            guard thumbnails[id]?.url != url else { continue }
            if case let .some(.some(cover)) = images[id],
               let cgImage = cover.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                startThumbnail(id, url) { Self.scaled(cgImage, maximumPixelSize: Self.thumbnailPixelSize) }
            } else {
                let loadArtwork = loadArtwork
                startThumbnail(id, url) { await loadArtwork(url, Self.thumbnailPixelSize) }
            }
        }
    }

    private func startThumbnail(_ id: PlaylistVersion.ID, _ url: URL, _ work: @escaping @Sendable () async -> CGImage?) {
        thumbnailsLoading[id] = url
        Task { [weak self] in
            let image = await Task.detached(priority: .utility) { await work() }.value
            guard let self else { return }
            self.thumbnailsLoading[id] = nil
            self.storeThumbnail(id, url: url, image: image)
            self.pumpThumbnails()
        }
    }

    private func storeThumbnail(_ id: PlaylistVersion.ID, url: URL, image: CGImage?) {
        let nsImage = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        thumbnails[id] = ThumbnailEntry(url: url, image: nsImage)
        if nsImage != nil { markThumbnailRecent(id) }
        onThumbnailLoaded?(id)
    }

    private func markThumbnailRecent(_ id: PlaylistVersion.ID) {
        if thumbnailRecency.last == id { return }
        thumbnailRecency.removeAll { $0 == id }
        thumbnailRecency.append(id)
        while thumbnailRecency.count > Self.thumbnailCapacity {
            thumbnails[thumbnailRecency.removeFirst()] = nil
        }
    }

    // MARK: Decoding

    nonisolated static func embeddedArtwork(for url: URL, maximumPixelSize: Int) async -> CGImage? {
        guard let data = await AudioFileLoader.embeddedArtworkData(for: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Scales an already-decoded image down so its longer side is
    /// `maximumPixelSize`, keeping its aspect ratio.
    nonisolated static func scaled(_ image: CGImage, maximumPixelSize: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maximumPixelSize else { return image }
        let scale = CGFloat(maximumPixelSize) / CGFloat(longest)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

// MARK: - Cover

/// The 360 pt full-bleed cover at the top of the main window (A2 spec §4).
/// No text overlay. A faint top shade keeps the window buttons legible over
/// bright art. When the window is wider than the cover, the square stays
/// 360 pt and centred over a blurred fill of the same image. Pressing on the
/// cover drags the window, as the control bar does.
struct ArtworkCoverView: View {
    let image: NSImage?

    private static let side = TakesWindowPolicy.artworkHeight
    private static let topShadeHeight: CGFloat = 40

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Theme.artworkPlaceholderFill
                if let image {
                    if proxy.size.width > Self.side + 0.5 {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .blur(radius: 36, opaque: true)
                            .overlay(Color.black.opacity(0.2))
                            .clipped()
                    }
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: Self.side, height: Self.side)
                        .clipped()
                    LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.topShadeHeight)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 72, weight: .light))
                        .foregroundStyle(Theme.artworkPlaceholderGlyph)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: Self.side)
        .clipped()
        .overlay(WindowDragArea())
        .accessibilityElement()
        .accessibilityLabel(image == nil ? "No Artwork" : "Artwork")
        .accessibilityAddTraits(.isImage)
    }
}

// MARK: - Titlebar toggle

/// Titlebar button that shows or hides the cover (A2 spec §4). On (artwork
/// showing): a lit glyph on a frosted chip that reads over any cover. Off: a
/// plain grey glyph over the control bar.
struct ArtworkToggleButton: View {
    @Binding var showsArtwork: Bool

    static let size = CGSize(width: 26, height: 22)
    static let glyphSize: CGFloat = 16

    var body: some View {
        Button {
            showsArtwork.toggle()
        } label: {
            ArtworkToggleGlyph()
                .frame(width: Self.glyphSize, height: Self.glyphSize)
        }
        .buttonStyle(ArtworkToggleButtonStyle(isOn: showsArtwork))
        .help(showsArtwork ? "Hide Artwork" : "Show Artwork")
        .accessibilityLabel(showsArtwork ? "Hide Artwork" : "Show Artwork")
        .accessibilityAddTraits(showsArtwork ? [.isToggle, .isSelected] : .isToggle)
    }
}

private struct ArtworkToggleButtonStyle: ButtonStyle {
    let isOn: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.transportAppearance) private var transportAppearance

    func makeBody(configuration: Configuration) -> some View {
        // The glow of an engaged secondary transport button (v2.9.0).
        let glow = colorScheme == .dark ? transportAppearance.darkSecondary : transportAppearance.lightSecondary
        return configuration.label
            .foregroundStyle(isOn ? Theme.primaryLitGlyph : Color(nsColor: .secondaryLabelColor))
            .shadow(color: isOn ? Theme.primary.opacity(glow.activeGlyphGlowOpacity) : .clear,
                    radius: isOn ? glow.activeGlyphGlowRadius : 0)
            .shadow(color: isOn ? Theme.primary.opacity(glow.activeGlyphBloomOpacity) : .clear,
                    radius: isOn ? glow.activeGlyphBloomRadius : 0)
            .frame(width: ArtworkToggleButton.size.width, height: ArtworkToggleButton.size.height)
            .background {
                if isOn { chip }
            }
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }

    /// Frosted chip: background blur under a translucent fill, a 0.5 pt inner
    /// hairline, and a small drop shadow. Dark over the cover in dark
    /// appearance, pale in light.
    private var chip: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let isDark = colorScheme == .dark
        return shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(isDark ? Color(white: 0.08).opacity(0.5) : Color.white.opacity(0.5)))
            .overlay(shape.strokeBorder(isDark ? Color.white.opacity(0.22) : Color.white.opacity(0.7), lineWidth: 0.5))
            .shadow(color: .black.opacity(isDark ? 0.35 : 0.2), radius: 1.5, y: 1)
    }
}

/// An album sleeve with a record sliding out of its right edge. No SF Symbol
/// matches, so it is drawn here on a 24-unit grid and scaled to its frame.
struct ArtworkToggleGlyph: View {
    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width, proxy.size.height) / 24
            ZStack {
                ArtworkToggleGlyphOutline()
                    .stroke(style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round, lineJoin: .round))
                Circle()
                    .frame(width: 2.2 * scale, height: 2.2 * scale)
                    .position(x: 18.2 * scale, y: 12 * scale)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ArtworkToggleGlyphOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        var path = Path()
        // Sleeve.
        path.addRoundedRect(
            in: CGRect(x: 2, y: 4.5, width: 12.5, height: 15),
            cornerSize: CGSize(width: 2, height: 2),
            style: .continuous
        )
        // Record: an r = 6.5 arc leaving the sleeve's right edge at
        // y = 5.81 and returning at y = 18.19, bulging to the right.
        let radius: CGFloat = 6.5
        let halfChord: CGFloat = 6.19
        let center = CGPoint(x: 14.5 + (radius * radius - halfChord * halfChord).squareRoot(), y: 12)
        let start = Angle(radians: atan2(-halfChord, 14.5 - center.x))
        let end = Angle(radians: atan2(halfChord, 14.5 - center.x))
        path.move(to: CGPoint(x: 14.5, y: 12 - halfChord))
        path.addRelativeArc(center: center, radius: radius, startAngle: start, delta: end - start)
        return path.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: rect.minX / scale, y: rect.minY / scale))
    }
}
