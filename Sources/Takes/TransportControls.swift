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

/// Invisible AppKit view that makes the transport bar behave like a titlebar:
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
    /// active.
    var activeGlyphGlowOpacity: Double = 0
    var activeGlyphGlowRadius: Double = 0
    /// Dark outer shadow above the button (recessed/pressed-in cue).
    var insetDarkOpacity: Double = 0.16
    var insetDarkRadius: Double = 1.5
    var insetDarkY: Double = -1
    /// Light outer lip below the button (recessed/pressed-in cue).
    var insetLightOpacity: Double = 0.60
    var insetLightRadius: Double = 1.0
    var insetLightY: Double = 1.5
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
        insetDarkY: -0.75
    )
    var lightSecondary = TransportButtonAppearance(
        glossOpacity: 0.70,
        bevelWidth: 1.0,
        bevelBottomOpacity: 0.20,
        activeFillOpacity: 0.04,
        activeGlyphGlowOpacity: 0.49,
        activeGlyphGlowRadius: 9.46,
        insetDarkRadius: 1.0,
        insetDarkY: -0.75,
        insetLightRadius: 0.75,
        insetLightY: 1.0
    )
    var darkPrimary = TransportButtonAppearance(
        glossOpacity: 0.32,
        bevelTopOpacity: 0.40,
        bevelBottomOpacity: 0.60,
        insetDarkOpacity: 0.50,
        insetDarkY: -0.75,
        insetLightOpacity: 0.12
    )
    var darkSecondary = TransportButtonAppearance(
        glossOpacity: 0.15,
        bevelWidth: 1.0,
        bevelTopOpacity: 0.35,
        bevelBottomOpacity: 0.50,
        activeFillOpacity: 0.10,
        activeGlyphGlowOpacity: 0.83,
        activeGlyphGlowRadius: 3.34,
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

/// Circular transport button styling shared by Play, Switch Track, and Repeat.
///
/// - `.primary` is the filled indigo call-to-action (Play/Pause).
/// - `.secondary` is a subtle bordered circle; when `isOn` it adopts the
///   primary tint to read as an engaged toggle (e.g. Repeat).
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

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(.system(size: glyphSize, weight: .semibold))
            .foregroundStyle(foreground)
            .shadow(color: activeGlyphGlowColor(opacityScale: 0.85), radius: activeGlyphTightGlowRadius)
            .shadow(color: activeGlyphGlowColor(), radius: activeGlyphGlowRadius)
            // Pressed: the glyph sinks with the surface instead of shrinking.
            .offset(y: pressed ? pressedGlyphOffset : 0)
            .frame(width: diameter, height: diameter)
            .background(background(pressed: pressed))
            .overlay(border(pressed: pressed))
            .clipShape(Circle())
            // Outer bevel: a soft dark shadow above and a light lip below make the
            // button read as slightly pressed into the window surface (concave cue).
            .shadow(color: .black.opacity(isEnabled ? appearance.insetDarkOpacity : 0), radius: CGFloat(appearance.insetDarkRadius), y: CGFloat(appearance.insetDarkY))
            .shadow(color: .white.opacity(isEnabled ? appearance.insetLightOpacity : 0), radius: CGFloat(appearance.insetLightRadius), y: CGFloat(appearance.insetLightY))
            .opacity(isEnabled ? 1 : 0.4)
            .brightness(pressed ? -0.06 : 0)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .contentShape(Circle())
    }

    private var foreground: Color {
        switch kind {
        case .primary:
            return .white
        case .secondary:
            return isOn ? Theme.primary : Color.primary.opacity(0.75)
        }
    }

    private var activeGlyphGlowRadius: CGFloat {
        kind == .secondary && isOn ? CGFloat(appearance.activeGlyphGlowRadius) : 0
    }

    private var activeGlyphTightGlowRadius: CGFloat {
        max(activeGlyphGlowRadius * 0.45, 0)
    }

    private func activeGlyphGlowColor(opacityScale: Double = 1) -> Color {
        guard kind == .secondary, isOn else { return .clear }
        return Theme.primary.opacity(appearance.activeGlyphGlowOpacity * opacityScale)
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
            Circle().fill(Theme.primary).overlay(Circle().fill(surfaceGloss(pressed: pressed)))
        case .secondary:
            Circle()
                .fill(isOn ? AnyShapeStyle(Theme.primary.opacity(appearance.activeFillOpacity)) : AnyShapeStyle(appearance.secondaryFill))
                .overlay(Circle().fill(surfaceGloss(pressed: pressed)))
        }
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
        return Circle().strokeBorder(
            LinearGradient(
                colors: pressed ? raised.reversed() : raised,
                startPoint: .top,
                endPoint: .bottom
            ),
            lineWidth: appearance.bevelWidth
        )
    }
}

/// "Digital readout" showing elapsed time, styled as a beveled inset panel on a
/// piece of hardware: an evenly recessed well with the digits engraved into it.
struct DigitalTimeReadout: View {
    /// Fixed panel height. Shared with the Play button diameter so the two line
    /// up exactly. Comfortably clears the 30pt digits with breathing room above
    /// and below.
    static let panelHeight: CGFloat = 56

    let elapsed: String

    private let cornerRadius: CGFloat = 10

    var body: some View {
        Text(elapsed)
            .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(.primary)
            // Engraved digits: a faint light copy pressed just below the glyphs
            // so they read as debossed into the panel, plus a hint of teal
            // backlight to evoke an LCD without tipping into neon.
            .shadow(color: Theme.readoutHighlight, radius: 0, y: 0.5)
            .shadow(color: Theme.secondary.opacity(0.22), radius: 3.5)
            // The digits' layout box lands 1pt high inside the fixed-height
            // panel, so nudge the glyphs down to true-center them.
            .offset(y: 1)
            .padding(.horizontal, 28)
            .frame(minWidth: 180)
            .frame(height: Self.panelHeight)
            .background {
                // Even, all-sides recess: one inner shadow rings the whole well
                // instead of a top-only edge, so the bevel looks uniform.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        Theme.readoutSurface
                            .shadow(.inner(color: Theme.readoutShadow, radius: 2.5, y: 0.5))
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.readoutStroke, lineWidth: 1)
            }
            .accessibilityLabel("Elapsed Time")
            .accessibilityValue(elapsed)
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
            }
            tuner("Inset dark opacity", value: b.insetDarkOpacity, in: 0...1, default: d.insetDarkOpacity)
            tuner("Inset dark radius", value: b.insetDarkRadius, in: 0...8, default: d.insetDarkRadius)
            tuner("Inset dark y", value: b.insetDarkY, in: -4...4, default: d.insetDarkY)
            tuner("Inset light opacity", value: b.insetLightOpacity, in: 0...1, default: d.insetLightOpacity)
            tuner("Inset light radius", value: b.insetLightRadius, in: 0...8, default: d.insetLightRadius)
            tuner("Inset light y", value: b.insetLightY, in: -4...4, default: d.insetLightY)
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
