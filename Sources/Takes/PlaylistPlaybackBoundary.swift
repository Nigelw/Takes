import Foundation

/// Value conversion only. Audio preparation remains the controller's responsibility.
enum PlaylistPlaybackBoundary {
    static func filePosition(transport: TimeInterval, version: PlaylistVersion) -> TimeInterval {
        let position = TransportMapping.filePosition(forGlobalTime: transport, offset: version.offsetSeconds)
        return min(max(position, 0), version.metadata.duration)
    }

    static func comparisonPosition(filePosition: TimeInterval, version: PlaylistVersion) -> TimeInterval {
        min(max(filePosition, 0), version.metadata.duration) + version.offsetSeconds
    }

    /// Preserve stable identities when materializing the current item's session.
    static func session(
        for item: PlaylistItem,
        incomingVersionID: UUID? = nil,
        incomingFilePosition: TimeInterval? = nil,
        isPlaying: Bool = false
    ) -> ComparisonSession {
        let tracks = item.versions.map { version in
            SessionTrack(id: version.id, loadedTrack: loadedTrack(for: version))
        }
        let range = TransportMapping.timelineRange(tracks: tracks.map(\.loadedTrack)) ?? 0...0
        let selectedID = incomingVersionID.flatMap { id in
            item.versions.contains(where: { $0.id == id }) ? id : nil
        } ?? item.selectedVersionID ?? tracks.first?.id
        let selected = item.versions.first { $0.id == selectedID }
        let position: TimeInterval
        if let incomingFilePosition, let selected {
            position = comparisonPosition(filePosition: incomingFilePosition, version: selected)
        } else {
            position = range.lowerBound
        }
        var loop = item.comparison.loopRegion
        if let saved = loop,
           position < saved.start || position >= saved.end || saved.start < range.lowerBound || saved.end > range.upperBound {
            loop = nil
        }
        return ComparisonSession(
            tracks: tracks,
            activeTrackID: selectedID,
            isPlaying: isPlaying,
            transportPosition: position,
            timelineStart: range.lowerBound,
            timelineEnd: range.upperBound,
            repeatMode: item.comparison.repeatMode,
            isBlindListeningModeEnabled: item.comparison.isBlindListeningModeEnabled,
            loopRegion: loop
        )
    }

    static func loadedTrack(for version: PlaylistVersion, playlistMode: Bool = false) -> LoadedTrack {
        let metadata = version.metadata
        return LoadedTrack(
            url: version.file.storedURL,
            displayName: metadata.displayName,
            fileFormatDescription: metadata.fileFormatDescription,
            duration: metadata.duration,
            sampleRate: metadata.sampleRate,
            channelCount: metadata.channelCount,
            bitRate: metadata.bitRate,
            gainDB: playlistMode ? 0 : version.gainDB,
            offsetSeconds: playlistMode ? 0 : version.offsetSeconds
        )
    }

    /// Blind-listening order is transient; transfer adjustments by ID only.
    static func capture(_ session: ComparisonSession, into item: inout PlaylistItem) {
        let tracks = Dictionary(session.tracks.map { ($0.id, $0.loadedTrack) }, uniquingKeysWith: { first, _ in first })
        for index in item.versions.indices {
            guard let track = tracks[item.versions[index].id] else { continue }
            item.versions[index].gainDB = track.gainDB
            item.versions[index].offsetSeconds = track.offsetSeconds
        }
        if let active = session.activeTrackID, item.versions.contains(where: { $0.id == active }) {
            item.selectedVersionID = active
        }
        item.comparison.repeatMode = session.repeatMode
        item.comparison.loopRegion = session.loopRegion
        item.comparison.isBlindListeningModeEnabled = session.isBlindListeningModeEnabled
    }
}
