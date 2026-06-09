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
        #expect(session.activeTrack == nil)

        let first = SessionTrack(loadedTrack: makeTrack(name: "a.wav"))
        session.tracks = [first]
        session.activeTrackID = first.id
        session.timelineEnd = 12

        #expect(session.isPlayable)
        #expect(!session.canSwitchPlayback)
        #expect(session.activeTrackID == first.id)
        #expect(session.activeTrack == first)

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
    func signedTimestampFormatsNegativeTimes() {
        #expect(TimeInterval(-12).formattedSignedTimestamp == "-00:12")
        #expect(TimeInterval(12).formattedSignedTimestamp == "00:12")
        #expect(TimeInterval(-3723).formattedSignedTimestamp == "-1:02:03")
    }

    @Test
    func timelineMarkersUseReadableIntervalsAcrossTheTimeline() {
        let markers = TimelineHeaderMarker.markers(
            timelineStart: 0,
            timelineEnd: 125,
            targetMarkerCount: 6
        )

        #expect(markers.map(\.label) == ["00:00", "00:30", "01:00", "01:30", "02:00"])
        #expect(markers.map(\.time) == [0, 30, 60, 90, 120])
    }

    @Test
    func timelineMarkersIncludeSignedNegativeTimes() {
        let markers = TimelineHeaderMarker.markers(
            timelineStart: -12,
            timelineEnd: 44,
            targetMarkerCount: 5
        )

        #expect(markers.map(\.label) == ["-00:10", "00:00", "00:10", "00:20", "00:30", "00:40"])
        #expect(markers.map(\.time) == [-10, 0, 10, 20, 30, 40])
    }

    @Test
    func timelineMarkerLabelsAreInsetToTheRightOfTickMarks() {
        #expect(TimelineHeaderMarker.labelLeadingPadding == 8)
    }

    @Test
    func timelineMarkerLabelsHideWhenTheyWouldOverflowTheRightEdge() {
        let visibleLayout = TimelineHeaderLabelLayout.leading(
            tickX: 40,
            labelWidth: 52,
            rulerWidth: 120
        )
        let overflowingLayout = TimelineHeaderLabelLayout.leading(
            tickX: 108,
            labelWidth: 52,
            rulerWidth: 120
        )

        #expect(visibleLayout.x == 48)
        #expect(visibleLayout.isVisible)
        #expect(overflowingLayout.x == 116)
        #expect(!overflowingLayout.isVisible)
    }

    @MainActor
    @Test
    func playbackErrorCanBeClearedAfterPresentation() {
        let controller = PlaybackController()

        controller.setPlaybackError(.engineStartFailed)
        controller.clearPlaybackError()

        #expect(controller.playbackError == nil)
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
    func windowPolicyAllowsOneTrackRowAtMinimumHeight() {
        #expect(TrackSwitchWindowPolicy.minimumContentHeight == TrackSwitchWindowPolicy.contentHeight(displayingTrackRows: 1))
    }

    @Test
    func windowPolicyDefaultsToOneVisibleTrackRow() {
        #expect(TrackSwitchWindowPolicy.defaultContentHeight == TrackSwitchWindowPolicy.contentHeight(displayingTrackRows: 1))
    }

    @Test
    func windowPolicyAddsChromeToDefaultWindowHeight() {
        #expect(TrackSwitchWindowPolicy.defaultWindowHeight == TrackSwitchWindowPolicy.defaultContentHeight + TrackSwitchWindowPolicy.windowChromeHeight)
        #expect(TrackSwitchWindowPolicy.defaultWindowHeight > TrackSwitchWindowPolicy.defaultContentHeight)
    }

    @Test
    func windowPolicyGrowsFrameDownwardForAdditionalTrackRows() {
        let currentFrame = CGRect(x: 80, y: 700, width: 700, height: TrackSwitchWindowPolicy.defaultWindowHeight)
        let visibleFrame = CGRect(x: 0, y: 100, width: 1200, height: 800)

        let resizedFrame = TrackSwitchWindowPolicy.frame(
            fittingTrackRows: 3,
            currentFrame: currentFrame,
            visibleFrame: visibleFrame
        )

        #expect(resizedFrame.maxY == currentFrame.maxY)
        #expect(resizedFrame.height == TrackSwitchWindowPolicy.windowHeight(displayingTrackRows: 3))
        #expect(resizedFrame.minY < currentFrame.minY)
    }

    @Test
    func windowPolicyCapsResizedFrameAtVisibleMonitorBottom() {
        let currentFrame = CGRect(x: 80, y: 300, width: 700, height: TrackSwitchWindowPolicy.defaultWindowHeight)
        let visibleFrame = CGRect(x: 0, y: 260, width: 1200, height: 800)

        let resizedFrame = TrackSwitchWindowPolicy.frame(
            fittingTrackRows: 8,
            currentFrame: currentFrame,
            visibleFrame: visibleFrame
        )

        #expect(resizedFrame.maxY == currentFrame.maxY)
        #expect(resizedFrame.minY == visibleFrame.minY)
        #expect(resizedFrame.height < TrackSwitchWindowPolicy.windowHeight(displayingTrackRows: 8))
    }

    @Test
    func windowPolicyOnlyAutoGrowsWhenTrackRowsAreAdded() {
        let currentWindowHeight = TrackSwitchWindowPolicy.windowHeight(displayingTrackRows: 2)

        #expect(TrackSwitchWindowPolicy.shouldAutoGrowWindow(
            previousTrackRowCount: 2,
            newTrackRowCount: 3,
            currentWindowHeight: currentWindowHeight
        ))
        #expect(!TrackSwitchWindowPolicy.shouldAutoGrowWindow(
            previousTrackRowCount: 6,
            newTrackRowCount: 5,
            currentWindowHeight: currentWindowHeight
        ))
        #expect(!TrackSwitchWindowPolicy.shouldAutoGrowWindow(
            previousTrackRowCount: 5,
            newTrackRowCount: 5,
            currentWindowHeight: currentWindowHeight
        ))
    }

    @Test
    func windowPolicyDoesNotAutoGrowWhenAddedRowsAlreadyFitCurrentWindowHeight() {
        let currentWindowHeight = TrackSwitchWindowPolicy.windowHeight(displayingTrackRows: 4)

        #expect(!TrackSwitchWindowPolicy.shouldAutoGrowWindow(
            previousTrackRowCount: 2,
            newTrackRowCount: 4,
            currentWindowHeight: currentWindowHeight
        ))
    }

    @Test
    func windowPolicyAutoShrinksWhenRemovedRowsFitBelowCurrentWindowHeight() {
        let currentWindowHeight = TrackSwitchWindowPolicy.windowHeight(displayingTrackRows: 4)

        #expect(TrackSwitchWindowPolicy.shouldAutoShrinkWindow(
            previousTrackRowCount: 4,
            newTrackRowCount: 2,
            currentWindowHeight: currentWindowHeight
        ))
    }

    @Test
    func windowPolicyDoesNotAutoShrinkWhenRemainingRowsNeedCurrentWindowHeight() {
        let currentWindowHeight = TrackSwitchWindowPolicy.windowHeight(displayingTrackRows: 4)

        #expect(!TrackSwitchWindowPolicy.shouldAutoShrinkWindow(
            previousTrackRowCount: 4,
            newTrackRowCount: 4,
            currentWindowHeight: currentWindowHeight
        ))
        #expect(!TrackSwitchWindowPolicy.shouldAutoShrinkWindow(
            previousTrackRowCount: 5,
            newTrackRowCount: 4,
            currentWindowHeight: currentWindowHeight
        ))
    }

    @Test
    func windowPolicyUsesNarrowerMinimumWidthThanDefaultWidth() {
        #expect(TrackSwitchWindowPolicy.minimumContentWidth == 500)
        #expect(TrackSwitchWindowPolicy.defaultWindowWidth > TrackSwitchWindowPolicy.minimumContentWidth)
    }

    @Test
    func windowPolicyClearsSavedMainWindowFrame() {
        let defaults = UserDefaults(suiteName: "TrackSwitchWindowPolicyTests-\(UUID().uuidString)")!
        defaults.set("10 20 900 568 0 0 1512 944", forKey: TrackSwitchWindowPolicy.mainWindowFrameAutosaveName)

        TrackSwitchWindowPolicy.clearSavedMainWindowFrame(defaults: defaults)

        #expect(defaults.string(forKey: TrackSwitchWindowPolicy.mainWindowFrameAutosaveName) == nil)
    }

    @Test
    func musicSelectionScriptDoesNotRejectMoreThanTwoTracks() {
        let script = LibraryTrackSelectionLoader.musicSelectionScript

        #expect(!script.contains("(count of selectedTracks) > 2"))
        #expect(script.contains("\"ERROR\""))
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
    func infoPlistDeclaresAudioAndFolderDocumentSupportForAppIconDrops() throws {
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
        let documentTypes = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let supportedTypes = documentTypes.flatMap { documentType in
            documentType["LSItemContentTypes"] as? [String] ?? []
        }

        #expect(supportedTypes.contains("public.audio"))
        #expect(supportedTypes.contains("public.folder"))
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

    @Test
    func musicSelectionParsingReturnsFailuresWithValidTracks() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
        let validURL = tempDirectory.appending(path: UUID().uuidString + ".mp3")
        let missingURL = tempDirectory.appending(path: UUID().uuidString + ".wav")

        FileManager.default.createFile(atPath: validURL.path, contents: Data())
        defer {
            try? FileManager.default.removeItem(at: validURL)
        }

        let output = """
        3\tOK\t\(missingURL.path)
        1\tOK\t\(validURL.path)
        2\tERROR\tThe selected Music track is not a local file.
        """

        let selection = try LibraryTrackSelectionLoader.parseSelection(output)

        #expect(selection.urls == [validURL])
        #expect(selection.failures.count == 2)
        #expect(selection.failures.map(\.fileName).contains("Music item 2"))
        #expect(selection.failures.map(\.fileName).contains(missingURL.lastPathComponent))
    }

    @MainActor
    @Test
    func musicSelectionLoadsValidTracksAndReportsSelectionFailures() async throws {
        let validURL = try makeTemporaryAudioFile(name: "valid.wav")
        defer { try? FileManager.default.removeItem(at: validURL.deletingLastPathComponent()) }

        let controller = PlaybackController(
            libraryTrackSelector: FakeLibraryTrackSelector(
                selection: LibraryTrackSelection(
                    urls: [validURL],
                    failures: [ImportFailure(fileName: "Cloud Track", message: "The selected Music track is not a local file.")]
                )
            )
        )

        await controller.loadSelectedLibraryTracks()

        #expect(controller.session.tracks.map { $0.loadedTrack.displayName } == ["valid.wav"])
        #expect(controller.playbackError?.localizedDescription.contains("Cloud Track") == true)
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
    func importedFilesSkipFilesAlreadyInTimeline() async throws {
        let first = try makeTemporaryAudioFile(name: "first.wav")
        let second = try makeTemporaryAudioFile(name: "second.wav")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }

        let controller = PlaybackController()
        await controller.loadImportedFiles([first])

        await controller.loadImportedFiles([first, second, first])

        #expect(controller.session.tracks.map { $0.loadedTrack.url } == [first, second])
        #expect(controller.playbackError == nil)
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
    func switchPlaybackCyclesThroughTrackOrderAndWraps() async throws {
        let urls = try (0..<3).map { try makeTemporaryAudioFile(name: "track-\($0).wav") }
        defer {
            for url in urls {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }

        let controller = PlaybackController()
        await controller.loadImportedFiles(urls)

        let ids = controller.session.tracks.map(\.id)
        #expect(controller.session.activeTrackID == ids[0])

        controller.selectNextTrack()
        #expect(controller.session.activeTrackID == ids[1])

        controller.selectNextTrack()
        #expect(controller.session.activeTrackID == ids[2])

        controller.selectNextTrack()
        #expect(controller.session.activeTrackID == ids[0])
    }

    @MainActor
    @Test
    func switchPlaybackCanCycleToPreviousTrackAndWraps() async throws {
        let urls = try (0..<3).map { try makeTemporaryAudioFile(name: "track-\($0).wav") }
        defer {
            for url in urls {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }

        let controller = PlaybackController()
        await controller.loadImportedFiles(urls)

        let ids = controller.session.tracks.map(\.id)
        #expect(controller.session.activeTrackID == ids[0])

        controller.selectPreviousTrack()
        #expect(controller.session.activeTrackID == ids[2])

        controller.selectPreviousTrack()
        #expect(controller.session.activeTrackID == ids[1])

        controller.selectPreviousTrack()
        #expect(controller.session.activeTrackID == ids[0])
    }

    @MainActor
    @Test
    func numericTrackHotkeysSelectRowsOneThroughEight() async throws {
        let urls = try (0..<8).map { try makeTemporaryAudioFile(name: "track-\($0).wav") }
        defer {
            for url in urls {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }

        let controller = PlaybackController()
        await controller.loadImportedFiles(urls)

        let ids = controller.session.tracks.map(\.id)

        controller.selectTrackForHotkey(1)
        #expect(controller.session.activeTrackID == ids[0])

        controller.selectTrackForHotkey(8)
        #expect(controller.session.activeTrackID == ids[7])
    }

    @MainActor
    @Test
    func numericTrackHotkeyNineSelectsLastTrackWhenMoreThanEightTracksAreLoaded() async throws {
        let urls = try (0..<9).map { try makeTemporaryAudioFile(name: "track-\($0).wav") }
        defer {
            for url in urls {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }

        let controller = PlaybackController()
        await controller.loadImportedFiles(urls)

        let ids = controller.session.tracks.map(\.id)

        controller.selectTrackForHotkey(9)
        #expect(controller.session.activeTrackID == ids[8])
    }

    @MainActor
    @Test
    func numericTrackHotkeysIgnoreUnavailableRows() async throws {
        let urls = try (0..<3).map { try makeTemporaryAudioFile(name: "track-\($0).wav") }
        defer {
            for url in urls {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }

        let controller = PlaybackController()
        await controller.loadImportedFiles(urls)

        let ids = controller.session.tracks.map(\.id)
        controller.selectTrackForHotkey(2)
        #expect(controller.session.activeTrackID == ids[1])

        controller.selectTrackForHotkey(8)
        #expect(controller.session.activeTrackID == ids[1])

        controller.selectTrackForHotkey(9)
        #expect(controller.session.activeTrackID == ids[1])
    }

    @MainActor
    @Test
    func reorderingTracksUpdatesPlaybackCyclingOrder() async throws {
        let urls = try (0..<3).map { try makeTemporaryAudioFile(name: "track-\($0).wav") }
        defer {
            for url in urls {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }

        let controller = PlaybackController()
        await controller.loadImportedFiles(urls)
        let ids = controller.session.tracks.map(\.id)

        controller.reorderTrack(ids[2], before: ids[0])

        #expect(controller.session.tracks.map(\.id) == [ids[2], ids[0], ids[1]])

        controller.selectActiveTrack(ids[2])
        controller.selectNextTrack()
        #expect(controller.session.activeTrackID == ids[0])
    }

    @MainActor
    @Test
    func reorderingTracksCanMoveTrackToEnd() async throws {
        let urls = try (0..<3).map { try makeTemporaryAudioFile(name: "track-\($0).wav") }
        defer {
            for url in urls {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }

        let controller = PlaybackController()
        await controller.loadImportedFiles(urls)
        let ids = controller.session.tracks.map(\.id)

        controller.reorderTrack(ids[0], before: nil)

        #expect(controller.session.tracks.map(\.id) == [ids[1], ids[2], ids[0]])
        #expect(controller.session.activeTrackID == ids[0])
    }

    @MainActor
    @Test
    func removingActiveTrackPausesAndSelectsNextOrPrevious() async throws {
        let urls = try (0..<3).map { try makeTemporaryAudioFile(name: "track-\($0).wav") }
        defer {
            for url in urls {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }

        let controller = PlaybackController()
        await controller.loadImportedFiles(urls)
        let ids = controller.session.tracks.map(\.id)
        controller.selectActiveTrack(ids[1])
        controller.play()

        controller.removeTrack(ids[1])

        #expect(!controller.session.isPlaying)
        #expect(controller.session.activeTrackID == ids[2])

        controller.play()
        controller.removeTrack(ids[2])

        #expect(!controller.session.isPlaying)
        #expect(controller.session.activeTrackID == ids[0])
    }

    @MainActor
    @Test
    func removingFinalTrackClearsActiveSelectionAndTimeline() async throws {
        let url = try makeTemporaryAudioFile(name: "only.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let controller = PlaybackController()
        await controller.loadImportedFiles([url])
        let id = try #require(controller.session.tracks.first?.id)

        controller.removeTrack(id)

        #expect(controller.session.tracks.isEmpty)
        #expect(controller.session.activeTrackID == nil)
        #expect(controller.session.timelineStart == 0)
        #expect(controller.session.timelineEnd == 0)
        #expect(controller.session.transportPosition == 0)
    }

    @MainActor
    @Test
    func clearingTracksStopsPlaybackAndResetsTimeline() async throws {
        let first = try makeTemporaryAudioFile(name: "clear-first.wav")
        let second = try makeTemporaryAudioFile(name: "clear-second.wav")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }

        let controller = PlaybackController()
        await controller.loadImportedFiles([first, second])
        controller.play()

        controller.clearTracks()

        #expect(controller.session.tracks.isEmpty)
        #expect(controller.session.activeTrackID == nil)
        #expect(controller.session.isPlaying == false)
        #expect(controller.session.timelineStart == 0)
        #expect(controller.session.timelineEnd == 0)
        #expect(controller.session.transportPosition == 0)
    }

    @MainActor
    @Test
    func replacingTrackResetsGainAndOffsetButKeepsRowActive() async throws {
        let first = try makeTemporaryAudioFile(name: "first.wav")
        let replacement = try makeTemporaryAudioFile(name: "replacement.wav")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: replacement.deletingLastPathComponent())
        }

        let controller = PlaybackController()
        await controller.loadImportedFiles([first])
        let id = try #require(controller.session.tracks.first?.id)
        controller.setGain(id, db: -12)
        controller.setOffset(id, seconds: 2)

        await controller.replaceTrack(id, with: replacement)

        #expect(controller.session.tracks.count == 1)
        #expect(controller.session.tracks[0].id == id)
        #expect(controller.session.tracks[0].loadedTrack.displayName == "replacement.wav")
        #expect(controller.session.tracks[0].loadedTrack.gainDB == 0)
        #expect(controller.session.tracks[0].loadedTrack.offsetSeconds == 0)
        #expect(controller.session.activeTrackID == id)
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
        #expect(controller.session.transportPosition >= 0.5)
    }

    @MainActor
    @Test
    func importedFilesAppendWhilePlayingUsesCurrentTransportAfterSlowImport() async throws {
        let first = try makeTemporaryAudioFile(name: "slow-playing-first.wav")
        let second = try makeTemporaryAudioFile(name: "slow-playing-second.wav")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }

        let controller = PlaybackController(
            loader: FakeAudioFileLoader(
                failingURLs: [],
                delayedMetadataURLs: [second],
                metadataDelay: 0.2
            )
        )
        await controller.loadImportedFiles([first])
        controller.play()
        controller.seek(to: 0.25)

        await controller.loadImportedFiles([second])

        #expect(controller.session.isPlaying == true)
        #expect(controller.session.transportPosition > 0.25)
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
    func endOfPlaybackPositionStopsAtTimelineEnd() {
        #expect(PlaybackController.transportPositionAtNaturalEnd(timelineEnd: 12.5) == 12.5)
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
    func numericControlEditStateKeepsTypedTextPendingUntilCommit() {
        var editState = NumericControlEditState(committedValue: 12)
        editState.beginEditing(currentValue: 12)
        editState.updatePendingText("27")

        #expect(editState.committedValue == 12)
        #expect(editState.pendingText == "27")

        let committed = editState.commitPendingText(
            fallbackValue: 12,
            configuration: .gain
        )

        #expect(committed == 24)
        #expect(editState.committedValue == 24)
        #expect(editState.pendingText == nil)
    }

    @Test
    func numericControlEditStateDoesNotOverwriteCommittedValueWithoutPendingText() {
        var editState = NumericControlEditState(committedValue: 12)
        editState.beginEditing(currentValue: 12)
        editState.updatePendingText("25")

        #expect(editState.commitPendingText(fallbackValue: 0, configuration: .offset) == 25)
        #expect(editState.pendingText == nil)
        #expect(editState.commitPendingText(fallbackValue: 0, configuration: .offset) == 25)
        #expect(editState.committedValue == 25)
    }

    @Test
    func numericControlEditStateRefreshesCommittedValueBeforeEditing() {
        var editState = NumericControlEditState(committedValue: 0)

        editState.refreshCommittedValue(12)
        editState.beginEditing(currentValue: 12)
        editState.updatePendingText("27")

        #expect(editState.cancelledValue() == 12)
        #expect(editState.committedValue == 12)
    }

    @Test
    func numericControlEditStateBeginsEditingFromDisplayedTextBeforeFallbackValue() {
        var editState = NumericControlEditState(committedValue: 12)

        editState.beginEditing(
            displayedText: "12",
            fallbackValue: 0,
            configuration: .offset
        )
        editState.updatePendingText("27")

        #expect(editState.cancelledValue() == 12)
    }

    @Test
    func numericControlEditStateCommitsSteppedPendingText() {
        var editState = NumericControlEditState(committedValue: 0)
        editState.beginEditing(currentValue: 0)
        editState.updatePendingText("20")

        let stepped = editState.commitSteppedPendingText(
            fallbackValue: 0,
            configuration: .offset,
            direction: 1,
            largeStep: true
        )

        #expect(stepped == 120)
        #expect(editState.committedValue == 120)
        #expect(editState.pendingText == nil)
    }

    @Test
    func numericControlEditStateKeepsPendingTextWhenSteppingWithStaleControlText() {
        var editState = NumericControlEditState(committedValue: 0)
        editState.beginEditing(currentValue: 0)
        editState.updatePendingText("20")

        let stepped = editState.commitSteppedEditingText(
            currentText: "0",
            fallbackValue: 0,
            configuration: .offset,
            direction: 1,
            largeStep: false
        )

        #expect(stepped == 30)
        #expect(editState.committedValue == 30)
        #expect(editState.pendingText == nil)
    }

    @Test
    func numericControlEditStateClearsPendingTextOnCancel() {
        var editState = NumericControlEditState(committedValue: 12)
        editState.beginEditing(currentValue: 12)
        editState.updatePendingText("27")

        #expect(editState.cancelledValue() == 12)
        #expect(editState.pendingText == nil)
        #expect(editState.committedValue == 12)
    }

    @Test
    func numericControlEditingTextPrefersFieldEditorTextWhenPresent() {
        #expect(
            NumericControlEditingText.current(
                controlText: "0",
                fieldEditorText: "25"
            ) == "25"
        )
        #expect(
            NumericControlEditingText.current(
                controlText: "25",
                fieldEditorText: nil
            ) == "25"
        )
    }

    @Test
    func numericInputKeyEquivalentPolicyRoutesHorizontalArrowsToTextEditing() {
        #expect(NumericInputKeyEquivalentPolicy.routesToFieldEditor(keyCode: 123, modifierFlags: []) == true)
        #expect(NumericInputKeyEquivalentPolicy.routesToFieldEditor(keyCode: 124, modifierFlags: []) == true)
        #expect(NumericInputKeyEquivalentPolicy.routesToFieldEditor(keyCode: 123, modifierFlags: .shift) == true)
        #expect(NumericInputKeyEquivalentPolicy.routesToFieldEditor(keyCode: 124, modifierFlags: .shift) == true)
        #expect(NumericInputKeyEquivalentPolicy.routesToFieldEditor(keyCode: 123, modifierFlags: .command) == true)
        #expect(NumericInputKeyEquivalentPolicy.routesToFieldEditor(keyCode: 124, modifierFlags: .command) == true)
        #expect(NumericInputKeyEquivalentPolicy.routesToFieldEditor(keyCode: 123, modifierFlags: [.command, .shift]) == true)
        #expect(NumericInputKeyEquivalentPolicy.routesToFieldEditor(keyCode: 124, modifierFlags: [.command, .shift]) == true)
    }

    @Test
    func numericInputKeyEquivalentPolicyRoutesVerticalArrowsToTextEditing() {
        #expect(NumericInputKeyEquivalentPolicy.routesToFieldEditor(keyCode: 125, modifierFlags: []) == true)
        #expect(NumericInputKeyEquivalentPolicy.routesToFieldEditor(keyCode: 126, modifierFlags: []) == true)
        #expect(NumericInputKeyEquivalentPolicy.routesToFieldEditor(keyCode: 125, modifierFlags: .shift) == true)
        #expect(NumericInputKeyEquivalentPolicy.routesToFieldEditor(keyCode: 126, modifierFlags: .shift) == true)
    }

    @Test
    func numericInputKeyEquivalentPolicyLeavesOtherKeysAlone() {
        #expect(NumericInputKeyEquivalentPolicy.routesToFieldEditor(keyCode: 49, modifierFlags: []) == false)
        #expect(NumericInputKeyEquivalentPolicy.routesToFieldEditor(keyCode: 7, modifierFlags: []) == false)
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

    @Test
    @MainActor
    func globalShortcutsAreDisabledWhileTextInputIsFocused() {
        #expect(GlobalShortcutFocusPolicy.shouldHandleGlobalShortcut(firstResponder: nil) == true)
        #expect(GlobalShortcutFocusPolicy.shouldHandleGlobalShortcut(firstResponder: NSView(frame: .zero)) == true)
        #expect(GlobalShortcutFocusPolicy.shouldHandleGlobalShortcut(firstResponder: NSTextField(frame: .zero)) == false)
        #expect(GlobalShortcutFocusPolicy.shouldHandleGlobalShortcut(firstResponder: NSTextView(frame: .zero)) == false)
    }

    @Test
    func trackNumberHotkeyMapsTopRowAndKeypadNumberKeys() {
        #expect(TrackNumberHotkey.hotkey(forKeyCode: 18, modifierFlags: []) == 1)
        #expect(TrackNumberHotkey.hotkey(forKeyCode: 28, modifierFlags: []) == 8)
        #expect(TrackNumberHotkey.hotkey(forKeyCode: 25, modifierFlags: []) == 9)
        #expect(TrackNumberHotkey.hotkey(forKeyCode: 83, modifierFlags: []) == 1)
        #expect(TrackNumberHotkey.hotkey(forKeyCode: 91, modifierFlags: []) == 8)
        #expect(TrackNumberHotkey.hotkey(forKeyCode: 92, modifierFlags: []) == 9)
    }

    @Test
    func trackNumberHotkeyIgnoresModifiedNumberKeys() {
        #expect(TrackNumberHotkey.hotkey(forKeyCode: 18, modifierFlags: .shift) == nil)
        #expect(TrackNumberHotkey.hotkey(forKeyCode: 18, modifierFlags: .command) == nil)
        #expect(TrackNumberHotkey.hotkey(forKeyCode: 18, modifierFlags: .control) == nil)
        #expect(TrackNumberHotkey.hotkey(forKeyCode: 18, modifierFlags: .option) == nil)
        #expect(TrackNumberHotkey.hotkey(forKeyCode: 29, modifierFlags: []) == nil)
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
    var delayedMetadataURLs: Set<URL> = []
    var metadataDelay: TimeInterval = 0

    func loadTrackMetadata(from url: URL) throws -> LoadedTrack {
        if failingURLs.contains(url) {
            throw PlaybackError.failedToOpenFile(url)
        }
        if delayedMetadataURLs.contains(url) {
            Thread.sleep(forTimeInterval: metadataDelay)
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

private struct FakeLibraryTrackSelector: LibraryTrackSelecting {
    let selection: LibraryTrackSelection

    func selectedTracks() throws -> LibraryTrackSelection {
        selection
    }
}
