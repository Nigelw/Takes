import AppKit
import SwiftUI

/// Fills the window with the standard system window-background material,
/// rendered edge-to-edge including *under* the transparent titlebar. A single
/// visual-effect material draws identically in the titlebar and content
/// regions, which erases the seam a plain opaque colour leaves behind a
/// `.fullSizeContentView` titlebar. Reads correctly in light and dark.
struct WindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .windowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Invisible AppKit view that makes the control bar behave like a titlebar:
/// it sits behind the SwiftUI controls, so buttons and sliders above it keep
/// their clicks, while presses on empty bar space fall through here and drag
/// the window. Double-clicks honour the system "double-click a window's title
/// bar to" preference.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize":
                    window?.performMiniaturize(nil)
                case "None":
                    break
                default:
                    window?.performZoom(nil)
                }
                return
            }
            super.mouseUp(with: event)
        }
    }
}

/// Live-tunable surface treatment for the transport buttons. Defaults match the
/// shipped look; the Debug ▸ Appearance Tuner panel binds these for adjustment.
struct TransportButtonAppearance: Equatable {
    /// Opacity of the top gloss highlight laid over the fill.
    var glossOpacity: Double = 0.30
    /// Thickness of the beveled rim.
    var bevelWidth: Double = 1.25
    /// Brightness of the rim's top (light) edge.
    var bevelTopOpacity: Double = 0.85
    /// Darkness of the rim's bottom (shadow) edge.
    var bevelBottomOpacity: Double = 0.40
    /// Fill for the secondary (Switch/Repeat) buttons when not engaged.
    /// Defaults to the adaptive theme token; a picked color overrides it.
    var secondaryFill: Color = Theme.transportButtonFill
    /// Primary-tinted fill opacity used when a secondary button is active
    /// (currently the Repeat button).
    var activeFillOpacity: Double = 0.18
    /// Primary-tinted shadow emitted by the glyph when a secondary button is
    /// active. Kept tight — a soft halo laid right at the glyph edge; the wide
    /// wash comes from the backlight pool below.
    var activeGlyphGlowOpacity: Double = 0
    var activeGlyphGlowRadius: Double = 0
    /// Second, wider bloom around the active glyph — the soft colored corona
    /// outside the tight halo that makes the glyph read as emitting light
    /// rather than merely tinted.
    var activeGlyphBloomOpacity: Double = 0
    var activeGlyphBloomRadius: Double = 0
    /// Radial pool of primary light under the face when a secondary button is
    /// active — brightest behind the glyph, fading out before the rim, like a
    /// lamp beneath a translucent button cap.
    var activeBacklightOpacity: Double = 0
    /// Primary-tinted light the active button spills onto the surrounding bar.
    var activeSpillOpacity: Double = 0
    var activeSpillRadius: Double = 6.0
    /// Dark outer shadow above the button (recessed/pressed-in cue).
    var insetDarkOpacity: Double = 0.16
    var insetDarkRadius: Double = 1.5
    var insetDarkY: Double = -1
    /// Light outer lip below the button (recessed/pressed-in cue).
    var insetLightOpacity: Double = 0.60
    var insetLightRadius: Double = 1.0
    var insetLightY: Double = 1.5
    /// Dark inner shadow cast across the top of the face while pressed. The
    /// primary's saturated fill needs this to read as sunk below its rim; the
    /// secondaries' fill matches the window surface, so the bevel inversion
    /// alone already sells their press.
    var pressedInnerShadowOpacity: Double = 0
    var pressedInnerShadowRadius: Double = 3.0
    var pressedInnerShadowY: Double = 2.0
}

/// Live-tunable bevel/shadow for the track index badge.
struct IndexBadgeAppearance: Equatable {
    var bevelWidth: Double = 1.43
    var bevelTopOpacity: Double = 0.80
    var bevelBottomOpacity: Double = 0.24
    var shadowOpacity: Double = 0.38
    var shadowRadius: Double = 1.06
    var shadowY: Double = 0.5
}

