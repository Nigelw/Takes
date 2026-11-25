import AppKit
import SwiftUI

// MARK: - A2 control-bar readouts

/// The playlist readout's title (spec §5.2): the version's title tag, else
/// its filename without the extension, preserving the source capitalization.
/// Compare has no readout title: its info bar shows the take count, and the
/// active lane and the cover carry the audible version.
enum ControlBarReadoutTitle {
    static func playlist(_ version: PlaylistVersion?) -> String {
        version.map(PlaylistRowText.versionName) ?? ""
    }
}

/// Playlist readout, 41 pt, two lines (spec §5.2): elapsed time, a divider
/// and the playing version's title, over an LED progress meter that is also
/// the seek control.
///
/// Steady playback does no per-frame main-thread work: the elapsed digits are
/// their own leaf and re-render once per displayed second
/// (`playingReadoutText`), the title re-renders only when it changes and
/// scrolls on Core Animation, and the meter steps on a discrete Core
/// Animation keyframe per transport anchor event.
struct PlaylistControlBarReadout: View {
    /// 8 pt above the digits, 6 pt to the meter, 8 pt below it, every edge
    /// on a whole point: 8 + 14 + 6 + 5 + 8 = 41 pt.
    static var height: CGFloat {
        contentTopInset + ControlBarReadoutLine.height + lineSpacing + meterHeight + verticalMargin
    }
    /// v2.9.0's radius scale (11 at 56, 9 at 42), rounded at 41.
    static let cornerRadius: CGFloat = 9
    /// 3 pt cells on a 4 pt pitch: about 80 cells across the 340 pt
    /// readout of a 360 pt window.
    static let meterMetrics = DotMatrixMetrics(dotSize: 3, dotGap: 1, cellGap: 3)
    static let meterHeight: CGFloat = 5
    /// The gap from the digits' bottom to the meter's top.
    static let lineSpacing: CGFloat = 6
    /// The margin above the digits and below the meter.
    static let verticalMargin: CGFloat = 8
    /// Inset from the panel top to the line (the digits' top).
    static var contentTopInset: CGFloat { verticalMargin }
    /// Extra hit area above and below the 5 pt meter, so it is easy to grab.
    static let meterHitOutset: CGFloat = 3

    let controller: PlaybackController
    let title: String
    let seek: (TimeInterval) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Self.lineSpacing) {
            ControlBarReadoutLine(controller: controller, title: title)
            DotMatrixProgressBar(controller: controller, seek: seek, metrics: Self.meterMetrics,
                                 barHeight: Self.meterHeight)
                .frame(height: Self.meterHeight + Self.meterHitOutset * 2)
                .padding(.vertical, -Self.meterHitOutset)
        }
        .padding(.horizontal, ControlBarReadoutLine.horizontalInset)
        .padding(.top, Self.contentTopInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(height: Self.height)
        .readoutGlass(cornerRadius: Self.cornerRadius, reflectionBehindContent: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now Playing")
    }
}

/// The compare info bar's elapsed time (A2 compare info-bar variant
/// §2.2): the seven-segment digits in a 24 pt Glass frame, as wide as its
/// content. The digits are `ControlBarElapsedDigits`, the isolated leaf that
/// re-renders once per displayed second; this frame reads nothing from the
/// controller itself.
struct CompareInfoBarTime: View {
    static let height: CGFloat = 24
    static let cornerRadius: CGFloat = 6
    static let horizontalPadding: CGFloat = 9

    let controller: PlaybackController

    var body: some View {
        ControlBarElapsedDigits(controller: controller, digitHeight: ControlBarReadoutLine.digitHeight, fitsWidth: true)
            .padding(.horizontal, Self.horizontalPadding)
            .frame(height: Self.height)
            .readoutGlass(cornerRadius: Self.cornerRadius)
            // Informational, as the readouts are.
            .allowsHitTesting(false)
    }
}

/// The playlist readout's line: seven-segment elapsed time, a faint divider,
/// then the title in the dot-matrix face, scrolling when it overflows.
struct ControlBarReadoutLine: View {
    static let horizontalInset: CGFloat = 10
    static let digitHeight: CGFloat = 14
    static let spacing: CGFloat = 9
    /// The title face, matched to the canvas's 16 px Doto: 1 pt dots with
    /// 1 pt gaps give 13 pt capitals on an 11 pt advance, just under the
    /// 14 pt digits. Whole points, so every dot lands on the pixel grid.
    static let titleMetrics = DotMatrixMetrics(dotSize: 1, dotGap: 1, cellGap: 2)
    /// The line is as tall as the digits. The 13 pt title sits on their
    /// bottom edge, 1 pt below their top, so both start on whole points.
    static var height: CGFloat { digitHeight }

    let controller: PlaybackController
    let title: String

    var body: some View {
        HStack(alignment: .bottom, spacing: Self.spacing) {
            ControlBarElapsedDigits(controller: controller, digitHeight: Self.digitHeight)
            Rectangle()
                .fill(Theme.readoutGlow.opacity(0.25))
                .frame(width: 1, height: Self.digitHeight)
                .accessibilityHidden(true)
            ControlBarReadoutTitleField(title: title)
        }
        .frame(height: Self.height)
        // Informational: clicks fall through to the window drag area, so
        // the readout isn't a dead spot in the titlebar.
        .allowsHitTesting(false)
    }
}

/// The elapsed-time digits, isolated so the once-per-second text change
/// re-renders only this leaf. While playing the text comes from
/// `playingReadoutText`, which changes only when the displayed second rolls
/// over; while paused it derives from `transportPosition`, written only at
/// anchor events. Shared by the playlist readout and the compare info bar;
/// nothing else in either reads `playingReadoutText` or the transport
/// position.
struct ControlBarElapsedDigits: View {
    let controller: PlaybackController
    let digitHeight: CGFloat
    var fitsWidth = false

    var body: some View {
        let elapsed = controller.session.isPlaying
            ? controller.playingReadoutText
            : controller.session.transportPosition.formattedSignedTimestamp
        Group {
            if fitsWidth {
                ViewThatFits(in: .horizontal) {
                    SevenSegmentDisplay(text: elapsed, digitHeight: digitHeight)
                    GeometryReader { proxy in
                        let naturalWidth = SevenSegmentDisplay.width(of: elapsed, digitHeight: digitHeight)
                        let scale = min(proxy.size.width / naturalWidth, 1)
                        if scale > 0 {
                            SevenSegmentDisplay(text: elapsed, digitHeight: digitHeight * scale)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(height: digitHeight)
                }
            } else {
                SevenSegmentDisplay(text: elapsed, digitHeight: digitHeight)
            }
        }
            .accessibilityElement()
            .accessibilityLabel("Elapsed Time")
            .accessibilityValue(elapsed)
    }
}

/// The title takes whatever width the line leaves it, as whole character
/// cells; a title wider than that scrolls (`DotMatrixMarqueeText`).
///
/// The field's width comes only from the line, never from the text: the
/// cells draw in an overlay. Sized by its own cells, the field could only
/// grow — once laid out wide (as when SwiftUI restores another window frame
/// before the launch code applies the A2 one), its cell count held that
/// width and pushed the readout past the window.
private struct ControlBarReadoutTitleField: View {
    let title: String
    private let metrics = ControlBarReadoutLine.titleMetrics
    @State private var columns = 1

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: metrics.lineHeight)
            .overlay(alignment: .leading) {
                DotMatrixMarqueeText(text: title.isEmpty ? "READY" : title, columns: columns, metrics: metrics)
                    .opacity(title.isEmpty ? 0.65 : 1)
            }
            .onGeometryChange(for: Int.self) { proxy in
                // A line of n cells is n advances minus the trailing cell gap.
                max(Int(((proxy.size.width + metrics.cellGap) / metrics.cellAdvance).rounded(.down)), 1)
            } action: { columns = $0 }
            .accessibilityElement()
            .accessibilityLabel("Title")
            .accessibilityValue(title.isEmpty ? "No track loaded" : title)
    }
}

