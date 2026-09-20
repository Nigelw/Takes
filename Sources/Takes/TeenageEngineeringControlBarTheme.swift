import AppKit
import SwiftUI

/// Chrome for the "Teenage Engineering" control bar theme
/// (`ControlBarTheme.teenageEngineering`): the control bar as a slab of TE
/// hardware in the manner of the TP-7 and the K.O. II.
///
/// The design language:
///
/// - **Keycaps, not circles.** Every transport button is a rounded-square cap
///   sitting in a rounded-square socket punched into the panel, with a visible
///   gap around it and a short side wall below the cap face, so it reads as a
///   separate molded part standing proud of the panel. Pressing does not
///   scale the cap: the whole cap shifts straight down by its wall height and
///   the wall disappears, so the key visibly seats flush in its socket.
/// - **Silkscreen.** Each secondary key has a tiny printed caption on the
///   panel under it ("PREV", "SHFL", "RPT"…) and a small indicator dot printed
///   above it that lights TE orange when the toggle is engaged. Captions are
///   part of the panel, so they stay printed when the key is disabled — only
///   the glyph on the cap dims.
/// - **One accent.** Play is the orange key; engaged toggles invert to the
///   panel's ink (a black key on the light unit, a white key on the black
///   unit) and light their dot. Nothing else is colored.
/// - **A real display window.** The readout is a light metal/cream plate (or
///   a charcoal one) holding a discrete near-black display window, recessed
///   with a hard top shadow and a light bottom lip, the way the TP-7's OLED
///   sits in its aluminum. The digits and dot-matrix text print on that black
///   glass in warm white in both colorways. Beside the window the plate
///   carries a tiny "TAKES" nameplate and a punched speaker grille — the
///   K.O. II's nameplate-and-grille strip in miniature.
/// - **A dashboard, not a text field.** Like the K.O. II's display strip, the
///   window holds one large numeral cluster (the elapsed time) surrounded by
///   small independent tiles in mixed treatments: solid inverted pills
///   ("TIME", "BLIND", an engaged mode), outlined chips (the file format, the
///   track position), bare printed values (the sample rate), monochrome
///   pictograms (mono/stereo rings, play/pause), and exactly one spot of
///   real color — an LED behind a printed ring that lights orange while the
///   transport runs. Every tile mirrors state that already exists
///   (`TeenageEngineeringDisplayStatus`); none is interactive.
///
/// `CircleTransportButtonStyle` and the readout panels (`DigitalTimeReadout`,
/// `ReadoutPanelChrome`) branch to these types when the theme is active; the
/// digit renderers (`SevenSegmentDisplay`, `DotMatrixDisplay`,
/// `DotMatrixProgressView`) read `TeenageEngineeringPalette.displayInk` so
/// they print in the window's ink. Layout, hit targets, glyphs and state
/// semantics are unchanged from the classic theme.

// MARK: - Palette