/// Separate primary/secondary treatments — the secondary buttons are smaller
/// (40pt vs 56pt), so they carry their own bevel/shadow values rather than
/// reusing the primary's, which would read proportionally larger on them.
///
/// Each role also carries a dark-mode variant: white-based highlights (gloss,
/// bevel top, light lip) glow far brighter against dark surfaces so they are
/// dialed down, while black-based shadows (bevel bottom, inset dark) all but
/// vanish on dark backgrounds so they are dialed up.
struct TransportAppearance: Equatable {
    var lightPrimary = TransportButtonAppearance(
        bevelTopOpacity: 0.70,
        insetDarkOpacity: 0.25,
        insetDarkY: -0.75,
        pressedInnerShadowOpacity: 0.80,
        pressedInnerShadowRadius: 2.0
    )
    var lightSecondary = TransportButtonAppearance(
        glossOpacity: 0.70,
        bevelWidth: 1.0,
        bevelBottomOpacity: 0.20,
        activeFillOpacity: 0.04,
        activeGlyphGlowOpacity: 0.50,
        activeGlyphGlowRadius: 3.0,
        activeGlyphBloomOpacity: 0.30,
        activeGlyphBloomRadius: 7.0,
        activeBacklightOpacity: 0.0,
        activeSpillOpacity: 0.11,
        activeSpillRadius: 0.0,
        insetDarkRadius: 1.0,
        insetDarkY: -0.75,
        insetLightRadius: 0.75,
        insetLightY: 1.0,
        // The light secondary's bevel bottom is faint (0.20), so its pressed rim
        // inversion barely darkens the top edge — a modest inner shadow, scaled
        // to the smaller 40pt face, restores the sunk-in read. Dark mode skips
        // this: its heavier bevel (0.50) inverts convincingly on its own.
        pressedInnerShadowOpacity: 0.20,
        pressedInnerShadowRadius: 2.0,
        pressedInnerShadowY: 1.5
    )
    var darkPrimary = TransportButtonAppearance(
        glossOpacity: 0.32,
        bevelTopOpacity: 0.40,
        bevelBottomOpacity: 0.60,
        insetDarkOpacity: 0.50,
        insetDarkY: -0.75,
        insetLightOpacity: 0.12,
        pressedInnerShadowOpacity: 0.55
    )
    var darkSecondary = TransportButtonAppearance(
        glossOpacity: 0.15,
        bevelWidth: 1.0,
        bevelTopOpacity: 0.35,
        bevelBottomOpacity: 0.50,
        activeFillOpacity: 0.16,
        activeGlyphGlowOpacity: 0.90,
        activeGlyphGlowRadius: 2.5,
        activeGlyphBloomOpacity: 0.65,
        activeGlyphBloomRadius: 8.0,
        activeBacklightOpacity: 0.45,
        activeSpillOpacity: 0.60,
        activeSpillRadius: 8.0,
        insetDarkOpacity: 0.45,
        insetDarkRadius: 1.0,
        insetDarkY: -0.75,
        insetLightOpacity: 0.10,
        insetLightRadius: 0.75,
        insetLightY: 1.0
    )
}

private struct TransportAppearanceKey: EnvironmentKey {
    static let defaultValue = TransportAppearance()
}

extension EnvironmentValues {
    var transportAppearance: TransportAppearance {
        get { self[TransportAppearanceKey.self] }
        set { self[TransportAppearanceKey.self] = newValue }
    }
}

