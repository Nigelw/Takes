import AVFoundation
import Foundation

protocol AudioFileLoading {
    func loadTrackMetadata(from url: URL) throws -> LoadedTrack
    func makeAudioFile(from url: URL) throws -> AVAudioFile
}

struct AudioFileLoader: AudioFileLoading {
    func loadTrackMetadata(from url: URL) throws -> LoadedTrack {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let duration = Double(file.length) / format.sampleRate
            guard duration.isFinite, duration > 0 else {
                throw PlaybackError.unsupportedFormat(url)
            }

            return LoadedTrack(
                url: url,
                displayName: url.lastPathComponent,
                fileFormatDescription: description(for: url),
                duration: duration,
                sampleRate: format.sampleRate,
                channelCount: format.channelCount,
                bitRate: estimatedBitRate(for: url)
            )
        } catch let error as PlaybackError {
            throw error
        } catch {
            throw PlaybackError.failedToOpenFile(url)
        }
    }

    /// Best-effort estimated data rate (bits/sec) of the file's first audio track.
    /// Returns `0` when no rate is available (e.g. some lossless files) so the UI
    /// can drop the bit-rate segment rather than show "0 kbps". Any failure degrades
    /// to `0`.
    ///
    /// Uses the synchronous `tracks`/`estimatedDataRate` accessors (deprecated in
    /// favour of the async `load(_:)` variants) because `loadTrackMetadata` is a
    /// synchronous, `throws`-only entry point; the target is always a fully
    /// available local file, so the synchronous read is safe here.
    private func estimatedBitRate(for url: URL) -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { return 0 }
        let rate = Double(track.estimatedDataRate)
        return rate.isFinite && rate > 0 ? rate : 0
    }

    func makeAudioFile(from url: URL) throws -> AVAudioFile {
        do {
            return try AVAudioFile(forReading: url)
        } catch {
            throw PlaybackError.failedToOpenFile(url)
        }
    }

    private func description(for url: URL) -> String {
        url.pathExtension.uppercased().ifEmpty("Audio")
    }
}
