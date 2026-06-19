import AVFoundation
import Foundation

/// A downsampled peak envelope for an audio file.
///
/// `peaks` holds the per-bin maximum absolute sample amplitude (0...1). It is
/// built up progressively: while a waveform is still being generated, `peaks`
/// contains only the bins computed so far (left-to-right), and `isComplete` is
/// `false`. Rendering code can draw whatever is available and will be refreshed
/// as more bins arrive.
struct Waveform: Equatable {
    /// Per-bin peak amplitudes in 0...1, ordered from the start of the file.
    var peaks: [Float]
    /// The total number of bins this waveform will contain once complete.
    var binCount: Int
    /// Whether generation has finished (or was cut short by a read error).
    var isComplete: Bool

    static let empty = Waveform(peaks: [], binCount: 0, isComplete: false)
}

/// Owns waveform generation for the loaded session tracks.
///
/// Generation runs on a detached background task per track so the main thread
/// (and audio playback) is never blocked. Partial results are streamed back to
/// the main actor and published, driving a progressive left-to-right fill in
/// the UI. Waveforms are cached in memory only for the lifetime of the process.
@MainActor
final class WaveformStore: ObservableObject {
    /// Target bin count for a generated waveform. Chosen to comfortably exceed
    /// the on-screen pixel width of a lane so the rendered envelope stays crisp
    /// even when a track spans the full timeline; the Canvas compresses as needed.
    static let targetBinCount = 2_000

    @Published private(set) var waveforms: [SessionTrack.ID: Waveform] = [:]

    private var tasks: [SessionTrack.ID: Task<Void, Never>] = [:]
    /// Identity (url + size + mod date) the in-flight/finished waveform was built
    /// from, so we can detect when a track's file changes and regenerate.
    private var sourceIdentities: [SessionTrack.ID: WaveformSource.Identity] = [:]

    /// Reconcile generation tasks with the current set of session tracks.
    /// Starts generation for newly added tracks, cancels and drops waveforms for
    /// removed ones, and regenerates if a track's underlying file changed.
    func sync(tracks: [SessionTrack]) {
        let liveIDs = Set(tracks.map(\.id))

        for id in tasks.keys where !liveIDs.contains(id) {
            cancel(id)
        }

        for track in tracks {
            let identity = WaveformSource.Identity(url: track.loadedTrack.url)
            if sourceIdentities[track.id] == identity {
                continue
            }
            cancel(id: track.id, keepWaveform: false)
            start(trackID: track.id, url: track.loadedTrack.url, identity: identity)
        }
    }

    func waveform(for trackID: SessionTrack.ID) -> Waveform? {
        waveforms[trackID]
    }

    private func cancel(_ id: SessionTrack.ID) {
        cancel(id: id, keepWaveform: false)
    }

    private func cancel(id: SessionTrack.ID, keepWaveform: Bool) {
        tasks[id]?.cancel()
        tasks[id] = nil
        sourceIdentities[id] = nil
        if !keepWaveform {
            waveforms[id] = nil
        }
    }

    private func start(trackID: SessionTrack.ID, url: URL, identity: WaveformSource.Identity) {
        sourceIdentities[trackID] = identity
        waveforms[trackID] = Waveform(peaks: [], binCount: Self.targetBinCount, isComplete: false)

        let binCount = Self.targetBinCount
        tasks[trackID] = Task.detached(priority: .utility) {
            await WaveformSource.generate(url: url, binCount: binCount) { peaks, isComplete in
                await MainActor.run { [weak self] in
                    self?.apply(peaks: peaks, isComplete: isComplete, to: trackID, identity: identity)
                }
            }
        }
    }

