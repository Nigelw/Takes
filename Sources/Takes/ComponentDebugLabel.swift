import AppKit
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

/// AppKit counterpart of `componentDebugLabel` for views SwiftUI can't tag,
/// such as the playlist table's rows: the same outline and badge, drawn by
/// a view that sits above its siblings and never takes clicks.
final class ComponentDebugBadgeView: NSView {
    var name: String { didSet { needsDisplay = true } }
    let color: NSColor

    init(name: String, color: NSColor) {
        self.name = name
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.zPosition = 10
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        outline.lineWidth = 1
        color.setStroke()
        outline.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: name, attributes: attributes)
        let size = text.size()
        let badge = NSRect(x: 2, y: 2, width: ceil(size.width) + 8, height: ceil(size.height) + 2)
        color.setFill()
        NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
        text.draw(at: NSPoint(x: badge.minX + 4, y: badge.minY + 1))
    }
}