// MARK: - Dot-matrix character display

/// Geometry shared by the text lines and the progress bar so their pixel
/// pitches match, the way one LCD controller drives the whole panel. The
/// defaults (2 pt dots) are the large face; the A2 readout titles use
/// `ControlBarReadoutLine.titleMetrics`.
///
/// Every value is a whole number of points. A 2pt dot is a 2×2 block of
/// device pixels at 1x and 4×4 at 2x, the 1pt gap one pixel and two, so the
/// dots, the gaps between them and every derived length (cell advance, line
/// height, bleed) land on the pixel grid at any backing scale without
/// per-scale snapping — and the layout is identical on every display.
/// Fractional values here reintroduce the anti-aliased smear this display
/// had before (a 1.3pt dot with a 0.4pt gap cannot be drawn at 1x at all).
struct DotMatrixMetrics: Equatable {
    /// Side of one square pixel.
    var dotSize: CGFloat = 2
    /// Gap between pixels within a character cell.
    var dotGap: CGFloat = 1
    /// Gap between character cells: one blank pixel column (dot plus gap).
    var cellGap: CGFloat = 3

    var dotPitch: CGFloat { dotSize + dotGap }
    var cellWidth: CGFloat { dotSize * 5 + dotGap * 4 }
    var cellAdvance: CGFloat { cellWidth + cellGap }
    var lineHeight: CGFloat { dotSize * 7 + dotGap * 6 }

    /// Width of a line of `columns` cells, with no trailing cell gap.
    func lineWidth(columns: Int) -> CGFloat {
        cellWidth * CGFloat(columns) + cellGap * CGFloat(max(columns - 1, 0))
    }
}

/// Draws a fixed number of 5x7 character cells as a dot-matrix LCD: only the
/// glyph's lit pixels are drawn, on the bare glass. Understands printable
/// ASCII; other characters are folded to ASCII where possible and otherwise
/// render as a blank cell. Text longer than the cell count is truncated with
/// an ellipsis.
struct DotMatrixDisplay: View {
    let text: String
    let columns: Int
    var metrics = DotMatrixMetrics()

    /// Light mode renders as an LCD (dark ink pixels that cast a soft shadow
    /// onto the pale glass), dark mode as an LED matrix (glowing pixels).
    @Environment(\.colorScheme) private var colorScheme

    /// Extra canvas margin so the glow blur can trail off instead of being
    /// clipped at the layout edge; trimmed back out with negative padding.
    private var bleed: CGFloat { metrics.dotSize * 2 }

    private var intrinsicWidth: CGFloat { metrics.lineWidth(columns: columns) }

    var body: some View {
        let glyphs = Array(Self.fit(text, columns: columns))
        Canvas { context, _ in
            Self.draw(glyphs: glyphs, columns: columns, metrics: metrics, colorScheme: colorScheme,
                      bleed: bleed, into: context)
        }
        .frame(width: intrinsicWidth + bleed * 2, height: metrics.lineHeight + bleed * 2)
        .padding(-bleed)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Draws `glyphs` into `columns` character cells starting at `(bleed,
    /// bleed)`, in the LED/LCD treatment matching `colorScheme`. Shared by the
    /// static `Canvas` above and the marquee's offscreen bitmap rendering, so
    /// both paths draw pixels identically.
    static func draw(glyphs: [Character], columns: Int, metrics: DotMatrixMetrics, colorScheme: ColorScheme,
                      bleed: CGFloat, into context: GraphicsContext) {
        var context = context
        context.translateBy(x: bleed, y: bleed)

        // Square dots: with whole-point metrics every dot edge is on the
        // pixel grid, and a corner radius would only anti-alias it off again.
        var lit = Path()
        let dotRect = CGRect(x: 0, y: 0, width: metrics.dotSize, height: metrics.dotSize)
        for column in 0..<columns {
            let cellX = CGFloat(column) * metrics.cellAdvance
            let rows = column < glyphs.count ? Self.rows(for: glyphs[column]) : Self.blankRows
            for row in 0..<7 {
                let bits = rows[row]
                for pixel in 0..<5 where bits & (0x10 >> pixel) != 0 {
                    let origin = CGPoint(x: cellX + CGFloat(pixel) * metrics.dotPitch, y: CGFloat(row) * metrics.dotPitch)
                    lit.addRect(dotRect.offsetBy(dx: origin.x, dy: origin.y))
                }
            }
        }

        // Resolve the dynamic glow color to a concrete color forced to
        // `colorScheme`, rather than filling with the raw dynamic `Color`.
        // `Theme.readoutGlow`'s `NSColor(name:dynamicProvider:)` resolves
        // against whatever `NSAppearance` is ambient at *draw* time, not
        // against this `colorScheme` parameter. That's correct by accident
        // for the live `Canvas` path (it really is attached to the window),
        // but the offscreen `ImageRenderer` path used by the marquee bitmap
        // has no real window backing it, so it resolves against some
        // default appearance regardless of `colorScheme` — producing the
        // light-mode brown/orange even when rendering for dark mode. Forcing
        // resolution through `performAsCurrentDrawingAppearance` here makes
        // both call sites correct explicitly, not by accident of context.
        let ink = colorScheme == .light ? Theme.lcdTitleInk : resolvedGlowColor(for: colorScheme)

        if colorScheme == .dark {
            // LED: a soft halo of the pixel color under the crisp fill.
            var glow = context
            glow.addFilter(.blur(radius: metrics.dotSize * 1.1))
            glow.fill(lit, with: .color(ink.opacity(0.9)))
        } else {
            // LCD: the ink layer floats just above the backlight, dropping
            // a tight shadow down-right onto the glass. Half a point: one
            // device pixel at 2x, and a faint tint of the gap pixel at 1x
            // (the ink itself stays crisp; the shade is a separate fill).
            var shade = context
            shade.translateBy(x: 0.5, y: 0.5)
            shade.addFilter(.blur(radius: metrics.dotSize * 0.3))
            shade.fill(lit, with: .color(.black.opacity(0.30)))
        }
        // A translucent rim adds weight between dots. Paint the opaque
        // squares last so their edges still land on the original grid.
        let rimOpacity = colorScheme == .light ? 0.44 : 0.35
        context.stroke(lit, with: .color(ink.opacity(rimOpacity)), lineWidth: metrics.dotGap)
        context.fill(lit, with: .color(ink))
    }

    /// Resolves `Theme.readoutGlow` to a concrete, non-dynamic `Color` forced
    /// to `colorScheme`'s appearance rather than whatever appearance happens
    /// to be ambient at the call site. See `draw(...)` above for why this
    /// matters for the offscreen marquee bitmap path.
    ///
    /// `NSColor(Theme.readoutGlow)` alone isn't enough: it hands back the
    /// same dynamic, catalog-backed `NSColor` `Theme.dynamic` built (its
    /// provider closure still runs lazily, at whatever moment something
    /// later asks for concrete components), so merely constructing it inside
    /// `performAsCurrentDrawingAppearance` doesn't bake anything in — the
    /// later, uncontrolled resolution is exactly what produced the wrong
    /// (light-mode) color intermittently. `usingColorSpace(_:)` forces
    /// immediate resolution against the appearance active *right now* and
    /// returns a plain concrete color that can no longer re-resolve later.
    private static func resolvedGlowColor(for colorScheme: ColorScheme) -> Color {
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua) ?? NSAppearance(named: .aqua)!
        var resolved = NSColor.controlAccentColor
        appearance.performAsCurrentDrawingAppearance {
            let dynamic = NSColor(Theme.readoutGlow)
            resolved = dynamic.usingColorSpace(.sRGB) ?? dynamic
        }
        return Color(resolved)
    }

