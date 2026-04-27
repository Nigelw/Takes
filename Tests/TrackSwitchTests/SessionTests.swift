import AVFoundation
import AppKit
import Foundation
import Testing
@testable import TrackSwitch

struct SessionTests {
    @Test
    func sessionReadinessUsesOrderedTracks() {
        var session = ComparisonSession()
        #expect(!session.isPlayable)
        #expect(!session.canSwitchPlayback)
        #expect(session.activeTrackID == nil)

        let first = SessionTrack(loadedTrack: makeTrack(name: "a.wav"))
        session.tracks = [first]
        session.activeTrackID = first.id
        session.timelineEnd = 12

        #expect(session.isPlayable)
        #expect(!session.canSwitchPlayback)
        #expect(session.activeTrackID == first.id)

        let second = SessionTrack(loadedTrack: makeTrack(name: "b.wav"))
        session.tracks.append(second)

        #expect(session.isPlayable)
        #expect(session.canSwitchPlayback)
    }

    @Test
    func sessionUsesSignedTimelineBoundsForPlaybackReadiness() {
        let first = SessionTrack(loadedTrack: makeTrack(name: "a.wav"))
        var session = ComparisonSession(tracks: [first], activeTrackID: first.id)
        #expect(!session.isPlayable)

        session.timelineStart = -4
        session.timelineEnd = 120
        session.transportPosition = -4

        #expect(session.isPlayable)
        #expect(session.duration == 124)
    }

    @Test
    func compatibilitySlotsPreserveABOrderWhenBLoadsFirst() {
        var session = ComparisonSession()
        session.trackB = makeTrack(name: "b.wav")
        session.trackA = makeTrack(name: "a.wav")

        #expect(session.trackA?.displayName == "a.wav")
        #expect(session.trackB?.displayName == "b.wav")
        #expect(session.tracks.map { $0.loadedTrack.displayName } == ["a.wav", "b.wav"])
    }

    @Test
    func compatibilitySlotsFallbackAfterDirectTrackMutation() {
        var session = ComparisonSession()
        session.trackA = makeTrack(name: "a.wav")
        session.trackB = makeTrack(name: "b.wav")
        session.tracks.removeFirst()

        #expect(session.trackA?.displayName == "b.wav")
        #expect(session.trackB == nil)
        #expect(!session.canToggleComparison)
    }

    @Test
    func compatibilityToggleRequiresBothLegacyTracks() {
        var session = ComparisonSession()
        session.tracks = [SessionTrack(loadedTrack: makeTrack(name: "only.wav"))]

        #expect(session.canSwitchPlayback == false)
        #expect(session.canToggleComparison == false)

        session.trackB = makeTrack(name: "b.wav")
        #expect(session.canToggleComparison)
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
    func musicSelectionScriptDoesNotRejectMoreThanTwoTracks() {
        let script = LibraryTrackSelectionLoader.musicSelectionScript

        #expect(!script.contains("Select one or two audio files."))
        #expect(!script.contains("(count of selectedTracks) > 2"))
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
    func musicSelectionParsingSortsManyTracksByViewOrder() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
        let thirdURL = tempDirectory.appending(path: UUID().uuidString + ".m4a")
        let firstURL = tempDirectory.appending(path: UUID().uuidString + ".mp3")
        let secondURL = tempDirectory.appending(path: UUID().uuidString + ".wav")

        FileManager.default.createFile(atPath: thirdURL.path, contents: Data())
        FileManager.default.createFile(atPath: firstURL.path, contents: Data())
        FileManager.default.createFile(atPath: secondURL.path, contents: Data())
        defer {
            try? FileManager.default.removeItem(at: thirdURL)
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        let output = """
        9\t\(thirdURL.path)
        2\t\(firstURL.path)
        5\t\(secondURL.path)
        """

        let urls = try LibraryTrackSelectionLoader.parseSelectionOutput(output)

        #expect(urls == [firstURL, secondURL, thirdURL])
    }

    @MainActor
    @Test
    func importedFilesAppendSuccessesAndReportFailures() async throws {
        let first = try makeTemporaryAudioFile(name: "first.wav")
        let missing = URL(fileURLWithPath: "/tmp/missing-second.wav")
        let third = try makeTemporaryAudioFile(name: "third.wav")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: third.deletingLastPathComponent())
        }

        let controller = PlaybackController(loader: FakeAudioFileLoader(failingURLs: [missing]))

        await controller.loadImportedFiles([first, missing, third])

        #expect(controller.session.tracks.map { $0.loadedTrack.displayName } == ["first.wav", "third.wav"])
        #expect(controller.session.activeTrackID == controller.session.tracks.first?.id)
        #expect(controller.playbackError?.localizedDescription.contains("missing-second.wav") == true)
    }

    @MainActor
    @Test
    func importedFilesAppendToExistingTracksAndPreserveSettings() async throws {
        let first = try makeTemporaryAudioFile(name: "first.wav")
        let second = try makeTemporaryAudioFile(name: "second.wav")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }

        let controller = PlaybackController()
        await controller.loadImportedFiles([first])
        let existingID = try #require(controller.session.tracks.first?.id)
        controller.setGain(existingID, db: -6)
        controller.setOffset(existingID, seconds: 1.25)

        await controller.loadImportedFiles([second])

