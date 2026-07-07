import Accelerate
import XCTest
@testable import Takes

/// `AnalogSourceAnalyzer` validation on synthesized signals. The key
/// property under test: every detector works on GAPLESS material — the
/// music never stops, only the per-band gaps between events exist.
final class AnalogSourceDSPTests: XCTestCase {
    private let sampleRate = 44_100.0

    private func whiteNoise(amplitude: Float, count: Int, seed: UInt64) -> [Float] {
        var state = seed
        return (0 ..< count).map { _ in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return amplitude * (Float(state % 2_000_001) / 1_000_000 - 1)
        }
    }

    /// Gapless "music": harmonics that change level every ~200 ms but never
    /// go quiet, at ≈ −14 dBFS RMS overall. Level changes are enveloped
    /// (one-pole smoothing) the way real music is — an instantaneous
    /// amplitude step is indistinguishable from a click by construction.
    private func gaplessMusic(count: Int, seed: UInt64) -> [Float] {
        var state = seed
        var samples = [Float](repeating: 0, count: count)
        let segment = Int(0.2 * sampleRate)
        let smoothing: Float = 0.001
        for (harmonic, frequency) in [220.0, 440, 587, 880].enumerated() {
            var phase = 0.0
            var level: Float = 0.2
            var target: Float = 0.2
            for index in 0 ..< count {
                if index % segment == 0 {
                    state ^= state << 13
                    state ^= state >> 7
                    state ^= state << 17
                    target = 0.08 + 0.24 * Float(state % 1_000) / 1_000
                }
                level += (target - level) * smoothing
                phase += 2 * .pi * frequency / sampleRate
                samples[index] += level / Float(harmonic + 1) * Float(sin(phase))
            }
        }
        return samples
    }

    private func analyze(left: [Float], right: [Float]?) -> AnalogSourceMetrics {
        let analyzer = AnalogSourceAnalyzer(sampleRate: sampleRate, channelCount: right == nil ? 1 : 2)
        let chunk = 65_536
        var offset = 0
        while offset < left.count {
            let end = min(offset + chunk, left.count)
            var channels = [Array(left[offset ..< end])]
            if let right { channels.append(Array(right[offset ..< end])) }
            analyzer.process(channels: channels)
            offset = end
        }
        return analyzer.finalize()
    }

    // MARK: Stationary floor

    func testStationaryFloorFindsHissUnderGaplessMusic() {
        let count = Int(20 * sampleRate)
        let music = gaplessMusic(count: count, seed: 7)
        // Decorrelated hiss at −50 dBFS per channel (amplitude for white
        // noise RMS −50 dB: 0.00316 / sqrt(1/3) — uniform noise RMS is a/√3).
        let hissAmplitude: Float = 0.00316 * 1.732
        let left = vDSP.add(music, whiteNoise(amplitude: hissAmplitude, count: count, seed: 1))
        let right = vDSP.add(music, whiteNoise(amplitude: hissAmplitude, count: count, seed: 2))

        let metrics = analyze(left: left, right: right)
        XCTAssertEqual(metrics.stationaryNoiseFloorDBFS, -50, accuracy: 6)
        XCTAssertGreaterThan(metrics.noiseFloorFlatness, 0.35)
    }

    func testCleanDigitalMusicHasNoStationaryFloor() {
        let count = Int(20 * sampleRate)
        let music = gaplessMusic(count: count, seed: 7)
        let metrics = analyze(left: music, right: music)
        // No noise bed ⇒ floor far below any hiss-plausible range.
        XCTAssertLessThan(metrics.stationaryNoiseFloorDBFS, -80)
    }

    // MARK: Noise coherence

    func testDecorrelatedHissReadsLowCoherence() {
        let count = Int(20 * sampleRate)
        let music = gaplessMusic(count: count, seed: 7)
        let left = vDSP.add(music, whiteNoise(amplitude: 0.0055, count: count, seed: 1))
        let right = vDSP.add(music, whiteNoise(amplitude: 0.0055, count: count, seed: 2))
        XCTAssertLessThan(analyze(left: left, right: right).highBandNoiseCoherence, 0.5)
    }

    func testCorrelatedNoiseReadsHighCoherence() {
        let count = Int(20 * sampleRate)
        let music = gaplessMusic(count: count, seed: 7)
        let sharedNoise = whiteNoise(amplitude: 0.0055, count: count, seed: 1)
        let left = vDSP.add(music, sharedNoise)
        let right = vDSP.add(music, sharedNoise)
        XCTAssertGreaterThan(analyze(left: left, right: right).highBandNoiseCoherence, 0.8)
    }

    // MARK: Clicks

    func testClicksAreCountedWithSalience() {
        let count = Int(20 * sampleRate)
        var music = gaplessMusic(count: count, seed: 7)
        // 10 clicks: 0.3 ms wideband spikes, well above the music — real
        // stylus pops are sub-millisecond, which is exactly the sharpness
        // the detector requires to reject drum onsets.
        let clickLength = Int(0.0003 * sampleRate)
        // Align spikes to the detector's 0.5 ms envelope frames: a spike
        // straddling a frame boundary splits across two frames and is
        // (intentionally) dropped by the sharpness rule — real surface
        // noise is dense enough that the loss doesn't matter, but a
        // 10-click test needs all 10 to land.
        let envelopeFrame = max(16, Int((sampleRate * 0.0005).rounded()))
        for clickIndex in 0 ..< 10 {
            var position = Int(1.9 * sampleRate) * clickIndex + Int(0.5 * sampleRate)
            position -= position % envelopeFrame
            let burst = whiteNoise(amplitude: 0.85, count: clickLength, seed: UInt64(clickIndex + 3))
            for (offset, value) in burst.enumerated() { music[position + offset] += value }
        }

        let metrics = analyze(left: music, right: music)
        let expectedRate = 10.0 / (20.0 / 60.0)
        XCTAssertEqual(metrics.clickRatePerMinute, expectedRate, accuracy: expectedRate * 0.35)
        XCTAssertGreaterThan(metrics.meanClickSalienceDB, 10)
    }

    func testCleanMusicHasNoClicks() {
        let count = Int(20 * sampleRate)
        let music = gaplessMusic(count: count, seed: 7)
        XCTAssertLessThan(analyze(left: music, right: music).clickRatePerMinute, 3)
    }

    // MARK: Rumble

    func testSideChannelRumbleIsMeasured() {
        let count = Int(20 * sampleRate)
        let music = gaplessMusic(count: count, seed: 7)
        // 15 Hz noise-ish wobble in the side channel at ≈ −30 dBFS.
        var phase = 0.0
        let rumble = (0 ..< count).map { index -> Float in
            phase += 2 * .pi * (15 + 5 * sin(2 * .pi * 0.3 * Double(index) / sampleRate)) / sampleRate
            return 0.03 * Float(sin(phase))
        }
        let left = vDSP.add(music, rumble)
        let right = vDSP.subtract(music, rumble)

        let withRumble = analyze(left: left, right: right)
        let clean = analyze(left: music, right: music)
        XCTAssertGreaterThan(withRumble.rumbleSideLevelDB, -40)
        XCTAssertLessThan(clean.rumbleSideLevelDB, -70)
    }
}