/// Circular transport button styling shared by Play, Previous/Next and
/// Switch Track (v2.9.0's style, unchanged).
///
/// - `.primary` is the filled indigo call-to-action (Play/Pause).
/// - `.secondary` is a subtle bordered circle; when `isOn` it adopts the
///   primary tint to read as an engaged toggle.
struct CircleTransportButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
    }

    var kind: Kind
    var isOn: Bool = false
    var diameter: CGFloat
    var glyphSize: CGFloat
    var pressedGlyphOffset: CGFloat = 0.75

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.transportAppearance) private var transportAppearance

    /// The treatment for this button's role and the current appearance mode —
    /// primary/secondary are tuned separately so effects stay proportional to
    /// each button's size, and light/dark carry their own highlight balances.
    private var appearance: TransportButtonAppearance {
        switch kind {
        case .primary:
            return colorScheme == .dark ? transportAppearance.darkPrimary : transportAppearance.lightPrimary
        case .secondary:
            return colorScheme == .dark ? transportAppearance.darkSecondary : transportAppearance.lightSecondary
        }
    }

    /// A circular-style rounded rectangle with radius `diameter / 2` is
    /// exactly v2.9.0's `Circle` on the square button frame.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: diameter / 2, style: .circular)
    }

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(.system(size: glyphSize, weight: .semibold))
            .foregroundStyle(foreground)
            // Two glow layers sell the lit glyph: a tight halo hugging the
            // glyph edge, then a wider soft bloom — white-hot core, colored
            // corona, like an LED behind the glyph.
            .shadow(color: activeGlyphGlowColor(opacity: appearance.activeGlyphGlowOpacity), radius: activeGlyphRadius(appearance.activeGlyphGlowRadius))
            .shadow(color: activeGlyphGlowColor(opacity: appearance.activeGlyphBloomOpacity), radius: activeGlyphRadius(appearance.activeGlyphBloomRadius))
            // Pressed: the glyph sinks with the surface instead of shrinking.
            .offset(y: pressed ? pressedGlyphOffset : 0)
            .frame(width: diameter, height: diameter)
            .background(background(pressed: pressed))
            .overlay(border(pressed: pressed))
            .clipShape(shape)
            // Active buttons spill primary-tinted light onto the surrounding bar,
            // so the glow reads as coming from the whole control, not the glyph.
            .shadow(color: activeSpillColor, radius: CGFloat(appearance.activeSpillRadius))
            // Outer bevel: a soft dark shadow above and a light lip below make the
            // button read as slightly pressed into the window surface (concave cue).
            .shadow(color: .black.opacity(isEnabled ? appearance.insetDarkOpacity : 0), radius: CGFloat(appearance.insetDarkRadius), y: CGFloat(appearance.insetDarkY))
            .shadow(color: .white.opacity(isEnabled ? appearance.insetLightOpacity : 0), radius: CGFloat(appearance.insetLightRadius), y: CGFloat(appearance.insetLightY))
            .opacity(isEnabled ? 1 : 0.4)
            // The primary's saturated fill swallows a light dim, so it darkens
            // harder than the near-background secondaries.
            .brightness(pressed ? (kind == .primary ? -0.10 : -0.06) : 0)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .contentShape(shape)
    }

    private var foreground: Color {
        switch kind {
        case .primary:
            return .white
        case .secondary:
            return isOn ? Theme.primaryLitGlyph : Color.primary.opacity(0.75)
        }
    }

    private func activeGlyphRadius(_ radius: Double) -> CGFloat {
        kind == .secondary && isOn ? CGFloat(radius) : 0
    }

    private func activeGlyphGlowColor(opacity: Double) -> Color {
        guard kind == .secondary, isOn else { return .clear }
        return Theme.primary.opacity(opacity)
    }

    private var activeSpillColor: Color {
        guard kind == .secondary, isOn, isEnabled else { return .clear }
        return Theme.primary.opacity(appearance.activeSpillOpacity)
    }

    /// Top-of-button gloss laid over the fill. Tweak these stops to adjust how
    /// glossy/shiny the transport buttons look. Dims while pressed so the face
    /// reads as tilted away from the light.
    private func surfaceGloss(pressed: Bool) -> LinearGradient {
        LinearGradient(
            colors: [Color.white.opacity(appearance.glossOpacity * (pressed ? 0.35 : 1)), .clear],
            startPoint: .top,
            endPoint: .center
        )
    }

    @ViewBuilder
    private func background(pressed: Bool) -> some View {
        switch kind {
        case .primary:
            shape.fill(pressedWell(Theme.primary, pressed: pressed))
                .overlay(shape.fill(surfaceGloss(pressed: pressed)))
        case .secondary:
            shape
                .fill(pressedWell(isOn ? AnyShapeStyle(Theme.primary.opacity(appearance.activeFillOpacity)) : AnyShapeStyle(appearance.secondaryFill), pressed: pressed))
                .overlay(shape.fill(backlight))
                .overlay(shape.fill(surfaceGloss(pressed: pressed)))
        }
    }

    /// Pool of primary light centered under the glyph of an active secondary
    /// button, fading out before the rim — the lamp behind the button cap.
    private var backlight: RadialGradient {
        let opacity = isOn ? appearance.activeBacklightOpacity : 0
        return RadialGradient(
            colors: [Theme.primary.opacity(opacity), .clear],
            center: .center,
            startRadius: 0,
            endRadius: diameter * 0.62
        )
    }

    /// Wraps a fill so it casts a dark inner shadow from the top while pressed,
    /// making the face read as sunk below the rim rather than merely dimmed.
    private func pressedWell(_ style: some ShapeStyle, pressed: Bool) -> AnyShapeStyle {
        guard pressed, appearance.pressedInnerShadowOpacity > 0 else { return AnyShapeStyle(style) }
        return AnyShapeStyle(style.shadow(.inner(
            color: .black.opacity(appearance.pressedInnerShadowOpacity),
            radius: appearance.pressedInnerShadowRadius,
            y: appearance.pressedInnerShadowY
        )))
    }

    // Crisp beveled rim matching the track index badge: bright along the top
    // edge fading to a dark bottom edge, encircling the whole button. While
    // pressed the rim inverts (dark top, light bottom) so the button reads as
    // pushed into the surface rather than raised.
    private func border(pressed: Bool) -> some View {
        let raised: [Color] = [
            .white.opacity(appearance.bevelTopOpacity),
            .white.opacity(appearance.bevelTopOpacity * 0.24),
            .black.opacity(appearance.bevelBottomOpacity)
        ]
        return shape.strokeBorder(
            LinearGradient(
                colors: pressed ? raised.reversed() : raised,
                startPoint: .top,
                endPoint: .bottom
            ),
            lineWidth: appearance.bevelWidth
        )
    }
}

