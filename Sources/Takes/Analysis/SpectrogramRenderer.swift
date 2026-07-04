import Accelerate
import CoreGraphics
import Foundation

/// Streaming STFT that renders a log-magnitude spectrogram image.
///
/// The frequency axis is linear (not log) on purpose: lossy-codec lowpass
/// shelves appear as a hard horizontal edge, which is the single most useful
/// visual cue this feature exists to surface.
final class SpectrogramAccumulator {
    static let fftSize = 2048
    /// Roughly how many pixel columns the final image should have; the hop
    /// is derived from the expected frame count so long files stay bounded.
    static let targetColumnCount = 1100

    private let fft: RealFFT
    private let hop: Int
    private let sampleRate: Double
    private var pending: [Float] = []
    private var columnsPower: [[Float]] = []
    private var scratch: [Float]

    init(sampleRate: Double, expectedFrameCount: Int) {
        self.sampleRate = sampleRate
        fft = RealFFT(size: Self.fftSize)
        hop = max(Self.fftSize / 4, expectedFrameCount / Self.targetColumnCount)
        scratch = [Float](repeating: 0, count: Self.fftSize / 2)
    }

    func process(monoSamples: [Float]) {
        pending.append(contentsOf: monoSamples)
        var start = 0
        while pending.count - start >= Self.fftSize {
            for index in scratch.indices { scratch[index] = 0 }
            pending.withUnsafeBufferPointer { pointer in
                fft.accumulatePowerSpectrum(
                    of: UnsafeBufferPointer(rebasing: pointer[start ..< start + Self.fftSize]),
                    into: &scratch
                )
            }
            columnsPower.append(scratch)
            start += hop
        }
        pending.removeFirst(start)
    }

    func finalize(durationSeconds: Double) -> SpectrogramImage? {
        guard !columnsPower.isEmpty,
              let image = SpectrogramRenderer.render(columnsPower: columnsPower)
        else { return nil }
        return SpectrogramImage(
            image: image,
            durationSeconds: durationSeconds,
            maxFrequencyHz: sampleRate / 2
        )
    }
}

enum SpectrogramRenderer {
    /// Dynamic range below the file's hottest bin that stays visible.
    private static let dynamicRangeDB: Float = 90

    /// Inferno-style ramp: reads dark-to-bright so codec shelves show as a
    /// clean dark region above the cutoff.
    private static let colorStops: [(r: Float, g: Float, b: Float)] = [
        (0.0 / 255, 0.0 / 255, 4.0 / 255),
        (87.0 / 255, 16.0 / 255, 110.0 / 255),
        (188.0 / 255, 55.0 / 255, 84.0 / 255),
        (249.0 / 255, 142.0 / 255, 9.0 / 255),
        (252.0 / 255, 255.0 / 255, 164.0 / 255),
    ]

    static func render(columnsPower: [[Float]]) -> CGImage? {
        guard let binCount = columnsPower.first?.count, binCount > 0 else { return nil }
        let width = columnsPower.count
        // Halve vertical resolution: 1024 bins → 512 rows keeps images small
        // with no visible loss at UI sizes.
        let rowsPerPixel = 2
        let height = binCount / rowsPerPixel

        // Convert to dB and find the global peak for normalization.
        var columnsDB = columnsPower
        var peak: Float = -160
        for columnIndex in columnsDB.indices {
            vDSP.clip(columnsDB[columnIndex], to: 1e-16 ... .greatestFiniteMagnitude, result: &columnsDB[columnIndex])
            vDSP.convert(power: columnsDB[columnIndex], toDecibels: &columnsDB[columnIndex], zeroReference: 1)
            peak = max(peak, vDSP.maximum(columnsDB[columnIndex]))
        }
        let floor = peak - dynamicRangeDB

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for (x, column) in columnsDB.enumerated() {
            for y in 0 ..< height {
                // Row 0 of the image is the top: highest frequency.
                let bin = (height - 1 - y) * rowsPerPixel
                let level = max(column[bin], column[min(bin + 1, binCount - 1)])
                let normalized = max(0, min(1, (level - floor) / dynamicRangeDB))
                let color = color(for: normalized)
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(color.r * 255)
                pixels[offset + 1] = UInt8(color.g * 255)
                pixels[offset + 2] = UInt8(color.b * 255)
                pixels[offset + 3] = 255
            }
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func color(for normalized: Float) -> (r: Float, g: Float, b: Float) {
        let scaled = normalized * Float(colorStops.count - 1)
        let low = min(Int(scaled), colorStops.count - 2)
        let fraction = scaled - Float(low)
        let from = colorStops[low]
        let to = colorStops[low + 1]
        return (
            from.r + (to.r - from.r) * fraction,
            from.g + (to.g - from.g) * fraction,
            from.b + (to.b - from.b) * fraction
        )
    }
}
