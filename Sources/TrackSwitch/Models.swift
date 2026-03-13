import AVFoundation
import Foundation

enum TrackSide: String, CaseIterable, Identifiable {
    case a = "A"
    case b = "B"

    var id: String { rawValue }
    var title: String { "Track \(rawValue)" }
}

struct LoadedTrack: Equatable {
    let url: URL
    let displayName: String
    let fileFormatDescription: String
    let duration: TimeInterval
    let sampleRate: Double
    let channelCount: AVAudioChannelCount

    var gainDB: Float = 0
    var offsetSeconds: TimeInterval = 0

    var metadataSummary: String {
        "\(fileFormatDescription) • \(Int(sampleRate)) Hz • \(channelCount) ch • \(duration.formattedTimestamp)"
    }
}

struct ComparisonSession: Equatable {
    var trackA: LoadedTrack?
    var trackB: LoadedTrack?
    var activeTrack: TrackSide = .a
    var isPlaying = false
    var transportPosition: TimeInterval = 0
    var duration: TimeInterval = 0

    var isPlayable: Bool {
        (trackA != nil || trackB != nil) && duration > 0
    }

    var canToggleComparison: Bool {
        trackA != nil && trackB != nil
    }
}

enum PlaybackError: LocalizedError, Equatable {
    case unsupportedFormat(URL)
    case failedToOpenFile(URL)
    case invalidSeekPosition
    case engineStartFailed
    case schedulingFailed
    case noValidOverlap
    case librarySelectionFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(url):
            "Unsupported audio format: \(url.lastPathComponent)"
        case let .failedToOpenFile(url):
            "Could not open file: \(url.lastPathComponent)"
        case .invalidSeekPosition:
            "Seek position is outside the valid compare range."
        case .engineStartFailed:
            "Audio engine failed to start."
        case .schedulingFailed:
            "Audio playback could not be scheduled."
        case .noValidOverlap:
            "The current offsets leave no valid overlap between the two tracks."
        case let .librarySelectionFailed(message):
            message
        }
    }
}

extension TimeInterval {
    var formattedTimestamp: String {
        guard self.isFinite else { return "--:--" }
        let rounded = Int(max(0, self.rounded()))
        let hours = rounded / 3600
        let minutes = (rounded % 3600) / 60
        let seconds = rounded % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