/// Draws a string of digits, colons, and minus signs as a slanted
/// seven-segment LED display: every cell shows all of its segments as faint
/// "ghosts" (the unlit LED material) with the active ones lit and glowing.
/// Understands `0`–`9`, `:`, and `-`; anything else renders as a blank cell.
struct SevenSegmentDisplay: View {
    let text: String
    var digitHeight: CGFloat

    /// Light mode renders as an LCD (dark ink segments that cast a soft shadow
    /// onto the pale glass), dark mode as an LED (glowing segments).
    @Environment(\.colorScheme) private var colorScheme

    // MARK: Metrics (all derived from digitHeight so the display scales as one)

    private var digitWidth: CGFloat { digitHeight * 0.56 }
    private var colonWidth: CGFloat { digitHeight * 0.24 }
    private var thickness: CGFloat { digitHeight * 0.15 }
    private var cellSpacing: CGFloat { digitHeight * 0.24 }
    /// Rightward lean of the digits (tangent of the slant angle), the classic
    /// italic cant of LED clock faces.
    private var skew: CGFloat { 0.10 }

    private var glyphs: [Character] { Array(text) }

    private func width(of glyph: Character) -> CGFloat {
        glyph == ":" ? colonWidth : digitWidth
    }

    private var intrinsicWidth: CGFloat {
        let cells = glyphs.reduce(CGFloat.zero) { $0 + width(of: $1) }
        let gaps = cellSpacing * CGFloat(max(glyphs.count - 1, 0))
        // The slant pushes the top of the leftmost cell past the layout origin,
        // so reserve the overhang.
        return cells + gaps + digitHeight * skew
    }

    /// Extra canvas margin on every side so the glow blur can trail off
    /// smoothly instead of being clipped hard at the digits' layout edge.
    /// Trimmed back out with negative padding so layout is unaffected.
    private var bleed: CGFloat { digitHeight * 0.5 }

    var body: some View {
        Canvas { context, size in
            context.translateBy(x: bleed, y: bleed)
            // Shear so cells lean right at the top while their baselines stay put.
            context.concatenate(CGAffineTransform(
                a: 1, b: 0, c: -skew, d: 1, tx: skew * digitHeight, ty: 0
            ))

            let isLED = colorScheme == .dark
            let segmentColor = Theme.readoutGlow

            // Unlit segments: softened a touch on the LED/LCD glass.
            var ghost = context
            ghost.addFilter(.blur(radius: thickness * 0.12))

            // LED: a wide halo of the segment color underneath the crisp fill.
            var glow = context
            glow.addFilter(.blur(radius: digitHeight * 0.17))

            // LCD: the ink layer floats just above the backing, dropping a
            // tight shadow down-right onto the glass.
            var shade = context
            shade.translateBy(x: 0.8, y: 1.2)
            shade.addFilter(.blur(radius: thickness * 0.35))

            var x: CGFloat = 0
            for glyph in glyphs {
                let cell = CGRect(x: x, y: 0, width: width(of: glyph), height: digitHeight)
                let lit = litPaths(for: glyph, in: cell)
                for path in unlitPaths(for: glyph, in: cell) {
                    ghost.fill(path, with: .color(segmentColor.opacity(0.14)))
                }
                for path in lit {
                    if isLED {
                        glow.fill(path, with: .color(segmentColor.opacity(0.95)))
                    } else {
                        shade.fill(path, with: .color(.black.opacity(0.30)))
                    }
                }
                for path in lit {
                    context.fill(path, with: .color(segmentColor))
                }
                x = cell.maxX + cellSpacing
            }
        }
        .frame(width: intrinsicWidth + bleed * 2, height: digitHeight + bleed * 2)
        .padding(-bleed)
    }

