import AppKit
import AVFoundation
import SwiftUI

// MARK: - Now-playing panel

/// The playlist transport's readout: a dot-matrix LCD in the manner of a 90s
/// car-stereo head unit. Album artwork on the left when the file carries any,
/// then two text lines (title; artist — album) and a third row with the
/// elapsed time and a segmented progress bar, all behind the same glass/bezel
/// the comparison readout uses and at the same panel height. The panel fills
/// whatever width it is given — the transport bar hands it a fixed width — and
/// fits as many character cells per line as that width allows.
///
/// Text lines re-render only when their strings change (track navigation, or
/// once per displayed second for the time). The bar's fill is Core
/// Animation-driven between transport anchor events, so steady playback does
/// no per-frame SwiftUI work.
struct PlaylistNowPlayingReadout: View {
    /// Shared with the comparison readout so the two transports match.
    static let panelHeight: CGFloat = DigitalTimeReadout.panelHeight

    struct NowPlaying: Equatable {
        var title: String = ""
        var artist: String?
        var album: String?
    }

    let style: ReadoutStyle
    let nowPlaying: NowPlaying
    let artwork: NSImage?
    let elapsed: String
    let controller: PlaybackController
    let seek: (TimeInterval) -> Void

    private let metrics = DotMatrixMetrics()
    /// The clock digits are a smaller typeface than the text lines, the way
    /// a head unit's time field is secondary to the track readout.
    private let timeMetrics = DotMatrixMetrics().scaled(by: 0.75)
    private let lineSpacing: CGFloat = 2.5
    /// Gap between the artwork square and the text block.
    private let artworkSpacing: CGFloat = 9
    /// Character cells reserved for the time field: enough for `-1:00:00`.
    private let timeColumns = 7
    /// Gap between the elapsed-time digits and the progress bar.
    private let timeBarGap: CGFloat = 4
    /// A small rounding on the artwork tile — not the panel's own bezel
    /// radius (too heavy for a small square), just enough to soften the
    /// corners.
    private let artworkCornerRadius: CGFloat = 2
    private var artworkShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous)
    }
    /// Progress bar/endcap height: matching the elapsed digits' full height
    /// read as too tall; the old `dotSize*3 + dotGap*2` "thin bar-graph" look
    /// read as too short. Halfway between the two.
    private var barHeight: CGFloat { (timeMetrics.lineHeight + metrics.dotSize * 3 + metrics.dotGap * 2) / 2 }

    /// Height of the title/artist—album lines plus the elapsed-time/progress
    /// row (sized to the elapsed digits' height, not the text lines' — the
    /// bar and its endcaps match that height too); the artwork square matches
    /// this total, so with top-aligned children of equal height, the artwork
    /// and the text block start and end at exactly the same points.
    private var contentHeight: CGFloat { metrics.lineHeight * 2 + lineSpacing * 2 + timeMetrics.lineHeight }

    /// Padding used uniformly on all four sides of the readout's content, so
    /// the left/right inset always equals the top/bottom inset by
    /// construction, and the content is vertically centered in the panel
    /// simply because equal padding on both edges leaves no space unaccounted
    /// for (`panelHeight - 2 × padding == contentHeight`, exactly).
    private var padding: CGFloat { (Self.panelHeight - contentHeight) / 2 }

    /// Cells per text line that fit in `panelWidth` after the glass insets
    /// and, when present, the artwork square and its gap. `DotMatrixDisplay.fit`
    /// truncates longer text with an ellipsis.
    private func columns(forPanelWidth panelWidth: CGFloat) -> Int {
        var available = panelWidth - padding * 2
        if artwork != nil { available -= contentHeight + artworkSpacing }
        // A line of n cells is n advances minus the trailing cell gap.
        return max(Int(((available + metrics.cellGap) / metrics.cellAdvance).rounded(.down)), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let columns = columns(forPanelWidth: proxy.size.width)
            // The time row is pinned to the text lines' width so the progress
            // bar ends flush with them.
            let lineWidth = metrics.lineWidth(columns: columns)
            // When both lines scroll, they share one loop period — the
            // longer of the two lines' own natural periods — so a shorter
            // line holds at its end-of-cycle position and waits rather than
            // looping ahead of a slower sibling. A line that fits, or is the
            // only one overflowing, is unaffected (`nil` lets it use its own
            // natural period).
            let sharedPeriod = Self.sharedMarqueePeriod(
                texts: [nowPlaying.title, secondLine], columns: columns, metrics: metrics
            )

            // Explicit `.top`, not the default `.center`: the artwork and the
            // text block are built to the same height (`contentHeight`), so
            // top-aligning them also aligns their bottoms — the elapsed-time
            // row's bottom lands exactly on the artwork's bottom — without
            // depending on that equality being coincidentally invisible under
            // `.center` too.
            HStack(alignment: .top, spacing: artworkSpacing) {
                if let artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: contentHeight, height: contentHeight)
                        .clipShape(artworkShape)
                        .overlay {
                            artworkShape.strokeBorder(.black.opacity(0.35), lineWidth: 0.5)
                        }
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: lineSpacing) {
                    DotMatrixMarqueeText(text: nowPlaying.title, columns: columns, metrics: metrics, sharedPeriod: sharedPeriod)
                    DotMatrixMarqueeText(text: secondLine, columns: columns, metrics: metrics, sharedPeriod: sharedPeriod)
                    HStack(spacing: timeBarGap) {
                        DotMatrixDisplay(text: elapsed, columns: timeColumns, metrics: timeMetrics)
                        DotMatrixProgressBar(controller: controller, seek: seek, metrics: metrics, barHeight: barHeight)
                    }
                    .frame(width: lineWidth, height: timeMetrics.lineHeight)
                }
            }
            // Horizontal inset only; the HStack's own natural height is
            // exactly `contentHeight`, so centering it (the vertical half of
            // `.leading`) within the full `proxy.size.height` (== panelHeight)
            // leaves exactly `padding` above and below — matching the
            // horizontal `padding` here without saying so twice.
            .padding(.horizontal, padding)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .frame(height: Self.panelHeight)
        .readoutPanelChrome(style: style)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now Playing")
        .accessibilityValue(accessibilityDescription)
    }

    // MARK: Line composition

    /// `artist — album` when both are tagged; whichever is present alone
    /// otherwise; blank when neither is.
    private var secondLine: String {
        let parts = [nowPlaying.artist, nowPlaying.album]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.joined(separator: " \u{2014} ")
    }

    private var accessibilityDescription: String {
        var parts = [nowPlaying.title]
        if !secondLine.isEmpty { parts.append(secondLine) }
        parts.append("\(elapsed) elapsed")
        return parts.joined(separator: ", ")
    }

    /// The longest natural loop period among `texts` that actually overflow
    /// `columns`, so sibling marquee lines can be told to loop in lockstep.
    /// `nil` when none of them overflow (nothing to synchronize).
    private static func sharedMarqueePeriod(texts: [String], columns: Int, metrics: DotMatrixMetrics) -> CFTimeInterval? {
        let periods = texts.compactMap { DotMatrixMarqueeView.naturalTiming(text: $0, columns: columns, metrics: metrics)?.period }
        return periods.max()
    }
}

