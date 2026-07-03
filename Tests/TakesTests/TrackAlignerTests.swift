import AVFoundation
import Testing
@testable import Takes

struct TrackAlignerTests {
    // MARK: - Correlation core

    @Test
    func bestAlignmentRecoversKnownLag() {
        let target = Self.sparseNovelty(count: 20_000, seed: 7)
        let lag = 4_321
        let reference = Array(target[lag..<(lag + 6_000)])

        let match = TrackAligner.bestAlignment(reference: reference, target: target)

        #expect(match?.lag == lag)
        #expect((match?.score ?? 0) > 0.9)
        #expect(match.map(TrackAligner.isConfident) == true)
    }

    @Test
    func bestAlignmentFindsNegativeLag() {
        // The reference starts 1.5 s before the target's content does: the
        // target is a trimmed version of the reference window.
        let reference = Self.sparseNovelty(count: 12_000, seed: 11)
        let target = Array(reference[1_500...])

        let match = TrackAligner.bestAlignment(reference: reference, target: target)

        #expect(match?.lag == -1_500)
        #expect((match?.score ?? 0) > 0.9)
    }

    @Test
    func bestAlignmentRejectsUnrelatedSignals() {
        let reference = Self.sparseNovelty(count: 10_000, seed: 1)
        let target = Self.sparseNovelty(count: 20_000, seed: 2)

        let match = TrackAligner.bestAlignment(reference: reference, target: target)

        // Unrelated signals may still produce a modest peak, but never a
        // confident one — the peak doesn't stand out from the background.
        #expect(match.map(TrackAligner.isConfident) != true)
    }

    @Test
    func bestAlignmentRejectsSignalsTooShortToTrust() {
        let target = Self.sparseNovelty(count: 20_000, seed: 3)
        let reference = Array(target[100..<600])

        #expect(TrackAligner.bestAlignment(reference: reference, target: target) == nil)
    }

    @Test
    func bestAlignmentRejectsFlatSignals() {
        let flat = [Float](repeating: 0.5, count: 5_000)
        let target = Self.sparseNovelty(count: 20_000, seed: 4)

        #expect(TrackAligner.bestAlignment(reference: flat, target: target) == nil)
    }

    // MARK: - Reference window

    @Test
    func referenceWindowUsesRequestedSpanWhereContentIsDense() {
        let novelty = Self.sparseNovelty(count: 100_000, seed: 5)

        let window = TrackAligner.referenceWindow(novelty: novelty, centerIndex: 50_000, halfWidth: 15_000)

        #expect(window == 35_000..<65_000)
    }

    @Test
    func referenceWindowWidensOverSilence() {
        // Content only in the final quarter; a window centered early must
        // widen until it reaches that energy.
        var novelty = [Float](repeating: 0, count: 100_000)
        for index in 75_000..<100_000 where index % 500 == 0 {
            novelty[index] = 1
        }

        let window = TrackAligner.referenceWindow(novelty: novelty, centerIndex: 10_000, halfWidth: 5_000)

        #expect(window.upperBound > 75_000)
    }

    @Test
    func referenceWindowFallsBackToWholeSilentTrack() {
        let novelty = [Float](repeating: 0, count: 10_000)

        let window = TrackAligner.referenceWindow(novelty: novelty, centerIndex: 5_000, halfWidth: 1_000)

        #expect(window == 0..<10_000)
    }

    // MARK: - Offset math

    @Test
    func alignedOffsetCombinesAnchorOffsetWindowAndLag() {
        // Anchor offset 1.25 s, window starting 2 s into the anchor's file,
        // match 5 s into the other file → other must start at -1.75 s.
        let offset = TrackAligner.alignedOffsetSeconds(
            anchorOffsetSeconds: 1.25,
            windowStartIndex: 2_000,
            matchLag: 5_000
        )
        #expect(abs(offset - -1.75) < 0.000_1)
    }

    @Test
    func alignedOffsetRoundsToWholeMilliseconds() {
        let offset = TrackAligner.alignedOffsetSeconds(
            anchorOffsetSeconds: 0.000_4,
            windowStartIndex: 0,
            matchLag: 0
        )
        #expect(offset == 0)
    }

    @Test
    func alignedOffsetClampsToOffsetFieldRange() {
        let offset = TrackAligner.alignedOffsetSeconds(
            anchorOffsetSeconds: 0,
            windowStartIndex: 400_000,
            matchLag: 0
        )
        #expect(offset == TrackAligner.maximumOffsetSeconds)
    }

    // MARK: - Novelty

    @Test
    func noveltyKeepsOnlyEnergyRises() {
        // Quiet → loud → quiet: novelty spikes at the rise, stays zero on the
        // fall and during steady state.
        var energy = [Float](repeating: 0.000_1, count: 100)
        for index in 40..<60 { energy[index] = 100 }

        let novelty = TrackAligner.noveltyFromEnergy(energy, framesPerHop: 44.1)

        #expect(novelty.count == 100)
        let rise = novelty[39...41].max() ?? 0
        let fall = novelty[59...61].max() ?? 0
        let steady = novelty[45...55].max() ?? 0
        #expect(rise > 1)
        #expect(fall < 0.001)
        #expect(steady < 0.001)
    }