    // MARK: Segment geometry

    private enum Segment: CaseIterable {
        case top, topRight, bottomRight, bottom, bottomLeft, topLeft, middle
    }

    private static let segmentMap: [Character: Set<Segment>] = [
        "0": [.top, .topRight, .bottomRight, .bottom, .bottomLeft, .topLeft],
        "1": [.topRight, .bottomRight],
        "2": [.top, .topRight, .middle, .bottomLeft, .bottom],
        "3": [.top, .topRight, .middle, .bottomRight, .bottom],
        "4": [.topLeft, .middle, .topRight, .bottomRight],
        "5": [.top, .topLeft, .middle, .bottomRight, .bottom],
        "6": [.top, .topLeft, .middle, .bottomLeft, .bottomRight, .bottom],
        "7": [.top, .topRight, .bottomRight],
        "8": Set(Segment.allCases),
        "9": [.top, .topRight, .bottomRight, .bottom, .topLeft, .middle],
        "-": [.middle]
    ]

    private func litPaths(for glyph: Character, in cell: CGRect) -> [Path] {
        if glyph == ":" { return colonDots(in: cell) }
        guard let segments = Self.segmentMap[glyph] else { return [] }
        return segments.map { path(for: $0, in: cell) }
    }

    private func unlitPaths(for glyph: Character, in cell: CGRect) -> [Path] {
        if glyph == ":" { return [] }
        let lit = Self.segmentMap[glyph] ?? []
        return Segment.allCases.filter { !lit.contains($0) }.map { path(for: $0, in: cell) }
    }

    private func path(for segment: Segment, in cell: CGRect) -> Path {
        let half = thickness / 2
        // Breathing room between segment tips so they don't fuse at the corners.
        let gap = thickness * 0.42
        let left = cell.minX + half
        let right = cell.maxX - half
        let top = cell.minY + half
        let mid = cell.midY
        let bottom = cell.maxY - half

        switch segment {
        case .top:
            return horizontalSegment(fromX: left + gap, toX: right - gap, centerY: top)
        case .middle:
            return horizontalSegment(fromX: left + gap, toX: right - gap, centerY: mid)
        case .bottom:
            return horizontalSegment(fromX: left + gap, toX: right - gap, centerY: bottom)
        case .topLeft:
            return verticalSegment(fromY: top + gap, toY: mid - gap, centerX: left)
        case .topRight:
            return verticalSegment(fromY: top + gap, toY: mid - gap, centerX: right)
        case .bottomLeft:
            return verticalSegment(fromY: mid + gap, toY: bottom - gap, centerX: left)
        case .bottomRight:
            return verticalSegment(fromY: mid + gap, toY: bottom - gap, centerX: right)
        }
    }

    /// Elongated hexagon with pointed ends, the canonical LED segment shape.
    private func horizontalSegment(fromX xa: CGFloat, toX xb: CGFloat, centerY y: CGFloat) -> Path {
        let half = thickness / 2
        var path = Path()
        path.move(to: CGPoint(x: xa, y: y))
        path.addLine(to: CGPoint(x: xa + half, y: y - half))
        path.addLine(to: CGPoint(x: xb - half, y: y - half))
        path.addLine(to: CGPoint(x: xb, y: y))
        path.addLine(to: CGPoint(x: xb - half, y: y + half))
        path.addLine(to: CGPoint(x: xa + half, y: y + half))
        path.closeSubpath()
        return path
    }

