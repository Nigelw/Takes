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
    /// Inset from the glass edge to the artwork / first character cell.
    private let wellInsetX: CGFloat = 10
    private let lineSpacing: CGFloat = 2.5
    /// Gap between the artwork square and the text block.
    private let artworkSpacing: CGFloat = 9
    /// Character cells reserved for the time field: enough for `-1:00:00`.
    private let timeColumns = 7

    /// Height of the three rows; the artwork square matches it.
    private var contentHeight: CGFloat { metrics.lineHeight * 3 + lineSpacing * 2 }

    /// Cells per text line that fit in `panelWidth` after the glass insets
    /// and, when present, the artwork square and its gap. `DotMatrixDisplay.fit`
    /// truncates longer text with an ellipsis.
    private func columns(forPanelWidth panelWidth: CGFloat) -> Int {
        var available = panelWidth - wellInsetX * 2
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

            HStack(spacing: artworkSpacing) {
                if let artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: contentHeight, height: contentHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .strokeBorder(.black.opacity(0.35), lineWidth: 0.5)
                        }
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: lineSpacing) {
                    DotMatrixDisplay(text: nowPlaying.title, columns: columns, metrics: metrics)
                    DotMatrixDisplay(text: secondLine, columns: columns, metrics: metrics)
                    HStack(spacing: metrics.cellAdvance - metrics.cellGap) {
                        DotMatrixDisplay(text: elapsed, columns: timeColumns, metrics: timeMetrics)
                        DotMatrixProgressBar(controller: controller, seek: seek, metrics: metrics)
                    }
                    .frame(width: lineWidth, height: metrics.lineHeight)
                }
            }
            .padding(.horizontal, wellInsetX)
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
}

// MARK: - Dot-matrix character display

/// Geometry shared by the text lines and the progress bar so their pixel
/// pitches match, the way one LCD controller drives the whole panel. Sized so
/// three lines fit inside the comparison readout's 56pt panel.
struct DotMatrixMetrics: Equatable {
    /// Side of one square pixel.
    var dotSize: CGFloat = 1.5
    /// Gap between pixels within a character cell.
    var dotGap: CGFloat = 0.45
    /// Gap between character cells (one blank pixel column, slightly wider).
    var cellGap: CGFloat = 1.6

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