// MARK: - Dot-matrix character display

/// Geometry shared by the text lines and the progress bar so their pixel
/// pitches match, the way one LCD controller drives the whole panel. Sized so
/// three lines fit inside the comparison readout's 56pt panel.
struct DotMatrixMetrics: Equatable {
    /// Side of one square pixel.
    var dotSize: CGFloat = 1.3
    /// Gap between pixels within a character cell.
    var dotGap: CGFloat = 0.4
    /// Gap between character cells (one blank pixel column, slightly wider).
    var cellGap: CGFloat = 1.4

    var dotPitch: CGFloat { dotSize + dotGap }
    var cellWidth: CGFloat { dotSize * 5 + dotGap * 4 }
    var cellAdvance: CGFloat { cellWidth + cellGap }
    var lineHeight: CGFloat { dotSize * 7 + dotGap * 6 }

    /// Width of a line of `columns` cells, with no trailing cell gap.
    func lineWidth(columns: Int) -> CGFloat {
        cellWidth * CGFloat(columns) + cellGap * CGFloat(max(columns - 1, 0))
    }

    /// The same pixel geometry at a different size.
    func scaled(by factor: CGFloat) -> DotMatrixMetrics {
        DotMatrixMetrics(dotSize: dotSize * factor, dotGap: dotGap * factor, cellGap: cellGap * factor)
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
            Self.draw(glyphs: glyphs, columns: columns, metrics: metrics, colorScheme: colorScheme, bleed: bleed, into: context)
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

        var lit = Path()
        let dotRect = CGRect(x: 0, y: 0, width: metrics.dotSize, height: metrics.dotSize)
        let dotRadius = metrics.dotSize * 0.2
        for column in 0..<columns {
            let cellX = CGFloat(column) * metrics.cellAdvance
            let rows = column < glyphs.count ? Self.rows(for: glyphs[column]) : Self.blankRows
            for row in 0..<7 {
                let bits = rows[row]
                for pixel in 0..<5 where bits & (0x10 >> pixel) != 0 {
                    let origin = CGPoint(x: cellX + CGFloat(pixel) * metrics.dotPitch, y: CGFloat(row) * metrics.dotPitch)
                    lit.addPath(Path(roundedRect: dotRect.offsetBy(dx: origin.x, dy: origin.y), cornerRadius: dotRadius))
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
        let glowColor = resolvedGlowColor(for: colorScheme)

        if colorScheme == .dark {
            // LED: a soft halo of the pixel color under the crisp fill.
            var glow = context
            glow.addFilter(.blur(radius: metrics.dotSize * 1.1))
            glow.fill(lit, with: .color(glowColor.opacity(0.9)))
        } else {
            // LCD: the ink layer floats just above the backlight, dropping
            // a tight shadow down-right onto the glass.
            var shade = context
            shade.translateBy(x: 0.5, y: 0.8)
            shade.addFilter(.blur(radius: metrics.dotSize * 0.3))
            shade.fill(lit, with: .color(.black.opacity(0.30)))
        }
        context.fill(lit, with: .color(glowColor))
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
            Self.draw(glyphs: glyphs, columns: columns, metrics: metrics, colorScheme: colorScheme, bleed: bleed, into: context)
        }
        .frame(width: width, height: height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        // `width`/`height` above are the *requested* point size handed to
        // `ImageRenderer`, but its `cgImage` is necessarily an integer number
        // of pixels — with this font's fractional metrics (`dotSize`,
        // `dotGap`, `cellGap`), `width * scale` / `height * scale` are almost
        // never whole numbers, so the renderer's actual pixel dimensions can
        // differ from `width * scale` / `height * scale` by a fraction of a
        // pixel. Returning the *actual* rasterized size (derived from the
        // image itself) rather than the pre-rasterization point value lets
        // the caller size the layer to exactly what was produced, so Core
        // Animation never has to resample/stretch the bitmap to fit a
        // slightly-mismatched `bounds`.
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
    /// artist—album lines in `PlaylistNowPlayingReadout`), so both lines
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

    func configure(text: String, columns: Int, metrics: DotMatrixMetrics, sharedPeriod: CFTimeInterval?, reduceMotion: Bool) {
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
        redraw()
    }

    private var colorScheme: ColorScheme {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    /// The natural timing this line's own content needs to scroll once
    /// through at `scrollSpeed`, independent of any view instance — usable
    /// both here and by a parent view (e.g. `PlaylistNowPlayingReadout`)
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
    /// `masksToBounds`. With the bleed itself pixel-aligned (see `redraw()`),
    /// at 2x: bleed 2.5pt, bitmap 11.5 + 5 = 16.5pt = 33px exactly, position
    /// `11.5 + 2.5 − 16.5 = −2.5`, glyph top at `−2.5 + 16.5 − 2.5 = 11.5`
    /// (the view's top) and glyph bottom at `0` — nothing clipped.
    private func restingPosition(bleed: CGFloat, scale: CGFloat) -> CGPoint {
        CGPoint(x: Self.snapped(-bleed, scale: scale),
                y: Self.snapped(bounds.height + bleed - content.bounds.height, scale: scale))
    }

    private func redraw() {
        guard columns > 0, bounds.width > 0 else { return }
        content.removeAnimation(forKey: "marquee")

        let scale = window?.backingScaleFactor ?? 2
        // A whole-device-pixel bleed keeps the glyph at an integer pixel row
        // and column inside the bitmap, so `restingPosition` can align it to
        // the view edge exactly. (`dotSize × 2` = 2.6pt is 5.2px at 2x — a
        // fractional offset no whole-pixel layer position could cancel.)
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
        // The end-of-cycle hold is also snapped to the device grid: the
        // cycle width is a multiple of the fractional `cellAdvance`, so an
        // exact `startX - cycleWidth` would park the second copy at a
        // sub-pixel offset (resampled blurry) for the whole hold. Snapping
        // moves the wrap by at most half a device pixel.
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

/// Segmented LCD progress bar: a row of pixel-pitch blocks, all drawn dim in
/// their "off" state between two endcaps, lit from the left up to the current
/// position. Only transport anchor events update this leaf; Core Animation
/// grows the lit run between anchors, and native input / accessibility write
/// seeks back to transport.
struct DotMatrixProgressBar: NSViewRepresentable {
    let controller: PlaybackController
    let seek: (TimeInterval) -> Void
    var metrics = DotMatrixMetrics()
    /// Height of the lit segments/endcaps — independent of `metrics`'
    /// dot pitch, which only governs the segments' horizontal width/spacing.
    var barHeight: CGFloat

    func makeNSView(context: Context) -> DotMatrixProgressView { DotMatrixProgressView() }
    func updateNSView(_ view: DotMatrixProgressView, context: Context) {
        _ = controller.session.transportPosition
        view.configure(position: controller.displayTransportPosition(), duration: controller.session.duration,
                       playing: controller.session.isPlaying, metrics: metrics, barHeight: barHeight, seek: seek)
    }
}

final class DotMatrixProgressView: NSView {
    /// The "off" segments: a shorter, dim bar under each block of `blocks`,
    /// so the whole scrubbable extent reads as an LCD bar graph with every
    /// segment present and only the leading ones lit.
    private let rail = CAShapeLayer()
    /// The endcaps framing the segment row at either end, in their dim
    /// resting state; the lit fill covers them once progress reaches them.
    private let caps = CAShapeLayer()
    private let track = CALayer()
    private let fill = CALayer()
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

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        track.addSublayer(fill)
        track.mask = blocks
        layer?.addSublayer(rail)
        layer?.addSublayer(caps)
        layer?.addSublayer(track)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Playback Position")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(position: TimeInterval, duration: TimeInterval, playing: Bool,
                   metrics: DotMatrixMetrics, barHeight: CGFloat, seek: @escaping (TimeInterval) -> Void) {
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
        // One pixel-aligned frame shared by the three layers.
        let frame = CGRect(x: 0, y: (((bounds.height - height) / 2) * scale).rounded() / scale,
                           width: width, height: height)
        track.frame = frame; rail.frame = frame; caps.frame = frame
        blocks.frame = track.bounds
        blocks.path = geometry.litMask
        rail.path = geometry.offSegments
        caps.path = geometry.caps
        applyHoverStyle(glow: glow)
        fill.backgroundColor = glow.cgColor
        fill.removeAnimation(forKey: "progress")

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
        if playing && duration > current && lit < elementCount {
            let remaining = duration - current
            var values: [CGFloat] = []
            var keyTimes: [NSNumber] = []
            for count in lit...elementCount {
                values.append(geometry.fillWidth(litCount: count))
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
        }
        CATransaction.commit()
    }

    /// The bar's shapes for a given width, in a common coordinate space
    /// `frameHeight` tall. The lit elements — left cap, each segment, right
    /// cap, in that order — are what progress consumes one at a time.
    struct BarGeometry {
        /// Full-height segments plus both caps: the lit fill's mask.
        var litMask: CGPath
        /// The shorter "off" bar under each segment.
        var offSegments: CGPath
        /// Both endcaps at full height, for their dim resting state.
        var caps: CGPath
        /// Right edge of every lit element in left-to-right order.
        var litRightEdges: [CGFloat]
        var gap: CGFloat
        var frameHeight: CGFloat

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

    /// Lays out every full block that fits between the two endcaps, each an
    /// identical whole-*device*-pixel width advancing by an identical
    /// whole-device-pixel pitch, with the row centered between the caps so
    /// neither end has a stray partial gap.
    ///
    /// At this bar's sub-2pt block sizes, a fractional-pixel edge anti-aliases
    /// into a visibly blurry notch on a Retina display — but snapping each
    /// block's left/right edge *independently* rounds `blockWidth` differently
    /// depending on where each block's unrounded position falls in the pixel
    /// grid, so blocks alternate between e.g. 2 and 3 device pixels wide.
    /// Quantizing the geometry *once* and stepping by the exact quantized
    /// pitch from a pixel-aligned origin keeps every block identically sized
    /// and evenly spaced with zero accumulated drift (each step adds an exact
    /// multiple of `1/scale`, which is exactly representable in binary
    /// floating point).
    ///
    /// The gap is quantized on its own and the pitch *derived* as block plus
    /// gap. Rounding the block width and the pitch independently let the gap
    /// vanish: at `dotSize 1.3` / `dotGap 0.4` on a 2x display, both
    /// `round(1.3 × 2)` and `round(1.7 × 2)` are 3 device pixels, so
    /// consecutive blocks touched and the bar drew as one solid line. With the
    /// gap floored at one device pixel, the same metrics give a 3px block,
    /// 1px gap, 4px pitch (1.5pt / 0.5pt / 2pt).
    ///
    /// `barHeight` (the lit segments'/endcaps' height) is independent of
    /// `metrics` — it's set by the caller to match the elapsed-time digits'
    /// rendered height exactly, not derived from the block pitch.
    static func barGeometry(width: CGFloat, metrics: DotMatrixMetrics, barHeight: CGFloat, scale: CGFloat) -> BarGeometry {
        let pixel = 1 / scale
        func snapped(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let blockWidth = max(snapped(metrics.dotSize), pixel)
        let gap = max(snapped(metrics.dotGap), pixel)
        let advance = blockWidth + gap
        // Lit segments and caps stand the full bar height; an unlit segment
        // is a shorter bar centered in the same slot, so "off" and "on" differ
        // in size as well as brightness.
        let segmentHeight = max(snapped(barHeight), pixel)
        let offHeight = min(max(snapped(metrics.dotSize * 2), pixel), segmentHeight)
        let offY = snapped((segmentHeight - offHeight) / 2)
        let cornerRadius = metrics.dotSize * 0.2

        // Endcaps: a thin post at either end, the lit segments' height, set
        // off from the row by a double gap. Narrower than a segment so it
        // reads as the frame the bar graph sits in, and lit like one when
        // progress reaches it.
        let capWidth = max(snapped(metrics.dotGap * 2), pixel)
        let capInset = gap * 2
        let frameHeight = segmentHeight

        let litMask = CGMutablePath()
        let offSegments = CGMutablePath()
        let caps = CGMutablePath()
        var litRightEdges: [CGFloat] = []
        let regionStart = capWidth + capInset
        let regionEnd = snapped(width) - capWidth - capInset
        let regionWidth = regionEnd - regionStart
        guard regionWidth >= blockWidth else {
            return BarGeometry(litMask: litMask, offSegments: offSegments, caps: caps, litRightEdges: litRightEdges,
                               gap: gap, frameHeight: frameHeight)
        }
        let capRadius = min(cornerRadius, capWidth / 2)
        let leftCap = CGRect(x: 0, y: 0, width: capWidth, height: frameHeight)
        let rightCap = CGRect(x: snapped(width) - capWidth, y: 0, width: capWidth, height: frameHeight)
        caps.addRoundedRect(in: leftCap, cornerWidth: capRadius, cornerHeight: capRadius)
        caps.addRoundedRect(in: rightCap, cornerWidth: capRadius, cornerHeight: capRadius)
        litMask.addRoundedRect(in: leftCap, cornerWidth: capRadius, cornerHeight: capRadius)
        litRightEdges.append(leftCap.maxX)

        // n blocks span n advances minus the trailing gap.
        let count = Int(((regionWidth + gap + 0.01) / advance).rounded(.down))
        let rowWidth = CGFloat(count) * advance - gap
        var x = snapped(regionStart + (regionWidth - rowWidth) / 2)
        for _ in 0..<count {
            litMask.addRoundedRect(in: CGRect(x: x, y: 0, width: blockWidth, height: segmentHeight),
                                   cornerWidth: cornerRadius, cornerHeight: cornerRadius)
            offSegments.addRoundedRect(in: CGRect(x: x, y: offY, width: blockWidth, height: offHeight),
                                       cornerWidth: cornerRadius, cornerHeight: cornerRadius)
            litRightEdges.append(x + blockWidth)
            x += advance
        }

        litMask.addRoundedRect(in: rightCap, cornerWidth: capRadius, cornerHeight: capRadius)
        litRightEdges.append(rightCap.maxX)
        return BarGeometry(litMask: litMask, offSegments: offSegments, caps: caps, litRightEdges: litRightEdges,
                           gap: gap, frameHeight: frameHeight)
    }

    // MARK: Hover affordance

    /// Hover state: the unlit segments and endcaps brighten so the full
    /// scrubbable extent stands out. Static once applied; only the transition
    /// animates.
    private func applyHoverStyle(glow: NSColor) {
        rail.fillColor = glow.withAlphaComponent(isHovered ? 0.45 : 0.22).cgColor
        caps.fillColor = glow.withAlphaComponent(isHovered ? 0.6 : 0.36).cgColor
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
    /// The transport readout's glass and bezel treatment, matching the
    /// comparison-mode time readout so both panels read as the same hardware.
    func readoutPanelChrome(style: ReadoutStyle) -> some View {
        modifier(ReadoutPanelChrome(style: style))
    }
}

/// Bezel/glass chrome shared by readout panels. Mirrors the treatments in
/// `DigitalTimeReadout`, sized for a panel of any width and height.
private struct ReadoutPanelChrome: ViewModifier {
    let style: ReadoutStyle

    @Environment(\.colorScheme) private var colorScheme

    private static let cornerRadius: CGFloat = 10
    /// Width of the raised bezel ring the glass window is sunk into.
    private static let bezelWidth: CGFloat = 4
    /// Corner radius of the LCD glass window inside the bezel. Also the
    /// radius of anything drawn on the glass as a physical inset — the
    /// artwork tile — so the two shapes never drift apart.
    static let glassCornerRadius: CGFloat = cornerRadius - bezelWidth
    /// Corner radius of the convex glass tile.
    private static let convexCornerRadius: CGFloat = 11

    private var cornerRadius: CGFloat { Self.cornerRadius }
    private var bezelWidth: CGFloat { Self.bezelWidth }
    private var glassCornerRadius: CGFloat { Self.glassCornerRadius }
    private var convexCornerRadius: CGFloat { Self.convexCornerRadius }

    func body(content: Content) -> some View {
        content
            .background {
                switch style {
                case .retro: retroPanel
                case .glass: convexGlassPanel
                }
            }
            .overlay {
                switch style {
                case .retro: retroSheen
                case .glass: convexGlassLight
                }
            }
    }

    /// Backlight bloom: the electroluminescent panel behind the light-mode LCD
    /// is brightest in the middle and falls off toward the edges.
    private var backlightBloom: EllipticalGradient {
        EllipticalGradient(
            colors: [.white.opacity(0.24), .clear],
            center: .center,
            startRadiusFraction: 0,
            endRadiusFraction: 0.85
        )
    }

    private var retroSheen: some View {
        RoundedRectangle(cornerRadius: glassCornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.08), location: 0),
                        .init(color: .white.opacity(0.02), location: 0.35),
                        .init(color: .clear, location: 0.5)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .padding(bezelWidth)
            .allowsHitTesting(false)
    }

    private var convexGlassPanel: some View {
        let shape = RoundedRectangle(cornerRadius: convexCornerRadius, style: .continuous)
        return shape
            .fill(Theme.readoutGlass)
            .overlay {
                if colorScheme == .light { shape.fill(backlightBloom) }
            }
            .allowsHitTesting(false)
    }

    private var convexGlassLight: some View {
        let shape = RoundedRectangle(cornerRadius: convexCornerRadius, style: .continuous)
        return shape
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

    private var retroPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.transportButtonFill)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: Theme.readoutBezelHighlight, location: 0),
                                    .init(color: .clear, location: 0.32),
                                    .init(color: Theme.readoutBezelShadow, location: 0.82),
                                    .init(color: Theme.readoutBezelReflection, location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Theme.readoutStroke, lineWidth: 1)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: glassCornerRadius + 1, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.clear, Theme.readoutBezelReflection],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                        .padding(bezelWidth - 1)
                }
                .shadow(color: Theme.readoutFrameShadow, radius: 2, y: 1)

            RoundedRectangle(cornerRadius: glassCornerRadius, style: .continuous)
                .fill(Theme.readoutGlass.shadow(.inner(color: Theme.readoutWellShadow, radius: 3, y: 1)))
                .overlay {
                    if colorScheme == .light {
                        RoundedRectangle(cornerRadius: glassCornerRadius, style: .continuous).fill(backlightBloom)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: glassCornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.black.opacity(0.45), .white.opacity(0.22)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                }
                .padding(bezelWidth)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Artwork store

/// In-memory embedded-artwork cache for the now-playing panel, keyed by
/// stable version ID. Like `WaveformStore`, it is process-lifetime runtime
/// state: nothing here is persisted or written to disk, and artwork is loaded
/// only for the version currently shown, never for the whole playlist.
@MainActor
@Observable
final class PlaylistArtworkStore {
    /// `.some(nil)` records a finished load that found no art, so it is not
    /// retried every time the version is shown again.
    private var images: [PlaylistVersion.ID: NSImage?] = [:]
    private var inFlight: Set<PlaylistVersion.ID> = []

    /// Cached artwork, or `nil` until `load(for:)` resolves (or when the
    /// file has none).
    func artwork(for versionID: PlaylistVersion.ID?) -> NSImage? {
        guard let versionID, let cached = images[versionID] else { return nil }
        return cached
    }

    /// Starts loading the version's embedded artwork if it hasn't been
    /// loaded already. Safe to call on every navigation.
    func load(for version: PlaylistVersion) {
        let id = version.id
        guard images[id] == nil, !inFlight.contains(id) else { return }
        guard case let .available(url) = PlaylistWorkspaceStore.resolveFileReference(version.file) else {
            images[id] = .some(nil)
            return
        }
        inFlight.insert(id)
        Task { [weak self] in
            let data = await Self.artworkData(for: url)
            guard let self else { return }
            self.inFlight.remove(id)
            self.images[id] = .some(data.flatMap(NSImage.init(data:)))
        }
    }

    /// Mirrors `AudioFileLoader.descriptiveMetadata(for:)`, for the common
    /// artwork key.
    nonisolated private static func artworkData(for url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in AVMetadataItem.metadataItems(from: items, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common) {
            if let data = try? await item.load(.dataValue), !data.isEmpty { return data }
        }
        return nil
    }
}