    private func verticalSegment(fromY ya: CGFloat, toY yb: CGFloat, centerX x: CGFloat) -> Path {
        let half = thickness / 2
        var path = Path()
        path.move(to: CGPoint(x: x, y: ya))
        path.addLine(to: CGPoint(x: x + half, y: ya + half))
        path.addLine(to: CGPoint(x: x + half, y: yb - half))
        path.addLine(to: CGPoint(x: x, y: yb))
        path.addLine(to: CGPoint(x: x - half, y: yb - half))
        path.addLine(to: CGPoint(x: x - half, y: ya + half))
        path.closeSubpath()
        return path
    }

    private func colonDots(in cell: CGRect) -> [Path] {
        let side = thickness
        return [cell.height * 0.32, cell.height * 0.68].map { y in
            Path(ellipseIn: CGRect(
                x: cell.midX - side / 2,
                y: cell.minY + y - side / 2,
                width: side,
                height: side
            ))
        }
    }
}

// MARK: - A2 control bar

/// The A2 control bar shared by playlist and compare (spec §3, §5): the
/// transport row, over the readout in playlist mode, on one surface, then
/// the one divider to the content below. Stretches to any window width: the
/// centre group stays centred, the side buttons sit midway between the
/// window edges and the playlist's centre group (`ControlBarTransportRow`),
/// and the readout takes the width inside the 10 pt edge insets. Compare has
/// no readout (its title bar sits below the divider), so its bar ends 10 pt
/// under the transport row.
struct ControlBarLayout<Leading: View, Center: View, Trailing: View, Readout: View>: View {
    @Environment(\.controlBarTopPadding) private var topPadding
    @ViewBuilder let leading: Leading
    @ViewBuilder let center: Center
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let readout: Readout

    private var hasReadout: Bool { Readout.self != EmptyView.self }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ControlBarTransportRow {
                    leading
                        .frame(width: ControlBarMetrics.sideSlotSize.width, height: ControlBarMetrics.sideSlotSize.height)
                    HStack(spacing: ControlBarMetrics.centerSpacing) { center }
                    trailing
                        .frame(width: ControlBarMetrics.sideSlotSize.width, height: ControlBarMetrics.sideSlotSize.height)
                }
                // 12 pt under the cover; 24 pt under the titlebar overlay so
                // the side buttons clear the window buttons and the toggle.
                .padding(.top, topPadding)
                .padding(.bottom, hasReadout ? 0 : ControlBarMetrics.transportRowBottomPadding)
                if hasReadout {
                    readout
                        .padding(.horizontal, ControlBarMetrics.edgeInset)
                        .padding(.top, ControlBarMetrics.readoutTopSpacing)
                        .padding(.bottom, ControlBarMetrics.readoutBottomPadding)
                }
            }
            // Raised deck: a light wash lifts the bar off the shared window
            // material. Decorative, so it must not take clicks from the drag
            // area behind it.
            .background(Theme.controlBarLift.allowsHitTesting(false))
            // The control bar doubles as the titlebar: clicks on empty bar
            // space drag the window.
            .background(WindowDragArea())
            ControlBarDivider()
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension EnvironmentValues {
    @Entry var controlBarTopPadding: CGFloat = TakesWindowPolicy.controlBarTopPaddingBelowArtwork
}

extension ControlBarLayout where Readout == EmptyView {
    /// A control bar with no readout: compare's (A2 compare title-bar
    /// variant), whose elapsed time is in the title bar below the divider.
    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder center: () -> Center,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(leading: leading, center: center, trailing: trailing) {
            EmptyView()
        }
    }
}

/// The groove between the control bar and the content below (spec §3): a
/// dark edge over a reflected light edge, as half-point lines so the
/// divider keeps a 1 pt layout height. The only divider under the bar.
struct ControlBarDivider: View {
    nonisolated static let height: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.transportDividerShadow)
            Rectangle().fill(Theme.transportDividerHighlight)
        }
        .frame(height: Self.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Shuffle, Blind and Repeat (spec §5.1): a plain 20 pt icon in the
/// secondary label colour, no circle, centred in the 30 × 40 pt side slot.
/// Engaged, the glyph lights the way v2.9.0's engaged secondary buttons do
/// (`Theme.primaryLitGlyph` with the secondary appearance's glow and bloom).
struct ControlBarSideButtonStyle: ButtonStyle {
    static let glyphSize: CGFloat = 20

    var isOn = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.transportAppearance) private var transportAppearance

    func makeBody(configuration: Configuration) -> some View {
        let appearance = colorScheme == .dark ? transportAppearance.darkSecondary : transportAppearance.lightSecondary
        let glow = isOn && isEnabled
        return configuration.label
            .font(.system(size: Self.glyphSize, weight: .medium))
            .foregroundStyle(isOn ? AnyShapeStyle(Theme.primaryLitGlyph) : AnyShapeStyle(.secondary))
            .shadow(color: glow ? Theme.primary.opacity(appearance.activeGlyphGlowOpacity) : .clear,
                    radius: glow ? CGFloat(appearance.activeGlyphGlowRadius) : 0)
            .shadow(color: glow ? Theme.primary.opacity(appearance.activeGlyphBloomOpacity) : .clear,
                    radius: glow ? CGFloat(appearance.activeGlyphBloomRadius) : 0)
            .frame(width: ControlBarMetrics.sideSlotSize.width,
                   height: ControlBarMetrics.sideSlotSize.height)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.55 : 1) : 0.35)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The transport row: the centre group centred, and the two side buttons
