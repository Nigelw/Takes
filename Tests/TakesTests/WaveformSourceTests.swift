import AVFoundation
import Testing
@testable import Takes

struct WaveformSourceTests {
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
