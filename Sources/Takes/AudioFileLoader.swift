import AVFoundation
import Foundation

protocol AudioFileLoading: Sendable {
    func loadTrackMetadata(from url: URL) async throws -> LoadedTrack
    func makeAudioFile(from url: URL) throws -> AVAudioFile
}

struct AudioFileLoader: AudioFileLoading {
    func loadTrackMetadata(from url: URL) async throws -> LoadedTrack {
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
                bitRate: await estimatedBitRate(for: url)
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
    private func estimatedBitRate(for url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return 0 }
            let rate = Double(try await track.load(.estimatedDataRate))
            return rate.isFinite && rate > 0 ? rate : 0
        } catch {
            return 0
        }
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
