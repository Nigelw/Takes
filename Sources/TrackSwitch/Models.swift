import AVFoundation
import Foundation

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

struct SessionTrack: Identifiable, Equatable {
    let id: UUID
    var loadedTrack: LoadedTrack

    init(id: UUID = UUID(), loadedTrack: LoadedTrack) {
        self.id = id
        self.loadedTrack = loadedTrack
    }
}

struct ComparisonSession: Equatable {
    var tracks: [SessionTrack] = []
    var activeTrackID: SessionTrack.ID?
    var isPlaying = false
    var transportPosition: TimeInterval = 0
    var timelineStart: TimeInterval = 0
    var timelineEnd: TimeInterval = 0

    init(
        tracks: [SessionTrack] = [],
        activeTrackID: SessionTrack.ID? = nil,
        isPlaying: Bool = false,
        transportPosition: TimeInterval = 0,
        timelineStart: TimeInterval = 0,
        timelineEnd: TimeInterval = 0
    ) {
        self.tracks = tracks
        self.activeTrackID = activeTrackID
        self.isPlaying = isPlaying
        self.transportPosition = transportPosition
        self.timelineStart = timelineStart
        self.timelineEnd = timelineEnd
    }

    var duration: TimeInterval {
        max(0, timelineEnd - timelineStart)
    }

    var isPlayable: Bool {
        !tracks.isEmpty && timelineEnd > timelineStart
    }

    var canSwitchPlayback: Bool {
        tracks.count >= 2
    }

    var activeTrackIndex: Int? {
        guard let activeTrackID else { return nil }
        return tracks.firstIndex { $0.id == activeTrackID }
    }
}

struct ImportFailure: Equatable {
    let fileName: String
    let message: String

    init(fileName: String, message: String) {
        self.fileName = fileName.ifEmpty("Unknown file")
        self.message = message
    }

    init(url: URL, message: String) {
        fileName = url.lastPathComponent.ifEmpty(url.path)
        self.message = message
    }
}

enum PlaybackError: LocalizedError, Equatable {
    case unsupportedFormat(URL)
    case failedToOpenFile(URL)
    case invalidSeekPosition
    case engineStartFailed
    case schedulingFailed
    case librarySelectionFailed(String)
    case importFailures([ImportFailure])
    case trackLimitExceeded(limit: Int, skippedFileNames: [String])
    case importSummary(failures: [ImportFailure], skippedFileNames: [String], limit: Int)

    var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(url):
            return "Unsupported audio format: \(url.lastPathComponent)"
        case let .failedToOpenFile(url):
            return "Could not open file: \(url.lastPathComponent)"
        case .invalidSeekPosition:
            return "Seek position is outside the valid compare range."
        case .engineStartFailed:
            return "Audio engine failed to start."
        case .schedulingFailed:
            return "Audio playback could not be scheduled."
        case let .librarySelectionFailed(message):
            return message
        case let .importFailures(failures):
            let details = failures.map { "\($0.fileName): \($0.message)" }.joined(separator: "\n")
            return "Some files could not be loaded.\n\(details)"
        case let .trackLimitExceeded(limit, skippedFileNames):
            let skipped = skippedFileNames.joined(separator: "\n")
            return "TrackSwitch currently supports up to \(limit) loaded tracks.\nSkipped:\n\(skipped)"
        case let .importSummary(failures, skippedFileNames, limit):
            return Self.importSummaryDescription(
                failures: failures,
                skippedFileNames: skippedFileNames,
                limit: limit
            )
        }
    }

    private static func importSummaryDescription(
        failures: [ImportFailure],
        skippedFileNames: [String],
        limit: Int
    ) -> String {
        var sections: [String] = []
        if !failures.isEmpty {
            let details = failures.map { "\($0.fileName): \($0.message)" }.joined(separator: "\n")
            sections.append("Some files could not be loaded.\n\(details)")
        }
        if !skippedFileNames.isEmpty {
            let skipped = skippedFileNames.joined(separator: "\n")
            sections.append("TrackSwitch currently supports up to \(limit) loaded tracks.\nSkipped:\n\(skipped)")
        }
        return sections.joined(separator: "\n")
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}

extension TimeInterval {
    var formattedTimestamp: String {
        formattedUnsignedTimestamp
    }

    var formattedSignedTimestamp: String {
        let prefix = self < 0 ? "-" : ""
        return prefix + abs(self).formattedUnsignedTimestamp
    }

    private var formattedUnsignedTimestamp: String {
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
