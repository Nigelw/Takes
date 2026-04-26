import AVFoundation
import AppKit
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
        session.timelineEnd = 12
        #expect(session.isPlayable)
        #expect(!session.canToggleComparison)

        session.trackB = makeTrack(name: "b.wav")
        session.timelineEnd = 12
        #expect(session.isPlayable)
        #expect(session.canToggleComparison)
    }

    @Test
    func sessionRemainsPlayableWithSingleTrackOrNoOverlapAsLongAsDurationExists() {
        var session = ComparisonSession()
        session.trackA = makeTrack(name: "a.wav")
        session.trackB = makeTrack(name: "b.wav")
        session.timelineEnd = 11

        #expect(session.isPlayable)
        #expect(session.canToggleComparison)
    }

    @Test
    func sessionUsesSignedTimelineBoundsForPlaybackReadiness() {
        var session = ComparisonSession()
        #expect(!session.isPlayable)

        session.trackA = makeTrack(name: "a.wav")
        session.timelineStart = -4
        session.timelineEnd = 120
        session.transportPosition = -4

        #expect(session.isPlayable)
        #expect(session.duration == 124)
    }

    @Test
    func signedTimestampFormatsNegativeTimes() {
        #expect(TimeInterval(-12).formattedSignedTimestamp == "-00:12")
        #expect(TimeInterval(12).formattedSignedTimestamp == "00:12")
        #expect(TimeInterval(-3723).formattedSignedTimestamp == "-1:02:03")
    }

    @Test
    func unsignedTimestampClampsNegativeTimes() {
        #expect(TimeInterval(-12).formattedTimestamp == "00:00")
        #expect(TimeInterval(12).formattedTimestamp == "00:12")
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
    func importAssignmentsUseSharedOpenRules() throws {
        var session = ComparisonSession()
        let first = URL(fileURLWithPath: "/tmp/first.wav")
        let second = URL(fileURLWithPath: "/tmp/second.wav")
        let third = URL(fileURLWithPath: "/tmp/third.wav")

        let firstAssignments = try PlaybackController.importAssignments(for: [first], in: session)
        #expect(firstAssignments.map(\.0) == [.a])
        #expect(firstAssignments.map(\.1) == [first])

        session.trackA = makeTrack(name: "a.wav")
        let secondAssignments = try PlaybackController.importAssignments(for: [second], in: session)
        #expect(secondAssignments.map(\.0) == [.b])
        #expect(secondAssignments.map(\.1) == [second])

        session.trackB = makeTrack(name: "b.wav")
        session.activeTrack = .b
        let thirdAssignments = try PlaybackController.importAssignments(for: [third], in: session)
        #expect(thirdAssignments.map(\.0) == [.b])
        #expect(thirdAssignments.map(\.1) == [third])

        let pairAssignments = try PlaybackController.importAssignments(for: [first, second], in: session)
        #expect(pairAssignments.map(\.0) == [.a, .b])
        #expect(pairAssignments.map(\.1) == [first, second])
    }

    @Test
    func importAssignmentsRejectMoreThanTwoFiles() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.wav"),
            URL(fileURLWithPath: "/tmp/b.wav"),
            URL(fileURLWithPath: "/tmp/c.wav")
        ]

        #expect(throws: PlaybackError.tooManyImportFiles) {
            try PlaybackController.importAssignments(for: urls, in: ComparisonSession())
        }
    }

    @Test
    func importAssignmentsLoadTwoSelectionsIntoTrackAThenTrackB() throws {
        let first = URL(fileURLWithPath: "/tmp/first.wav")
        let second = URL(fileURLWithPath: "/tmp/second.wav")

        let assignments = try PlaybackController.importAssignments(for: [first, second], in: ComparisonSession())

        #expect(assignments.count == 2)
        #expect(assignments[0].0 == .a)
        #expect(assignments[0].1 == first)
        #expect(assignments[1].0 == .b)
        #expect(assignments[1].1 == second)
    }

    @Test
    func numericControlStepUsesSmallAndLargeIncrements() {
        let gainConfig = NumericControlConfiguration.gain
        let offsetConfig = NumericControlConfiguration.offset

        #expect(gainConfig.steppedValue(from: 0, direction: 1, largeStep: false) == 1)
        #expect(gainConfig.steppedValue(from: 0, direction: -1, largeStep: true) == -10)
        #expect(offsetConfig.steppedValue(from: 0, direction: 1, largeStep: false) == 10)
        #expect(offsetConfig.steppedValue(from: 0, direction: -1, largeStep: true) == -100)
    }

    @Test
    func numericControlStepClampsToConfiguredRange() {
        let gainConfig = NumericControlConfiguration.gain
        let offsetConfig = NumericControlConfiguration.offset

        #expect(gainConfig.steppedValue(from: 20, direction: 1, largeStep: true) == 24)
        #expect(gainConfig.steppedValue(from: -20, direction: -1, largeStep: true) == -24)
        #expect(offsetConfig.steppedValue(from: 299_950, direction: 1, largeStep: true) == 300_000)
        #expect(offsetConfig.steppedValue(from: -299_950, direction: -1, largeStep: true) == -300_000)
    }

    @Test
    func offsetRangeExpandsToFiveMinutes() {
        let offsetConfig = NumericControlConfiguration.offset

        #expect(offsetConfig.clamped(300_001) == 300_000)
        #expect(offsetConfig.clamped(-300_001) == -300_000)
        #expect(offsetConfig.steppedValue(from: 299_950, direction: 1, largeStep: true) == 300_000)
        #expect(offsetConfig.steppedValue(from: -299_950, direction: -1, largeStep: true) == -300_000)
    }

    @Test
    func numericControlUsesCurrentFieldValueWhenStepping() {
        let offsetConfig = NumericControlConfiguration.offset

        #expect(offsetConfig.steppedValue(fromText: "20", fallbackValue: 0, direction: 1, largeStep: false) == 30)
        #expect(offsetConfig.steppedValue(fromText: "30", fallbackValue: 0, direction: 1, largeStep: true) == 130)
        #expect(offsetConfig.steppedValue(fromText: "130", fallbackValue: 0, direction: -1, largeStep: true) == 30)
    }

    @Test
    func numericControlTreatsShiftArrowSelectorsAsLargeStepCommands() {
        #expect(NumericControlConfiguration.isLargeStepCommand(#selector(NSResponder.moveUp(_:))) == false)
        #expect(NumericControlConfiguration.isLargeStepCommand(#selector(NSResponder.moveDown(_:))) == false)
        #expect(NumericControlConfiguration.isLargeStepCommand(#selector(NSResponder.moveUpAndModifySelection(_:))) == true)
        #expect(NumericControlConfiguration.isLargeStepCommand(#selector(NSResponder.moveDownAndModifySelection(_:))) == true)
    }

    @Test
    func numericControlTreatsShiftModifierAsLargeStepForButtons() {
        #expect(NumericControlConfiguration.isLargeStepModifierFlags([]) == false)
        #expect(NumericControlConfiguration.isLargeStepModifierFlags(.shift) == true)
        #expect(NumericControlConfiguration.isLargeStepModifierFlags([.command, .shift]) == true)
    }

    @Test
    func numericControlTreatsEscapeAsCancelEditingCommand() {
        #expect(NumericControlConfiguration.isCancelEditingCommand(#selector(NSResponder.insertNewline(_:))) == false)
        #expect(NumericControlConfiguration.isCancelEditingCommand(#selector(NSResponder.cancelOperation(_:))) == true)
    }

    @Test
    func numericControlEditStateRestoresCommittedValueOnCancel() {
        var editState = NumericControlEditState(committedValue: 12)
        editState.beginEditing(currentValue: 12)

        #expect(editState.cancelledValue() == 12)

        editState.commit(27)
        editState.beginEditing(currentValue: 27)

        #expect(editState.cancelledValue() == 27)
    }

    @Test
    func numericControlFocusPolicyClearsEditingFocusOnlyForOutsideClicks() {
        let fieldEditor = NSTextView(frame: .zero)
        let container = NSView(frame: .zero)
        let textField = NSTextField(frame: .zero)
        container.addSubview(textField)
        let button = NSButton(frame: .zero)
        container.addSubview(button)

        #expect(NumericControlFocusPolicy.shouldClearEditingFocus(firstResponder: nil, clickedView: button) == false)
        #expect(NumericControlFocusPolicy.shouldClearEditingFocus(firstResponder: fieldEditor, clickedView: textField) == false)
        #expect(NumericControlFocusPolicy.shouldClearEditingFocus(firstResponder: fieldEditor, clickedView: button) == true)
        #expect(NumericControlFocusPolicy.shouldClearEditingFocus(firstResponder: fieldEditor, clickedView: nil) == true)
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
