import AppKit
import SwiftUI

extension NSAppearance {
    /// Whether this appearance resolves to a dark variant, used by the dynamic
    /// color providers below so every token adapts to light/dark automatically.
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

/// Central palette and semantic color tokens for the Takes redesign.
///
/// Everything visual draws from here so the primary (indigo) and secondary
/// (teal) hues stay consistent across the transport bar, timeline, and rows.
/// Colors are built from `NSColor` dynamic providers so a single token yields
/// the right value in light and dark mode.
enum Theme {
    private static func dynamic(
        light: (r: Double, g: Double, b: Double),
        dark: (r: Double, g: Double, b: Double)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.isDark ? dark : light
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        })
    }

    // MARK: Brand hues

    /// Indigo-purple pulled from `UI Colors.png` (#6C63E9). Active track,
    /// active buttons, active waveform.
    static let primary = dynamic(
        light: (0.424, 0.388, 0.914), // #6C63E9
        dark: (0.561, 0.529, 0.961)   // #8F87F5
    )

    /// Teal used for the playhead and the loop-selection highlight.
    static let secondary = dynamic(
        light: (0.059, 0.702, 0.780), // #0FB3C7
        dark: (0.220, 0.831, 0.902)   // #38D4E6
    )

    // MARK: Semantic tokens

    /// Fill behind an active track row (info + lane).
    static let activeRowFill = primary.opacity(0.12)

    /// Waveform color for inactive (non-selected) tracks.
    static let waveformInactive = dynamic(
        light: (0.52, 0.52, 0.56),
        dark: (0.60, 0.60, 0.64)
    )

    /// Hairline separators between full-bleed regions and rows.
    static let hairline = Color(nsColor: .separatorColor)
}
