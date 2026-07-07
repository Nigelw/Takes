import Accelerate
import AVFoundation
import Foundation

/// A downsampled peak envelope for an audio file.
///
/// `peaks` holds per-bucket maximum-magnitude sample amplitudes (0...1) at a
/// fixed, high horizontal resolution — far finer than the on-screen pixel
/// width — so the view can pool it down to any zoom level or window size
/// without re-decoding the file. It is built up progressively: while a waveform
/// is still being generated, `peaks` contains only the buckets computed so far
/// (left-to-right), and `isComplete` is `false`.
struct Waveform: Equatable {
    /// Per-bucket peak magnitudes in 0...1, ordered from the start of the file.
    var peaks: [Float]
    /// Total number of buckets this waveform will contain once complete. Bucket
    /// `i` covers the file fraction `i/bucketCount ... (i+1)/bucketCount`, so the
    /// view can position partial results correctly even before generation ends.
    var bucketCount: Int
    /// Whether generation has finished (or was cut short by a read error).
    var isComplete: Bool

    static let empty = Waveform(peaks: [], bucketCount: 0, isComplete: false)
}

/// Owns waveform generation for the loaded session tracks.
///
/// Generation runs on a detached background task per track so the main thread
/// (and audio playback) is never blocked. Partial results are streamed back to
/// the main actor and published, driving a progressive left-to-right fill in
/// the UI. Waveforms are cached in memory only for the lifetime of the process.
@MainActor
final class WaveformStore: ObservableObject {
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
            cancel(id: track.id)
            start(trackID: track.id, url: track.loadedTrack.url, identity: identity)
        }
    }

    func waveform(for trackID: SessionTrack.ID) -> Waveform? {
        waveforms[trackID]
    }

    private func cancel(_ id: SessionTrack.ID) {
        cancel(id: id)
    }

    private func cancel(id: SessionTrack.ID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        sourceIdentities[id] = nil
        waveforms[id] = nil
    }

    private func start(trackID: SessionTrack.ID, url: URL, identity: WaveformSource.Identity) {
        sourceIdentities[trackID] = identity
        waveforms[trackID] = .empty

        // User-initiated, not utility: the progressive fill is the visible
        // feedback for a just-imported track, and utility QoS gets throttled
        // onto efficiency cores.
        tasks[trackID] = Task.detached(priority: .userInitiated) {
            await WaveformSource.generate(url: url) { peaks, bucketCount, isComplete in
                await MainActor.run { [weak self] in
                    self?.apply(
                        peaks: peaks,
                        bucketCount: bucketCount,
                        isComplete: isComplete,
                        to: trackID,
                        identity: identity
                    )
                }
            }
        }
    }

    private func apply(
        peaks: [Float],
        bucketCount: Int,
        isComplete: Bool,
        to trackID: SessionTrack.ID,
        identity: WaveformSource.Identity
    ) {
        // Ignore updates from a task that has since been superseded (track
        // removed, or its file changed and a new task started).
        guard sourceIdentities[trackID] == identity else { return }

        waveforms[trackID] = Waveform(
            peaks: peaks,
            bucketCount: bucketCount,
            isComplete: isComplete
        )

        if isComplete {
            tasks[trackID] = nil
        }
    }
}

