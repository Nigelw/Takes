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
    /// Twice the default 360 pt cover, for Retina.
    nonisolated static let maximumPixelSize = 720
    static let capacity = 12
    /// Twice the 34 pt row thumbnail, for Retina.
    nonisolated static let thumbnailPixelSize = 68
    /// About 18 KB each, so a few megabytes at most; covers a 100-item
    /// playlist scrolled end to end.
    static let thumbnailCapacity = 160
    static let maximumConcurrentThumbnailLoads = 2

    /// Reads a file's embedded artwork, downsampled for the given target.
    typealias ArtworkLoader = @Sendable (URL, ArtworkDecodeTarget) async -> CGImage?

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

    init(loadArtwork: @escaping ArtworkLoader = { url, target in await PlaylistArtworkStore.embeddedArtwork(for: url, target: target) }) {
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
            let image = await loadArtwork(url, .cover)
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
                startThumbnail(id, url) {
                    Self.scaled(cgImage, maximumPixelSize: ArtworkDecodeTarget.thumbnail.longEdge(width: cgImage.width, height: cgImage.height))
                }
            } else {
                let loadArtwork = loadArtwork
                startThumbnail(id, url) { await loadArtwork(url, .thumbnail) }
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

    nonisolated static func embeddedArtwork(for url: URL, target: ArtworkDecodeTarget) async -> CGImage? {
        guard let data = await AudioFileLoader.embeddedArtworkData(for: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // The thumbnail size caps the LONG edge; a cropped image needs its
        // short edge at the target, so size it from the image's shape.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        var height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        if let orientation = properties?[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&width, &height) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: target.longEdge(width: width, height: height),
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

// MARK: - Aspect ratio

/// How non-square artwork is shown. The cover crops art that is nearly
/// square (losing at most a sliver) and otherwise shows the whole image,
/// fitted, over a blurred fill of itself. Row thumbnails always crop: bars
/// at 34 pt would read as a rendering fault.
enum CoverArtworkLayout {
    /// Longer side over shorter side, up to which the cover crops.
    nonisolated static let maximumCropAspect: CGFloat = 1.1

    nonisolated static func aspect(width: CGFloat, height: CGFloat) -> CGFloat {
        guard width > 0, height > 0 else { return 1 }
        return max(width, height) / min(width, height)
    }

    /// Whether the cover fills its square by cropping (else it fits).
    nonisolated static func crops(_ size: CGSize) -> Bool {
        aspect(width: size.width, height: size.height) <= maximumCropAspect
    }
}

/// The pixel size artwork is decoded at. Image I/O caps the long edge, so a
/// cropped image's long edge must grow with its aspect ratio for the short
/// edge to reach `side`; a fitted image only needs its long edge there.
struct ArtworkDecodeTarget: Equatable, Sendable {
    /// Pixels across the square it is drawn in (2× the points, for Retina).
    var side: Int
    /// Crops (fills the square) up to this aspect ratio; beyond it, fits.
    var maximumCropAspect: CGFloat
    /// Crops at any aspect, capping the extra resolution at
    /// `maximumCropAspect`.
    var alwaysCrops: Bool

    /// The cover at its default width.
    static let cover = ArtworkDecodeTarget(
        side: PlaylistArtworkStore.maximumPixelSize,
        maximumCropAspect: CoverArtworkLayout.maximumCropAspect,
        alwaysCrops: false
    )
    /// The 34 pt row thumbnail.
    static let thumbnail = ArtworkDecodeTarget(
        side: PlaylistArtworkStore.thumbnailPixelSize, maximumCropAspect: 4, alwaysCrops: true
    )

    func longEdge(width: Int, height: Int) -> Int {
        let aspect = CoverArtworkLayout.aspect(width: CGFloat(width), height: CGFloat(height))
        if aspect <= maximumCropAspect { return Self.pixels(CGFloat(side) * aspect) }
        return alwaysCrops ? Self.pixels(CGFloat(side) * maximumCropAspect) : side
    }

    /// Whole pixels, rounding up past floating-point noise (720 × 1.1 is
    /// 792.000…1, which must not become 793).
    private static func pixels(_ value: CGFloat) -> Int {
        Int((value - 0.001).rounded(.up))
    }
}

// MARK: - Record placeholder

/// The record shown when a version has no artwork
/// (docs/a2-record-placeholder-spec.md). Both pictures are bundled bitmaps
/// with a light and a dark variant, generated by
/// `scripts/make-record-placeholder.swift`; nothing is drawn at runtime
/// except the cover's ground gradient.
enum RecordPlaceholder {
    /// The cover square's record on transparency (with its cast and floor
    /// shadows), drawn for `referenceSide` and exported at
    /// `coverPixelSide`.
    static let coverImageName = "RecordPlaceholderCover"
    /// The simplified 34 pt thumbnail, ground included, at 68 px.
    static let thumbnailImageName = "RecordPlaceholderThumbnail"

    static let referenceSide: CGFloat = 360
    static let coverPixelSide = 1440
    static let thumbnailPixelSide = 68

    /// §3 geometry at the 360 pt reference square.
    static let discDiameter: CGFloat = 288
    static let labelDiameter: CGFloat = 100.8
    static let holeRadius: CGFloat = 7.5
    /// The lead-in's smooth ring: `discDiameter × 0.028` wide, its outer
    /// edge on the disc's edge.
    static let leadInWidth: CGFloat = discDiameter * 0.028

    /// The shared thumbnail. A dynamic catalog image: it resolves its light
    /// or dark bitmap for the drawing appearance current when it is turned
    /// into a `CGImage` (`PlaylistFillView.updateLayer`).
    static let thumbnail: NSImage? = NSImage(named: thumbnailImageName)

    /// The `min(width, height)` square, centred in a cover of `size`. The
    /// record bitmap fills it, and the ground gradient is sized to it.
    static func coverSquare(in size: CGSize) -> CGRect {
        let side = max(min(size.width, size.height), 0)
        return CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
    }

    /// §3.1's ground stops for each appearance.
    static func groundStops(isDark: Bool) -> [Gradient.Stop] {
        let colors: [(Double, Double, Double)] = isDark
            ? [(0x34, 0x34, 0x3A), (0x1D, 0x1D, 0x20), (0x14, 0x14, 0x16)]
            : [(0xFB, 0xFB, 0xFD), (0xE6, 0xE6, 0xEB), (0xD4, 0xD4, 0xDB)]
        return zip(colors, [0, 0.62, 1]).map { color, location in
            Gradient.Stop(color: Color(.sRGB, red: color.0 / 255, green: color.1 / 255, blue: color.2 / 255),
                          location: location)
        }
    }

    /// The ground's centre, (50%, 38%) of the square, as a unit point of
    /// the whole cover.
    static func groundCenter(square: CGRect, in size: CGSize) -> UnitPoint {
        guard size.width > 0, size.height > 0 else { return .center }
        return UnitPoint(x: square.midX / size.width, y: (square.minY + square.height * 0.38) / size.height)
    }

    /// The ground reaches the square's farthest corner from its centre.
    static func groundRadius(square: CGRect) -> CGFloat {
        hypot(square.width * 0.5, square.height * 0.62)
    }
}

/// The cover's no-artwork state: the ground gradient sized to the square,
/// its edge colour carried to the cover's edges, and the record bitmap
/// scaled to the square.
private struct RecordPlaceholderCoverView: View {
    let size: CGSize

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let square = RecordPlaceholder.coverSquare(in: size)
        let stops = RecordPlaceholder.groundStops(isDark: colorScheme == .dark)
        ZStack {
            stops[stops.count - 1].color
            RadialGradient(
                stops: stops,
                center: RecordPlaceholder.groundCenter(square: square, in: size),
                startRadius: 0,
                endRadius: RecordPlaceholder.groundRadius(square: square)
            )
            Image(RecordPlaceholder.coverImageName)
                .resizable()
                .interpolation(.high)
                .frame(width: square.width, height: square.height)
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Cover

/// The width-scaled cover at the top of the main window (A2 spec §4).
/// A faint top shade appears with the window buttons to keep them legible
/// over bright art. When height limits the square, it is centred over a
/// blurred fill of the same image. Non-square art
/// (`CoverArtworkLayout`) is cropped when nearly square, and otherwise shown
/// whole, fitted in the square, over that same blurred fill. Pressing on the
/// cover drags the window, as the control bar does.
struct ArtworkCoverView: View {
    let image: NSImage?
    let showsTitlebarControls: Bool

    private static let topShadeHeight: CGFloat = 40

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Theme.artworkPlaceholderFill
                if let image {
                    let crops = CoverArtworkLayout.crops(image.size)
                    if max(proxy.size.width, proxy.size.height) > side + 0.5 || !crops {
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
                        .aspectRatio(contentMode: crops ? .fill : .fit)
                        .frame(width: side, height: side)
                        .clipped()
                    if showsTitlebarControls {
                        LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: Self.topShadeHeight)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                } else {
                    RecordPlaceholderCoverView(size: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .clipped()
        .overlay(WindowDragArea())
        .accessibilityElement()
        .accessibilityLabel(image == nil ? "No Artwork" : "Artwork")
        .accessibilityAddTraits(.isImage)
    }
}

// MARK: - Titlebar toggles

struct WorkspaceVisibilityButton: View {
    let region: WorkspaceVisibility.Region
    let visibility: WorkspaceVisibility
    let toggle: () -> Void

    static let size = CGSize(width: 26, height: 22)
    private static let glyphSize: CGFloat = 16

    private var isOn: Bool { visibility[region] }

    var body: some View {
        Button(action: toggle) {
            Group {
                switch region {
                case .artwork: ArtworkToggleGlyph()
                case .player: Image(systemName: "play.rectangle")
                case .playlist: Image(systemName: "list.bullet")
                }
            }
            .font(.system(size: Self.glyphSize, weight: .medium))
            .frame(width: Self.glyphSize, height: Self.glyphSize)
        }
        .buttonStyle(WorkspaceVisibilityButtonStyle(isOn: isOn))
        .disabled(!visibility.canToggle(region))
        .help(region.visibilityAction(isVisible: isOn))
        .accessibilityLabel(region.visibilityAction(isVisible: isOn))
        .accessibilityAddTraits(isOn ? [.isToggle, .isSelected] : .isToggle)
    }
}

extension WorkspaceVisibility.Region {
    func visibilityAction(isVisible: Bool) -> String {
        let name = switch self {
        case .artwork: "Artwork"
        case .player: "Player"
        case .playlist: "Playlist"
        }
        return "\(isVisible ? "Hide" : "Show") \(name)"
    }
}

private struct WorkspaceVisibilityButtonStyle: ButtonStyle {
    let isOn: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.transportAppearance) private var transportAppearance

    func makeBody(configuration: Configuration) -> some View {
        // The lit side buttons' glyph and glow (side-button lamps spec §7:
        // the toggle matches them).
        let glow = transportAppearance.sideButton(for: colorScheme).glyphGlow
        return configuration.label
            .foregroundStyle(isOn ? Theme.sideButtonLitGlyph : Color(nsColor: .secondaryLabelColor))
            .sideButtonGlyphGlow(isOn ? glow : [])
            .frame(width: WorkspaceVisibilityButton.size.width, height: WorkspaceVisibilityButton.size.height)
            .background {
                if isOn { chip }
            }
            .contentShape(Rectangle())
            .opacity(isEnabled && !configuration.isPressed ? 1 : 0.7)
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
