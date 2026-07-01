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

    /// Labeled ticks for the ruler. Thin wrapper over ``ruler(timelineStart:timelineEnd:targetMarkerCount:)``.
    static func markers(
        timelineStart: TimeInterval,
        timelineEnd: TimeInterval,
        targetMarkerCount: Int
    ) -> [TimelineHeaderMarker] {
        ruler(
            timelineStart: timelineStart,
            timelineEnd: timelineEnd,
            targetMarkerCount: targetMarkerCount
        ).majorTicks
    }

    /// Builds the full two-tier ruler for the visible window: tall labeled *major* ticks plus
    /// shorter unlabeled *minor* ticks that subdivide each major span. Minor ticks never coincide
    /// with a major tick. Both tiers are derived from the same chosen interval so they stay aligned.
    static func ruler(
        timelineStart: TimeInterval,
        timelineEnd: TimeInterval,
        targetMarkerCount: Int,
        leadingMajorTicks: Int = 0
    ) -> TimelineRuler {
        let span = timelineEnd - timelineStart
        guard span > 0, targetMarkerCount > 0 else { return TimelineRuler(majorTicks: [], minorTicks: [], minorInterval: 0) }

        let interval = readableInterval(for: span / Double(targetMarkerCount))
        guard interval > 0 else { return TimelineRuler(majorTicks: [], minorTicks: [], minorInterval: 0) }

        let epsilon = interval * 0.0001
        var majorTicks: [TimelineHeaderMarker] = []
        // Begin `leadingMajorTicks` intervals before the window so a major tick whose line has just
        // scrolled off the left edge still emits its label. Its label sits to the right of the tick,
        // so part of it remains on-screen and should clip at the edge rather than vanish. Stepping
        // back by whole intervals keeps `interval` (and thus spacing/labels) derived from the visible
        // span, so tick positions don't jump as the extra ticks come and go.
        var time = ceil(timelineStart / interval) * interval - Double(max(0, leadingMajorTicks)) * interval
        while time <= timelineEnd + epsilon {
            majorTicks.append(
                TimelineHeaderMarker(time: time, label: time.formattedSignedTimestamp(forInterval: interval))
            )
            time += interval
        }

        var minorTicks: [TimeInterval] = []
        let divisions = minorDivisions(for: interval)
        let minorInterval = divisions > 1 ? interval / Double(divisions) : 0
        if minorInterval > 0 {
            var index = Int((timelineStart / minorInterval).rounded(.up))
            while Double(index) * minorInterval < timelineStart - epsilon { index += 1 }
            while Double(index) * minorInterval <= timelineEnd + epsilon {
                // Skip positions that land on a major tick (multiples of `divisions`).
                if index % divisions != 0 {
                    minorTicks.append(Double(index) * minorInterval)
                }
                index += 1
            }
        }

        return TimelineRuler(majorTicks: majorTicks, minorTicks: minorTicks, minorInterval: minorInterval)
    }

    /// Ascending "nice number" ladder spanning sub-second to a full day. `readableInterval`
    /// picks the smallest value `>= rawInterval`, keeping the chosen tick spacing close to the
    /// target so the visible tick count stays near `targetMarkerCount` at every zoom level.
    static let niceIntervals: [TimeInterval] = [
        0.1, 0.2, 0.5,
        1, 2, 5, 10, 15, 30,
        60, 120, 300, 600, 900, 1800,
        3600, 7200, 10800, 21600, 43200, 86400
    ]

    /// How many equal parts to split each ladder interval into for minor ticks. Chosen so every
    /// resulting minor step is itself a round value (0.5→0.1, 60→15 s, 600→120 s, …) rather than an
    /// awkward fraction. Parallel to `niceIntervals`; `1` would mean "no minor ticks".
    static let minorDivisionsPerInterval: [Int] = [
        2, 2, 5,      // 0.1  0.2  0.5
        5, 4, 5, 5, 3, 6,   // 1  2  5  10  15  30
        4, 4, 5, 5, 3, 6,   // 60  120  300  600  900  1800
        6, 4, 3, 6, 6, 6    // 3600  7200  10800  21600  43200  86400
    ]

    static func readableInterval(for rawInterval: TimeInterval) -> TimeInterval {
        guard rawInterval.isFinite, rawInterval > 0 else { return niceIntervals.first ?? 1 }
        return niceIntervals.first { $0 >= rawInterval } ?? niceIntervals.last ?? 1
    }

    static func minorDivisions(for interval: TimeInterval) -> Int {
        guard let index = niceIntervals.firstIndex(of: interval) else { return 1 }
        return minorDivisionsPerInterval[index]
    }
}

struct TimelineRuler: Equatable {
    let majorTicks: [TimelineHeaderMarker]
    let minorTicks: [TimeInterval]
    /// Spacing between adjacent minor ticks, in seconds (`0` when there are no minor ticks). Lets the
    /// view convert to a pixel spacing and drop minor ticks when they would render too densely.
    let minorInterval: TimeInterval
}

struct TimelineHeaderLabelLayout: Equatable {
    let x: Double
    let isVisible: Bool

    static func leading(
        tickX: Double,
        rulerWidth: Double,
        leadingPadding: Double = TimelineHeaderMarker.labelLeadingPadding
    ) -> TimelineHeaderLabelLayout {
        let labelX = tickX + leadingPadding
        // Keep the label mounted as long as its leading edge is still on-screen; the ruler clips its
        // right edge, so an overflowing label scrolls out of view instead of vanishing all at once.
        return TimelineHeaderLabelLayout(
            x: labelX,
            isVisible: labelX < rulerWidth
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

    /// Resolution-aware variant for ruler labels: sub-second tick intervals append tenths
    /// (e.g. `0:03.5`) so adjacent labels stay distinct; whole-second intervals are unchanged.
    func formattedSignedTimestamp(forInterval interval: TimeInterval) -> String {
        let prefix = self < 0 ? "-" : ""
        if interval.isFinite, interval > 0, interval < 1 {
            return prefix + abs(self).formattedSubSecondTimestamp
        }
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

    private var formattedSubSecondTimestamp: String {
        guard self.isFinite else { return "--:--" }
        let totalTenths = Int((max(0, self) * 10).rounded())
        let tenths = totalTenths % 10
        let totalSeconds = totalTenths / 10
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d.%d", hours, minutes, seconds, tenths)
        }
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }
}