        #expect(controller.session.tracks.count == 2)
        #expect(controller.session.tracks[0].id == existingID)
        #expect(controller.session.tracks[0].loadedTrack.gainDB == -6)
        #expect(controller.session.tracks[0].loadedTrack.offsetSeconds == 1.25)
        #expect(controller.session.tracks[1].loadedTrack.displayName == "second.wav")
    }

    @MainActor
    @Test
    func importedFilesRespectThirtyTwoTrackCap() async throws {
        let urls = try (0..<33).map { index in
            try makeTemporaryAudioFile(name: "track-\(index).wav")
        }
        defer {
            for url in urls {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }

        let controller = PlaybackController()

        await controller.loadImportedFiles(urls)

        #expect(controller.session.tracks.count == PlaybackController.maximumTrackCount)
        #expect(controller.playbackError?.localizedDescription.contains("TrackSwitch currently supports up to 32 loaded tracks.") == true)
        #expect(controller.playbackError?.localizedDescription.contains("track-32.wav") == true)
    }

    @MainActor
    @Test
    func importedFilesReportFailuresAndTrackCapSkipsTogether() async throws {
        let existingURLs = try (0..<30).map { index in
            try makeTemporaryAudioFile(name: "existing-\(index).wav")
        }
        let importURLs = try (0..<3).map { index in
            try makeTemporaryAudioFile(name: "incoming-\(index).wav")
        }
        let missing = URL(fileURLWithPath: "/tmp/missing-mixed.wav")
        defer {
            for url in existingURLs + importURLs {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }

        let controller = PlaybackController(loader: FakeAudioFileLoader(failingURLs: [missing]))
        await controller.loadImportedFiles(existingURLs)

        await controller.loadImportedFiles([missing] + importURLs)

        #expect(controller.session.tracks.count == PlaybackController.maximumTrackCount)
        #expect(controller.session.tracks.map { $0.loadedTrack.displayName }.suffix(2) == ["incoming-0.wav", "incoming-1.wav"])
        #expect(controller.playbackError?.localizedDescription.contains("missing-mixed.wav") == true)
        #expect(controller.playbackError?.localizedDescription.contains("TrackSwitch currently supports up to 32 loaded tracks.") == true)
        #expect(controller.playbackError?.localizedDescription.contains("incoming-2.wav") == true)
    }

    @MainActor
    @Test
    func timelineRecalculationIncludesThirdAppendedTrack() async throws {
        let urls = try (0..<3).map { index in
            try makeTemporaryAudioFile(name: "timeline-\(index).wav")
        }
        defer {
            for url in urls {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }

        let controller = PlaybackController()
        await controller.loadImportedFiles(urls)
        let thirdID = try #require(controller.session.tracks.last?.id)

        controller.setOffset(thirdID, seconds: 10)

        #expect(controller.session.timelineEnd == 11)
    }

    @MainActor
    @Test
    func importedFilesAppendWhilePlayingPreservesPlaybackStateAndPosition() async throws {
        let first = try makeTemporaryAudioFile(name: "playing-first.wav")
        let second = try makeTemporaryAudioFile(name: "playing-second.wav")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }

        let controller = PlaybackController()
        await controller.loadImportedFiles([first])
        controller.play()
        controller.seek(to: 0.5)

        await controller.loadImportedFiles([second])

        #expect(controller.session.isPlaying == true)
        #expect(controller.session.transportPosition == 0.5)
    }

    @Test
    func loadRecalculationPrefersZeroWhenStoppedAtPreviousNegativeStart() {
        let position = PlaybackController.transportPositionAfterTimelineRecalculation(
            currentPosition: -12,
            timelineStart: -12,
            timelineEnd: 120,
            preferZero: true
        )

        #expect(position == 0)
    }

    @Test
    func timelineRecalculationPreservesCurrentPositionWithoutZeroPreference() {
        let position = PlaybackController.transportPositionAfterTimelineRecalculation(
            currentPosition: -12,
            timelineStart: -20,
            timelineEnd: 120,
            preferZero: false
        )

        #expect(position == -12)
    }

    @Test
    func timelineRecalculationClampsWhenRangeExcludesZero() {
        let position = PlaybackController.transportPositionAfterTimelineRecalculation(
            currentPosition: 0,
            timelineStart: 10,
            timelineEnd: 120,
            preferZero: true
        )

        #expect(position == 10)
    }

    @Test
    func silenceSchedulingSplitsLongDurationsIntoBoundedChunks() {
        let chunks = PlaybackController.silenceChunkDurations(duration: 12.5, maximumChunkDuration: 5)

        #expect(chunks == [5, 5, 2.5])
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
    @MainActor
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

    private func makeTemporaryAudioFile(name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
        buffer.frameLength = 44_100
        try file.write(from: buffer)
        return url
    }
}

private struct FakeAudioFileLoader: AudioFileLoading {
    let failingURLs: Set<URL>

    func loadTrackMetadata(from url: URL) throws -> LoadedTrack {
        if failingURLs.contains(url) {
            throw PlaybackError.failedToOpenFile(url)
        }

        let file = try AVAudioFile(forReading: url)
        return LoadedTrack(
            url: url,
            displayName: url.lastPathComponent,
            fileFormatDescription: url.pathExtension.uppercased(),
            duration: Double(file.length) / file.processingFormat.sampleRate,
            sampleRate: file.processingFormat.sampleRate,
            channelCount: file.processingFormat.channelCount
        )
    }

    func makeAudioFile(from url: URL) throws -> AVAudioFile {
        try AVAudioFile(forReading: url)
    }
}
