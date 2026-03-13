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
    func musicSelectionScriptJoinsMultipleResultsWithLinefeeds() {
        let script = LibraryTrackSelectionLoader.musicSelectionScript

        #expect(script.contains("text item delimiters to linefeed"))
        #expect(script.contains("outputLines as text"))
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

    @Test
    func musicSelectionParsingSortsTwoTracksByViewOrder() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
        let laterURL = tempDirectory.appending(path: UUID().uuidString + ".m4a")
        let earlierURL = tempDirectory.appending(path: UUID().uuidString + ".mp3")

        FileManager.default.createFile(atPath: laterURL.path, contents: Data())
        FileManager.default.createFile(atPath: earlierURL.path, contents: Data())
        defer {
            try? FileManager.default.removeItem(at: laterURL)
            try? FileManager.default.removeItem(at: earlierURL)
        }

        let output = """
        9\t\(laterURL.path)
        2\t\(earlierURL.path)
        """

        let urls = try LibraryTrackSelectionLoader.parseSelectionOutput(output)

        #expect(urls == [earlierURL, laterURL])
    }

    @Test
    func musicSelectionParsingRejectsMoreThanTwoTracks() {
        let output = """
        1\t/tmp/a.wav
        2\t/tmp/b.wav
        3\t/tmp/c.wav
        """

        #expect(throws: PlaybackError.librarySelectionFailed("Select one or two tracks in Music.")) {
            try LibraryTrackSelectionLoader.parseSelectionOutput(output)
        }
    }

    @Test
    func libraryAssignmentsKeepSingleSelectionOnClickedSide() throws {
        let url = URL(fileURLWithPath: "/tmp/example.wav")

        let assignments = try PlaybackController.libraryAssignments(for: [url], clickedSide: .b)

        #expect(assignments.count == 1)
        #expect(assignments[0].0 == .b)
        #expect(assignments[0].1 == url)
    }

    @Test
    func libraryAssignmentsLoadTwoSelectionsIntoTrackAThenTrackB() throws {
        let first = URL(fileURLWithPath: "/tmp/first.wav")
        let second = URL(fileURLWithPath: "/tmp/second.wav")

        let assignments = try PlaybackController.libraryAssignments(for: [first, second], clickedSide: .b)

        #expect(assignments.count == 2)
        #expect(assignments[0].0 == .a)
        #expect(assignments[0].1 == first)
        #expect(assignments[1].0 == .b)
        #expect(assignments[1].1 == second)
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