/// (Shuffle or Blind, and Repeat) each centred between its window edge and
/// the playlist's Previous · Play · Next group. Compare keeps the same side
/// positions even though its centre group (Play · Switch Track) is narrower,
/// so Blind and Repeat don't move between modes. Spans the full bar width.
/// Expects three subviews: leading, centre group, trailing.
struct ControlBarTransportRow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(
            width: proposal.width ?? sizes.reduce(0) { $0 + $1.width },
            height: sizes.map(\.height).max() ?? 0
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let sideCenter = ControlBarMetrics.sideButtonCenterX(barWidth: bounds.width)
        let xs = [bounds.minX + sideCenter, bounds.midX, bounds.maxX - sideCenter]
        for (subview, x) in zip(subviews, xs) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .center, proposal: .unspecified)
        }
    }
}

/// A2 control-bar metrics (spec §3, §5.1) and v2.9.0's transport button
/// sizes.
enum ControlBarMetrics {
    static let edgeInset: CGFloat = 10
    /// Shuffle/Blind and Repeat: a 20 pt glyph's hit area.
    static let sideSlotSize = CGSize(width: 30, height: 40)
    static let centerSpacing: CGFloat = 12
    /// Playlist only: the gap from the transport row to the readout, and
    /// from the readout to the divider.
    static let readoutTopSpacing: CGFloat = 10
    static let readoutBottomPadding: CGFloat = 10
    /// Compare only: the gap from the transport row to the divider.
    static let transportRowBottomPadding: CGFloat = 10
    static let primaryDiameter: CGFloat = 56
    static let primaryGlyphSize: CGFloat = 22
    static let secondaryDiameter: CGFloat = 40
    static let secondaryGlyphSize: CGFloat = 15

    /// The playlist's Previous · Play · Next group (160 pt), which places the
    /// side buttons in both modes.
    static let playlistCenterGroupWidth = secondaryDiameter * 2 + primaryDiameter + centerSpacing * 2

    /// A side button's centre, from its window edge: midway between the edge
    /// and the playlist's centre group (50 pt in a 360 pt window).
    static func sideButtonCenterX(barWidth: CGFloat) -> CGFloat {
        max((barWidth - playlistCenterGroupWidth) / 4, sideSlotSize.width / 2)
    }
}