/// The theme's colors, resolved per `ColorScheme` to *concrete* sRGB values
/// rather than dynamic providers. The dot-matrix marquee rasterizes its
/// bitmap offscreen with no window appearance to resolve against, and the
/// progress bar paints Core Animation layers, so both need a color that is
/// already fixed for the scheme they are drawing for.
enum TeenageEngineeringPalette {
    struct Colors {
        /// The panel plate behind the readout, top and bottom of its brushed
        /// gradient.
        var chassisTop: Color
        var chassisBottom: Color
        /// Hairline around the chassis plate.
        var chassisRim: Color
        /// The socket a keycap sits in — the dark gap ring around every key.
        var buttonWell: Color
        /// A resting (off) keycap's face.
        var buttonCap: Color
        /// The keycap's side wall, visible below the face while it is up.
        var buttonCapSide: Color
        /// Hairline around a keycap face.
        var buttonCapRim: Color
        /// Silkscreen: captions, the nameplate, and an engaged keycap.
        var ink: Color
        /// An engaged keycap's side wall.
        var inkSide: Color
        /// A resting key's glyph — ink at reduced strength.
        var inkMuted: Color
        /// The glyph on an engaged (ink-colored) key.
        var inkGlyph: Color
        /// The one accent: TE orange, for Play and the indicator dots.
        var accent: Color
        /// Play's side wall.
        var accentSide: Color
        /// Darkening laid over a keycap while it is held down.
        var pressShade: Color
        /// The recessed display window's glass.
        var display: Color
        /// Print color on the display glass.
        var displayInk: Color
        /// An unlit indicator dot: a printed ring.
        var ledOff: Color
        /// A punched grille hole and the lit edge below it.
        var grilleHole: Color
        var grilleLip: Color
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r, green: g, blue: b)
    }

    static let light = Colors(
        chassisTop: rgb(0.894, 0.886, 0.863),      // #E4E2DC brushed light gray
        chassisBottom: rgb(0.843, 0.835, 0.812),   // #D7D5CF
        chassisRim: .black.opacity(0.24),
        buttonWell: rgb(0.753, 0.741, 0.714),      // #C0BDB6
        buttonCap: rgb(0.953, 0.945, 0.925),       // #F3F1EC
        buttonCapSide: rgb(0.741, 0.729, 0.702),   // #BDBAB3
        buttonCapRim: .black.opacity(0.20),
        ink: rgb(0.149, 0.141, 0.129),             // #262421 warm near-black
        inkSide: rgb(0.055, 0.051, 0.047),         // #0E0D0C
        inkMuted: rgb(0.149, 0.141, 0.129).opacity(0.66),
        inkGlyph: rgb(0.945, 0.937, 0.914),        // #F1EFE9
        accent: rgb(0.949, 0.408, 0.129),          // #F26821 TE orange
        accentSide: rgb(0.706, 0.278, 0.063),      // #B44710
        pressShade: .black.opacity(0.09),
        display: rgb(0.086, 0.086, 0.086),         // #161616
        displayInk: rgb(0.949, 0.933, 0.894),      // #F2EEE4 warm white
        ledOff: .black.opacity(0.22),
        grilleHole: rgb(0.667, 0.655, 0.627),      // #AAA7A0
        grilleLip: .white.opacity(0.55)
    )

    static let dark = Colors(
        chassisTop: rgb(0.196, 0.196, 0.208),      // #323235 charcoal
        chassisBottom: rgb(0.153, 0.153, 0.165),   // #27272A
        chassisRim: .white.opacity(0.14),
        buttonWell: rgb(0.078, 0.078, 0.086),      // #141416
        buttonCap: rgb(0.251, 0.251, 0.267),       // #404044
        buttonCapSide: rgb(0.118, 0.118, 0.129),   // #1E1E21
        buttonCapRim: .white.opacity(0.12),
        ink: rgb(0.925, 0.910, 0.878),             // #ECE8E0 warm off-white
        inkSide: rgb(0.667, 0.651, 0.612),         // #AAA69C
        inkMuted: rgb(0.925, 0.910, 0.878).opacity(0.62),
        inkGlyph: rgb(0.118, 0.118, 0.125),        // #1E1E20
        accent: rgb(0.961, 0.451, 0.227),          // #F5733A lifted a step for black
        accentSide: rgb(0.667, 0.263, 0.086),      // #AA4316
        pressShade: .black.opacity(0.24),
        display: rgb(0.031, 0.031, 0.035),         // #080809
        displayInk: rgb(0.925, 0.910, 0.878),      // #ECE8E0
        ledOff: .white.opacity(0.18),
        grilleHole: rgb(0.051, 0.051, 0.059),      // #0D0D0F
        grilleLip: .white.opacity(0.10)
    )

    static func colors(for colorScheme: ColorScheme) -> Colors {
        colorScheme == .dark ? dark : light
    }

    /// The display window's print color for `colorScheme`, as a concrete
    /// color. Warm white on near-black glass in both colorways.
    static func displayInk(for colorScheme: ColorScheme) -> Color {
        colors(for: colorScheme).displayInk
    }

    /// `displayInk(for:)` as an `NSColor` for Core Animation layer fills.
    static func displayInkNSColor(for colorScheme: ColorScheme) -> NSColor {
        let sRGB = colorScheme == .dark ? (0.925, 0.910, 0.878) : (0.949, 0.933, 0.894)
        return NSColor(srgbRed: sRGB.0, green: sRGB.1, blue: sRGB.2, alpha: 1)
    }
}

/// Geometry of the readout plate shared by the readout views and the content
/// they hold, so the display window and the content that prints on it agree
/// about where the glass ends and the grille strip begins.
enum TeenageEngineeringReadoutLayout {
    /// Corner radius of the plate.
    static let plateCornerRadius: CGFloat = 7
    /// From the plate edge to the display window on the top, bottom and
    /// leading sides.
    static let windowInset: CGFloat = 4
    static let windowCornerRadius: CGFloat = 3.5
    /// Width of the nameplate-and-grille strip at the trailing edge, between
    /// the window and the plate edge. Readout content must keep clear of it:
    /// `DigitalTimeReadout` adds it to its trailing padding and
    /// `PlaylistNowPlayingReadout` subtracts it from its column budget.
    static let stripWidth: CGFloat = 26

