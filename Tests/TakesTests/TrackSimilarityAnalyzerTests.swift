import AVFoundation
import Foundation
import Testing
@testable import Takes

struct TrackSimilarityAnalyzerTests {
    @Test func pairKeysAreOrderIndependent() {
        let a = UUID(), b = UUID()
        #expect(TrackSimilarityPair(firstID: a, secondID: b) == TrackSimilarityPair(firstID: b, secondID: a))
    }

    @Test func gainAndLeadingSilencePreserveRecordingMatch() {
        let original = Self.features(seed: 17)
        let shifted = TrackSimilarityAnalyzer.Features(
            novelty: [Float](repeating: 0, count: 2_345) + original.novelty,
            mono: [Float](repeating: 0, count: 2_345) + original.mono.map { $0 * 0.21 },
            activeRange: 2_345..<(2_345 + original.novelty.count)
        )
        let evidence = TrackSimilarityAnalyzer.compare(original, shifted)
        #expect(evidence.sameRecording == .match)
        #expect(evidence.samePerformance == .match)
        #expect(abs(evidence.offsetSeconds - 2.345) < 0.005)
        #expect(evidence.firstCoverage > 0.99)
        #expect(evidence.secondCoverage > 0.99)
    }

    @Test func unrelatedSignalsAreNotGrouped() {
        let evidence = TrackSimilarityAnalyzer.compare(Self.features(seed: 17), Self.features(seed: 31))
        #expect(evidence.sameRecording == .mismatch)
        #expect(evidence.samePerformance == .mismatch)
    }

    @Test func sharedEventsWithoutWaveformCoherenceOnlySupportPerformance() {
        let original = Self.features(seed: 17)
        let other = Self.features(seed: 31)
        let mixed = TrackSimilarityAnalyzer.Features(novelty: original.novelty, mono: other.mono, activeRange: original.activeRange)
        let evidence = TrackSimilarityAnalyzer.compare(original, mixed)
        #expect(evidence.sameRecording == .insufficientEvidence)
        #expect(evidence.samePerformance == .match)
    }

    @Test func shortExcerptCannotEstablishWholeTrackIdentity() {
        let original = Self.features(seed: 17)
        let excerpt = TrackSimilarityAnalyzer.Features(novelty: Array(original.novelty.prefix(30_000)),
            mono: Array(original.mono.prefix(30_000)), activeRange: 0..<30_000)
        let evidence = TrackSimilarityAnalyzer.compare(original, excerpt)
        #expect(evidence.sameRecording == .mismatch)
        #expect(evidence.samePerformance == .mismatch)
    }

    @Test func partiallySharedBackingDoesNotMatch() {
        let a = Self.features(seed: 17)
        let b = Self.features(seed: 31)
        let partial = TrackSimilarityAnalyzer.Features(
            novelty: Array(a.novelty.prefix(20_000)) + Array(b.novelty.dropFirst(20_000)),
            mono: Array(a.mono.prefix(20_000)) + Array(b.mono.dropFirst(20_000)), activeRange: a.activeRange)
        #expect(TrackSimilarityAnalyzer.compare(a, partial).samePerformance != .match)
    }

    @Test func reorderedRegionsFailTimingConsistency() {
        let a = Self.features(seed: 17)
        let split = 30_000
        let reordered = TrackSimilarityAnalyzer.Features(
            novelty: Array(a.novelty.dropFirst(split)) + Array(a.novelty.prefix(split)),
            mono: Array(a.mono.dropFirst(split)) + Array(a.mono.prefix(split)), activeRange: a.activeRange)
        #expect(TrackSimilarityAnalyzer.compare(a, reordered).samePerformance != .match)
    }

    @Test func silenceAndShortFilesAbstain() {
        let silent = TrackSimilarityAnalyzer.Features(novelty: [Float](repeating: 0, count: 60_000),
            mono: [Float](repeating: 0, count: 60_000), activeRange: 0..<0)
        #expect(TrackSimilarityAnalyzer.compare(silent, silent).sameRecording == .insufficientEvidence)
        let short = Self.features(seed: 17, count: 10_000)
        #expect(TrackSimilarityAnalyzer.compare(short, short).sameRecording == .insufficientEvidence)
    }

    @Test func cancelledVerificationNeverReturnsPartialMatch() {
        let a = Self.features(seed: 17)
        #expect(TrackSimilarityAnalyzer.compare(a, a, stopped: { true }).sameRecording == .insufficientEvidence)
    }

    @Test func expiredDeadlineAndDecodeFailureAreDistinct() async {
        let a = TrackSimilaritySource(id: UUID(), url: URL(fileURLWithPath: "/missing-similarity-a.wav"))
        let b = TrackSimilaritySource(id: UUID(), url: URL(fileURLWithPath: "/missing-similarity-b.wav"))
        let pair = TrackSimilarityPair(firstID: a.id, secondID: b.id)
        let analyzer = TrackSimilarityAnalyzer()
        let timeout = await analyzer.analyze(TrackSimilarityRequest(sources: [a, b], pairs: [pair], deadline: .distantPast))
        #expect(timeout.timedOut)
        #expect(timeout.evidence[pair]?.sameRecording == .insufficientEvidence)
        let failure = await analyzer.analyze(TrackSimilarityRequest(sources: [a, b], pairs: [pair], deadline: .distantFuture))
        #expect(!failure.timedOut)
        #expect(failure.evidence[pair]?.sameRecording == .analysisFailure)
    }

    @Test func extractionHonorsCancellationAndRejectsCorruptFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("takes-similarity-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("audio.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        for index in 0..<8_000 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.2)) * 0.3 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        #expect(throws: CancellationError.self) { try TrackSimilarityAnalyzer.extract(url: url, stopped: { true }) }
        let features = try TrackSimilarityAnalyzer.extract(url: url)
        #expect(features.novelty.count == 1_000)
        #expect(features.activeRange.count > 990)
        let identity = try TrackSimilarityAnalyzer.FileIdentity(url: url)
        try Data("corrupt audio".utf8).write(to: url)
        #expect(try TrackSimilarityAnalyzer.FileIdentity(url: url) != identity)
        #expect(throws: (any Error).self) { try TrackSimilarityAnalyzer.extract(url: url) }
    }

    private static func features(seed: UInt64, count: Int = 60_000) -> TrackSimilarityAnalyzer.Features {
        var state = seed
        func random() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Float(state >> 40) / Float(1 << 24)
        }
        var novelty = [Float](repeating: 0, count: count)
        var mono = novelty
        for index in 0..<count {
            let event = random()
            if event > 0.985 { novelty[index] = 0.2 + random() * 3 }
            mono[index] = random() - 0.5
        }
        return TrackSimilarityAnalyzer.Features(novelty: novelty, mono: mono, activeRange: 0..<count)
    }
}
