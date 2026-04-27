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
    private var trackASlotID: SessionTrack.ID?
    private var trackBSlotID: SessionTrack.ID?
    private var activeTrackSideFallback: TrackSide = .a
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
        self.trackASlotID = tracks.indices.contains(0) ? tracks[0].id : nil
        self.trackBSlotID = tracks.indices.contains(1) ? tracks[1].id : nil
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

    var trackA: LoadedTrack? {
        get {
            track(for: .a)
        }
        set {
            setTrack(newValue, for: .a)
        }
    }

    var trackB: LoadedTrack? {
        get {
            track(for: .b)
        }
        set {
            setTrack(newValue, for: .b)
        }
    }

    var activeTrack: TrackSide {
        get {
            if activeTrackID == slotID(for: .a) {
                return .a
            }
            if activeTrackID == slotID(for: .b) {
                return .b
            }
            return activeTrackSideFallback
        }
        set {
            activeTrackSideFallback = newValue
            if let id = slotID(for: newValue) {
                activeTrackID = id
            }
        }
    }

    var canToggleComparison: Bool {
        canSwitchPlayback
    }

    private func track(for side: TrackSide) -> LoadedTrack? {
        guard let id = slotID(for: side),
              let index = tracks.firstIndex(where: { $0.id == id })
        else { return nil }
        return tracks[index].loadedTrack
    }

    private mutating func setTrack(_ loadedTrack: LoadedTrack?, for side: TrackSide) {
        if let loadedTrack {
            if let id = slotID(for: side),
               let index = tracks.firstIndex(where: { $0.id == id }) {
                tracks[index].loadedTrack = loadedTrack
            } else {
                let slotIndex = Self.index(for: side)
                if tracks.indices.contains(slotIndex), !isTrackAssignedToCompatibilitySlot(tracks[slotIndex].id) {
                    setSlotID(tracks[slotIndex].id, for: side)
                    tracks[slotIndex].loadedTrack = loadedTrack
                } else {
                    let sessionTrack = SessionTrack(loadedTrack: loadedTrack)
                    tracks.append(sessionTrack)
                    setSlotID(sessionTrack.id, for: side)
                }
            }

            if activeTrackID == nil {
                activeTrackID = slotID(for: side)
            }
        } else if let id = slotID(for: side),
                  let index = tracks.firstIndex(where: { $0.id == id }) {
            tracks.remove(at: index)
            clearSlotID(for: side)
            if activeTrackID == id {
                activeTrackID = tracks.first?.id
            }
        }
    }

    private func slotID(for side: TrackSide) -> SessionTrack.ID? {
        switch side {
        case .a:
            return trackASlotID ?? fallbackSlotID(for: .a)
        case .b:
            return trackBSlotID ?? fallbackSlotID(for: .b)
        }
    }

    private func fallbackSlotID(for side: TrackSide) -> SessionTrack.ID? {
        let index = Self.index(for: side)
        guard tracks.indices.contains(index) else { return nil }
        let id = tracks[index].id
        guard !isTrackAssignedToOtherCompatibilitySlot(id, side: side) else { return nil }
        return id
    }

    private func isTrackAssignedToCompatibilitySlot(_ id: SessionTrack.ID) -> Bool {
        trackASlotID == id || trackBSlotID == id
    }

    private func isTrackAssignedToOtherCompatibilitySlot(_ id: SessionTrack.ID, side: TrackSide) -> Bool {
        switch side {
        case .a:
            return trackBSlotID == id
        case .b:
            return trackASlotID == id
        }
    }

    private mutating func setSlotID(_ id: SessionTrack.ID, for side: TrackSide) {
        switch side {
        case .a:
            trackASlotID = id
        case .b:
            trackBSlotID = id
        }
    }

    private mutating func clearSlotID(for side: TrackSide) {
        switch side {
        case .a:
            trackASlotID = nil
        case .b:
            trackBSlotID = nil
        }
    }

    private static func index(for side: TrackSide) -> Int {
        switch side {
        case .a:
            return 0
        case .b:
            return 1
        }
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
    case tooManyImportFiles

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
        case .tooManyImportFiles:
            "Select one or two audio files."
        }
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
