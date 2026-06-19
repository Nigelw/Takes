import AVFoundation
import Testing
@testable import Takes

struct WaveformSourceTests {
    @Test
    func generatesPeaksThatTrackTheSignalEnvelope() async throws {
        // First half silent, second half full-scale, so the resulting envelope
        // should be ~0 across the first half of bins and ~1 across the second.
        let url = try writeTestFile(frameCount: 44_100) { frame, total in
            frame < total / 2 ? 0 : 1
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await collectWaveform(url: url, binCount: 100)

        #expect(result.isComplete)
        #expect(result.peaks.count == 100)

        let firstHalfPeak = result.peaks[0..<50].max() ?? 0
        let secondHalfMin = result.peaks[50..<100].min() ?? 0
        #expect(firstHalfPeak < 0.01)
        #expect(secondHalfMin > 0.99)
    }

    @Test
    func reportsProgressBeforeCompletion() async throws {
        let url = try writeTestFile(frameCount: 200_000) { _, _ in 0.5 }
        defer { try? FileManager.default.removeItem(at: url) }

        let progress = ProgressCounter()
        await WaveformSource.generate(url: url, binCount: 100) { _, isComplete in
            await progress.record(isComplete: isComplete)
        }

        #expect(await progress.partialCount > 0)
        #expect(await progress.sawComplete)
    }

    @Test
    func emptyOrMissingFileCompletesWithNoPeaks() async throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("does-not-exist.caf")

        let result = await collectWaveform(url: missing, binCount: 100)

        #expect(result.isComplete)
        #expect(result.peaks.isEmpty)
    }

    // MARK: - Helpers

    private func collectWaveform(url: URL, binCount: Int) async -> (peaks: [Float], isComplete: Bool) {
        let collector = Collector()
        await WaveformSource.generate(url: url, binCount: binCount) { peaks, isComplete in
            await collector.record(peaks: peaks, isComplete: isComplete)
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
        private var isComplete = false

        func record(peaks: [Float], isComplete: Bool) {
            self.peaks = peaks
            self.isComplete = isComplete
        }

        func snapshot() -> (peaks: [Float], isComplete: Bool) {
            (peaks, isComplete)
        }
    }
}