    /// The display window's frame within a plate of `size`.
    static func windowRect(in size: CGSize) -> CGRect {
        CGRect(
            x: windowInset,
            y: windowInset,
            width: size.width - windowInset * 2 - stripWidth,
            height: size.height - windowInset * 2
        )
    }
}

// MARK: - Buttons

/// A rounded-square keycap in a socket punched through the panel.
///
/// Structure, outside in: the full `diameter` square (rounded) is the socket
/// (the darker `buttonWell`, shadowed along its top edge like a hole); the
/// cap sits inside it with a gap all round; below the cap's face, its side
/// wall shows in a darker tone, so the cap stands `travel` points proud of
/// the socket floor. Pressing shifts the whole cap — face, wall and glyph —
/// straight down by `travel` and collapses the wall, seating the key flush.
/// No gloss, no bevel, no scaling.
///
/// - Primary (Play): the cap is TE orange with a white glyph; the one accent
///   on the bar. No caption, no dot — it is the hero key.
/// - Secondary, off: white/charcoal cap with a muted-ink glyph; a printed
///   caption under the socket and an unlit ring above it.
/// - Secondary, on: the cap inverts to ink with a panel-colored glyph and
///   the indicator dot above it lights orange.
/// - Disabled: the key is still a key — only the glyph on it fades. The
///   caption is silkscreened on the panel and stays.
struct TeenageEngineeringButtonChrome<Label: View>: View {
    let kind: CircleTransportButtonStyle.Kind
    let isOn: Bool
    let diameter: CGFloat
    let glyphSize: CGFloat
    /// Unused by this chrome: the glyph travels with the cap by `travel`.
    let pressedGlyphOffset: CGFloat
    let isEnabled: Bool
    /// Silkscreen caption printed on the panel under a secondary key.
    var caption: String? = nil
    @ViewBuilder let label: () -> Label
    let isPressed: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var palette: TeenageEngineeringPalette.Colors {
        TeenageEngineeringPalette.colors(for: colorScheme)
    }

    private var isPrimary: Bool { kind == .primary }

    /// Socket corner radius; the cap uses the concentric radius inside it.
    private var socketRadius: CGFloat { diameter * 0.26 }
    /// Gap between the socket edge and the cap.
    private var capInset: CGFloat { isPrimary ? 3.5 : 3 }
    private var capRadius: CGFloat { socketRadius - capInset }
    /// How far the cap stands above the socket floor, and how far it moves
    /// when pressed.
    private var travel: CGFloat { isPrimary ? 2.5 : 2 }
    /// Vertical position of the cap face: up at rest, down while pressed.
    private var capY: CGFloat { isPressed ? travel / 2 : -travel / 2 }
    /// Visible wall height below the face.
    private var wallHeight: CGFloat { isPressed ? 0 : travel }

    private var capFill: Color {
        switch kind {
        case .primary: return palette.accent
        case .secondary: return isOn ? palette.ink : palette.buttonCap
        }
    }

    private var capSide: Color {
        switch kind {
        case .primary: return palette.accentSide
        case .secondary: return isOn ? palette.inkSide : palette.buttonCapSide
        }
    }

    private var glyphColor: Color {
        switch kind {
        case .primary: return .white
        case .secondary: return isOn ? palette.inkGlyph : palette.inkMuted
        }
    }