/// Debug panel (surfaced in an inspector via Debug ▸ Appearance Tuner) for
/// live-adjusting the transport button surface treatment while the app runs.
struct AppearanceTunerView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        let badge = $settings.indexBadgeAppearance
        let badgeDefaults = IndexBadgeAppearance()
        return Form {
            buttonSection("Primary Button — Light", $settings.transportAppearance.lightPrimary,
                          defaults: TransportAppearance().lightPrimary, showFill: false)
            buttonSection("Secondary Buttons — Light", $settings.transportAppearance.lightSecondary,
                          defaults: TransportAppearance().lightSecondary, showFill: true)
            buttonSection("Primary Button — Dark", $settings.transportAppearance.darkPrimary,
                          defaults: TransportAppearance().darkPrimary, showFill: false)
            buttonSection("Secondary Buttons — Dark", $settings.transportAppearance.darkSecondary,
                          defaults: TransportAppearance().darkSecondary, showFill: true)
            Section("Index Badge") {
                tuner("Bevel width", value: badge.bevelWidth, in: 0...4, default: badgeDefaults.bevelWidth)
                tuner("Bevel top", value: badge.bevelTopOpacity, in: 0...1, default: badgeDefaults.bevelTopOpacity)
                tuner("Bevel bottom", value: badge.bevelBottomOpacity, in: 0...1, default: badgeDefaults.bevelBottomOpacity)
                tuner("Shadow opacity", value: badge.shadowOpacity, in: 0...1, default: badgeDefaults.shadowOpacity)
                tuner("Shadow radius", value: badge.shadowRadius, in: 0...8, default: badgeDefaults.shadowRadius)
                tuner("Shadow y", value: badge.shadowY, in: -4...4, default: badgeDefaults.shadowY)
            }
            Section {
                Button("Reset All to Defaults") {
                    settings.transportAppearance = TransportAppearance()
                    settings.indexBadgeAppearance = IndexBadgeAppearance()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Appearance")
    }

    @ViewBuilder
    private func buttonSection(_ title: String, _ b: Binding<TransportButtonAppearance>,
                               defaults d: TransportButtonAppearance, showFill: Bool) -> some View {
        Section(title) {
            tuner("Gloss", value: b.glossOpacity, in: 0...1, default: d.glossOpacity)
            tuner("Bevel width", value: b.bevelWidth, in: 0...4, default: d.bevelWidth)
            tuner("Bevel top", value: b.bevelTopOpacity, in: 0...1, default: d.bevelTopOpacity)
            tuner("Bevel bottom", value: b.bevelBottomOpacity, in: 0...1, default: d.bevelBottomOpacity)
            if showFill {
                HStack(spacing: 6) {
                    ColorPicker("Fill", selection: b.secondaryFill, supportsOpacity: true)
                        .font(.caption)
                    Spacer()
                    resetButton(disabled: false) { b.secondaryFill.wrappedValue = d.secondaryFill }
                }
                tuner("Active highlight", value: b.activeFillOpacity, in: 0...1, default: d.activeFillOpacity)
                tuner("Active glyph glow", value: b.activeGlyphGlowOpacity, in: 0...1, default: d.activeGlyphGlowOpacity)
                tuner("Active glow radius", value: b.activeGlyphGlowRadius, in: 0...12, default: d.activeGlyphGlowRadius)
                tuner("Active glyph bloom", value: b.activeGlyphBloomOpacity, in: 0...1, default: d.activeGlyphBloomOpacity)
                tuner("Active bloom radius", value: b.activeGlyphBloomRadius, in: 0...16, default: d.activeGlyphBloomRadius)
                tuner("Active backlight", value: b.activeBacklightOpacity, in: 0...1, default: d.activeBacklightOpacity)
                tuner("Active spill", value: b.activeSpillOpacity, in: 0...1, default: d.activeSpillOpacity)
                tuner("Active spill radius", value: b.activeSpillRadius, in: 0...16, default: d.activeSpillRadius)
            }
            tuner("Inset dark opacity", value: b.insetDarkOpacity, in: 0...1, default: d.insetDarkOpacity)
            tuner("Inset dark radius", value: b.insetDarkRadius, in: 0...8, default: d.insetDarkRadius)
            tuner("Inset dark y", value: b.insetDarkY, in: -4...4, default: d.insetDarkY)
            tuner("Inset light opacity", value: b.insetLightOpacity, in: 0...1, default: d.insetLightOpacity)
            tuner("Inset light radius", value: b.insetLightRadius, in: 0...8, default: d.insetLightRadius)
            tuner("Inset light y", value: b.insetLightY, in: -4...4, default: d.insetLightY)
            tuner("Pressed inner shadow", value: b.pressedInnerShadowOpacity, in: 0...1, default: d.pressedInnerShadowOpacity)
            tuner("Pressed inner radius", value: b.pressedInnerShadowRadius, in: 0...8, default: d.pressedInnerShadowRadius)
            tuner("Pressed inner y", value: b.pressedInnerShadowY, in: -4...4, default: d.pressedInnerShadowY)
        }
    }

    private func tuner(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>, default def: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            HStack(spacing: 6) {
                Slider(value: value, in: range)
                resetButton(disabled: value.wrappedValue == def) { value.wrappedValue = def }
            }
        }
    }

    /// Small inline reset control shown beside each slider / the fill picker.
    private func resetButton(disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(disabled)
        .help("Reset to default")
    }
}
