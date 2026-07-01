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

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: glyphSize, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: diameter, height: diameter)
            .background(background)
            .overlay(border)
            .clipShape(Circle())
            .shadow(
                color: kind == .primary && isEnabled ? Theme.primary.opacity(0.35) : .clear,
                radius: kind == .primary ? 5 : 0,
                y: kind == .primary ? 2 : 0
            )
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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

    @ViewBuilder
    private var background: some View {
        switch kind {
        case .primary:
            Circle()
                .fill(Theme.primary)
                .overlay(
                    Circle().fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.22), .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                )
        case .secondary:
            Circle()
                .fill(isOn ? Theme.primary.opacity(0.16) : Color.primary.opacity(0.06))
        }
    }

    @ViewBuilder
    private var border: some View {
        switch kind {
        case .primary:
            Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        case .secondary:
            Circle().strokeBorder(
                isOn ? Theme.primary.opacity(0.45) : Color.primary.opacity(0.12),
                lineWidth: 1
            )
        }
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
