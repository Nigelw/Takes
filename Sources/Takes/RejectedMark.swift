import AppKit

/// The rejection indicator (culling §9.1): a broken heart, drawn in code at
/// the three sizes it appears at (the version mark column, the compare
/// strip and the artwork badge) so each gets its exact gap and zigzag.
///
/// The geometry is on the design's 24-unit grid with y pointing down. The
/// heart splits along a zigzag from the notch to the tip, and the gap comes
/// from moving the two halves apart, never from cutting a shape out: each
/// half shifts sideways by half the tip gap and tilts outward about the
/// tip, so the gap is widest at the notch and narrowest at the tip. The gap
/// is empty, so whatever is behind the mark (the row, its selection) shows
/// through it.
enum RejectedMark {
    static let notch = CGPoint(x: 12, y: 6.4)
    static let tip = CGPoint(x: 12, y: 21.2)

    /// Sizes up to this use the three-turn zigzag; larger ones the six-turn one.
    static let smallSizeLimit: CGFloat = 18

    /// The zigzag's turns between the notch and the tip, without the ends.
    static func turns(size: CGFloat) -> [CGPoint] {
        if size <= smallSizeLimit {
            return [CGPoint(x: 10.3, y: 10.4), CGPoint(x: 13.6, y: 13.5), CGPoint(x: 11.4, y: 17.3)]
        }
        return [
            CGPoint(x: 10.6, y: 9.4), CGPoint(x: 13.2, y: 12.1), CGPoint(x: 10.9, y: 15),
            CGPoint(x: 12.9, y: 17.9), CGPoint(x: 11.7, y: 19.6),
        ]
    }

    /// How far the halves move apart at a given size, in grid units.
    struct Separation: Equatable {
        /// The gap in pixels, `1.1 + 0.028 × size`, converted to grid units
        /// and kept between 0.8 and 3.
        var baseGap: CGFloat
        /// The horizontal gap at the notch (1.5× the base gap).
        var notchGap: CGFloat { baseGap * 1.5 }
        /// The horizontal gap at the tip (0.45× the base gap).
        var tipGap: CGFloat { baseGap * 0.45 }
        /// Each half's outward tilt about the tip, in radians.
        var tilt: CGFloat {
            asin(min(0.5, (notchGap - tipGap) / (2 * (RejectedMark.tip.y - RejectedMark.notch.y))))
        }

        /// The left half's placement: tilted left about the tip, then shifted left.
        var leftTransform: CGAffineTransform { Self.transform(tilt: -tilt, shift: -tipGap / 2) }
        /// The right half's placement, mirrored.
        var rightTransform: CGAffineTransform { Self.transform(tilt: tilt, shift: tipGap / 2) }

        private static func transform(tilt: CGFloat, shift: CGFloat) -> CGAffineTransform {
            let tip = RejectedMark.tip
            return CGAffineTransform(translationX: tip.x, y: tip.y)
                .rotated(by: tilt)
                .translatedBy(x: -tip.x, y: -tip.y)
                .concatenating(CGAffineTransform(translationX: shift, y: 0))
        }
    }

    static func separation(size: CGFloat) -> Separation {
        let unit = size / 24
        let pixels = 1.1 + 0.028 * size
        return Separation(baseGap: min(3, max(0.8, pixels / unit)))
    }

    /// The two halves, moved apart, on the 24-unit grid (y down). Each is its
    /// own closed path: its side of the outline, then back along the zigzag.
    static func gridHalves(size: CGFloat) -> (left: CGPath, right: CGPath) {
        let zig = turns(size: size)
        let separation = separation(size: size)

        let left = CGMutablePath()
        left.move(to: tip)
        left.addCurve(to: CGPoint(x: 2, y: 8.6), control1: CGPoint(x: 9.5, y: 19.6), control2: CGPoint(x: 2, y: 14.8))
        left.addCurve(to: CGPoint(x: 7.5, y: 2.8), control1: CGPoint(x: 2, y: 5.3), control2: CGPoint(x: 4.5, y: 2.8))
        left.addCurve(to: notch, control1: CGPoint(x: 9.5, y: 2.8), control2: CGPoint(x: 11.2, y: 4))
        zig.forEach { left.addLine(to: $0) }
        left.closeSubpath()

        let right = CGMutablePath()
        right.move(to: notch)
        right.addCurve(to: CGPoint(x: 16.5, y: 2.8), control1: CGPoint(x: 12.8, y: 4), control2: CGPoint(x: 14.5, y: 2.8))
        right.addCurve(to: CGPoint(x: 22, y: 8.6), control1: CGPoint(x: 19.5, y: 2.8), control2: CGPoint(x: 22, y: 5.3))
        right.addCurve(to: tip, control1: CGPoint(x: 22, y: 14.8), control2: CGPoint(x: 14.5, y: 19.6))
        zig.reversed().forEach { right.addLine(to: $0) }
        right.closeSubpath()

        var leftTransform = separation.leftTransform
        var rightTransform = separation.rightTransform
        return (
            left.copy(using: &leftTransform) ?? left,
            right.copy(using: &rightTransform) ?? right
        )
    }

    /// The halves scaled to `size` points, placed in `rect` (y down).
    static func halves(size: CGFloat, in rect: CGRect) -> (left: CGPath, right: CGPath) {
        let grid = gridHalves(size: size)
        let unit = size / 24
        var transform = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: unit, y: unit)
        return (grid.left.copy(using: &transform) ?? grid.left, grid.right.copy(using: &transform) ?? grid.right)
    }

    /// The mark in the badge grey. Drawn when displayed, so the dynamic
    /// colour follows the appearance.
    static func image(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let halves = halves(size: size, in: rect)
            context.setFillColor(PlaylistRowPalette.rejectionBadge.cgColor)
            context.addPath(halves.left)
            context.addPath(halves.right)
            context.fillPath()
            return true
        }
        image.accessibilityDescription = PlaylistRowText.rejectedAccessibilityValue
        return image
    }

    /// The badge's ring as one outline: both halves widened by `ring` with
    /// mitred joins, so the ring stays an even offset of the heart, keeps the
    /// notch's V and a pointed tip, and covers the crack. Cut out of the
    /// thumbnail so the row shows around the badge (y down, in `rect`).
    static func ringOutline(size: CGFloat, ring: CGFloat, in rect: CGRect) -> CGPath {
        let halves = halves(size: size, in: rect)
        let pieces = [halves.left, halves.right].flatMap { half in
            [half, half.copy(strokingWithWidth: ring * 2, lineCap: .butt, lineJoin: .miter, miterLimit: 1.5)]
        }
        return pieces.dropFirst().reduce(pieces[0]) { $0.union($1) }
    }
}
