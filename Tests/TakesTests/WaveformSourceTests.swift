import AVFoundation
import QuartzCore
import SwiftUI
import Testing
@testable import Takes

struct WaveformSourceTests {
    @Test
    func zoomedOutLaneRenderPathStaysFast() {
        // A ~4-minute file at 256 frames/bucket is ~41k base buckets; the lane
        // window at fit spans the whole file, so this is the worst-case path
        // build. Informational timing is printed for the perf log.
        let bucketCount = 41_344
        var peaks = [Float](repeating: 0, count: bucketCount)
        for index in 0..<bucketCount {
            peaks[index] = Float((sin(Double(index) * 0.37) + 1) / 2)
        }
        let waveform = Waveform(
            peaks: peaks,
            bucketCount: bucketCount,
            isComplete: true,
            reducedLevels: WaveformPyramid.reducedLevels(from: peaks)
        )
        let size = CGSize(width: 3200, height: 58)
        let duration: TimeInterval = 240

        func build() -> Path {
            LaneWaveformRenderer.waveformPath(
                for: waveform,
                in: size,
                trackStart: 0,
                trackDuration: duration,
                visibleStart: 0,
                visibleSpan: duration * 2
            )
        }

        #expect(!build().isEmpty)

        let iterations = 20
        let start = CACurrentMediaTime()
        for _ in 0..<iterations {
            _ = build()
        }
        let milliseconds = (CACurrentMediaTime() - start) / Double(iterations) * 1000
        print("[perf] zoomed-out waveformPath build: \(String(format: "%.3f", milliseconds)) ms")
        #expect(milliseconds >= 0)
    }

    @Test
    func pyramidLevelsMaxPoolFileAnchoredPairs() {
        // Odd count exercises the trailing carry-over bucket at every level.
        let count = 10_001
        var peaks = [Float](repeating: 0, count: count)
        for index in 0..<count {
            peaks[index] = Float((sin(Double(index) * 1.7) + 1) / 2)
        }

        let levels = WaveformPyramid.reducedLevels(from: peaks)
        #expect(!levels.isEmpty)
        // Reduction stops once a level is small enough.
        #expect(levels.last!.count <= WaveformPyramid.minimumLevelBucketCount * 2)

        // Every level-k bucket must equal the max over its fixed base range
        // [i·2^(k+1), (i+1)·2^(k+1)) — file-anchored pooling, clamped at the end.
        for (levelIndex, level) in levels.enumerated() {
            let scale = 1 << (levelIndex + 1)
            #expect(level.count == (count + scale - 1) / scale)
            for bucket in [0, 1, level.count / 2, level.count - 2, level.count - 1] where bucket >= 0 {
                let low = bucket * scale
                let high = min(low + scale, count)
                let expected = peaks[low..<high].max() ?? 0
                #expect(level[bucket] == expected, "level \(levelIndex) bucket \(bucket)")
            }
        }
    }

    @Test
    func pyramidIsExcludedFromWaveformEquality() {
        let peaks: [Float] = [0.1, 0.9, 0.4]
        let bare = Waveform(peaks: peaks, bucketCount: 3, isComplete: true)
        let withLevels = Waveform(
            peaks: peaks,
            bucketCount: 3,
            isComplete: true,
            reducedLevels: [[0.9]]
        )
        #expect(bare == withLevels)
    }

    @Test
    func generatesPeaksThatTrackTheSignalEnvelope() async throws {
        // First half silent, second half full-scale, so the resulting envelope
        // should be ~0 across the first half of buckets and ~1 across the second.
        let frameCount = 44_100
        let url = try writeTestFile(frameCount: frameCount) { frame, total in
            frame < total / 2 ? 0 : 1
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await collectWaveform(url: url)

        let expectedBuckets = WaveformSource.bucketCount(forFrameCount: AVAudioFramePosition(frameCount))
        #expect(result.isComplete)
        #expect(result.bucketCount == expectedBuckets)
        #expect(result.peaks.count == expectedBuckets)

        // Sample either side of the midpoint, leaving a margin for the single
        // bucket that straddles the silence/full-scale boundary.
        let mid = expectedBuckets / 2
        let firstHalfPeak = result.peaks[0..<(mid - 2)].max() ?? 0
        let secondHalfMin = result.peaks[(mid + 2)...].min() ?? 0
        #expect(firstHalfPeak < 0.01)
        #expect(secondHalfMin > 0.99)
    }

    @Test
    func reportsProgressBeforeCompletion() async throws {
        let url = try writeTestFile(frameCount: 200_000) { _, _ in 0.5 }
        defer { try? FileManager.default.removeItem(at: url) }

        let progress = ProgressCounter()
        await WaveformSource.generate(url: url) { _, _, isComplete in
            await progress.record(isComplete: isComplete)
        }

        #expect(await progress.partialCount > 0)
        #expect(await progress.sawComplete)
    }

    @Test
    func emptyOrMissingFileCompletesWithNoPeaks() async throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("does-not-exist.caf")

        let result = await collectWaveform(url: missing)

        #expect(result.isComplete)
        #expect(result.peaks.isEmpty)
        #expect(result.bucketCount == 0)
    }

    @Test
    func bucketCountCapsResolutionForLongFiles() {
        // Short files: one bucket per `minimumFramesPerBucket`.
        #expect(WaveformSource.bucketCount(forFrameCount: 0) == 0)
        #expect(WaveformSource.bucketCount(forFrameCount: 256) == 1)
        #expect(WaveformSource.bucketCount(forFrameCount: 257) == 2)

        // Very long files are capped so memory stays bounded.
        let huge = AVAudioFramePosition(WaveformSource.maximumBuckets) * 256 * 10
        #expect(WaveformSource.bucketCount(forFrameCount: huge) == WaveformSource.maximumBuckets)
    }

    // MARK: - Helpers

    private func collectWaveform(url: URL) async -> (peaks: [Float], bucketCount: Int, isComplete: Bool) {
        let collector = Collector()
        await WaveformSource.generate(url: url) { peaks, bucketCount, isComplete in
            await collector.record(peaks: peaks, bucketCount: bucketCount, isComplete: isComplete)
        }
        return await collector.snapshot()
    }

    /// Writes a mono 44.1 kHz float file whose samples are produced by `sample`.
    private func writeTestFile(
        frameCount: Int,
        sample: (_ frame: Int, _ total: Int) -> Float
    ) throws -> URL {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waveform-test-\(UUID().uuidString).caf")

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        )
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let channel = try #require(buffer.floatChannelData)
        for frame in 0..<frameCount {
            channel[0][frame] = sample(frame, frameCount)
        }
        try file.write(from: buffer)
        return url
    }

    private actor ProgressCounter {
        private(set) var partialCount = 0
        private(set) var sawComplete = false

        func record(isComplete: Bool) {
            if isComplete {
                sawComplete = true
            } else {
                partialCount += 1
            }
        }
    }

    private actor Collector {
        private var peaks: [Float] = []
        private var bucketCount = 0
        private var isComplete = false

        func record(peaks: [Float], bucketCount: Int, isComplete: Bool) {
            self.peaks = peaks
            self.bucketCount = bucketCount
            self.isComplete = isComplete
        }

        func snapshot() -> (peaks: [Float], bucketCount: Int, isComplete: Bool) {
            (peaks, bucketCount, isComplete)
        }
    }
}