/// Decodes an audio file off the main thread and downsamples it into a
/// high-resolution peak envelope using vectorized (vDSP/Accelerate) reductions,
/// streaming progress back via a callback.
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

    /// Smallest number of frames a single bucket may represent. This sets the
    /// finest horizontal resolution of the cache (~5.8 ms at 44.1 kHz), which
    /// bounds how far the timeline can be zoomed before peaks look blocky.
    static let minimumFramesPerBucket = 256

    /// Upper bound on bucket count so very long files stay small in memory
    /// (~`maximumBuckets` × 4 bytes per track). Longer files simply use a
    /// coarser bucket size.
    static let maximumBuckets = 100_000

    /// Number of frames read per decode pass. Large enough to keep decoding
    /// efficient, small enough that cancellation stays responsive.
    private static let framesPerChunk: AVAudioFrameCount = 65_536

    /// Minimum wall-clock gap between progress callbacks, so a long decode does
    /// not flood the main actor with Canvas re-renders. The first finalized
    /// batch is always emitted immediately for prompt visual feedback.
    private static let progressInterval: CFTimeInterval = 0.05

    /// Bucket count for a file of `frameCount` frames: one bucket per
    /// `minimumFramesPerBucket` frames, capped at `maximumBuckets`.
    static func bucketCount(forFrameCount frameCount: AVAudioFramePosition) -> Int {
        guard frameCount > 0 else { return 0 }
        let ideal = (frameCount + AVAudioFramePosition(minimumFramesPerBucket) - 1)
            / AVAudioFramePosition(minimumFramesPerBucket)
        return max(1, min(Int(ideal), maximumBuckets))
    }

    /// Generate a peak envelope for `url`, calling `onProgress` periodically with
    /// the buckets finalized so far. `onProgress` is always called once more with
    /// `isComplete == true` when decoding finishes or stops early.
    ///
    /// Runs synchronously on whatever (background) task invokes it; it reads the
    /// file in chunks and yields between them so cancellation is honored quickly.
    static func generate(
        url: URL,
        onProgress: @Sendable (_ peaks: [Float], _ bucketCount: Int, _ isComplete: Bool) async -> Void
    ) async {
        guard
            let file = try? AVAudioFile(forReading: url),
            file.length > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: framesPerChunk)
        else {
            await onProgress([], 0, true)
            return
        }

        let totalFrames = file.length
        let buckets = bucketCount(forFrameCount: totalFrames)
        guard buckets > 0 else {
            await onProgress([], 0, true)
            return
        }

        var peaks = [Float](repeating: 0, count: buckets)
        // Scratch holds the per-frame magnitude (folded across channels) for the
        // current chunk; reused every pass to avoid per-chunk allocation.
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: Int(framesPerChunk))
        defer { scratch.deallocate() }

        var framesRead: AVAudioFramePosition = 0
        var finalizedBuckets = 0
        var lastEmit: CFTimeInterval = 0

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
                bucketCount: buckets,
                scratch: scratch,
                into: &peaks
            )

            framesRead += AVAudioFramePosition(frames)

            // Every bucket whose frames have all been read is now final.
            let newFinalized = min(
                Int((framesRead * AVAudioFramePosition(buckets)) / totalFrames),
                buckets
            )
            let now = CACurrentMediaTime()
            if newFinalized > finalizedBuckets,
               lastEmit == 0 || now - lastEmit >= progressInterval {
                finalizedBuckets = newFinalized
                lastEmit = now
                await onProgress(Array(peaks[0..<finalizedBuckets]), buckets, false)
            }

            await Task.yield()
        }

        if Task.isCancelled { return }
        await onProgress(peaks, buckets, true)
    }

    /// Fold the chunk's channels into per-frame magnitudes, then take the max
    /// magnitude over each bucket's slice — all via vDSP so the heavy lifting
    /// runs as vectorized Accelerate code regardless of build configuration.
    private static func accumulatePeaks(
        from buffer: AVAudioPCMBuffer,
        frameCount: Int,
        startFrame: AVAudioFramePosition,
        totalFrames: AVAudioFramePosition,
        bucketCount: Int,
        scratch: UnsafeMutablePointer<Float>,
        into peaks: inout [Float]
    ) {
        guard let channels = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let count = vDSP_Length(frameCount)

        // scratch[i] = max magnitude across channels for frame i.
        if channelCount == 1 {
            vDSP_vabs(channels[0], 1, scratch, 1, count)
        } else {
            vDSP_vmaxmg(channels[0], 1, channels[1], 1, scratch, 1, count)
            for channel in 2..<channelCount {
                vDSP_vmaxmg(scratch, 1, channels[channel], 1, scratch, 1, count)
            }
        }

        // Walk the buckets overlapping this chunk, reducing each bucket's slice
        // of `scratch` to a single max with vDSP_maxv.
        var frame = 0
        while frame < frameCount {
            let globalFrame = startFrame + AVAudioFramePosition(frame)
            var bucket = Int((globalFrame * AVAudioFramePosition(bucketCount)) / totalFrames)
            if bucket >= bucketCount { bucket = bucketCount - 1 }

            let bucketEndGlobal = (AVAudioFramePosition(bucket) + 1) * totalFrames
                / AVAudioFramePosition(bucketCount)
            var endFrame = Int(bucketEndGlobal - startFrame)
            if endFrame > frameCount { endFrame = frameCount }
            if endFrame <= frame { endFrame = frame + 1 }

            var maximum: Float = 0
            vDSP_maxv(scratch + frame, 1, &maximum, vDSP_Length(endFrame - frame))
            if maximum > peaks[bucket] {
                peaks[bucket] = maximum
            }

            frame = endFrame
        }
    }
}