            if colorScheme == .dark {
                // LED: a soft halo of the pixel color under the crisp fill.
                var glow = context
                glow.addFilter(.blur(radius: metrics.dotSize * 1.1))
                glow.fill(lit, with: .color(Theme.readoutGlow.opacity(0.9)))
            } else {
                // LCD: the ink layer floats just above the backlight, dropping
                // a tight shadow down-right onto the glass.
                var shade = context
                shade.translateBy(x: 0.5, y: 0.8)
                shade.addFilter(.blur(radius: metrics.dotSize * 0.3))
                shade.fill(lit, with: .color(.black.opacity(0.30)))
            }
            context.fill(lit, with: .color(Theme.readoutGlow))
        }
        .frame(width: intrinsicWidth + bleed * 2, height: metrics.lineHeight + bleed * 2)
        .padding(-bleed)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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

    /// Strips diacritics and maps common typographic punctuation onto the
    /// ASCII cells so real tag text (`Café`, `Don’t`, `Rock – Live`) stays
    /// legible. Newlines and tabs collapse to spaces.
    private static func fold(_ text: String) -> String {
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

// MARK: - Progress bar

/// Segmented LCD progress bar: a thin rail with pixel-pitch blocks lit from
/// the left up to the current position. Only transport anchor
/// events update this leaf; Core Animation grows the lit run between anchors,
/// and native input / accessibility write seeks back to transport.
struct DotMatrixProgressBar: NSViewRepresentable {
    let controller: PlaybackController
    let seek: (TimeInterval) -> Void
    var metrics = DotMatrixMetrics()

    func makeNSView(context: Context) -> DotMatrixProgressView { DotMatrixProgressView() }
    func updateNSView(_ view: DotMatrixProgressView, context: Context) {
        _ = controller.session.transportPosition
        view.configure(position: controller.displayTransportPosition(), duration: controller.session.duration,
                       playing: controller.session.isPlaying, metrics: metrics, seek: seek)
    }
}

final class DotMatrixProgressView: NSView {
    private let rail = CALayer()
    private let track = CALayer()
    private let fill = CALayer()
    private let blocks = CAShapeLayer()
    private var metrics = DotMatrixMetrics()
    private var duration: TimeInterval = 0
    private var position: TimeInterval = 0
    private var playing = false
    private var anchorTime: TimeInterval = 0
    private var seek: (TimeInterval) -> Void = { _ in }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        track.addSublayer(fill)
        track.mask = blocks
        layer?.addSublayer(rail)
        layer?.addSublayer(track)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Playback Position")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(position: TimeInterval, duration: TimeInterval, playing: Bool,
                   metrics: DotMatrixMetrics, seek: @escaping (TimeInterval) -> Void) {
        self.position = position; self.duration = duration; self.playing = playing
        self.metrics = metrics; self.anchorTime = CACurrentMediaTime(); self.seek = seek
        setAccessibilityEnabled(duration > 0)
        redraw()
    }
    override func layout() { super.layout(); redraw() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); redraw() }

    private var currentPosition: TimeInterval {
        min(max(position + (playing ? CACurrentMediaTime() - anchorTime : 0), 0), duration)
    }

    /// The bar's pixel color under the view's current appearance.
    private var glowColor: NSColor {
        var color = NSColor.controlAccentColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor(Theme.readoutGlow) }
        return color
    }

    /// Block pitch: one character cell's worth of pixels per block, so the
    /// bar reads as part of the same matrix as the text above it.
    private var blockAdvance: CGFloat { metrics.dotPitch }
    private var blockWidth: CGFloat { metrics.dotSize }

    private func redraw() {
        let current = currentPosition
        let width = bounds.width
        let height = metrics.dotSize * 3 + metrics.dotGap * 2
        let fraction = duration > 0 ? CGFloat(current / duration) : 0
        let glow = glowColor

        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: width, height: height)
        blocks.frame = track.bounds
        blocks.path = Self.blockPath(width: width, height: height, blockWidth: blockWidth, advance: blockAdvance,
                                     cornerRadius: metrics.dotSize * 0.2)
        // Unlit track: a hairline rail through the bar's midline, so the
        // scrubbable extent reads without a per-segment "off" pattern.
        rail.frame = CGRect(x: 0, y: (bounds.height - 1) / 2, width: width, height: 1)
        rail.backgroundColor = glow.withAlphaComponent(0.22).cgColor
        fill.backgroundColor = glow.cgColor
        fill.removeAnimation(forKey: "progress")
        fill.position = CGPoint(x: 0, y: height / 2)
        fill.bounds = CGRect(x: 0, y: 0, width: width * fraction, height: height)
        if playing && duration > current {
            let animation = CABasicAnimation(keyPath: "bounds.size.width")
            animation.fromValue = width * fraction; animation.toValue = width
            animation.duration = duration - current; animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.fillMode = .forwards; animation.isRemovedOnCompletion = false
            fill.add(animation, forKey: "progress")
        }
        CATransaction.commit()
    }

    /// Every full block that fits, snapped to whole pixels so the last block
    /// isn't clipped mid-way.
    private static func blockPath(width: CGFloat, height: CGFloat, blockWidth: CGFloat, advance: CGFloat,
                                  cornerRadius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard advance > 0 else { return path }
        var x: CGFloat = 0
        while x + blockWidth <= width + 0.01 {
            path.addRoundedRect(in: CGRect(x: x, y: 0, width: blockWidth, height: height),
                                cornerWidth: cornerRadius, cornerHeight: cornerRadius)
            x += advance
        }
        return path
    }

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

    private let cornerRadius: CGFloat = 10
    /// Width of the raised bezel ring the glass window is sunk into.
    private let bezelWidth: CGFloat = 4
    private var glassCornerRadius: CGFloat { cornerRadius - bezelWidth }
    /// Corner radius of the convex glass tile.
    private let convexCornerRadius: CGFloat = 11

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
