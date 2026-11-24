#!/usr/bin/env swift
// Generates the record artwork placeholder's four bundled bitmaps
// (docs/a2-record-placeholder-spec.md §3–§5):
//
//   RecordPlaceholderCover.imageset      1440 × 1440 px, light and dark:
//       the whole 360 pt cover square, transparent except the record and
//       its cast and floor shadows (the app draws the ground live).
//   RecordPlaceholderThumbnail.imageset    68 × 68 px, light and dark:
//       the simplified 34 pt thumbnail, ground and cast shadow included.
//
// Usage (from the repository root):
//
//   swift scripts/make-record-placeholder.swift [--preview DIR]
//
// Writes the PNGs and each image set's Contents.json into
// Assets/Assets.xcassets. --preview also writes the covers composited on
// their ground, for comparing against the design artboard.
//
// The output is reproducible: groove opacities and the label's paper noise
// come from fixed seeds, and nothing reads the clock or the environment.
//
// Coordinates are points in a y-down context. Spec angles use the CSS
// convention (0° at 12 o'clock, clockwise); `cssPoint(_:_:_:)` converts.

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Basics

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

struct RGBA {
    var r, g, b, a: Double
    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { (self.r, self.g, self.b, self.a) = (r, g, b, a) }
    init(hex: UInt32, _ a: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, a)
    }
    static func white(_ a: Double) -> RGBA { RGBA(1, 1, 1, a) }
    static func black(_ a: Double) -> RGBA { RGBA(0, 0, 0, a) }
    static let clear = RGBA(0, 0, 0, 0)
    var cg: CGColor { CGColor(colorSpace: sRGB, components: [r, g, b, a])! }
}

enum Appearance: String, CaseIterable { case light, dark }

/// SplitMix64: a small seeded generator, so every run draws the same values.
struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// A point at `radius` from `center` at a CSS angle (degrees, 0 at 12
/// o'clock, clockwise) in a y-down context.
func cssPoint(_ center: CGPoint, _ radius: CGFloat, _ degrees: Double) -> CGPoint {
    let t = degrees * .pi / 180
    return CGPoint(x: center.x + radius * CGFloat(sin(t)), y: center.y - radius * CGFloat(cos(t)))
}

/// The CSS angle (degrees, 0..<360) of `point` around `center`, y down.
func cssAngle(_ dx: Double, _ dy: Double) -> Double {
    let degrees = atan2(dx, -dy) * 180 / .pi
    return degrees < 0 ? degrees + 360 : degrees
}

func circleRect(_ c: CGPoint, _ r: CGFloat) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r) }

func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }

/// A bitmap context `side` points square at `scale` pixels per point, with a
/// y-down coordinate system in points.
func makeContext(side: CGFloat, scale: CGFloat) -> CGContext {
    let px = Int((side * scale).rounded())
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: scale, y: -scale)
    return ctx
}

/// Shadow parameters live in device space (y up, pixels); the CTM doesn't
/// touch them, so convert a CSS shadow here.
func setShadow(_ ctx: CGContext, scale: CGFloat, dy: CGFloat, blur: CGFloat, _ color: RGBA) {
    ctx.setShadow(offset: CGSize(width: 0, height: -dy * scale), blur: blur * scale, color: color.cg)
}

func gradient(_ stops: [(Double, RGBA)]) -> CGGradient {
    let colors = stops.map { $0.1.cg } as CFArray
    let locations = stops.map { CGFloat($0.0) }
    return CGGradient(colorsSpace: sRGB, colors: colors, locations: locations)!
}

