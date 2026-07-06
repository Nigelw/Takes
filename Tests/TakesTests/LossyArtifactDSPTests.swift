import Accelerate
import XCTest
@testable import Takes

/// `LossyArtifactAnalyzer` and `MP3BitstreamInspector` validation on
/// synthesized signals/bitstreams.
final class LossyArtifactDSPTests: XCTestCase {
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

    private func analyze(left: [Float], right: [Float]? = nil) -> LossyArtifactMetrics {
        let analyzer = LossyArtifactAnalyzer(sampleRate: sampleRate, channelCount: right == nil ? 1 : 2)
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

    // MARK: Pre-echo

    /// Castanet-style attacks out of near-silence; the "encoded" variant
    /// injects a noise burst in the ~6 ms before each attack, exactly the
    /// artifact shape short-block-less encoders produce.
    private func transientSignal(preEchoAmplitude: Float) -> [Float] {
        let count = Int(15 * sampleRate)
        var samples = whiteNoise(amplitude: 0.0002, count: count, seed: 9) // -74 dB bed
        let attackLength = Int(0.004 * sampleRate)
        let preLength = Int(0.006 * sampleRate)
        var position = Int(0.4 * sampleRate)
        var attackSeed: UInt64 = 40
        while position + attackLength < count {
            if preEchoAmplitude > 0 {
                let smear = whiteNoise(amplitude: preEchoAmplitude, count: preLength, seed: attackSeed &+ 1)
                for (offset, value) in smear.enumerated() { samples[position - preLength + offset] += value }
            }
            let burst = whiteNoise(amplitude: 0.5, count: attackLength, seed: attackSeed)
            for (offset, value) in burst.enumerated() {
                // Instant onset, exponential decay — castanet-ish.
                samples[position + offset] += value * exp(-6 * Float(offset) / Float(attackLength))
            }
            attackSeed &+= 2
            position += Int(0.35 * sampleRate)
        }
        return samples
    }

    func testPreEchoScoreSeparatesSmearedFromCleanTransients() {
        let clean = analyze(left: transientSignal(preEchoAmplitude: 0))
        let smeared = analyze(left: transientSignal(preEchoAmplitude: 0.02))

        XCTAssertGreaterThanOrEqual(clean.attackCount, 5)
        XCTAssertGreaterThanOrEqual(smeared.attackCount, 5)
        XCTAssertGreaterThan(
            smeared.preEchoScore, clean.preEchoScore + 6,
            "injected 6 ms pre-attack smear must lift the score well clear of clean transients"
        )
    }

    // MARK: HF flicker

    func testCodecStyleHighBandTogglingOutscoresSteadyHF() {
        let count = Int(15 * sampleRate)
        // Both signals share a steady 1–3 kHz reference band.
        let lowBand = bandNoise(centerHz: 2_000, halfWidthHz: 900, amplitude: 0.1, count: count, seed: 5)
        let steadyHF = bandNoise(centerHz: 13_000, halfWidthHz: 2_500, amplitude: 0.05, count: count, seed: 6)

        // "Birdies": the HF band gates fully on/off every ~26 ms.
        let gateLength = Int(0.026 * sampleRate)
        var gatedHF = steadyHF
        var state: UInt64 = 11
        var index = 0
        while index < count {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            if state % 2 == 0 {
                for offset in index ..< min(index + gateLength, count) { gatedHF[offset] = 0 }
            }
            index += gateLength
        }

        let steady = analyze(left: vDSP.add(lowBand, steadyHF))
        let flickering = analyze(left: vDSP.add(lowBand, gatedHF))
        XCTAssertGreaterThan(flickering.highBandFlickerScore, steady.highBandFlickerScore * 1.5)
    }

    /// Noise bandpassed by frequency-domain construction: sum of many
    /// random-phase sines across the band.
    private func bandNoise(centerHz: Double, halfWidthHz: Double, amplitude: Float, count: Int, seed: UInt64) -> [Float] {
        var samples = [Float](repeating: 0, count: count)
        var state = seed
        let toneCount = 40
        for tone in 0 ..< toneCount {
            let frequency = centerHz - halfWidthHz + 2 * halfWidthHz * Double(tone) / Double(toneCount - 1)
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            let phase0 = 2 * Double.pi * Double(state % 1_000) / 1_000
            let step = 2 * .pi * frequency / sampleRate
            var phase = phase0
            let toneAmplitude = amplitude / Float(toneCount).squareRoot()
            for index in 0 ..< count {
                samples[index] += toneAmplitude * Float(sin(phase))
                phase += step
                if phase > 2 * .pi { phase -= 2 * .pi }
            }
        }
        return samples
    }

    // MARK: HF stereo coherence

    func testMonoifiedHFReadsCoherentAndTrueStereoDoesNot() {
        let count = Int(12 * sampleRate)
        let low = bandNoise(centerHz: 2_000, halfWidthHz: 900, amplitude: 0.1, count: count, seed: 5)
        let sharedHF = bandNoise(centerHz: 13_000, halfWidthHz: 2_500, amplitude: 0.05, count: count, seed: 6)
        let leftHF = bandNoise(centerHz: 13_000, halfWidthHz: 2_500, amplitude: 0.05, count: count, seed: 7)
        let rightHF = bandNoise(centerHz: 13_000, halfWidthHz: 2_500, amplitude: 0.05, count: count, seed: 8)

        let intensity = analyze(
            left: vDSP.add(low, sharedHF), right: vDSP.add(low, sharedHF)
        )
        let trueStereo = analyze(
            left: vDSP.add(low, leftHF), right: vDSP.add(low, rightHF)
        )
        XCTAssertGreaterThan(intensity.hfStereoCoherence, 0.9)
        XCTAssertLessThan(trueStereo.hfStereoCoherence, 0.6)
    }

    // MARK: MP3 bitstream inspector

    /// Builds a valid MPEG-1 Layer III 44.1 kHz stereo CBR-192 frame
    /// (626 bytes) with a zeroed payload.
    private func mp3Frame(firstPayload: [(offset: Int, bytes: [UInt8])] = []) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: 626)
        frame[0] = 0xFF
        frame[1] = 0xFB // MPEG-1, Layer III, no CRC
        frame[2] = 0xB0 // bitrate index 11 (192), 44.1 kHz, no padding
        frame[3] = 0x00 // stereo
        for (offset, bytes) in firstPayload {
            frame.replaceSubrange(offset ..< offset + bytes.count, with: bytes)
        }
        return frame
    }

    func testInspectorParsesPlainCBRStream() {
        let data = Data((0 ..< 12).flatMap { _ in mp3Frame() })
        let info = MP3BitstreamInspector.parse(data: data)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.bitrateMode, .cbr)
        XCTAssertEqual(info?.meanBitrateKbps ?? 0, 192, accuracy: 0.1)
        XCTAssertEqual(info?.hasXingOrInfoHeader, false)
        XCTAssertEqual(info?.hasLameTag, false)
        XCTAssertEqual(info?.usesIntensityStereo, false)
    }

    func testInspectorReadsLameTagAndLowpass() {
        // Info magic sits after the 32-byte MPEG-1 stereo side info
        // (offset 4 + 32 = 36); LAME string at +0x78 from the magic;
        // lowpass byte (+10 into the tag) is stored as Hz/100.
        let tagOffset = 4 + 32
        var lameBlock: [UInt8] = Array("LAME3.100".utf8)
        lameBlock += [0x00] // info tag revision/VBR method
        lameBlock += [190]  // lowpass 19 000 Hz
        let first = mp3Frame(firstPayload: [
            (tagOffset, Array("Info".utf8)),
            (tagOffset + 0x78, lameBlock),
        ])
        let data = Data(first + (0 ..< 11).flatMap { _ in mp3Frame() })

        let info = MP3BitstreamInspector.parse(data: data)
        XCTAssertEqual(info?.hasXingOrInfoHeader, true)
        XCTAssertEqual(info?.hasLameTag, true)
        XCTAssertEqual(info?.encoderInfo, "LAME3.100")
        XCTAssertEqual(info?.declaredLowpassHz ?? 0, 19_000, accuracy: 0.1)
    }

    func testInspectorFlagsIntensityStereoFrames() {
        var frame = mp3Frame()
        frame[3] = 0x50 // joint stereo (01), mode extension 01 = intensity on
        let data = Data((0 ..< 12).flatMap { _ in frame })
        let info = MP3BitstreamInspector.parse(data: data)
        XCTAssertEqual(info?.usesIntensityStereo, true)
        XCTAssertEqual(info?.jointStereoFrameFraction ?? 0, 1.0, accuracy: 0.01)
    }

    func testInspectorRejectsNonMP3Data() {
        let junk = Data((0 ..< 100_000).map { UInt8(($0 * 37) % 251) })
        XCTAssertNil(MP3BitstreamInspector.parse(data: junk))
    }

    // MARK: Module selection

    func testAnalysisModuleMetadataIsComplete() {
        // Every toggle needs the copy the configuration screen renders.
        for module in AnalysisModule.allCases {
            XCTAssertFalse(module.name.isEmpty)
            XCTAssertFalse(module.determines.isEmpty)
            XCTAssertFalse(module.howItWorks.isEmpty)
        }
        XCTAssertEqual(AnalysisSelection.all.count, AnalysisModule.allCases.count)
    }
}