    private func apply(
        peaks: [Float],
        isComplete: Bool,
        to trackID: SessionTrack.ID,
        identity: WaveformSource.Identity
    ) {
        // Ignore updates from a task that has since been superseded (track
        // removed, or its file changed and a new task started).
        guard sourceIdentities[trackID] == identity else { return }

        waveforms[trackID] = Waveform(
            peaks: peaks,
            binCount: Self.targetBinCount,
            isComplete: isComplete
        )

        if isComplete {
            tasks[trackID] = nil
        }
    }
}

/// Decodes an audio file off the main thread and downsamples it into a peak
/// envelope, streaming progress back via a callback.
enum WaveformSource {
    /// Lightweight fingerprint of a file used to decide whether a cached/in-flight
    /// waveform is still valid for a given track.
    struct Identity: Equatable {
        let path: String
        let size: Int
        let modified: Date?

        init(url: URL) {
            path = url.standardizedFileURL.resolvingSymlinksInPath().path
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            size = (attributes?[.size] as? Int) ?? 0
            modified = attributes?[.modificationDate] as? Date
        }
    }

    /// Number of frames read per decode pass. Large enough to keep decoding
    /// efficient, small enough that cancellation stays responsive.
    private static let framesPerChunk: AVAudioFrameCount = 65_536

    /// Generate a peak envelope for `url`, calling `onProgress` periodically with
    /// the bins finalized so far. `onProgress` is always called once more with
    /// `isComplete == true` when decoding finishes or stops early.
    ///
    /// Runs synchronously on whatever (background) task invokes it; it reads the
    /// file in chunks and yields between them so cancellation is honored quickly.
    static func generate(
        url: URL,
        binCount: Int,
        onProgress: @Sendable (_ peaks: [Float], _ isComplete: Bool) async -> Void
    ) async {
        guard binCount > 0 else {
            await onProgress([], true)
            return
        }

        guard
            let file = try? AVAudioFile(forReading: url),
            file.length > 0
        else {
            await onProgress([], true)
            return
        }

        let format = file.processingFormat
        let totalFrames = file.length
        guard
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerChunk)
        else {
            await onProgress([], true)
            return
        }

        var peaks = [Float](repeating: 0, count: binCount)
        var framesRead: AVAudioFramePosition = 0
        // Highest bin index whose samples have all been read; everything up to
        // (but excluding) this is safe to publish as final.
        var finalizedBins = 0

        while framesRead < totalFrames {
            if Task.isCancelled { return }

            do {
                try file.read(into: buffer, frameCount: framesPerChunk)
            } catch {
                break
            }

            let frames = Int(buffer.frameLength)
            if frames == 0 { break }

            accumulatePeaks(
                from: buffer,
                frameCount: frames,
                startFrame: framesRead,
                totalFrames: totalFrames,
                binCount: binCount,
                into: &peaks
            )

            framesRead += AVAudioFramePosition(frames)

            // All frames up to framesRead are decoded, so every bin that ends at
            // or before framesRead is final.
            let newFinalized = Int((framesRead * AVAudioFramePosition(binCount)) / totalFrames)
            if newFinalized > finalizedBins {
                finalizedBins = min(newFinalized, binCount)
                await onProgress(Array(peaks[0..<finalizedBins]), false)
            }

            await Task.yield()
        }

        if Task.isCancelled { return }
        await onProgress(peaks, true)
    }

    private static func accumulatePeaks(
        from buffer: AVAudioPCMBuffer,
        frameCount: Int,
        startFrame: AVAudioFramePosition,
        totalFrames: AVAudioFramePosition,
        binCount: Int,
        into peaks: inout [Float]
    ) {
        guard let channels = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)

        for frame in 0..<frameCount {
            var sample: Float = 0
            for channel in 0..<channelCount {
                sample = max(sample, abs(channels[channel][frame]))
            }

            let globalFrame = startFrame + AVAudioFramePosition(frame)
            var bin = Int((globalFrame * AVAudioFramePosition(binCount)) / totalFrames)
            if bin >= binCount { bin = binCount - 1 }
            if sample > peaks[bin] {
                peaks[bin] = sample
            }
        }
    }
}