func fillRadial(_ ctx: CGContext, center: CGPoint, radius: CGFloat, _ stops: [(Double, RGBA)]) {
    ctx.drawRadialGradient(gradient(stops), startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// Distance from (cx, cy) to the farthest corner of `rect` (CSS
/// `farthest-corner`).
func farthestCorner(_ c: CGPoint, in rect: CGRect) -> CGFloat {
    [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
     CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
        .map { hypot($0.x - c.x, $0.y - c.y) }.max()!
}

func strokeCircle(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, width: CGFloat, _ color: RGBA) {
    ctx.setStrokeColor(color.cg)
    ctx.setLineWidth(width)
    ctx.strokeEllipse(in: circleRect(c, r))
}

func fillCircle(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ color: RGBA) {
    ctx.setFillColor(color.cg)
    ctx.fillEllipse(in: circleRect(c, r))
}

func clipCircle(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat) {
    ctx.addEllipse(in: circleRect(c, r))
    ctx.clip()
}

/// A CSS inset shadow inside a circle: the shadow of everything outside
/// it, clipped to it.
func innerShadow(_ ctx: CGContext, scale: CGFloat, _ c: CGPoint, _ r: CGFloat, dy: CGFloat, blur: CGFloat, _ color: RGBA) {
    ctx.saveGState()
    clipCircle(ctx, c, r)
    setShadow(ctx, scale: scale, dy: dy, blur: blur, color)
    let pad = r + dy.magnitude + blur * 3 + 4
    ctx.addRect(circleRect(c, pad))
    ctx.addEllipse(in: circleRect(c, r))
    ctx.setFillColor(RGBA.black(1).cg)
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
}

/// Draws a layer computed pixel by pixel. `rect` is rounded out to whole
/// device pixels; `shade` receives each pixel centre in points and returns
/// a non-premultiplied colour.
func drawPixels(_ ctx: CGContext, scale: CGFloat, rect: CGRect, blend: CGBlendMode = .normal, alpha: CGFloat = 1,
                _ shade: (Double, Double) -> RGBA) {
    let x0 = Int((rect.minX * scale).rounded(.down)), y0 = Int((rect.minY * scale).rounded(.down))
    let x1 = Int((rect.maxX * scale).rounded(.up)), y1 = Int((rect.maxY * scale).rounded(.up))
    let w = x1 - x0, h = y1 - y0
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let s = Double(scale)
    for j in 0..<h {
        let y = (Double(y0 + j) + 0.5) / s
        for i in 0..<w {
            let x = (Double(x0 + i) + 0.5) / s
            let c = shade(x, y)
            let a = clamp01(c.a)
            let o = (j * w + i) * 4
            bytes[o] = UInt8((clamp01(c.r) * a * 255).rounded())
            bytes[o + 1] = UInt8((clamp01(c.g) * a * 255).rounded())
            bytes[o + 2] = UInt8((clamp01(c.b) * a * 255).rounded())
            bytes[o + 3] = UInt8((a * 255).rounded())
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: sRGB,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let dest = CGRect(x: CGFloat(x0) / scale, y: CGFloat(y0) / scale, width: CGFloat(w) / scale, height: CGFloat(h) / scale)
    ctx.saveGState()
    ctx.setBlendMode(blend)
    ctx.setAlpha(alpha)
    // The context is y-down; flip locally so row 0 lands at the top.
    ctx.translateBy(x: 0, y: dest.maxY + dest.minY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: dest)
    ctx.restoreGState()
}

/// Interpolates colour stops in premultiplied space, as CSS does.
func interpolate(_ stops: [(Double, RGBA)], at t: Double) -> RGBA {
    if t <= stops[0].0 { return stops[0].1 }
    for k in 1..<stops.count where t <= stops[k].0 {
        let (t0, a) = stops[k - 1], (t1, b) = stops[k]
        let f = t1 > t0 ? (t - t0) / (t1 - t0) : 1
        let alpha = a.a + (b.a - a.a) * f
        guard alpha > 0 else { return .clear }
        func mix(_ x: Double, _ y: Double) -> Double { (x * a.a + (y * b.a - x * a.a) * f) / alpha }
        return RGBA(mix(a.r, b.r), mix(a.g, b.g), mix(a.b, b.b), alpha)
    }
    return stops[stops.count - 1].1
}

func over(_ top: RGBA, _ bottom: RGBA) -> RGBA {
    let a = top.a + bottom.a * (1 - top.a)
    guard a > 0 else { return .clear }
    func c(_ t: Double, _ b: Double) -> Double { (t * top.a + b * bottom.a * (1 - top.a)) / a }
    return RGBA(c(top.r, bottom.r), c(top.g, bottom.g), c(top.b, bottom.b), a)
}

// MARK: - Noise

/// Seeded 2-D gradient (Perlin) noise.
struct GradientNoise {
    private var permutation = [Int](repeating: 0, count: 512)
    private var gradients = [(Double, Double)](repeating: (0, 0), count: 256)

    init(seed: UInt64) {
        var random = SeededRandom(seed: seed)
        var p = Array(0..<256)
        for i in stride(from: 255, to: 0, by: -1) {
            p.swapAt(i, Int(random.next() % UInt64(i + 1)))
        }
        for i in 0..<512 { permutation[i] = p[i & 255] }
        for i in 0..<256 {
            let t = random.unit() * 2 * .pi
            gradients[i] = (cos(t), sin(t))
        }
    }

    func value(_ x: Double, _ y: Double) -> Double {
        let xf = floor(x), yf = floor(y)
        let xi = Int(xf) & 255, yi = Int(yf) & 255
        let dx = x - xf, dy = y - yf
        func fade(_ t: Double) -> Double { t * t * t * (t * (t * 6 - 15) + 10) }
        func dot(_ ix: Int, _ iy: Int, _ ox: Double, _ oy: Double) -> Double {
            let g = gradients[permutation[permutation[ix] + iy]]
            return g.0 * ox + g.1 * oy
        }
        let u = fade(dx), v = fade(dy)
        let n00 = dot(xi, yi, dx, dy), n10 = dot(xi + 1, yi, dx - 1, dy)
        let n01 = dot(xi, yi + 1, dx, dy - 1), n11 = dot(xi + 1, yi + 1, dx - 1, dy - 1)
        let a = n00 + (n10 - n00) * u, b = n01 + (n11 - n01) * u
        return a + (b - a) * v
    }

    /// SVG `fractalNoise`-style: octaves summed at halving amplitude,
    /// mapped to 0…1 around 0.5.
    func fractal(_ x: Double, _ y: Double, fx: Double, fy: Double, octaves: Int) -> Double {
        var sum = 0.0, amplitude = 1.0, f = 1.0
        for _ in 0..<octaves {
            sum += value(x * fx * f, y * fy * f) * amplitude
            amplitude *= 0.5
            f *= 2
        }
        return clamp01((sum + 1) / 2)
    }
}

// MARK: - Shared design values

enum Ground {
    static func stops(_ appearance: Appearance) -> [(Double, RGBA)] {
        switch appearance {
        case .dark: [(0, RGBA(hex: 0x34343A)), (0.62, RGBA(hex: 0x1D1D20)), (1, RGBA(hex: 0x141416))]
        case .light: [(0, RGBA(hex: 0xFBFBFD)), (0.62, RGBA(hex: 0xE6E6EB)), (1, RGBA(hex: 0xD4D4DB))]
        }
    }

    /// §3.1: centred at (50%, 38%), reaching the farthest corner.
    static func draw(_ ctx: CGContext, side: CGFloat, _ appearance: Appearance) {
        let square = CGRect(x: 0, y: 0, width: side, height: side)
        let c = CGPoint(x: side * 0.5, y: side * 0.38)
        fillRadial(ctx, center: c, radius: farthestCorner(c, in: square), stops(appearance))
    }
}

/// §3.2 step 6: two highlights opposite each other.
let sheenStops: [(Double, RGBA)] = [
    (0, .white(0)), (18, .white(0.035)), (40, .white(0.24)), (63, .white(0.035)), (95, .white(0)),
    (180, .white(0)), (198, .white(0.03)), (220, .white(0.17)), (243, .white(0.03)), (275, .white(0)), (360, .white(0)),
]

/// §3.2 step 7.
let iridescenceStops: [(Double, RGBA)] = [
    (0, .clear), (28, .clear), (36, RGBA(1, 110 / 255, 200 / 255, 0.07)), (44, RGBA(110 / 255, 210 / 255, 1, 0.08)),
    (51, RGBA(160 / 255, 1, 190 / 255, 0.05)), (58, .clear), (208, .clear), (216, RGBA(110 / 255, 210 / 255, 1, 0.05)),
    (224, RGBA(190 / 255, 140 / 255, 1, 0.07)), (232, .clear), (360, .clear),
]

/// The sheen's falloff: 25% at 30% of r rising to 100% at 70% of r.
func sheenFalloff(_ rho: Double) -> Double {
    0.25 + 0.75 * clamp01((rho - 0.3) / 0.4)
}

func drawConic(_ ctx: CGContext, scale: CGFloat, center c: CGPoint, radius r: CGFloat, stops: [(Double, RGBA)],
               falloff: Bool, blend: CGBlendMode = .normal, alpha: CGFloat = 1) {
    ctx.saveGState()
    clipCircle(ctx, c, r)
    drawPixels(ctx, scale: scale, rect: circleRect(c, r), blend: blend, alpha: alpha) { x, y in
        let dx = x - c.x, dy = y - c.y
        var color = interpolate(stops, at: cssAngle(dx, dy))
        if falloff { color.a *= sheenFalloff(hypot(dx, dy) / r) }
        return color
    }
    ctx.restoreGState()
}

/// §3.2 step 8: a 160° linear gradient across the disc's box.
func drawLightFall(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat) {
    let t = 160.0 * .pi / 180
    let dir = CGPoint(x: sin(t), y: -cos(t))
    let half = r * (abs(dir.x) + abs(dir.y))
    ctx.saveGState()
    clipCircle(ctx, c, r)
    ctx.drawLinearGradient(
        gradient([(0, .white(0.07)), (0.45, .white(0)), (0.45, .black(0)), (1, .black(0.28))]),
        start: CGPoint(x: c.x - dir.x * half, y: c.y - dir.y * half),
        end: CGPoint(x: c.x + dir.x * half, y: c.y + dir.y * half),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

/// §3.2 step 9: a ring at the disc's edge with a vertical gradient, its
/// inner edge softened over the innermost 30% of its width.
func drawRim(_ ctx: CGContext, scale: CGFloat, center c: CGPoint, radius r: CGFloat, width: CGFloat) {
    let stops: [(Double, RGBA)] = [(0, .white(0.42)), (0.5, .white(0.06)), (1, .white(0.18))]
    let inner = Double(r - width), soft = Double(width) * 0.3
    ctx.saveGState()
    clipCircle(ctx, c, r)
    drawPixels(ctx, scale: scale, rect: circleRect(c, r)) { x, y in
        let d = hypot(x - c.x, y - c.y)
        guard d > inner else { return .clear }
        var color = interpolate(stops, at: (y - (c.y - r)) / Double(2 * r))
        color.a *= clamp01((d - inner) / soft)
        return color
    }
    ctx.restoreGState()
}

/// §3.2 step 2.
let discBaseStops: [(Double, RGBA)] = [(0, RGBA(hex: 0x121215)), (0.7, RGBA(hex: 0x0A0A0C)), (1, RGBA(hex: 0x0D0D10))]

/// §3.2 step 11 (and §4 step 9 without the lip).
func drawSpindle(_ ctx: CGContext, scale: CGFloat, center c: CGPoint, radius r: CGFloat, lip: Bool) {
    if lip {
        // CSS `0 0.5px 0 white 25%`: the hole's outline shifted down.
        fillCircle(ctx, CGPoint(x: c.x, y: c.y + 0.5), r, .white(0.25))
    }
    ctx.saveGState()
    clipCircle(ctx, c, r)
    let box = circleRect(c, r)
    let g = CGPoint(x: c.x, y: box.minY + box.height * 0.6)
    fillRadial(ctx, center: g, radius: farthestCorner(g, in: box), [(0, RGBA(hex: 0x26262A)), (1, RGBA(hex: 0x050506))])
    ctx.restoreGState()
    innerShadow(ctx, scale: scale, c, r, dy: 1, blur: 1.5, .black(0.9))
}

// MARK: - Text

struct PlacedGlyph {
    var font: CTFont
    var glyph: CGGlyph
    var x: CGFloat
    var advance: CGFloat
}

/// Shapes `string` with Core Text and returns its glyphs with `tracking`
/// added after each, plus the visible width (no trailing tracking).
func shape(_ string: String, font: CTFont, tracking: CGFloat) -> ([PlacedGlyph], CGFloat) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font]))
    var placed: [PlacedGlyph] = []
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        let runFont = attributes[kCTFontAttributeName] as! CTFont
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        var advances = [CGSize](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(), &glyphs)
        CTRunGetPositions(run, CFRange(), &positions)
        CTRunGetAdvances(run, CFRange(), &advances)
        for k in 0..<count {
            placed.append(PlacedGlyph(font: runFont, glyph: glyphs[k], x: positions[k].x, advance: advances[k].width))
        }
    }
    for k in placed.indices { placed[k].x += CGFloat(k) * tracking }
    let width = placed.last.map { $0.x + $0.advance } ?? 0
    return (placed, width)
}

/// Draws one glyph with its baseline origin at the current origin, in a
/// y-down context.
func drawGlyph(_ ctx: CGContext, _ g: PlacedGlyph) {
    ctx.saveGState()
    ctx.scaleBy(x: 1, y: -1)
    var glyph = g.glyph
    var origin = CGPoint.zero
    CTFontDrawGlyphs(g.font, &glyph, &origin, 1, ctx)
    ctx.restoreGState()
}

func drawCentredText(_ ctx: CGContext, _ string: String, font: CTFont, tracking: CGFloat = 0, centerX: CGFloat,
                     baseline: CGFloat, _ color: RGBA) {
    let (glyphs, width) = shape(string, font: font, tracking: tracking)
    ctx.setFillColor(color.cg)
    for g in glyphs {
        ctx.saveGState()
        ctx.translateBy(x: centerX - width / 2 + g.x, y: baseline)
        drawGlyph(ctx, g)
        ctx.restoreGState()
    }
}

/// Lays `string` glyph by glyph on a circle of baseline radius `radius`,
/// centred on 12 o'clock (`top`, letters standing outward) or on 6 o'clock
/// (letters upright, standing inward), reading left to right.
func drawArcText(_ ctx: CGContext, _ string: String, font: CTFont, tracking: CGFloat, center c: CGPoint,
                 radius: CGFloat, top: Bool, _ color: RGBA) {
    let (glyphs, width) = shape(string, font: font, tracking: tracking)
    ctx.setFillColor(color.cg)
    for g in glyphs {
        // Arc length from the arc's middle to the glyph's centre.
        let s = Double(g.x + g.advance / 2 - width / 2)
        let theta = top ? s / Double(radius) : .pi - s / Double(radius)
        let rotation = top ? theta : theta - .pi
        let p = cssPoint(c, radius, theta * 180 / .pi)
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.rotate(by: CGFloat(rotation))
        ctx.translateBy(x: -g.advance / 2, y: 0)
        drawGlyph(ctx, g)
        ctx.restoreGState()
    }
}

func systemFont(_ size: CGFloat, _ weight: NSFont.Weight) -> CTFont {
    NSFont.systemFont(ofSize: size, weight: weight) as CTFont
}

// MARK: - Cover (§3)

enum Cover {
    static let side: CGFloat = 360
    static let pixels = 1440
    static let discDiameter: CGFloat = 288
    static let labelDiameter: CGFloat = 100.8
    static let holeRadius: CGFloat = 7.5

    static func render(_ appearance: Appearance, withGround: Bool) -> CGImage {
        let scale = CGFloat(pixels) / side
        let ctx = makeContext(side: side, scale: scale)
        if withGround { Ground.draw(ctx, side: side, appearance) }
        let c = CGPoint(x: side / 2, y: side / 2)
        let r = discDiameter / 2
        drawFloorShadow(ctx, scale: scale, appearance)
        drawDisc(ctx, scale: scale, center: c, radius: r, appearance)
        drawLabel(ctx, scale: scale, center: c)
        drawSpindle(ctx, scale: scale, center: c, radius: holeRadius, lip: true)
        return ctx.makeImage()!
    }

    /// §3.1: an ellipse spanning 18%–82% of the width, 8% of the height, its
    /// bottom 7% above the square's bottom; closest-side radial from black
    /// to clear, blurred 4 pt (a Gaussian with σ = 4 pt, as CSS `blur()`).
    static func drawFloorShadow(_ ctx: CGContext, scale: CGFloat, _ appearance: Appearance) {
        let peak = appearance == .dark ? 0.5 : 0.22
        let ellipse = CGRect(x: side * 0.18, y: side * 0.85, width: side * 0.64, height: side * 0.08)
        let sigma = 4 * Double(scale)
        let pad = CGFloat(ceil(sigma * 3)) / scale
        let rect = ellipse.insetBy(dx: -pad, dy: -pad)
        let x0 = Int((rect.minX * scale).rounded(.down)), y0 = Int((rect.minY * scale).rounded(.down))
        let w = Int((rect.maxX * scale).rounded(.up)) - x0, h = Int((rect.maxY * scale).rounded(.up)) - y0
        let s = Double(scale)
        let cx = Double(ellipse.midX), cy = Double(ellipse.midY)
        let rx = Double(ellipse.width / 2), ry = Double(ellipse.height / 2)
        var alpha = [Double](repeating: 0, count: w * h)
        for j in 0..<h {
            for i in 0..<w {
                let x = (Double(x0 + i) + 0.5) / s, y = (Double(y0 + j) + 0.5) / s
                let d = hypot((x - cx) / rx, (y - cy) / ry)
                alpha[j * w + i] = peak * max(0, 1 - d)
            }
        }
        alpha = gaussianBlur(alpha, width: w, height: h, sigma: sigma)
        let local = CGRect(x: CGFloat(x0) / scale, y: CGFloat(y0) / scale, width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        drawPixels(ctx, scale: scale, rect: local) { x, y in
            let i = min(max(Int(x * s) - x0, 0), w - 1), j = min(max(Int(y * s) - y0, 0), h - 1)
            return .black(alpha[j * w + i])
        }
    }

    static func drawDisc(_ ctx: CGContext, scale: CGFloat, center c: CGPoint, radius r: CGFloat, _ appearance: Appearance) {
        let D = 2 * r
        // 1. Cast shadow.
        let shadows: [(CGFloat, CGFloat, Double)] = appearance == .dark
            ? [(22, 44, 0.6), (4, 10, 0.45)]
            : [(22, 40, 0.3), (4, 10, 0.22)]
        for (dy, blur, a) in shadows {
            ctx.saveGState()
            setShadow(ctx, scale: scale, dy: dy, blur: blur, .black(a))
            fillCircle(ctx, c, r, RGBA(hex: 0x0A0A0C))
            ctx.restoreGState()
        }
        ctx.saveGState()
        clipCircle(ctx, c, r)
        // 2. Base.
        fillRadial(ctx, center: c, radius: r, discBaseStops)
        // 3. Grooves: 0.44 r to 0.965 r every 1.7 pt, seeded opacities.
        var random = SeededRandom(seed: 0x7A4E_56E0)
        var radius = 0.44 * r
        while radius <= 0.965 * r + 0.001 {
            let opacity = 0.05 * (0.4 + 0.8 * random.unit())
            strokeCircle(ctx, c, radius, width: 0.45, .white(opacity))
            radius += 1.7
        }
        // 4. Smooth zones: the lead-in (outer edge on the disc's edge) and
        // the run-out.
        let leadInWidth = D * 0.028
        strokeCircle(ctx, c, r - leadInWidth / 2, width: leadInWidth, RGBA(hex: 0x0C0C0E))
        fillCircle(ctx, c, 0.43 * r, RGBA(hex: 0x0C0C0E))
        // 5. Track bands.
        for f in [0.55, 0.64, 0.75, 0.87] {
            let br = r * CGFloat(f)
            strokeCircle(ctx, c, br, width: D * 0.007, .black(0.95))
            strokeCircle(ctx, c, br + D * 0.0045, width: 0.6, .white(0.07))
        }
        ctx.restoreGState()
        // 6–9. Sheen, iridescence, light fall, rim.
        drawConic(ctx, scale: scale, center: c, radius: r, stops: sheenStops, falloff: true)
        drawConic(ctx, scale: scale, center: c, radius: r, stops: iridescenceStops, falloff: true, blend: .screen)
        drawLightFall(ctx, center: c, radius: r)
        drawRim(ctx, scale: scale, center: c, radius: r, width: 2.2)
    }

    /// §3.3, drawn in the label's 100-unit box scaled to L.
    static func drawLabel(_ ctx: CGContext, scale: CGFloat, center c: CGPoint) {
        let L = labelDiameter
        let r = L / 2
        let unit = L / 100
        let origin = CGPoint(x: c.x - r, y: c.y - r)
        let labelRect = circleRect(c, r)

        // Edge outline outside the label: CSS `0 0 0 1.21px black 60%`.
        strokeCircle(ctx, c, r + 0.605, width: 1.21, .black(0.6))

        ctx.saveGState()
        clipCircle(ctx, c, r)
        // 1. Base.
        let g = CGPoint(x: c.x, y: labelRect.minY + L * 0.3)
        fillRadial(ctx, center: g, radius: farthestCorner(g, in: labelRect),
                   [(0, RGBA(hex: 0x8D86FA)), (0.52, RGBA(hex: 0x6C63E9)), (1, RGBA(hex: 0x4C44C6))])
        // 2–3. Grain and fibre, in label units.
        let whiteGrain = GradientNoise(seed: 11), darkGrain = GradientNoise(seed: 29), fibre = GradientNoise(seed: 5)
        let fibreAngle = 24.0 * .pi / 180
        drawPixels(ctx, scale: scale, rect: labelRect) { x, y in
            let u = (x - origin.x) / unit, v = (y - origin.y) / unit
            let w = clamp01(0.55 * whiteGrain.fractal(u, v, fx: 1.1, fy: 1.1, octaves: 3) - 0.22) * 0.22
            let d = clamp01(0.6 * darkGrain.fractal(u, v, fx: 1.1, fy: 1.1, octaves: 3) - 0.25) * 0.26
            // The fibre rectangle is rotated −24°; sample it rotated back.
            let du = u - 50, dv = v - 50
            let fu = 50 + du * cos(fibreAngle) - dv * sin(fibreAngle)
            let fv = 50 + du * sin(fibreAngle) + dv * cos(fibreAngle)
            let f = clamp01(0.5 * fibre.fractal(fu, fv, fx: 0.04, fy: 0.9, octaves: 2) - 0.28) * 0.18
            return over(.white(f), over(.black(d), .white(w)))
        }
        // 4. Vignette.
        fillRadial(ctx, center: c, radius: r, [(0, .clear), (0.72, .black(0)), (1, .black(0.2))])
        // 5–6. The lip and the pressed ring round the spindle.
        strokeCircle(ctx, c, 47.6 * unit, width: 0.6 * unit, .white(0.16))
        fillCircle(ctx, c, 12.5 * unit, .white(0.05))
        strokeCircle(ctx, c, 12.5 * unit, width: 0.5 * unit, .black(0.14))
        ctx.restoreGState()

        // 7. Inner top highlight and bottom shade.
        innerShadow(ctx, scale: scale, c, r, dy: 0.81, blur: 1.21, .white(0.3))
        innerShadow(ctx, scale: scale, c, r, dy: -3, blur: 6, .black(0.18))

        // Printing.
        ctx.saveGState()
        clipCircle(ctx, c, r)
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: unit, y: unit)
        let mid = CGPoint(x: 50, y: 50)
        strokeCircle(ctx, mid, 44, width: 0.45, .white(0.5))
        strokeCircle(ctx, mid, 43, width: 0.25, .white(0.25))
        drawArcText(ctx, "RAREBIT RECORDS", font: systemFont(5.2, .bold), tracking: 1.6, center: mid, radius: 37,
                    top: true, .white(0.88))
        drawCentredText(ctx, "Takes", font: scriptFont(12.5), centerX: 50, baseline: 32, .white(0.94))
        drawCentredText(ctx, "SIDE", font: systemFont(3.2, .bold), tracking: 1, centerX: 25, baseline: 48, .white(0.62))
        drawCentredText(ctx, "A", font: systemFont(9, .bold), centerX: 25, baseline: 57.5, .white(0.9))
        drawCentredText(ctx, "33⅓", font: systemFont(6.6, .semibold), tracking: -0.1, centerX: 75, baseline: 54.5, .white(0.9))
        drawCentredText(ctx, "RPM", font: systemFont(3.2, .bold), tracking: 1, centerX: 75, baseline: 59.5, .white(0.62))
        drawArcText(ctx, "STEREO  ·  RB-001", font: systemFont(3.6, .semibold), tracking: 1.3, center: mid, radius: 39.5,
                    top: false, .white(0.7))
        ctx.restoreGState()

        // 8. The disc's sheen at 28%, screen.
        drawConic(ctx, scale: scale, center: c, radius: r, stops: sheenStops, falloff: false, blend: .screen, alpha: 0.28)
        // 9. Gloss from the top left: white 14% → clear at 45%, along
        // (0, 0) → (0.7, 1) of the label's box.
        ctx.saveGState()
        clipCircle(ctx, c, r)
        ctx.drawLinearGradient(gradient([(0, .white(0.14)), (0.45, .white(0)), (1, .white(0))]),
                               start: labelRect.origin,
                               end: CGPoint(x: labelRect.minX + 0.7 * L, y: labelRect.maxY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// Snell Roundhand has no italic face; browsers synthesize the
    /// artboard's italic with a 14° oblique, so do the same.
    static func scriptFont(_ size: CGFloat) -> CTFont {
        var oblique = CGAffineTransform(a: 1, b: 0, c: CGFloat(tan(14.0 * .pi / 180)), d: 1, tx: 0, ty: 0)
        return CTFontCreateWithName("SnellRoundhand" as CFString, size, &oblique)
    }
}

// MARK: - Thumbnail (§4)

enum Thumbnail {
    static let side: CGFloat = 34
    static let pixels = 68
    static let discDiameter: CGFloat = 29.9
    static let labelDiameter: CGFloat = 12
    static let holeRadius: CGFloat = 1.6

    static func render(_ appearance: Appearance) -> CGImage {
        let scale = CGFloat(pixels) / side
        let ctx = makeContext(side: side, scale: scale)
        Ground.draw(ctx, side: side, appearance)
        let c = CGPoint(x: side / 2, y: side / 2)
        let r = discDiameter / 2
        // 1. Cast shadow.
        ctx.saveGState()
        setShadow(ctx, scale: scale, dy: 1, blur: 2, .black(appearance == .dark ? 0.5 : 0.25))
        fillCircle(ctx, c, r, RGBA(hex: 0x0A0A0C))
        ctx.restoreGState()
        // 2. Base. 4. Two bands.
        ctx.saveGState()
        clipCircle(ctx, c, r)
        fillRadial(ctx, center: c, radius: r, discBaseStops)
        for f in [0.62, 0.8] { strokeCircle(ctx, c, r * CGFloat(f), width: 0.5, .white(0.07)) }
        ctx.restoreGState()
        // 5–7. Sheen, light fall, rim.
        drawConic(ctx, scale: scale, center: c, radius: r, stops: sheenStops, falloff: true)
        drawLightFall(ctx, center: c, radius: r)
        drawRim(ctx, scale: scale, center: c, radius: r, width: 1.2)
        // 8. Label.
        let lr = labelDiameter / 2
        let labelRect = circleRect(c, lr)
        strokeCircle(ctx, c, lr + 0.25, width: 0.5, .black(0.55))
        ctx.saveGState()
        clipCircle(ctx, c, lr)
        let g = CGPoint(x: c.x, y: labelRect.minY + labelDiameter * 0.32)
        fillRadial(ctx, center: g, radius: farthestCorner(g, in: labelRect),
                   [(0, RGBA(hex: 0x9D96FF)), (0.48, RGBA(hex: 0x6C63E9)), (1, RGBA(hex: 0x3F37B5))])
        ctx.restoreGState()
        innerShadow(ctx, scale: scale, c, lr, dy: 0.5, blur: 0.5, .white(0.35))
        drawConic(ctx, scale: scale, center: c, radius: lr, stops: sheenStops, falloff: false, blend: .screen, alpha: 0.35)
        // 9. Spindle hole.
        drawSpindle(ctx, scale: scale, center: c, radius: holeRadius, lip: false)
        return ctx.makeImage()!
    }
}

// MARK: - Blur

func gaussianBlur(_ input: [Double], width w: Int, height h: Int, sigma: Double) -> [Double] {
    let radius = Int(ceil(sigma * 3))
    var kernel = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
    let total = kernel.reduce(0, +)
    kernel = kernel.map { $0 / total }
    var pass = [Double](repeating: 0, count: w * h)
    for j in 0..<h {
        for i in 0..<w {
            var sum = 0.0
            for k in -radius...radius {
                let x = i + k
                if x >= 0 && x < w { sum += input[j * w + x] * kernel[k + radius] }
            }
            pass[j * w + i] = sum
        }
    }
    var output = [Double](repeating: 0, count: w * h)
    for j in 0..<h {
        for i in 0..<w {
            var sum = 0.0
            for k in -radius...radius {
                let y = j + k
                if y >= 0 && y < h { sum += pass[y * w + i] * kernel[k + radius] }
            }
            output[j * w + i] = sum
        }
    }
    return output
}

// MARK: - Output

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Couldn't write \(url.path)") }
    print("wrote \(url.path) (\(image.width) × \(image.height))")
}

/// One image set: a light and a dark variant, each a single bitmap used at
/// every display scale (no `scale` key).
func writeImageSet(named name: String, prefix: String, in catalog: URL, images: [Appearance: CGImage]) throws {
    let folder = catalog.appendingPathComponent("\(name).imageset")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for appearance in Appearance.allCases {
        writePNG(images[appearance]!, to: folder.appendingPathComponent("\(prefix)-\(appearance.rawValue).png"))
    }
    let contents = """
    {
      "images" : [
        {
          "filename" : "\(prefix)-light.png",
          "idiom" : "universal"
        },
        {
          "appearances" : [
            {
              "appearance" : "luminosity",
              "value" : "dark"
            }
          ],
          "filename" : "\(prefix)-dark.png",
          "idiom" : "universal"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
    try contents.write(to: folder.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}

let arguments = CommandLine.arguments
let catalog = URL(fileURLWithPath: "Assets/Assets.xcassets")
guard FileManager.default.fileExists(atPath: catalog.path) else {
    fatalError("Run from the repository root (Assets/Assets.xcassets not found).")
}

var covers: [Appearance: CGImage] = [:]
var thumbnails: [Appearance: CGImage] = [:]
for appearance in Appearance.allCases {
    covers[appearance] = Cover.render(appearance, withGround: false)
    thumbnails[appearance] = Thumbnail.render(appearance)
}
try writeImageSet(named: "RecordPlaceholderCover", prefix: "record-cover", in: catalog, images: covers)
try writeImageSet(named: "RecordPlaceholderThumbnail", prefix: "record-thumbnail", in: catalog, images: thumbnails)

if let flag = arguments.firstIndex(of: "--preview"), flag + 1 < arguments.count {
    let folder = URL(fileURLWithPath: arguments[flag + 1])
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for appearance in Appearance.allCases {
        writePNG(Cover.render(appearance, withGround: true),
                 to: folder.appendingPathComponent("cover-on-ground-\(appearance.rawValue).png"))
    }
}
