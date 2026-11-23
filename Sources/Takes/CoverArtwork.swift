import AppKit
import ImageIO
import SwiftUI

// MARK: - Artwork store

/// In-memory embedded-artwork cache for the cover and the now-playing readout,
/// keyed by stable version ID. Like `WaveformStore`, it is process-lifetime
/// runtime state: nothing is persisted or written to disk, and artwork is
/// loaded only for the version on display, never for the whole playlist.
///
/// Images are downsampled to `maximumPixelSize` on load so one cover costs a
/// couple of megabytes however large the embedded file is, and at most
/// `capacity` decoded images are kept (least recently shown first out).
@MainActor
@Observable
final class PlaylistArtworkStore {
    /// Twice the 360 pt cover, for Retina.
    nonisolated static let maximumPixelSize = 720
    static let capacity = 12

    /// `.some(nil)` records a finished load that found no art, so it is not
    /// retried every time the version is shown again. Misses cost nothing and
    /// are never evicted.
    private var images: [PlaylistVersion.ID: NSImage?] = [:]
    @ObservationIgnored private var inFlight: Set<PlaylistVersion.ID> = []
    /// Versions holding a decoded image, least recently requested first.
    @ObservationIgnored private var recency: [PlaylistVersion.ID] = []

    /// Cached artwork, or `nil` until `load(for:)` resolves (or when the
    /// file has none).
    func artwork(for versionID: PlaylistVersion.ID?) -> NSImage? {
        guard let versionID, let cached = images[versionID] else { return nil }
        return cached
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
        Task { [weak self] in
            let image = await Self.downsampledArtwork(for: url)
            guard let self else { return }
            self.inFlight.remove(id)
            self.images[id] = .some(image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) })
            if image != nil { self.markRecent(id) }
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

    nonisolated private static func downsampledArtwork(for url: URL) async -> CGImage? {
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
