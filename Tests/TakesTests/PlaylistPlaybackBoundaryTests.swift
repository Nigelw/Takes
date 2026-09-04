import Foundation
import Testing
@testable import Takes

struct PlaylistPlaybackBoundaryTests {
    @Test func signedOffsetsRoundTripAndBackClampsToFile() {
        let version = makeVersion(offset: -5)
        #expect(PlaylistPlaybackBoundary.comparisonPosition(filePosition: 20, version: version) == 15)
        #expect(PlaylistPlaybackBoundary.filePosition(transport: 15, version: version) == 20)
        #expect(PlaylistPlaybackBoundary.filePosition(transport: -20, version: version) == 0)
        #expect(PlaylistPlaybackBoundary.filePosition(transport: 200, version: version) == 100)
    }

    @Test func enteringComparisonRetainsIDsAndDeselectsExcludingLoop() {
        let version = makeVersion(offset: -5)
        var item = PlaylistItem(title: "Song", versions: [version], selectedVersionID: version.id)
        item.comparison.loopRegion = LoopRegion(start: 30, end: 40)
        item.comparison.repeatMode = .switchAndRepeat
        let session = PlaylistPlaybackBoundary.session(
            for: item, incomingVersionID: version.id, incomingFilePosition: 20, isPlaying: true
        )
        #expect(session.tracks.map(\.id) == [version.id])
        #expect(session.activeTrackID == version.id)
        #expect(session.transportPosition == 15)
        #expect(session.timelineStart == -5)
        #expect(session.timelineEnd == 95)
        #expect(session.isPlaying)
        #expect(session.loopRegion == nil)
        #expect(session.repeatMode == .switchAndRepeat)
        #expect(item.comparison.loopRegion != nil)
    }

    @Test func playlistPreparationIgnoresComparisonAdjustments() {
        var version = makeVersion(offset: 7)
        version.gainDB = -8
        let track = PlaylistPlaybackBoundary.loadedTrack(for: version, playlistMode: true)
        #expect(track.gainDB == 0)
        #expect(track.offsetSeconds == 0)
        #expect(track.duration == 100)
        #expect(version.gainDB == -8)
    }

    @Test func enteringWithinSavedLoopKeepsLoopAndPausedState() {
        let version = makeVersion(offset: 5)
        var item = PlaylistItem(title: "Song", versions: [version], selectedVersionID: version.id)
        item.comparison.loopRegion = LoopRegion(start: 10, end: 30)
        let session = PlaylistPlaybackBoundary.session(for: item, incomingFilePosition: 10)
        #expect(session.transportPosition == 15)
        #expect(session.loopRegion == item.comparison.loopRegion)
        #expect(!session.isPlaying)
    }

    @Test func capturePreservesOrganizationDespiteBlindRuntimeOrder() {
        let first = makeVersion(offset: 0)
        let second = makeVersion(offset: 3)
        var item = PlaylistItem(title: "Song", versions: [first, second], selectedVersionID: first.id)
        var session = PlaylistPlaybackBoundary.session(for: item)
        session.tracks.reverse()
        session.tracks[0].loadedTrack.gainDB = -4
        session.activeTrackID = second.id
        session.isBlindListeningModeEnabled = true
        PlaylistPlaybackBoundary.capture(session, into: &item)
        #expect(item.versions.map(\.id) == [first.id, second.id])
        #expect(item.versions[1].gainDB == -4)
        #expect(item.selectedVersionID == second.id)
        #expect(item.comparison.isBlindListeningModeEnabled)
    }

    @Test func repeatedActivationOfSameItemInvalidatesContext() {
        let id = UUID()
        #expect(PlaylistRuntimeContext(itemID: id) != PlaylistRuntimeContext(itemID: id))
    }

    private func makeVersion(offset: Double) -> PlaylistVersion {
        PlaylistVersion(
            file: PlaylistFileReference(storedURL: URL(fileURLWithPath: "/tmp/\(UUID()).wav")),
            metadata: PlaylistMetadata(duration: 100, sampleRate: 44_100, channelCount: 2,
                                       fileFormatDescription: "WAV", displayName: "Song.wav"),
            offsetSeconds: offset
        )
    }
}
