import XCTest
@testable import Takes

final class AnalysisEngineTests: XCTestCase {
    private let sampleRate = 48_000.0

    private func sine(frequency: Double, amplitude: Float, seconds: Double) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0 ..< count).map {
            amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate))
        }
    }

    private func whiteNoise(amplitude: Float, seconds: Double, seed: UInt64 = 1) -> [Float] {
        var state = seed
        let count = Int(seconds * sampleRate)
        return (0 ..< count).map { _ in
            // xorshift64: deterministic noise so thresholds are stable.
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            let unit = Float(state % 2_000_001) / 1_000_000 - 1
            return amplitude * unit
        }
    }

    // MARK: Loudness (BS.1770 reference points)

    func testIntegratedLoudnessOfFullScaleStereoSineReadsZero() {
        // BS.1770 reference point: a 0 dBFS 997 Hz sine in ONE channel reads
        // −3.01 LKFS, so the same sine in both stereo channels reads ≈0.
        let meter = LoudnessMeter(sampleRate: sampleRate, channelCount: 2)
        let signal = sine(frequency: 997, amplitude: 1.0, seconds: 5)
        signal.withUnsafeBufferPointer { pointer in
            meter.process(channels: [pointer, pointer])
        }
        let result = meter.finalize()
        XCTAssertNotNil(result.integratedLUFS)
        XCTAssertEqual(result.integratedLUFS!, 0.0, accuracy: 0.5)
        XCTAssertEqual(result.samplePeakDBFS, 0, accuracy: 0.05)
    }

    func testIntegratedLoudnessOfMonoSineIsMinusThreeLKFS() {
        // The −3.01 LKFS single-channel reference case from BS.1770-4.
        let meter = LoudnessMeter(sampleRate: sampleRate, channelCount: 1)
        let signal = sine(frequency: 997, amplitude: 1.0, seconds: 5)
        signal.withUnsafeBufferPointer { meter.process(channels: [$0]) }
        XCTAssertEqual(meter.finalize().integratedLUFS!, -3.01, accuracy: 0.5)
    }

    func testQuietSineGainMovesLoudnessLinearly() {
        let meter = LoudnessMeter(sampleRate: sampleRate, channelCount: 2)
        // −20 dB amplitude ⇒ loudness should fall by exactly 20 LU.
        let signal = sine(frequency: 997, amplitude: 0.1, seconds: 5)
        signal.withUnsafeBufferPointer { meter.process(channels: [$0, $0]) }
        XCTAssertEqual(meter.finalize().integratedLUFS!, -20.0, accuracy: 0.5)
    }

    func testClippedRunsAreCounted() {
        let meter = LoudnessMeter(sampleRate: sampleRate, channelCount: 1)
        var signal = sine(frequency: 100, amplitude: 0.5, seconds: 1)
        // Two separated bursts of hard clipping.
        for index in 1_000 ..< 1_020 { signal[index] = 1.0 }
        for index in 30_000 ..< 30_010 { signal[index] = -1.0 }
        signal.withUnsafeBufferPointer { meter.process(channels: [$0]) }
        XCTAssertEqual(meter.finalize().clippedRunCount, 2)
    }

    // MARK: Spectrum

    func testAverageSpectrumPeaksAtSineFrequency() {
        let welch = WelchSpectrumAccumulator(sampleRate: sampleRate)
        welch.process(monoSamples: sine(frequency: 3_000, amplitude: 0.5, seconds: 3))
        let spectrum = welch.finalize()

        let peakBin = spectrum.magnitudesDB.indices.max(by: { spectrum.magnitudesDB[$0] < spectrum.magnitudesDB[$1] })!
        let peakFrequency = Double(peakBin) * spectrum.binWidthHz
        XCTAssertEqual(peakFrequency, 3_000, accuracy: spectrum.binWidthHz * 2)
        // 0.5 amplitude sine ⇒ −6 dBFS spectral line under our normalization.
        XCTAssertEqual(Double(spectrum.magnitudesDB[peakBin]), -6.02, accuracy: 1.5)
    }

    func testBandwidthDetectsSharpCutoff() {
        // Synthetic spectrum: flat −40 dB up to 16 kHz, −110 dB above —
        // the signature of a 128 kbps MP3 encode.
        let binWidth = sampleRate / 8_192
        let binCount = 4_096
        let cutoffBin = Int(16_000 / binWidth)
        var magnitudes = [Float](repeating: -40, count: binCount)
        for bin in cutoffBin ..< binCount { magnitudes[bin] = -110 }
        let spectrum = AverageSpectrum(binWidthHz: binWidth, magnitudesDB: magnitudes)

        let bandwidth = SpectrumMetrics.bandwidth(from: spectrum, sampleRate: sampleRate)
        XCTAssertNotNil(bandwidth.detectedCutoffHz)
        XCTAssertEqual(bandwidth.detectedCutoffHz!, 16_000, accuracy: 300)
        XCTAssertEqual(bandwidth.confidence, .high)
        XCTAssertGreaterThan(bandwidth.shelfDepthDB ?? 0, 50)
    }

    func testBandwidthReportsFullSpectrumForWideband() {
        let binWidth = sampleRate / 8_192
        // Gently sloping spectrum with content all the way to Nyquist.
        let magnitudes = (0 ..< 4_096).map { -40 - Float($0) * 0.002 }
        let spectrum = AverageSpectrum(binWidthHz: binWidth, magnitudesDB: magnitudes)

        let bandwidth = SpectrumMetrics.bandwidth(from: spectrum, sampleRate: sampleRate)
        XCTAssertNil(bandwidth.detectedCutoffHz)
    }

    func testTonalBalanceTiltReflectsSpectrumShape() {
        let binWidth = sampleRate / 8_192
        // Strongly bass-weighted spectrum: −20 dB below 250 Hz, −60 above.
        let magnitudes = (0 ..< 4_096).map { bin -> Float in
            Double(bin) * binWidth < 250 ? -20 : -60
        }
        let spectrum = AverageSpectrum(binWidthHz: binWidth, magnitudesDB: magnitudes)
        let balance = SpectrumMetrics.tonalBalance(from: spectrum)

        let bass = balance.bands.first { $0.name == "Bass" }!.relativeDB
        let treble = balance.bands.first { $0.name == "Treble" }!.relativeDB
        XCTAssertGreaterThan(bass - treble, 15)
        XCTAssertLessThan(balance.spectralCentroidHz, 900)
    }

    // MARK: Noise floor

    func testQuietFramesFindHissUnderMusic() {
        let collector = QuietFrameCollector(sampleRate: sampleRate)
        // "Music" bursts with hissy gaps at ≈ −52 dBFS.
        let loud = sine(frequency: 440, amplitude: 0.8, seconds: 2)
        let hiss = whiteNoise(amplitude: 0.0044, seconds: 2)
        collector.process(monoSamples: loud)
        collector.process(monoSamples: hiss)
        collector.process(monoSamples: loud)

        let metrics = collector.finalize()
        XCTAssertEqual(metrics.noiseFloorDBFS, -52, accuracy: 4)
        XCTAssertGreaterThan(metrics.quietFrameSpectralFlatness, 0.25)
    }

    func testDigitalSilenceReadsAsPristineFloor() {
        let collector = QuietFrameCollector(sampleRate: sampleRate)
        collector.process(monoSamples: sine(frequency: 440, amplitude: 0.8, seconds: 2))
        collector.process(monoSamples: [Float](repeating: 0, count: Int(2 * sampleRate)))
        let metrics = collector.finalize()
        XCTAssertLessThan(metrics.noiseFloorDBFS, -100)
    }
}
