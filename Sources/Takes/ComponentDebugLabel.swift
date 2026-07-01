import SwiftUI

/// Overlays a named badge and outline on a view so its region can be identified
/// on screen. Driven by `AppSettings.showsComponentDebugLabels` (Help ▸ Show
/// Component Names) to make it easy to refer to specific parts of the UI while
/// discussing a redesign.
///
/// The overlay never participates in hit testing, so the app stays fully usable
/// while the labels are showing, and it draws no chrome when disabled.
struct ComponentDebugLabelModifier: ViewModifier {
    let name: String
    let enabled: Bool
    let color: Color

    func body(content: Content) -> some View {
        content
            .overlay {
                if enabled {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(color, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if enabled {
                    Text(name)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .fixedSize()
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(color, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .padding(2)
                        .fixedSize()
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    /// Tags this view as a named component for the Help ▸ Show Component Names
    /// debug overlay. A no-op when `enabled` is `false`.
    func componentDebugLabel(
        _ name: String,
        enabled: Bool,
        color: Color = .pink
    ) -> some View {
        modifier(ComponentDebugLabelModifier(name: name, enabled: enabled, color: color))
    }
}
