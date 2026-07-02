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
/// (amber in light mode, cyan in dark) hues stay consistent across the
/// transport bar, timeline, and rows.
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

    /// Accent for the playhead and the loop-selection highlight. Tied to the
    /// transport readout's display color (`readoutGlass`/`readoutGlow`): amber
    /// in light mode, LED cyan in dark. The light amber is deepened a touch
    /// from the glass color so a 2pt line holds up on light backgrounds.
    static let secondary = dynamic(
        light: (0.871, 0.557, 0.118), // #DE8E1E
        dark: (0.220, 0.831, 0.902)   // #38D4E6
    )

    // MARK: Semantic tokens

    /// Fill behind an active track row (info + lane).
    static let activeRowFill = primary.opacity(0.12)

    /// Neutral fill for the index badge on an inactive row (the active row uses
    /// `primary`). Kept subtle so the number reads without competing with the title.
    static let indexBadgeInactiveFill = dynamic(
        light: (0.90, 0.90, 0.92),
        dark: (0.24, 0.24, 0.27)
    )

    /// Surface fill for the secondary transport buttons (Switch Track, Repeat)
    /// when not engaged. Distinct from the window background so they read as
    /// tactile controls rather than blending in.
    static let transportButtonFill = dynamic(
        light: (0.965, 0.968, 0.98),
        dark: (0.22, 0.23, 0.27)
    )

    /// Waveform color for inactive (non-selected) tracks.
    static let waveformInactive = dynamic(
        light: (0.52, 0.52, 0.56),
        dark: (0.60, 0.60, 0.64)
    )

    /// Hairline separators between full-bleed regions and rows.
    static let hairline = Color(nsColor: .separatorColor)

    /// Opaque frozen-column edge dividing the info/control column from the
    /// ruler/waveform column. Opaque (unlike the translucent `hairline`) so ruler
    /// notches sit behind it cleanly instead of bleeding through.
    static let frozenColumnEdge = dynamic(
        light: (0.82, 0.82, 0.84),
        dark: (0.28, 0.28, 0.30)
    )

    /// Soft drop shadow cast by the transport bar onto the timeline header, so the
    /// header reads as slightly recessed beneath it. A touch stronger in dark mode.
    static let transportShadow = Color(nsColor: NSColor(name: nil) { appearance in
        NSColor(srgbRed: 0, green: 0, blue: 0, alpha: appearance.isDark ? 0.45 : 0.10)
    })

    // MARK: Beveled transport readout

    /// Fill for the transport time readout panel.
    static let readoutSurface = dynamic(
        light: (0.898, 0.910, 0.937), // #E5E8EF
        dark: (0.047, 0.055, 0.071)   // #0C0E12
    )

    private static func whiteAlpha(light: Double, dark: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(srgbRed: 1, green: 1, blue: 1, alpha: appearance.isDark ? dark : light)
        })
    }

    /// Bright light edge of the readout, also used to engrave the digits.
    static let readoutHighlight = whiteAlpha(light: 0.72, dark: 0.08)

    /// Glass window of the transport time readout. Two different machines:
    /// light mode is a 90s amber-backlit LCD (the Alesis/Yamaha rack look),
    /// dark mode the unlit near-black glass of an LED display.
    static let readoutGlass = dynamic(
        light: (0.922, 0.647, 0.235), // #EBA53C
        dark: (0.027, 0.031, 0.043)   // #07080B
    )

    /// Seven-segment digit color: dark warm-brown LCD ink on the amber glass
    /// in light mode, glowing LED cyan in dark mode.
    static let readoutGlow = dynamic(
        light: (0.243, 0.145, 0.055), // #3E250E
        dark: (0.220, 0.831, 0.902)   // #38D4E6
    )

    /// Inner shadow of the readout's recessed glass well. Softer on the pale
    /// LCD pane, deep on the dark LED glass.
    static let readoutWellShadow = Color(nsColor: NSColor(name: nil) { appearance in
        NSColor(srgbRed: 0, green: 0, blue: 0, alpha: appearance.isDark ? 0.65 : 0.28)
    })

    /// Soft recessed inner-shadow edge of the readout.
    static let readoutShadow = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.64)
            : NSColor(srgbRed: 96 / 255, green: 104 / 255, blue: 125 / 255, alpha: 0.28)
    })

    /// Outer hairline around the readout panel.
    static let readoutStroke = whiteAlpha(light: 0.76, dark: 0.08)

    /// Bright top edge of the raised bezel ring around the readout glass.
    static let readoutBezelHighlight = whiteAlpha(light: 0.65, dark: 0.14)

    /// Shadowed bottom edge of the bezel ring.
    static let readoutBezelShadow = Color(nsColor: NSColor(name: nil) { appearance in
        NSColor(srgbRed: 0, green: 0, blue: 0, alpha: appearance.isDark ? 0.45 : 0.16)
    })
}