    /// Renders `text` (already folded/fit by the caller) at its own natural
    /// width — not clamped to any display's `columns` — into an offscreen
    /// bitmap, for the marquee's scrolling layer. Returns `nil` if rendering
    /// fails (e.g. off-main-thread misuse); callers should skip animating
    /// rather than crash.
    static func renderedBitmap(text: String, metrics: DotMatrixMetrics, colorScheme: ColorScheme,
                                bleed: CGFloat, scale: CGFloat) -> (image: CGImage, width: CGFloat, height: CGFloat)? {
        let glyphs = Array(text)
        let columns = glyphs.count
        let width = metrics.lineWidth(columns: columns) + bleed * 2
        let height = metrics.lineHeight + bleed * 2
        let content = Canvas { context, _ in
            Self.draw(glyphs: glyphs, columns: columns, metrics: metrics, colorScheme: colorScheme,
                      bleed: bleed, into: context)
        }
        .frame(width: width, height: height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        // With whole-point metrics and a whole-point `bleed`, `width * scale`
        // and `height * scale` are whole pixel counts at 1x and 2x, so the
        // rasterized size matches the request. Still return the *actual*
        // size from the image so the caller's layer `bounds` can never
        // disagree with the bitmap (which would make Core Animation resample
        // it), e.g. on a non-integral backing scale.
        let actualWidth = CGFloat(image.width) / scale
        let actualHeight = CGFloat(image.height) / scale
        return (image, actualWidth, actualHeight)
    }

    // MARK: Text preparation

    /// Folds the string to the glyph set and truncates it to `columns` cells,
    /// ending in an ellipsis when it had to cut.
    static func fit(_ text: String, columns: Int) -> String {
        let folded = fold(text)
        guard folded.count > columns else { return folded }
        guard columns > 0 else { return "" }
        return String(folded.prefix(columns - 1)) + "\u{2026}"
    }

    /// Whether `text` would be truncated by `fit(_:columns:)` — the marquee's
    /// trigger for scrolling instead of a static ellipsis.
    static func overflows(_ text: String, columns: Int) -> Bool {
        fold(text).count > columns
    }

    /// Strips diacritics and maps common typographic punctuation onto the
    /// ASCII cells so real tag text (`Café`, `Don’t`, `Rock – Live`) stays
    /// legible. Newlines and tabs collapse to spaces.
    static func fold(_ text: String) -> String {
        let base = text.folding(options: [.diacriticInsensitive], locale: nil)
        return String(base.map { character -> Character in
            switch character {
            case "\u{2018}", "\u{2019}", "\u{2032}": return "'"
            case "\u{201C}", "\u{201D}", "\u{2033}": return "\""
            case "\u{2013}", "\u{2014}", "\u{2212}": return "-"
            case "\n", "\r", "\t": return " "
            default: return character
            }
        })
    }

    // MARK: 5x7 font

    private static let blankRows: [UInt8] = [0, 0, 0, 0, 0, 0, 0]

    private static func rows(for glyph: Character) -> [UInt8] {
        font[glyph] ?? blankRows
    }

    /// Seven rows per glyph, top to bottom; each row is five bits with the
    /// leftmost pixel in bit 4. Based on the classic HD44780 character set.
    private static let font: [Character: [UInt8]] = [
        " ": [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
        "!": [0x04, 0x04, 0x04, 0x04, 0x00, 0x00, 0x04],
        "\"": [0x0A, 0x0A, 0x0A, 0x00, 0x00, 0x00, 0x00],
        "#": [0x0A, 0x0A, 0x1F, 0x0A, 0x1F, 0x0A, 0x0A],
        "$": [0x04, 0x0F, 0x14, 0x0E, 0x05, 0x1E, 0x04],
        "%": [0x18, 0x19, 0x02, 0x04, 0x08, 0x13, 0x03],
        "&": [0x0C, 0x12, 0x14, 0x08, 0x15, 0x12, 0x0D],
        "'": [0x0C, 0x04, 0x08, 0x00, 0x00, 0x00, 0x00],
        "(": [0x02, 0x04, 0x08, 0x08, 0x08, 0x04, 0x02],
        ")": [0x08, 0x04, 0x02, 0x02, 0x02, 0x04, 0x08],
        "*": [0x00, 0x04, 0x15, 0x0E, 0x15, 0x04, 0x00],
        "+": [0x00, 0x04, 0x04, 0x1F, 0x04, 0x04, 0x00],
        ",": [0x00, 0x00, 0x00, 0x00, 0x0C, 0x04, 0x08],
        "-": [0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00],
        ".": [0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C],
        "/": [0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x00],
        "0": [0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E],
        "1": [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E],
        "2": [0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F],
        "3": [0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E],
        "4": [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02],
        "5": [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E],
        "6": [0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E],
        "7": [0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08],
        "8": [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E],
        "9": [0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C],
        ":": [0x00, 0x0C, 0x0C, 0x00, 0x0C, 0x0C, 0x00],
        ";": [0x00, 0x0C, 0x0C, 0x00, 0x0C, 0x04, 0x08],
        "<": [0x02, 0x04, 0x08, 0x10, 0x08, 0x04, 0x02],
        "=": [0x00, 0x00, 0x1F, 0x00, 0x1F, 0x00, 0x00],
        ">": [0x08, 0x04, 0x02, 0x01, 0x02, 0x04, 0x08],
        "?": [0x0E, 0x11, 0x01, 0x02, 0x04, 0x00, 0x04],
        "@": [0x0E, 0x11, 0x01, 0x0D, 0x15, 0x15, 0x0E],
        "A": [0x0E, 0x11, 0x11, 0x11, 0x1F, 0x11, 0x11],
        "B": [0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E],
        "C": [0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E],
        "D": [0x1C, 0x12, 0x11, 0x11, 0x11, 0x12, 0x1C],
        "E": [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F],
        "F": [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10],
        "G": [0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F],
        "H": [0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
        "I": [0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E],
        "J": [0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C],
        "K": [0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11],
        "L": [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F],
        "M": [0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11],
        "N": [0x11, 0x11, 0x19, 0x15, 0x13, 0x11, 0x11],
        "O": [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
        "P": [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10],
        "Q": [0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D],
        "R": [0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11],
        "S": [0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E],
        "T": [0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04],
        "U": [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
        "V": [0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04],
        "W": [0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0A],
        "X": [0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11],
        "Y": [0x11, 0x11, 0x11, 0x0A, 0x04, 0x04, 0x04],
        "Z": [0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F],
        "[": [0x0E, 0x08, 0x08, 0x08, 0x08, 0x08, 0x0E],
        "\\": [0x00, 0x10, 0x08, 0x04, 0x02, 0x01, 0x00],
        "]": [0x0E, 0x02, 0x02, 0x02, 0x02, 0x02, 0x0E],
        "^": [0x04, 0x0A, 0x11, 0x00, 0x00, 0x00, 0x00],
        "_": [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1F],
        "`": [0x08, 0x04, 0x02, 0x00, 0x00, 0x00, 0x00],
        "a": [0x00, 0x00, 0x0E, 0x01, 0x0F, 0x11, 0x0F],
        "b": [0x10, 0x10, 0x16, 0x19, 0x11, 0x11, 0x1E],
        "c": [0x00, 0x00, 0x0E, 0x10, 0x10, 0x11, 0x0E],
        "d": [0x01, 0x01, 0x0D, 0x13, 0x11, 0x11, 0x0F],
        "e": [0x00, 0x00, 0x0E, 0x11, 0x1F, 0x10, 0x0E],
        "f": [0x06, 0x09, 0x08, 0x1C, 0x08, 0x08, 0x08],
        "g": [0x00, 0x0F, 0x11, 0x11, 0x0F, 0x01, 0x0E],
        "h": [0x10, 0x10, 0x16, 0x19, 0x11, 0x11, 0x11],
        "i": [0x04, 0x00, 0x0C, 0x04, 0x04, 0x04, 0x0E],
        "j": [0x02, 0x00, 0x06, 0x02, 0x02, 0x12, 0x0C],
        "k": [0x10, 0x10, 0x12, 0x14, 0x18, 0x14, 0x12],
        "l": [0x0C, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E],
        "m": [0x00, 0x00, 0x1A, 0x15, 0x15, 0x11, 0x11],
        "n": [0x00, 0x00, 0x16, 0x19, 0x11, 0x11, 0x11],
        "o": [0x00, 0x00, 0x0E, 0x11, 0x11, 0x11, 0x0E],
        "p": [0x00, 0x00, 0x1E, 0x11, 0x1E, 0x10, 0x10],
        "q": [0x00, 0x00, 0x0D, 0x13, 0x0F, 0x01, 0x01],
        "r": [0x00, 0x00, 0x16, 0x19, 0x10, 0x10, 0x10],
        "s": [0x00, 0x00, 0x0E, 0x10, 0x0E, 0x01, 0x1E],
        "t": [0x08, 0x08, 0x1C, 0x08, 0x08, 0x09, 0x06],
        "u": [0x00, 0x00, 0x11, 0x11, 0x11, 0x13, 0x0D],
        "v": [0x00, 0x00, 0x11, 0x11, 0x11, 0x0A, 0x04],
        "w": [0x00, 0x00, 0x11, 0x11, 0x15, 0x15, 0x0A],
        "x": [0x00, 0x00, 0x11, 0x0A, 0x04, 0x0A, 0x11],
        "y": [0x00, 0x00, 0x11, 0x11, 0x0F, 0x01, 0x0E],
        "z": [0x00, 0x00, 0x1F, 0x02, 0x04, 0x08, 0x1F],
        "{": [0x02, 0x04, 0x04, 0x08, 0x04, 0x04, 0x02],
        "|": [0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04],
        "}": [0x08, 0x04, 0x04, 0x02, 0x04, 0x04, 0x08],
        "~": [0x00, 0x08, 0x15, 0x02, 0x00, 0x00, 0x00],
        "\u{2026}": [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x15],
    ]
}

// MARK: - Marquee text

/// A `DotMatrixDisplay` line that scrolls (car-stereo marquee style) instead
/// of truncating when its text doesn't fit `columns` cells. Text that fits
/// renders exactly as a static `DotMatrixDisplay` — the scrolling machinery
/// only exists for lines that actually overflow, so the elapsed-time field
/// (which never overflows its fixed 7 columns) never pays for it.
struct DotMatrixMarqueeText: View {
    let text: String
    let columns: Int
    var metrics = DotMatrixMetrics()
    /// A loop period shared with a sibling marquee line (e.g. the title and
    /// artist—album lines of a two-line readout), so both lines
    /// start their pause/scroll cycles in lockstep instead of drifting.
    /// `nil` lets this line use its own natural period.
    var sharedPeriod: CFTimeInterval?

    var body: some View {
        if DotMatrixDisplay.overflows(text, columns: columns) {
            DotMatrixMarqueeDisplay(text: text, columns: columns, metrics: metrics, sharedPeriod: sharedPeriod)
                .frame(width: metrics.lineWidth(columns: columns), height: metrics.lineHeight)
        } else {
            DotMatrixDisplay(text: text, columns: columns, metrics: metrics)
        }
    }
}

/// The scrolling half of `DotMatrixMarqueeText`: an `NSView` whose layer
/// holds one offscreen-rendered bitmap of the text rendered as **two
/// back-to-back copies with a gap** between them. A `CAKeyframeAnimation`
/// slides that layer strictly leftward, by exactly one "text + gap" cycle
/// width, then holds — never scrolling back right. Because the second copy
/// is pixel-identical to the first, the view after one full cycle looks
/// exactly like it did at the start, so the keyframe animation's repeat
/// (which snaps the layer back to its starting position) is invisible: a
/// seamless one-directional ticker with no reverse leg. Entirely on Core
/// Animation's own clock — once armed, this does zero per-frame
/// SwiftUI/main-thread work, matching `DotMatrixProgressView`'s use of
/// `CABasicAnimation` for the progress fill.
///
/// Re-armed only when the text, column count, metrics, shared period, color
/// scheme, or the reduced-motion preference changes — not per frame, not on
/// a timer.
struct DotMatrixMarqueeDisplay: NSViewRepresentable {
    let text: String
    let columns: Int
    var metrics = DotMatrixMetrics()
    var sharedPeriod: CFTimeInterval?

    func makeNSView(context: Context) -> DotMatrixMarqueeView { DotMatrixMarqueeView() }
    func updateNSView(_ view: DotMatrixMarqueeView, context: Context) {
        view.configure(text: text, columns: columns, metrics: metrics, sharedPeriod: sharedPeriod,
                       reduceMotion: context.environment.accessibilityReduceMotion)
    }
}

final class DotMatrixMarqueeView: NSView {
    private let content = CALayer()
    private var text = ""
    private var columns = 0
    private var metrics = DotMatrixMetrics()
    private var sharedPeriod: CFTimeInterval?
    private var reduceMotion = false

    /// Pixels/second the text travels. Slow, legible, LCD-marquee pace.
    private static let scrollSpeed: CGFloat = 32
    /// Rest at the start of each cycle before the scroll starts.
    private static let pause: CFTimeInterval = 2.4
    /// Blank cells separating the two back-to-back copies of the text in the
    /// ticker bitmap.
    private static let separatorColumns = 4
    private static let separator = String(repeating: " ", count: separatorColumns)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        content.anchorPoint = CGPoint(x: 0, y: 0)
        content.contentsGravity = .topLeft
        layer?.addSublayer(content)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text: String, columns: Int, metrics: DotMatrixMetrics, sharedPeriod: CFTimeInterval?,
                   reduceMotion: Bool) {
        let unchanged = text == self.text && columns == self.columns && metrics == self.metrics
            && sharedPeriod == self.sharedPeriod && reduceMotion == self.reduceMotion
        self.text = text; self.columns = columns; self.metrics = metrics
        self.sharedPeriod = sharedPeriod; self.reduceMotion = reduceMotion
        guard !unchanged else { return }
        redraw()
    }

    override func layout() {
        super.layout()
        redraw()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redraw()
    }

    /// `redraw()` can run before the view has a window (e.g. an early
    /// `configure()`/`layout()` call during initial SwiftUI attachment), at
    /// which point `window?.backingScaleFactor` falls back to a guessed `2`.
    /// If the real display isn't 2x, that guess bakes a wrong pixel density
    /// into the bitmap, and `configure()`'s `unchanged` guard (which doesn't
    /// consider window/scale) would otherwise never trigger a fresh render
    /// once the window — and its real scale — become available. Redraw
    /// unconditionally whenever the window changes so the bitmap is always
    /// re-rasterized at the real backing scale.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(windowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(windowResignedKey(_:)), name: NSWindow.didResignKeyNotification, object: window)
        }
        setMarqueePaused(window?.isKeyWindow != true)
        redraw()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            let center = NotificationCenter.default
            center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
            center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func windowBecameKey(_ notification: Notification) { setMarqueePaused(false) }
    @objc private func windowResignedKey(_ notification: Notification) { setMarqueePaused(true) }

    /// Freeze the bitmap's local clock so returning to the window continues
    /// the same scroll, including any remaining pause before it starts.
    private func setMarqueePaused(_ paused: Bool) {
        guard paused != (content.speed == 0) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if paused {
            let localTime = content.convertTime(CACurrentMediaTime(), from: nil)
            content.speed = 0
            content.timeOffset = localTime
        } else {
            let pausedTime = content.timeOffset
            content.speed = 1
            content.timeOffset = 0
            content.beginTime = 0
            content.beginTime = content.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        }
        CATransaction.commit()
    }

    private var colorScheme: ColorScheme {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    /// The natural timing this line's own content needs to scroll once
    /// through at `scrollSpeed`, independent of any view instance — usable
    /// both here and by a parent view
    /// computing a shared period across sibling lines. `nil` when `text`
    /// doesn't overflow `columns` at all, i.e. no marquee is needed.
    ///
    /// `cycleWidth` is the width, in points, of one "text + gap" ticker
    /// cycle — the distance the layer scrolls before its content repeats.
    static func naturalTiming(text: String, columns: Int, metrics: DotMatrixMetrics)
        -> (cycleWidth: CGFloat, scrollDuration: CFTimeInterval, period: CFTimeInterval)? {
        let baseText = DotMatrixDisplay.fold(text)
        let textWidth = metrics.lineWidth(columns: baseText.count)
        let visibleWidth = metrics.lineWidth(columns: columns)
        guard textWidth > visibleWidth else { return nil }
        // The distance to scroll for one full cycle must match the pixel
        // offset, in the doubled ticker bitmap, from the first copy's start
        // to the second copy's start. `draw(glyphs:columns:...)` places
        // column `n` at `n * cellAdvance` — a plain per-cell pitch, with no
        // trailing-gap trim. `lineWidth(columns:)` measures rendered content
        // width and *subtracts* one trailing `cellGap` (there's no gap after
        // the last cell of a line), so using it here would undercount the
        // true copy-to-copy offset by exactly `cellGap`. That mismatch is
        // invisible while the animation holds (same wrong value the whole
        // time) but pops the layer by `cellGap` points at every repeat/wrap,
        // when the keyframe animation loops from its held end value back to
        // its start value — which is supposed to look seamless because the
        // second copy is pixel-identical to the first, but only lines up
        // when the scroll distance is the exact copy-to-copy pitch.
        let cycleWidth = CGFloat(baseText.count + separatorColumns) * metrics.cellAdvance
        let scrollDuration = max(CFTimeInterval(cycleWidth / scrollSpeed), 0.1)
        return (cycleWidth, scrollDuration, pause + scrollDuration)
    }

    private static func snapped(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }

    /// Where the bitmap layer sits at rest: its bleed margin pulled outside
    /// the view so the first glyph's top-left lands exactly at the view's
    /// top-left, the way the static `DotMatrixDisplay` places its `Canvas`
    /// (`.padding(-bleed)`). Both coordinates are snapped to the device pixel
    /// grid, because a bitmap layer at a fractional position is bilinearly
    /// resampled by Core Animation: every dot edge smears across two pixels,
    /// which is the residual softness the static `Canvas` path (drawn
    /// straight into the window's backing store) never showed.
    ///
    /// The glyph is placed by its *top* edge, not by centering the bitmap:
    /// the bitmap's rasterized height is a whole pixel count that can differ
    /// from the requested point height, so centering would shift the glyph
    /// by half that difference and clip its bottom row against the view's
    /// `masksToBounds`. With whole-point metrics: bleed 4pt, bitmap
    /// 20 + 8 = 28pt, position `20 + 4 − 28 = −4`, glyph top at
    /// `−4 + 28 − 4 = 20` (the view's top) and glyph bottom at `0` —
    /// nothing clipped.
    private func restingPosition(bleed: CGFloat, scale: CGFloat) -> CGPoint {
        CGPoint(x: Self.snapped(-bleed, scale: scale),
                y: Self.snapped(bounds.height + bleed - content.bounds.height, scale: scale))
    }

    private func redraw() {
        guard columns > 0, bounds.width > 0 else { return }
        content.removeAnimation(forKey: "marquee")

        let scale = window?.backingScaleFactor ?? 2
        // The bleed is a whole number of points (`dotSize` is), so the glyph
        // sits at an integer pixel row and column inside the bitmap and
        // `restingPosition` can align it to the view edge exactly. Snapped
        // anyway for non-integral backing scales.
        let bleed = Self.snapped(metrics.dotSize * 2, scale: scale)

        guard !reduceMotion, let timing = Self.naturalTiming(text: text, columns: columns, metrics: metrics) else {
            // Either motion is reduced, or the text fits after all (columns
            // shrank) — render the plain fitted text with no animation.
            let displayText = DotMatrixDisplay.fit(text, columns: columns)
            guard let (image, bitmapWidth, bitmapHeight) = DotMatrixDisplay.renderedBitmap(
                text: displayText, metrics: metrics, colorScheme: colorScheme, bleed: bleed, scale: scale
            ) else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            content.contentsScale = scale
            // Bounds come from the bitmap's own actual pixel dimensions
            // (divided back to points by the same `scale`), never a
            // separately-computed point size — that guarantees `bounds` and
            // the rasterized image agree exactly, so Core Animation displays
            // the bitmap at 1:1 with no implicit resampling.
            content.bounds = CGRect(x: 0, y: 0, width: bitmapWidth, height: bitmapHeight)
            content.contents = image
            content.position = restingPosition(bleed: bleed, scale: scale)
            CATransaction.commit()
            return
        }

        // Two back-to-back copies of the text with a gap, so scrolling
        // exactly one cycle-width leftward lands on a visually identical
        // frame (the second copy takes the first copy's place).
        let baseText = DotMatrixDisplay.fold(text)
        let doubledText = baseText + Self.separator + baseText
        guard let (image, bitmapWidth, bitmapHeight) = DotMatrixDisplay.renderedBitmap(
            text: doubledText, metrics: metrics, colorScheme: colorScheme, bleed: bleed, scale: scale
        ) else { return }

        CATransaction.begin(); CATransaction.setDisableActions(true)
        content.contentsScale = scale
        // See the static-text branch above: bounds derived from the actual
        // rasterized image, not a recomputed point size.
        content.bounds = CGRect(x: 0, y: 0, width: bitmapWidth, height: bitmapHeight)
        content.contents = image
        // Vertically aligned to the view's top edge (see `restingPosition`);
        // horizontally the animation below positions it.
        content.position = restingPosition(bleed: bleed, scale: scale)

        let startX = content.position.x
        // The end-of-cycle hold is also snapped to the device grid so the
        // second copy never parks at a sub-pixel offset (resampled blurry)
        // for the whole hold. With whole-point `cellAdvance` this is a no-op
        // at 1x and 2x; it matters only on non-integral backing scales.
        let endX = Self.snapped(startX - timing.cycleWidth, scale: scale)
        // Use the caller-supplied shared period when it's longer than this
        // line's own natural period, so a shorter line pauses at its
        // end-of-cycle (== start-of-cycle) position and waits for a slower
        // sibling line rather than looping ahead of it. Scroll *speed* never
        // changes — only how long the line holds before repeating.
        let total = max(sharedPeriod ?? timing.period, timing.period)
        let animation = CAKeyframeAnimation(keyPath: "position.x")
        animation.values = [startX, startX, endX, endX]
        animation.keyTimes = [
            0,
            NSNumber(value: Self.pause / total),
            NSNumber(value: (Self.pause + timing.scrollDuration) / total),
            1,
        ]
        animation.duration = total
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        content.add(animation, forKey: "marquee")
        CATransaction.commit()
    }
}

// MARK: - Progress bar

/// Segmented LED progress bar: a row of pixel-pitch blocks across the full
/// width, all drawn dim in their "off" state, lit from the left up to the
/// current position. In dark appearance the lit run glows and the leading
/// cell glows brighter (the canvas's LED). Only transport anchor events
/// update this leaf; Core Animation steps the lit run between anchors, and
/// native input / accessibility write seeks back to transport.
struct DotMatrixProgressBar: NSViewRepresentable {
    let controller: PlaybackController
    let seek: (TimeInterval) -> Void
    var metrics = DotMatrixMetrics()
    /// Height of the segments — independent of `metrics`' dot pitch, which
    /// only governs the segments' horizontal width/spacing.
    var barHeight: CGFloat

    func makeNSView(context: Context) -> DotMatrixProgressView { DotMatrixProgressView() }
    func updateNSView(_ view: DotMatrixProgressView, context: Context) {
        _ = controller.session.transportPosition
        view.configure(position: controller.displayTransportPosition(), duration: controller.session.duration,
                       playing: controller.session.isPlaying, metrics: metrics, barHeight: barHeight,
                       seek: seek)
    }
}

final class DotMatrixProgressView: NSView {
    /// The "off" segments: a shorter, dim bar under each block of `blocks`,
    /// so the whole scrubbable extent reads as an LCD bar graph with every
    /// segment present and only the leading ones lit.
    private let rail = CAShapeLayer()
    /// Dark appearance's LED glow, under the cells: a pre-blurred image of
    /// every cell's halo, clipped to the lit run by its container's width
    /// (stepped with the fill), and a brighter halo for the leading cell
    /// (stepped with the head). Static images, so the glow costs no shadow
    /// rendering per frame.
    private let runGlowClip = CALayer()
    private let runGlow = CALayer()
    private let headGlowClip = CALayer()
    private let headGlow = CALayer()
    private var glowCacheKey: GlowCacheKey?
    private let track = CALayer()
    private let fill = CALayer()
    /// The leading lit element, drawn brighter than the rest of the run
    /// (spec §5.2). One element slot wide, right-anchored at the fill's edge
    /// and stepped by the same discrete keyframes, inside the same mask.
    private let head = CALayer()
    private let blocks = CAShapeLayer()
    private var metrics = DotMatrixMetrics()
    private var barHeight: CGFloat = 0
    private var duration: TimeInterval = 0
    private var position: TimeInterval = 0
    private var playing = false
    private var anchorTime: TimeInterval = 0
    private var seek: (TimeInterval) -> Void = { _ in }
    private var hoverArea: NSTrackingArea?
    private var isHovered = false
    override var acceptsFirstResponder: Bool { true }
    /// A click takes focus from a text field, but the meter has no keyboard
    /// control, so Tab never stops on it.
    override var canBecomeKeyView: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        head.anchorPoint = CGPoint(x: 1, y: 0.5)
        track.addSublayer(fill)
        track.addSublayer(head)
        track.mask = blocks
        runGlowClip.anchorPoint = CGPoint(x: 0, y: 0.5)
        runGlowClip.masksToBounds = true
        runGlowClip.addSublayer(runGlow)
        headGlowClip.masksToBounds = true
        headGlow.anchorPoint = CGPoint(x: 1, y: 0.5)
        headGlowClip.addSublayer(headGlow)
        layer?.addSublayer(rail)
        layer?.addSublayer(runGlowClip)
        layer?.addSublayer(headGlowClip)
        layer?.addSublayer(track)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Playback Position")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(position: TimeInterval, duration: TimeInterval, playing: Bool,
                   metrics: DotMatrixMetrics, barHeight: CGFloat,
                   seek: @escaping (TimeInterval) -> Void) {
        self.position = position; self.duration = duration; self.playing = playing
        self.metrics = metrics; self.barHeight = barHeight
        self.anchorTime = CACurrentMediaTime(); self.seek = seek
        setAccessibilityEnabled(duration > 0)
        redraw()
    }
    override func layout() { super.layout(); redraw() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); redraw() }

    private var currentPosition: TimeInterval {
        min(max(position + (playing ? CACurrentMediaTime() - anchorTime : 0), 0), duration)
    }

    private var colorScheme: ColorScheme {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    /// The bar's pixel color under the view's current appearance, forced to
    /// a concrete (non-dynamic) color — see `DotMatrixDisplay.resolvedGlowColor`
    /// for why `NSColor(Theme.readoutGlow)` alone can resolve against the
    /// wrong appearance later (this is what let the bar intermittently
    /// render dark mode's cyan while the window was in light mode).
    private var glowColor: NSColor {
        var color = NSColor.controlAccentColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dynamic = NSColor(Theme.readoutGlow)
            color = dynamic.usingColorSpace(.sRGB) ?? dynamic
        }
        return color
    }

    private func redraw() {
        let current = currentPosition
        let width = bounds.width
        let scale = window?.backingScaleFactor ?? 2
        let fraction = duration > 0 ? CGFloat(current / duration) : 0
        let glow = glowColor
        let geometry = Self.barGeometry(width: width, metrics: metrics, barHeight: barHeight, scale: scale)
        let height = geometry.frameHeight

        CATransaction.begin(); CATransaction.setDisableActions(true)
        // One pixel-aligned frame shared by the cell layers.
        let frame = CGRect(x: 0, y: (((bounds.height - height) / 2) * scale).rounded() / scale,
                           width: width, height: height)
        track.frame = frame; rail.frame = frame
        blocks.frame = track.bounds
        blocks.path = geometry.litMask
        rail.path = geometry.offSegments
        applyHoverStyle(glow: glow)
        // Dark: the run glows a step below full and the head runs white-hot.
        // Light (dark ink on the backlit LCD): the run is a touch faded and
        // the head carries the full ink.
        let isDark = colorScheme == .dark
        fill.backgroundColor = glow.withAlphaComponent(isDark ? 0.78 : 0.72).cgColor
        head.backgroundColor = (isDark ? glow.blended(withFraction: 0.55, of: .white) ?? glow : glow).cgColor
        fill.removeAnimation(forKey: "progress")
        head.removeAnimation(forKey: "progress")
        runGlowClip.removeAnimation(forKey: "progress")
        headGlow.removeAnimation(forKey: "progress")
        layOutGlow(geometry: geometry, frame: frame, glow: glow, scale: scale, isDark: isDark)

        // A real bar graph lights whole elements only. The fill's width is
        // quantized to element boundaries (its edge always sits in a gap, so
        // the mask never shows a partially lit block), and between anchor
        // events a *discrete* keyframe animation steps it to the next
        // boundary at the moment playback crosses each element's share of the
        // duration — one animation per anchor, no per-frame work.
        let elementCount = geometry.litRightEdges.count
        let lit = geometry.litCount(fraction: fraction)
        fill.position = CGPoint(x: 0, y: height / 2)
        fill.bounds = CGRect(x: 0, y: 0, width: geometry.fillWidth(litCount: lit), height: height)
        head.bounds = CGRect(x: 0, y: 0, width: geometry.headWidth, height: height)
        head.position = CGPoint(x: geometry.fillWidth(litCount: lit), y: height / 2)
        runGlowClip.bounds.size.width = Self.runGlowClipWidth(geometry: geometry, litCount: lit)
        headGlow.position.x = Self.headGlowX(geometry: geometry, litCount: lit)
        if playing && duration > current && lit < elementCount {
            let remaining = duration - current
            var values: [CGFloat] = []
            var runGlowValues: [CGFloat] = []
            var headGlowValues: [CGFloat] = []
            var keyTimes: [NSNumber] = []
            for count in lit...elementCount {
                values.append(geometry.fillWidth(litCount: count))
                runGlowValues.append(Self.runGlowClipWidth(geometry: geometry, litCount: count))
                headGlowValues.append(Self.headGlowX(geometry: geometry, litCount: count))
                // Element `count` lights when position reaches `count / elementCount`
                // of the duration; the first keyframe is the current state.
                let at = duration * TimeInterval(count) / TimeInterval(elementCount) - current
                let keyTime = count == lit ? 0 : (count == elementCount ? 1 : min(max(at / remaining, 0), 1))
                keyTimes.append(NSNumber(value: keyTime))
            }
            let animation = CAKeyframeAnimation(keyPath: "bounds.size.width")
            animation.values = values
            animation.keyTimes = keyTimes
            animation.calculationMode = .discrete
            animation.duration = remaining
            animation.fillMode = .forwards; animation.isRemovedOnCompletion = false
            fill.add(animation, forKey: "progress")
            let headAnimation = CAKeyframeAnimation(keyPath: "position.x")
            headAnimation.values = values
            headAnimation.keyTimes = keyTimes
            headAnimation.calculationMode = .discrete
            headAnimation.duration = remaining
            headAnimation.fillMode = .forwards; headAnimation.isRemovedOnCompletion = false
            head.add(headAnimation, forKey: "progress")
            if !runGlowClip.isHidden {
                runGlowClip.add(Self.steps("bounds.size.width", runGlowValues, keyTimes, remaining), forKey: "progress")
                headGlow.add(Self.steps("position.x", headGlowValues, keyTimes, remaining), forKey: "progress")
            }
        }
        CATransaction.commit()
    }

    private static func steps(_ keyPath: String, _ values: [CGFloat], _ keyTimes: [NSNumber],
                              _ duration: TimeInterval) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = keyTimes
        animation.calculationMode = .discrete
        animation.duration = duration
        animation.fillMode = .forwards; animation.isRemovedOnCompletion = false
        return animation
    }

    // MARK: LED glow

    /// The canvas's LED glow, dark appearance only (light is an LCD: ink
    /// doesn't glow): the lit run's cells carry a 2 pt blur of the glow
    /// colour at 50% (CSS `0 0 2px`), the leading cell a 5 pt blur at full
    /// strength (`0 0 5px`). Blur radii follow CSS, where the blur is twice
    /// the Gaussian's standard deviation.
    enum GlowMetrics {
        static let runBlur: CGFloat = 2
        static let runOpacity: CGFloat = 0.5
        static let headBlur: CGFloat = 5
        static let headOpacity: CGFloat = 1
        /// Room around a glow image for its blur to fade out.
        static func bleed(blur: CGFloat) -> CGFloat { (blur * 1.5).rounded(.up) }
    }

    private struct GlowCacheKey: Equatable {
        var width: CGFloat
        var height: CGFloat
        var scale: CGFloat
        var color: NSColor
    }

    /// The run glow's clip width: the bleed left of the first cell plus the
    /// fill, so the halo of every lit cell shows and none of an unlit one;
    /// nothing at all when no cell is lit.
    static func runGlowClipWidth(geometry: BarGeometry, litCount: Int) -> CGFloat {
        litCount > 0 ? geometry.fillWidth(litCount: litCount) + GlowMetrics.bleed(blur: GlowMetrics.runBlur) : 0
    }

    /// The head glow's right edge in its clip (which starts one bleed left
    /// of the bar): the leading cell's right edge plus the image's bleed.
    /// With nothing lit it parks far outside the clip.
    static func headGlowX(geometry: BarGeometry, litCount: Int) -> CGFloat {
        guard litCount > 0, litCount <= geometry.litRightEdges.count else { return -10_000 }
        return geometry.litRightEdges[litCount - 1] + GlowMetrics.bleed(blur: GlowMetrics.headBlur) * 2
    }

    private func layOutGlow(geometry: BarGeometry, frame: CGRect, glow: NSColor, scale: CGFloat, isDark: Bool) {
        runGlowClip.isHidden = !isDark
        headGlowClip.isHidden = !isDark
        guard isDark, !geometry.litRightEdges.isEmpty else { return }
        let runBleed = GlowMetrics.bleed(blur: GlowMetrics.runBlur)
        let headBleed = GlowMetrics.bleed(blur: GlowMetrics.headBlur)
        let runSize = CGSize(width: frame.width + runBleed * 2, height: frame.height + runBleed * 2)
        runGlowClip.position = CGPoint(x: frame.minX - runBleed, y: frame.midY)
        runGlowClip.bounds = CGRect(x: 0, y: 0, width: runGlowClip.bounds.width, height: runSize.height)
        runGlow.frame = CGRect(origin: .zero, size: runSize)
        headGlowClip.frame = frame.insetBy(dx: -headBleed, dy: -headBleed)
        let headSize = CGSize(width: geometry.blockWidth + headBleed * 2, height: frame.height + headBleed * 2)
        headGlow.bounds = CGRect(origin: .zero, size: headSize)
        headGlow.position.y = headGlowClip.bounds.midY
        runGlow.contentsScale = scale
        headGlow.contentsScale = scale

        let key = GlowCacheKey(width: frame.width, height: frame.height, scale: scale, color: glow)
        guard key != glowCacheKey else { return }
        glowCacheKey = key
        let cells = geometry.cellRects.map { $0.offsetBy(dx: runBleed, dy: runBleed) }
        runGlow.contents = Self.glowImage(
            cells: cells, size: runSize, scale: scale, blur: GlowMetrics.runBlur,
            color: glow.withAlphaComponent(GlowMetrics.runOpacity)
        )
        let cell = CGRect(x: headBleed, y: headBleed, width: geometry.blockWidth, height: frame.height)
        headGlow.contents = Self.glowImage(
            cells: [cell], size: headSize, scale: scale, blur: GlowMetrics.headBlur,
            color: glow.withAlphaComponent(GlowMetrics.headOpacity)
        )
    }

    /// Only the blurred halo of `cells`, not the cells themselves: they are
    /// drawn far to the right and their shadow is cast back into place.
    /// Shadow offset and blur are in device pixels, so both take `scale`.
    static func glowImage(cells: [CGRect], size: CGSize, scale: CGFloat, blur: CGFloat, color: NSColor) -> CGImage? {
        let pixelWidth = Int((size.width * scale).rounded(.up))
        let pixelHeight = Int((size.height * scale).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        let shift = size.width + blur * 4
        context.setShadow(offset: CGSize(width: -shift * scale, height: 0), blur: blur * scale, color: color.cgColor)
        context.setFillColor(NSColor.black.cgColor)
        for cell in cells { context.fill(cell.offsetBy(dx: shift, dy: 0)) }
        return context.makeImage()
    }

    /// The bar's shapes for a given width, in a common coordinate space
    /// `frameHeight` tall. The segments, left to right, are what progress
    /// consumes one at a time.
    struct BarGeometry {
        /// Every segment at full height: the lit fill's mask.
        var litMask: CGPath
        /// The "off" bar under each segment.
        var offSegments: CGPath
        /// Every segment's rect, left to right (the glow's source).
        var cellRects: [CGRect]
        /// Right edge of every segment in left-to-right order.
        var litRightEdges: [CGFloat]
        var blockWidth: CGFloat
        var gap: CGFloat
        var frameHeight: CGFloat
        /// Width of the head layer: one block plus a gap, so right-anchored
        /// at `fillWidth(litCount:)` it covers the leading segment only.
        var headWidth: CGFloat

        /// How many whole elements are lit at `fraction` of the duration:
        /// the bar only ever shows completed elements, so this floors.
        func litCount(fraction: CGFloat) -> Int {
            let count = litRightEdges.count
            guard count > 0, fraction > 0 else { return 0 }
            return min(Int((fraction * CGFloat(count)).rounded(.down)), count)
        }

        /// A fill width that lights exactly `litCount` elements: half a gap
        /// past the last lit element's right edge, safely inside the gap
        /// before the next one.
        func fillWidth(litCount: Int) -> CGFloat {
            guard litCount > 0, let last = litRightEdges.last else { return 0 }
            guard litCount < litRightEdges.count else { return last + gap }
            return litRightEdges[litCount - 1] + gap / 2
        }
    }

    /// Lays out every full block that fits the width, each an identical
    /// whole-*device*-pixel width advancing by an identical whole-device-pixel
    /// pitch, with the row centered so neither end has a stray partial gap.
    /// No endcaps: the canvas has none (they were dropped after milestone 5).
    ///
    /// The block, gap and cap widths come straight from the whole-point
    /// `metrics`, so at 1x and 2x the snapping here is a no-op; it remains
    /// so the geometry stays on the device grid at non-integral scales. The
    /// row is stepped by the exact pitch from a pixel-aligned origin so every
    /// block is identically sized with no accumulated drift (each step is a
    /// multiple of `1/scale`, exactly representable in binary floating
    /// point). The gap is quantized on its own and the pitch *derived* as
    /// block plus gap, and floored at one device pixel, so consecutive blocks
    /// can never touch and draw as a solid line.
    ///
    /// `barHeight` (the segments' height) is independent of
    /// `metrics` — the caller sets it from the elapsed-time row, as a whole
    /// number of points.
    static func barGeometry(width: CGFloat, metrics: DotMatrixMetrics, barHeight: CGFloat, scale: CGFloat) -> BarGeometry {
        let pixel = 1 / scale
        func snapped(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let blockWidth = max(snapped(metrics.dotSize), pixel)
        let gap = max(snapped(metrics.dotGap), pixel)
        let advance = blockWidth + gap
        // Lit segments stand the full bar height; an unlit segment is a
        // bar centered in the same slot, never taller (with the meter's 3 pt
        // cells and 5 pt bar the two are the same height).
        let segmentHeight = max(snapped(barHeight), pixel)
        let offHeight = min(max(snapped(metrics.dotSize * 2), pixel), segmentHeight)
        let offY = snapped((segmentHeight - offHeight) / 2)
        // Square blocks, like the text dots: every edge is on the pixel grid.
        let frameHeight = segmentHeight

        let litMask = CGMutablePath()
        let offSegments = CGMutablePath()
        var cellRects: [CGRect] = []
        var litRightEdges: [CGFloat] = []
        let regionWidth = snapped(width)
        // n blocks span n advances minus the trailing gap.
        let count = regionWidth >= blockWidth ? Int(((regionWidth + gap + 0.01) / advance).rounded(.down)) : 0
        let rowWidth = CGFloat(count) * advance - gap
        var x = snapped((regionWidth - rowWidth) / 2)
        for _ in 0..<count {
            let cell = CGRect(x: x, y: 0, width: blockWidth, height: segmentHeight)
            litMask.addRect(cell)
            offSegments.addRect(CGRect(x: x, y: offY, width: blockWidth, height: offHeight))
            cellRects.append(cell)
            litRightEdges.append(cell.maxX)
            x += advance
        }
        return BarGeometry(litMask: litMask, offSegments: offSegments, cellRects: cellRects,
                           litRightEdges: litRightEdges, blockWidth: blockWidth, gap: gap,
                           frameHeight: frameHeight, headWidth: blockWidth + gap)
    }

    // MARK: Hover affordance

    /// The unlit segments' opacity: the canvas's 9% in dark; light's LCD
    /// keeps its fainter-ink 22% (the canvas draws dark only). Hover
    /// brightens them so the full scrubbable extent stands out.
    static func unlitOpacity(isDark: Bool, hovered: Bool) -> CGFloat {
        isDark ? (hovered ? 0.2 : 0.09) : (hovered ? 0.45 : 0.22)
    }

    /// Hover state: static once applied; only the transition animates.
    private func applyHoverStyle(glow: NSColor) {
        rail.fillColor = glow.withAlphaComponent(Self.unlitOpacity(isDark: colorScheme == .dark, hovered: isHovered)).cgColor
    }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        // One-shot transition into the hovered state; an implicit layer
        // action fades the rail color, then nothing runs while hovering.
        CATransaction.begin()
        CATransaction.setAnimationDuration(hovered ? 0.12 : 0.22)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        applyHoverStyle(glow: glowColor)
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        // `.inVisibleRect` keeps the area pinned to the current bounds, so a
        // resize needs no manual rect bookkeeping here.
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); scrub(event) }
    override func mouseDragged(with event: NSEvent) { scrub(event) }
    private func scrub(_ event: NSEvent) {
        guard duration > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        seek(min(max(point.x / max(bounds.width, 1), 0), 1) * duration)
    }
    override func accessibilityValue() -> Any? { currentPosition.formattedSignedTimestamp }
    override func accessibilityPerformIncrement() -> Bool { seek(min(currentPosition + 1, duration)); return duration > 0 }
    override func accessibilityPerformDecrement() -> Bool { seek(max(currentPosition - 1, 0)); return duration > 0 }
}

// MARK: - Panel chrome

extension View {
    /// v2.9.0's Glass readout frame (its `ReadoutStyle.glass`), sized for any
    /// panel: a convex tile on the control-bar surface with no bezel. The
    /// corner radius scales with the panel height (11 at 56, 9 at 42 and 41,
    /// 7 at 30).
    func readoutGlass(cornerRadius: CGFloat, reflectionBehindContent: Bool = false) -> some View {
        modifier(ReadoutGlassChrome(cornerRadius: cornerRadius, reflectionBehindContent: reflectionBehindContent))
    }
}

private struct ReadoutGlassChrome: ViewModifier {
    let cornerRadius: CGFloat
    let reflectionBehindContent: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    func body(content: Content) -> some View {
        content
            .background {
                glassPanel.overlay { if reflectionBehindContent { glassLight } }
            }
            .overlay { if !reflectionBehindContent { glassLight } }
    }