    private var socketShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: socketRadius, style: .continuous)
    }

    private var capShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: capRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            // The hole: darker floor with a hard shadow under its top edge.
            socketShape
                .fill(palette.buttonWell.shadow(.inner(color: .black.opacity(colorScheme == .dark ? 0.7 : 0.28), radius: 1.5, y: 1)))

            // Side wall: the cap's silhouette extended down to the socket
            // floor. Drawn as a stack of the cap shape so its rounded corners
            // stay continuous with the face.
            capShape
                .fill(capSide)
                .padding(capInset)
                .offset(y: capY + wallHeight)

            // Face.
            capShape
                .fill(capFill)
                .overlay(capShape.strokeBorder(palette.buttonCapRim, lineWidth: 1))
                .overlay(capShape.fill(isPressed ? palette.pressShade : .clear))
                .padding(capInset)
                .offset(y: capY)

            label()
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(glyphColor)
                .opacity(isEnabled ? 1 : 0.28)
                .offset(y: capY)
        }
        .frame(width: diameter, height: diameter)
        .overlay(alignment: .top) {
            if kind == .secondary { indicatorDot.offset(y: -7) }
        }
        .overlay(alignment: .bottom) {
            if kind == .secondary, let caption { captionLabel(caption).offset(y: 8.5) }
        }
        .animation(.easeOut(duration: 0.07), value: isPressed)
        .contentShape(socketShape)
    }

    /// The indicator printed on the panel above a toggle key: a ring at
    /// rest, a lit orange dot when the toggle is engaged.
    private var indicatorDot: some View {
        ZStack {
            Circle().strokeBorder(palette.ledOff, lineWidth: 0.8)
            Circle()
                .fill(palette.accent)
                .shadow(color: palette.accent.opacity(0.8), radius: 1.6)
                .opacity(isOn ? 1 : 0)
        }
        .frame(width: 3.6, height: 3.6)
        .animation(.easeOut(duration: 0.12), value: isOn)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func captionLabel(_ caption: String) -> some View {
        Text(caption)
            .font(.system(size: 5.5, weight: .bold, design: .rounded))
            .kerning(0.7)
            .foregroundStyle(palette.inkMuted)
            .fixedSize()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Readout panel

/// The plate behind a readout: a brushed light-gray (or charcoal) part with
/// a discrete near-black display window recessed into it, and a nameplate-
/// and-grille strip beside the window. Content prints on the window; see
/// `TeenageEngineeringReadoutLayout` for where it must stay.
struct TeenageEngineeringReadoutBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = TeenageEngineeringPalette.colors(for: colorScheme)
        let plate = RoundedRectangle(cornerRadius: TeenageEngineeringReadoutLayout.plateCornerRadius, style: .continuous)

        plate
            .fill(
                LinearGradient(
                    colors: [palette.chassisTop, palette.chassisBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            // The plate is a separate part on the bar: a hairline rim and a
            // touch of shadow under its bottom edge.
            .overlay(plate.strokeBorder(palette.chassisRim, lineWidth: 1))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.16), radius: 1, y: 1)
            .overlay {
                GeometryReader { proxy in
                    let window = TeenageEngineeringReadoutLayout.windowRect(in: proxy.size)
                    RoundedRectangle(cornerRadius: TeenageEngineeringReadoutLayout.windowCornerRadius, style: .continuous)
                        .fill(palette.display)
                        .frame(width: window.width, height: window.height)
                        .offset(x: window.minX, y: window.minY)
                    TeenageEngineeringGrilleStrip(palette: palette)
                        .frame(width: TeenageEngineeringReadoutLayout.stripWidth, height: proxy.size.height)
                        .offset(x: proxy.size.width - TeenageEngineeringReadoutLayout.stripWidth)
                }
            }
    }
}

/// Drawn over a readout: the display window's recess edge (a hard shadow
/// along its top, a light lip along its bottom, where the glass sits below
/// the plate).
struct TeenageEngineeringReadoutOverlay: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let window = TeenageEngineeringReadoutLayout.windowRect(in: proxy.size)
            let recess = RoundedRectangle(cornerRadius: TeenageEngineeringReadoutLayout.windowCornerRadius + 1, style: .continuous)

            recess
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(colorScheme == .dark ? 0.9 : 0.55), location: 0),
                            .init(color: .black.opacity(colorScheme == .dark ? 0.6 : 0.25), location: 0.5),
                            .init(color: .white.opacity(colorScheme == .dark ? 0.16 : 0.7), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .frame(width: window.width + 2, height: window.height + 2)
                .offset(x: window.minX - 1, y: window.minY - 1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Display dashboard

/// What the display window's indicator tiles show. Every field mirrors state
/// that already exists on the comparison session, the playlist workspace, or
/// the loaded file's metadata; the readouts build one per body and the
/// dashboard views only draw it. Nothing here is stored or acted on.
struct TeenageEngineeringDisplayStatus: Equatable {
    enum RepeatIndicator: Equatable {
        case off
        case one
        case all
        case switchTracks
    }

    var isPlaying = false
    /// 1-based position of the active track among the loaded comparison
    /// tracks, or of the current item in the playlist, and the count.
    var trackNumber: Int?
    var trackCount = 0
    /// The file's extension, uppercased (`LoadedTrack.fileFormatDescription`).
    var fileFormat: String?
    /// Hz. `nil` or zero prints nothing.
    var sampleRate: Double?
    var channelCount: UInt32?
    /// Bits per second; zero means the file reported none.
    var bitRate: Double?
    var repeatMode: RepeatIndicator = .off
    /// `nil` when the mode has no shuffle (comparison).
    var isShuffleEnabled: Bool?
    /// `nil` when the mode has no loop region (playlist playback ignores it).
    var isLoopActive: Bool?
    /// Blind Listening hides everything that could identify a version: the
    /// format, rate, and channel tiles give way to a single "BLIND" tile.
    var isBlindListening = false

    init() {}

    // MARK: Tile text

    /// "2/3": the active track's position in the loaded set.
    var trackLabel: String? {
        guard let trackNumber, trackCount > 0 else { return nil }
        return "\(trackNumber)/\(trackCount)"
    }

    /// "FLAC", "MP3" — the file's own extension; blank extensions print nothing.
    var formatLabel: String? {
        guard !isBlindListening, let fileFormat else { return nil }
        let trimmed = fileFormat.trimmingCharacters(in: .whitespaces).uppercased()
        return trimmed.isEmpty || trimmed == "AUDIO" ? nil : trimmed
    }

    /// "44.1K", "48K", "96K".
    var sampleRateLabel: String? {
        guard !isBlindListening, let sampleRate, sampleRate.isFinite, sampleRate > 0 else { return nil }
        let kHz = sampleRate / 1000
        return kHz == kHz.rounded() ? String(format: "%.0fK", kHz) : String(format: "%.1fK", kHz)
    }

    /// "256KBPS" when the file reported a data rate.
    var bitRateLabel: String? {
        guard !isBlindListening, let bitRate, bitRate.isFinite, bitRate > 0 else { return nil }
        return "\(Int((bitRate / 1000).rounded()))KBPS"
    }

    /// The channel pictogram, hidden with the rest of the file facts while
    /// listening blind (a mono mix against a stereo one is a giveaway).
    var channelPictogram: UInt32? {
        guard !isBlindListening, let channelCount, channelCount > 0 else { return nil }
        return channelCount
    }

    var repeatLabel: String {
        switch repeatMode {
        case .off: return "RPT"
        case .one: return "RPT 1"
        case .all: return "RPT ALL"
        case .switchTracks: return "RPT SW"
        }
    }

    /// Spoken summary for the dashboard's accessibility element.
    var accessibilityDescription: String {
        var parts: [String] = []
        if let trackLabel { parts.append("track \(trackLabel)") }
        if isBlindListening { parts.append("blind listening") }
        if let formatLabel { parts.append(formatLabel) }
        if let sampleRateLabel { parts.append(sampleRateLabel) }
        if let bitRateLabel { parts.append(bitRateLabel) }
        if let channelPictogram { parts.append(channelPictogram == 1 ? "mono" : channelPictogram == 2 ? "stereo" : "\(channelPictogram) channels") }
        switch repeatMode {
        case .off: break
        case .one: parts.append("repeat one")
        case .all: parts.append("repeat all")
        case .switchTracks: parts.append("switch and repeat")
        }
        if isShuffleEnabled == true { parts.append("shuffle on") }
        if isLoopActive == true { parts.append("loop on") }
        parts.append(isPlaying ? "playing" : "paused")
        return parts.joined(separator: ", ")
    }
}

/// A micro-tag printed on the display glass, in one of the K.O. II's three
/// treatments: a solid inverted pill, an outlined chip, or an outlined chip
/// printed dim (an indicator that is present but not lit).
struct TeenageEngineeringDisplayChip: View {
    enum Style { case filled, outlined, dim }

    var text: String
    var style: Style = .outlined
    var palette: TeenageEngineeringPalette.Colors

    static let height: CGFloat = 7

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
    }

    var body: some View {
        Text(text)
            .font(.system(size: 4.5, weight: .heavy, design: .rounded))
            .kerning(0.45)
            .foregroundStyle(style == .filled ? palette.display : palette.displayInk.opacity(style == .dim ? 0.38 : 0.92))
            .padding(.horizontal, 2.5)
            .frame(height: Self.height)
            .background(shape.fill(style == .filled ? palette.displayInk.opacity(0.92) : .clear))
            .overlay {
                if style != .filled {
                    shape.strokeBorder(palette.displayInk.opacity(style == .dim ? 0.3 : 0.7), lineWidth: 0.6)
                }
            }
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// Bare printed text on the glass at chip scale — a value without a box,
/// like the K.O. II's "1.9.3" but at tag size.
struct TeenageEngineeringDisplayText: View {
    var text: String
    var palette: TeenageEngineeringPalette.Colors

    var body: some View {
        Text(text)
            .font(.system(size: 5, weight: .bold, design: .rounded))
            .kerning(0.3)
            .foregroundStyle(palette.displayInk.opacity(0.85))
            .frame(height: TeenageEngineeringDisplayChip.height)
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// Glyph-scale pictograms printed on the glass.
struct TeenageEngineeringDisplayPictogram: View {
    enum Glyph: Equatable {
        /// One ring for mono, two linked rings for stereo, a ring with a
        /// count for anything wider.
        case channels(UInt32)
        case play
        case pause
    }

    var glyph: Glyph
    var palette: TeenageEngineeringPalette.Colors

    var body: some View {
        Canvas { context, size in
            let ink = palette.displayInk.opacity(0.85)
            switch glyph {
            case let .channels(count):
                let d: CGFloat = 5.2
                let y = (size.height - d) / 2
                if count == 1 {
                    context.stroke(Path(ellipseIn: CGRect(x: (size.width - d) / 2, y: y, width: d, height: d)), with: .color(ink), lineWidth: 0.75)
                } else {
                    // Two rings overlapping by a third: the classic stereo mark.
                    let overlap = d * 0.36
                    let left = (size.width - (d * 2 - overlap)) / 2
                    context.stroke(Path(ellipseIn: CGRect(x: left, y: y, width: d, height: d)), with: .color(ink), lineWidth: 0.75)
                    context.stroke(Path(ellipseIn: CGRect(x: left + d - overlap, y: y, width: d, height: d)), with: .color(ink), lineWidth: 0.75)
                }
            case .play:
                var path = Path()
                let h: CGFloat = 5, w: CGFloat = 4.2
                let x = (size.width - w) / 2, y = (size.height - h) / 2
                path.move(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x + w, y: y + h / 2))
                path.addLine(to: CGPoint(x: x, y: y + h))
                path.closeSubpath()
                context.fill(path, with: .color(ink))
            case .pause:
                let h: CGFloat = 5, bar: CGFloat = 1.5, gap: CGFloat = 1.2
                let x = (size.width - bar * 2 - gap) / 2, y = (size.height - h) / 2
                var path = Path()
                path.addRect(CGRect(x: x, y: y, width: bar, height: h))
                path.addRect(CGRect(x: x + bar + gap, y: y, width: bar, height: h))
                context.fill(path, with: .color(ink))
            }
        }
        .frame(width: glyph == .channels(2) ? 10 : 7, height: TeenageEngineeringDisplayChip.height)
        .accessibilityHidden(true)
    }
}

/// The display's one spot of real color: a ring printed on the glass with an
/// LED behind it that lights TE orange while the transport is running. The
/// K.O. II's colored dial glyph, doing a job.
struct TeenageEngineeringDisplayLED: View {
    var isOn: Bool
    var palette: TeenageEngineeringPalette.Colors

    var body: some View {
        ZStack {
            Circle().strokeBorder(palette.displayInk.opacity(0.45), lineWidth: 0.7)
            Circle()
                .fill(palette.accent)
                .shadow(color: palette.accent.opacity(0.85), radius: 1.4)
                .padding(1.6)
                .opacity(isOn ? 1 : 0)
        }
        .frame(width: 7, height: 7)
        .animation(.easeOut(duration: 0.12), value: isOn)
        .accessibilityHidden(true)
    }
}

/// The comparison readout's window contents: the elapsed-time digits as the
/// one large numeral cluster, flanked by two loose columns of tiles — the
/// printed "TIME" tag, the track position and transport glyph on the left;
/// the file's format, rate and channel marks, the loop and repeat tags, and
/// the lit LED on the right. Laid out as a dashboard, not a text field.
struct TeenageEngineeringTimeDisplayContent: View {
    var elapsed: String
    var status: TeenageEngineeringDisplayStatus

    @Environment(\.colorScheme) private var colorScheme

    /// Spacing between tile rows.
    private let rowSpacing: CGFloat = 3
    private let tileSpacing: CGFloat = 3

    var body: some View {
        let palette = TeenageEngineeringPalette.colors(for: colorScheme)

        HStack(alignment: .center, spacing: 0) {
            // Left column: what the digits are, and where we are.
            VStack(alignment: .leading, spacing: rowSpacing) {
                TeenageEngineeringDisplayChip(text: "TIME", style: .filled, palette: palette)
                if let track = status.trackLabel {
                    TeenageEngineeringDisplayChip(text: track, style: .outlined, palette: palette)
                }
                HStack(spacing: tileSpacing) {
                    TeenageEngineeringDisplayPictogram(glyph: status.isPlaying ? .play : .pause, palette: palette)
                    TeenageEngineeringDisplayLED(isOn: status.isPlaying, palette: palette)
                }
            }
            .frame(width: 30, alignment: .leading)
            .padding(.leading, 9)

            SevenSegmentDisplay(text: elapsed, digitHeight: 27)
                .padding(.horizontal, 12)

            // Right column: the file, then the transport modes.
            VStack(alignment: .leading, spacing: rowSpacing) {
                HStack(spacing: tileSpacing) {
                    if status.isBlindListening {
                        TeenageEngineeringDisplayChip(text: "BLIND", style: .filled, palette: palette)
                    } else {
                        if let format = status.formatLabel {
                            TeenageEngineeringDisplayChip(text: format, style: .outlined, palette: palette)
                        }
                        if let rate = status.sampleRateLabel {
                            TeenageEngineeringDisplayText(text: rate, palette: palette)
                        }
                    }
                }
                if status.channelPictogram != nil || status.bitRateLabel != nil {
                    HStack(spacing: tileSpacing) {
                        if let channels = status.channelPictogram {
                            TeenageEngineeringDisplayPictogram(glyph: .channels(channels), palette: palette)
                        }
                        if let bitRate = status.bitRateLabel {
                            TeenageEngineeringDisplayText(text: bitRate, palette: palette)
                        }
                    }
                }
                HStack(spacing: tileSpacing) {
                    TeenageEngineeringDisplayChip(text: "LOOP", style: status.isLoopActive == true ? .filled : .dim, palette: palette)
                    TeenageEngineeringDisplayChip(text: status.repeatLabel, style: status.repeatMode == .off ? .dim : .filled, palette: palette)
                }
            }
            .frame(width: 60, alignment: .leading)
            .padding(.trailing, 8)
        }
        .padding(.trailing, TeenageEngineeringReadoutLayout.stripWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Display Status")
        .accessibilityValue(status.accessibilityDescription)
    }
}

/// The dashboard column at the trailing end of the now-playing window: the
/// elapsed time as seven-segment digits (the same numerals the comparison
/// readout uses, so both windows are one product's display) with the LED
/// beside it, then the file marks, then the position, shuffle and repeat
/// tags. The text lines and progress bar keep the rest of the glass.
struct TeenageEngineeringNowPlayingDashboard: View {
    var elapsed: String
    var status: TeenageEngineeringDisplayStatus

    /// Fixed so the text columns beside it don't re-flow as the time string
    /// or the tiles change; wide enough for `-1:00:00` plus the LED.
    static let width: CGFloat = 96
    /// Gap between the text block and the dashboard.
    static let gap: CGFloat = 8
    /// Below this panel width the window has no glass to spare — the text
    /// lines would fall to a handful of cells — so the dashboard is left off.
    static let minimumPanelWidth: CGFloat = 330

    @Environment(\.colorScheme) private var colorScheme

    private let rowSpacing: CGFloat = 3
    private let tileSpacing: CGFloat = 3

    var body: some View {
        let palette = TeenageEngineeringPalette.colors(for: colorScheme)

        VStack(alignment: .leading, spacing: rowSpacing) {
            HStack(alignment: .center, spacing: 5) {
                SevenSegmentDisplay(text: elapsed, digitHeight: 14)
                TeenageEngineeringDisplayLED(isOn: status.isPlaying, palette: palette)
            }
            HStack(spacing: tileSpacing) {
                if let format = status.formatLabel {
                    TeenageEngineeringDisplayChip(text: format, style: .outlined, palette: palette)
                }
                if let rate = status.sampleRateLabel {
                    TeenageEngineeringDisplayText(text: rate, palette: palette)
                }
                if let channels = status.channelPictogram {
                    TeenageEngineeringDisplayPictogram(glyph: .channels(channels), palette: palette)
                }
            }
            HStack(spacing: tileSpacing) {
                if let track = status.trackLabel {
                    TeenageEngineeringDisplayChip(text: track, style: .outlined, palette: palette)
                }
                if let shuffle = status.isShuffleEnabled {
                    TeenageEngineeringDisplayChip(text: "SHFL", style: shuffle ? .filled : .dim, palette: palette)
                }
                TeenageEngineeringDisplayChip(text: status.repeatLabel, style: status.repeatMode == .off ? .dim : .filled, palette: palette)
            }
        }
        .frame(width: Self.width, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Display Status")
        .accessibilityValue(status.accessibilityDescription)
    }
}

/// The strip beside the display window: "TAKES" silkscreened at the top,
/// a punched speaker grille filling the rest.
struct TeenageEngineeringGrilleStrip: View {
    var palette: TeenageEngineeringPalette.Colors

    private let holeDiameter: CGFloat = 2.2
    private let pitch: CGFloat = 4.4
    /// Top of the grille, below the nameplate.
    private let grilleTop: CGFloat = 15
    private let grilleBottom: CGFloat = 5.5

    var body: some View {
        ZStack(alignment: .top) {
            Text("TAKES")
                .font(.system(size: 5, weight: .black, design: .rounded))
                .kerning(0.6)
                .foregroundStyle(palette.ink)
                .fixedSize()
                .frame(maxWidth: .infinity)
                .padding(.top, 6)

            Canvas { context, size in
                let columns = Int(((size.width - holeDiameter) / pitch).rounded(.down)) + 1
                let rows = Int(((size.height - grilleTop - grilleBottom - holeDiameter) / pitch).rounded(.down)) + 1
                guard columns > 0, rows > 0 else { return }
                let gridWidth = CGFloat(columns - 1) * pitch + holeDiameter
                let gridHeight = CGFloat(rows - 1) * pitch + holeDiameter
                let originX = (size.width - gridWidth) / 2
                let originY = grilleTop + (size.height - grilleTop - grilleBottom - gridHeight) / 2

                var holes = Path()
                var lips = Path()
                for row in 0..<rows {
                    for column in 0..<columns {
                        let rect = CGRect(
                            x: originX + CGFloat(column) * pitch,
                            y: originY + CGFloat(row) * pitch,
                            width: holeDiameter, height: holeDiameter
                        )
                        holes.addEllipse(in: rect)
                        lips.addEllipse(in: rect.offsetBy(dx: 0, dy: 0.6))
                    }
                }
                // Each hole's lower edge catches the light — the punched lip.
                context.fill(lips, with: .color(palette.grilleLip))
                context.fill(holes, with: .color(palette.grilleHole))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Status conversion

extension TeenageEngineeringDisplayStatus {
    /// Comparison mode: the active track's file and the session's transport
    /// toggles.
    init(session: ComparisonSession) {
        isPlaying = session.isPlaying
        trackNumber = session.activeTrackIndex.map { $0 + 1 }
        trackCount = session.tracks.count
        if let track = session.activeTrack?.loadedTrack {
            fileFormat = track.fileFormatDescription
            sampleRate = track.sampleRate
            channelCount = track.channelCount
            bitRate = track.bitRate
        }
        switch session.repeatMode {
        case .off: repeatMode = .off
        case .one: repeatMode = .one
        case .switchAndRepeat: repeatMode = .switchTracks
        }
        isLoopActive = session.loopRegion != nil
        isBlindListening = session.isBlindListeningModeEnabled
    }

    /// Playlist mode: the current version's stored metadata and the
    /// workspace's traversal toggles.
    init(workspace: PlaylistWorkspace, currentItemID: PlaylistItem.ID?, version: PlaylistVersion?, isPlaying: Bool) {
        self.isPlaying = isPlaying
        trackNumber = workspace.items.firstIndex { $0.id == currentItemID }.map { $0 + 1 }
        trackCount = workspace.items.count
        if let metadata = version?.metadata {
            fileFormat = metadata.fileFormatDescription
            sampleRate = metadata.sampleRate
            channelCount = metadata.channelCount
            bitRate = metadata.bitRate
        }
        switch workspace.playlistRepeatMode {
        case .off: repeatMode = .off
        case .one: repeatMode = .one
        case .all: repeatMode = .all
        }
        isShuffleEnabled = workspace.isShuffleEnabled
    }
}