    // MARK: - End to end

    @Test
    func alignsShiftedCopiesAcrossSampleRates() async throws {
        // The same aperiodic burst pattern rendered at 44.1 kHz and, shifted
        // 0.75 s later with extra padding, at 48 kHz. The aligner should slide
        // the second track 0.75 s earlier — anchor offset included.
        let bursts: [TimeInterval] = [0.5, 0.9, 1.35, 2.0, 2.3, 3.05, 3.7]
        let shift: TimeInterval = 0.75

        let anchorURL = try Self.writeBurstFile(sampleRate: 44_100, duration: 4.5, burstTimes: bursts)
        let otherURL = try Self.writeBurstFile(
            sampleRate: 48_000,
            duration: 6,
            burstTimes: bursts.map { $0 + shift }
        )
        defer {
            try? FileManager.default.removeItem(at: anchorURL)
            try? FileManager.default.removeItem(at: otherURL)
        }

        let otherID = UUID()
        let request = TrackAligner.Request(
            anchor: TrackAligner.Source(id: UUID(), url: anchorURL, displayName: "anchor", currentOffsetSeconds: 0.2),
            anchorPlayheadFileTime: 0,
            others: [
                TrackAligner.Source(id: otherID, url: otherURL, displayName: "other", currentOffsetSeconds: 0)
            ]
        )

        let results = await TrackAligner.align(request)

        #expect(results.count == 1)
        let result = try #require(results.first)
        #expect(result.trackID == otherID)
        let newOffset = try #require(result.newOffsetSeconds)
        // Aligned: otherOffset + burstTime + shift == anchorOffset + burstTime.
        #expect(abs(newOffset - (0.2 - shift)) <= 0.003)
        #expect(result.score > 0.6)
    }

    @Test
    func reportsNoMatchForUnrelatedAudio() async throws {
        // Dense enough that one coincidentally-aligned onset pair can't
        // dominate the normalized score, and jittered off any common grid so
        // no single lag lines up several onsets at once.
        let anchorURL = try Self.writeBurstFile(
            sampleRate: 44_100,
            duration: 6,
            burstTimes: [0.317, 0.851, 1.204, 1.793, 2.118, 2.677, 3.241, 3.598, 4.166, 4.723, 5.291, 5.644]
        )
        let otherURL = try Self.writeBurstFile(
            sampleRate: 44_100,
            duration: 6,
            burstTimes: [0.402, 0.939, 1.487, 1.862, 2.539, 2.941, 3.376, 3.812, 4.408, 4.856, 5.137, 5.783],
            seed: 99
        )
        defer {
            try? FileManager.default.removeItem(at: anchorURL)
            try? FileManager.default.removeItem(at: otherURL)
        }

        let request = TrackAligner.Request(
            anchor: TrackAligner.Source(id: UUID(), url: anchorURL, displayName: "anchor", currentOffsetSeconds: 0),
            anchorPlayheadFileTime: 0,
            others: [
                TrackAligner.Source(id: UUID(), url: otherURL, displayName: "other", currentOffsetSeconds: 0)
            ]
        )

        let results = await TrackAligner.align(request)

        #expect(results.first?.newOffsetSeconds == nil)
    }

    // MARK: - Tempo pass

    @Test
    func stretchedEnvelopeResamplesLinearly() {
        let values: [Float] = [0, 1, 2, 3]

        let stretched = TrackAligner.stretchedEnvelope(values, ratio: 2)

        #expect(stretched.count == 8)
        #expect(abs(stretched[2] - 1) < 0.000_1)
        #expect(abs(stretched[3] - 1.5) < 0.000_1)
    }

    @Test
    func tempoAlignedOffsetMatchesPlainOffsetAtUnitRatio() {
        let tempo = TrackAligner.tempoAlignedOffsetSeconds(
            anchorOffsetSeconds: 0.5,
            anchorPlayheadFileTime: 42,
            speedRatio: 1,
            matchLag: 1_250
        )
        let plain = TrackAligner.alignedOffsetSeconds(
            anchorOffsetSeconds: 0.5,
            windowStartIndex: 0,
            matchLag: 1_250
        )
        #expect(tempo == plain)
    }

    @Test
    func tempoAlignedOffsetAnchorsAtThePlayhead() {
        // The other track runs 3% slower with its content 0.4 s late: anchor
        // time t sits at track time 0.4 + 1.03·t. Aligning at playhead 10 s
        // must put track time 10.7 at global time anchorOffset + 10.
        let offset = TrackAligner.tempoAlignedOffsetSeconds(
            anchorOffsetSeconds: 0,
            anchorPlayheadFileTime: 10,
            speedRatio: 1.03,
            matchLag: 400
        )
        #expect(abs(offset - (10 - 10.7)) < 0.000_1)
    }