    /// The tile itself: the glass and, in light mode, the backlit LCD's
    /// bloom, brightest at the center.
    private var glassPanel: some View {
        shape
            .fill(Theme.readoutGlass)
            .overlay {
                if colorScheme == .light {
                    shape.fill(EllipticalGradient(
                        colors: [.white.opacity(0.24), .clear],
                        center: .center,
                        startRadiusFraction: 0,
                        endRadiusFraction: 0.85
                    ))
                }
            }
            .allowsHitTesting(false)
    }

    /// A domed reflection and lit edges. The playlist draws its title,
    /// clock and meter above this reflection in both appearances.
    private var glassLight: some View {
        shape
            .fill(
                EllipticalGradient(
                    stops: [
                        .init(color: .white.opacity(colorScheme == .light ? 0.28 : 0.13), location: 0),
                        .init(color: .white.opacity(colorScheme == .light ? 0.10 : 0.04), location: 0.55),
                        .init(color: .clear, location: 1)
                    ],
                    center: UnitPoint(x: 0.5, y: 0.16),
                    startRadiusFraction: 0,
                    endRadiusFraction: 0.95
                )
            )
            .overlay {
                shape.strokeBorder(.black.opacity(colorScheme == .light ? 0.10 : 0.28), lineWidth: 1)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(colorScheme == .light ? 0.60 : 0.30), location: 0),
                            .init(color: .clear, location: 0.5),
                            .init(color: .black.opacity(colorScheme == .light ? 0.22 : 0.45), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
            .allowsHitTesting(false)
    }
}
