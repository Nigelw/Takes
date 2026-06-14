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
                channelCount: format.channelCount
            )
        } catch let error as PlaybackError {
            throw error
        } catch {
            throw PlaybackError.failedToOpenFile(url)
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