    @Test
    func tempoSearchDetectsSpeedDifference() async throws {
        // Same burst pattern, second file 3% slower (times and duration
        // scaled) plus 0.4 s of extra lead-in.
        let bursts: [TimeInterval] = [0.5, 0.9, 1.35, 2.0, 2.3, 3.05, 3.7, 4.4, 4.9, 5.6]
        let ratio = 1.03
        let lead = 0.4

        let anchorURL = try Self.writeBurstFile(sampleRate: 44_100, duration: 6.2, burstTimes: bursts)
        let otherURL = try Self.writeBurstFile(
            sampleRate: 44_100,
            duration: 6.2 * ratio + lead,
            burstTimes: bursts.map { $0 * ratio + lead }
        )
        defer {
            try? FileManager.default.removeItem(at: anchorURL)
            try? FileManager.default.removeItem(at: otherURL)
        }

        let otherID = UUID()
        let request = TrackAligner.Request(
            anchor: TrackAligner.Source(id: UUID(), url: anchorURL, displayName: "anchor", currentOffsetSeconds: 0),
            anchorPlayheadFileTime: 0,
            others: [
                TrackAligner.Source(id: otherID, url: otherURL, displayName: "other", currentOffsetSeconds: 0)
            ]
        )

        let recorder = ProgressRecorder()
        let results = await TrackAligner.alignTempo(request) { progress in
            recorder.record(progress)
        }

        let result = try #require(results.first)
        #expect(result.trackID == otherID)
        let detectedRatio = try #require(result.speedRatio)
        #expect(abs(detectedRatio - ratio) < 0.005)
        // Playhead at 0: content aligns when the other track is pulled the
        // lead-in earlier.
        let newOffset = try #require(result.newOffsetSeconds)
        #expect(abs(newOffset - -lead) < 0.05)

        let progressValues = recorder.snapshot()
        #expect(progressValues == progressValues.sorted())
        #expect(abs((progressValues.last ?? 0) - 1) < 0.000_1)
    }

    @Test
    func tempoSearchRejectsUnrelatedAudio() async throws {
        let anchorURL = try Self.writeBurstFile(
            sampleRate: 44_100,
            duration: 6,
            burstTimes: [0.317, 0.851, 1.204, 1.793, 2.118, 2.677, 3.241, 3.598, 4.166, 4.723, 5.291, 5.644]
        )
        let otherURL = try Self.writeBurstFile(
            sampleRate: 44_100,
            duration: 6,
            burstTimes: [0.402, 0.939, 1.487, 1.862, 2.539, 2.941, 3.376, 3.812, 4.408, 4.856, 5.137, 5.783],
            seed: 99
        )
        defer {
            try? FileManager.default.removeItem(at: anchorURL)
            try? FileManager.default.removeItem(at: otherURL)
        }

        let request = TrackAligner.Request(
            anchor: TrackAligner.Source(id: UUID(), url: anchorURL, displayName: "anchor", currentOffsetSeconds: 0),
            anchorPlayheadFileTime: 0,
            others: [
                TrackAligner.Source(id: UUID(), url: otherURL, displayName: "other", currentOffsetSeconds: 0)
            ]
        )

        let results = await TrackAligner.alignTempo(request) { _ in }

        #expect(results.first?.newOffsetSeconds == nil)
        #expect(results.first?.speedRatio == nil)
    }

    /// Collects progress callbacks from any thread.
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []

        func record(_ value: Double) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        func snapshot() -> [Double] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    // MARK: - Helpers

    /// Deterministic sparse spike train resembling an onset-novelty envelope.
    private static func sparseNovelty(count: Int, seed: UInt64) -> [Float] {
        var state = seed
        func next() -> UInt64 {
            // SplitMix64: deterministic across runs and platforms.
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        var novelty = [Float](repeating: 0, count: count)
        var index = Int(next() % 200)
        while index < count {
            novelty[index] = 0.5 + Float(next() % 1000) / 1000
            index += 20 + Int(next() % 400)
        }
        return novelty
    }

    /// Writes a mono file of noise bursts (~60 ms each) at the given times
    /// over silence, so alignment has clear onsets to lock onto.
    private static func writeBurstFile(
        sampleRate: Double,
        duration: TimeInterval,
        burstTimes: [TimeInterval],
        seed: UInt64 = 42
    ) throws -> URL {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aligner-test-\(UUID().uuidString).caf")

        let frameCount = Int(duration * sampleRate)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        )
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let channel = try #require(buffer.floatChannelData)

        var state = seed
        func noise() -> Float {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Float(z % 20_000) / 10_000 - 1
        }

        for frame in 0..<frameCount {
            channel[0][frame] = 0
        }
        let burstFrames = Int(0.06 * sampleRate)
        for time in burstTimes {
            let start = Int(time * sampleRate)
            for frame in start..<min(start + burstFrames, frameCount) {
                channel[0][frame] = noise() * 0.8
            }
        }

        try file.write(from: buffer)
        return url
    }
}
