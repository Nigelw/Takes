import AVFoundation
import Foundation
import Testing
@testable import TrackSwitch

struct SessionTests {
    @Test
    func sessionReadinessRequiresTwoTracksAndOverlap() {
        var session = ComparisonSession()
        #expect(!session.isPlayable)
        #expect(!session.canToggleComparison)

        session.trackA = makeTrack(name: "a.wav")
        session.duration = 12
        #expect(session.isPlayable)
        #expect(!session.canToggleComparison)

        session.trackB = makeTrack(name: "b.wav")
        session.duration = 12
        #expect(session.isPlayable)
        #expect(session.canToggleComparison)
    }

    @Test
    func loadedTrackMetadataSummaryIncludesKeyFacts() {
        let track = makeTrack(name: "master.wav")

        #expect(track.metadataSummary.contains("WAV"))
        #expect(track.metadataSummary.contains("44100"))
        #expect(track.metadataSummary.contains("02:00"))
    }

    @Test
    func musicSelectionScriptTargetsMusicByBundleIdentifier() {
        let script = LibraryTrackSelectionLoader.musicSelectionScript

        #expect(script.contains("application id \"com.apple.Music\""))
        #expect(!script.contains("\"iTunes\""))
    }

    @Test
    func infoPlistDeclaresAppleEventsUsageDescription() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Config")
            .appending(path: "TrackSwitch-Info.plist")

        let data = try Data(contentsOf: plistURL)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        let usage = plist["NSAppleEventsUsageDescription"] as? String
        #expect(usage?.isEmpty == false)
    }

    private func makeTrack(name: String) -> LoadedTrack {
        LoadedTrack(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            displayName: name,
            fileFormatDescription: "WAV",
            duration: 120,
            sampleRate: 44_100,
            channelCount: 2,
            gainDB: 0,
            offsetSeconds: 0
        )
    }
}
