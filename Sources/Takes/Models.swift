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

    /// The window currently drawn, in absolute seconds. A sub-window of the
    /// content range `[timelineStart, timelineEnd]`. When it equals the content
    /// range the timeline is fully zoomed out ("fit"). See `TimelineViewport`.
    var visibleStart: TimeInterval = 0
    var visibleSpan: TimeInterval = 0

    init(
        tracks: [SessionTrack] = [],
        activeTrackID: SessionTrack.ID? = nil,
        isPlaying: Bool = false,
        transportPosition: TimeInterval = 0,
        timelineStart: TimeInterval = 0,
        timelineEnd: TimeInterval = 0,
        visibleStart: TimeInterval = 0,
        visibleSpan: TimeInterval = 0
    ) {
        self.tracks = tracks
        self.activeTrackID = activeTrackID
        self.isPlaying = isPlaying
        self.transportPosition = transportPosition
        self.timelineStart = timelineStart
        self.timelineEnd = timelineEnd
        self.visibleStart = visibleStart
        self.visibleSpan = visibleSpan
    }

    var duration: TimeInterval {
        max(0, timelineEnd - timelineStart)
    }

    var visibleEnd: TimeInterval {
        visibleStart + visibleSpan
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

    var activeTrack: SessionTrack? {
        guard let activeTrackIndex else { return nil }
        return tracks[activeTrackIndex]
    }
}

struct TimelineHeaderMarker: Equatable {
    let time: TimeInterval
    let label: String

    static let labelLeadingPadding: Double = 8

    static func markers(
        timelineStart: TimeInterval,
        timelineEnd: TimeInterval,
        targetMarkerCount: Int
    ) -> [TimelineHeaderMarker] {
        let span = timelineEnd - timelineStart
        guard span > 0, targetMarkerCount > 0 else { return [] }

        let interval = readableInterval(for: span / Double(targetMarkerCount))
        guard interval > 0 else { return [] }

        let firstTick = ceil(timelineStart / interval) * interval
        var time = firstTick
        var markers: [TimelineHeaderMarker] = []

        while time <= timelineEnd + 0.0001 {
            markers.append(TimelineHeaderMarker(time: time, label: time.formattedSignedTimestamp))
            time += interval
        }

        return markers
    }

    private static func readableInterval(for rawInterval: TimeInterval) -> TimeInterval {
        guard rawInterval.isFinite, rawInterval > 0 else { return 1 }

        let baseIntervals: [TimeInterval] = [1, 2, 5, 10, 30]
        var scale: TimeInterval = 1

        while scale * 30 < rawInterval {
            scale *= 60
        }

        if scale > 1 {
            for multiplier in baseIntervals {
                let candidate = multiplier * scale
                if candidate >= rawInterval {
                    return candidate
                }
            }
        }

        if rawInterval <= 12 {
            return 10
        }

        return baseIntervals.first { $0 >= rawInterval } ?? 30
    }
}

struct TimelineHeaderLabelLayout: Equatable {
    let x: Double
    let isVisible: Bool

    static func leading(
        tickX: Double,
        labelWidth: Double,
        rulerWidth: Double,
        leadingPadding: Double = TimelineHeaderMarker.labelLeadingPadding
    ) -> TimelineHeaderLabelLayout {
        let labelX = tickX + leadingPadding
        return TimelineHeaderLabelLayout(
            x: labelX,
            isVisible: labelX + labelWidth <= rulerWidth
        )
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
            return "Takes currently supports up to \(limit) loaded tracks.\nSkipped:\n\(skipped)"
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
            sections.append("Takes currently supports up to \(limit) loaded tracks.\nSkipped:\n\(skipped)")
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
