import AVFoundation
import AppKit
import Foundation
import Testing
@testable import Takes

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
            timelineStart: -20,
            timelineEnd: 40,
            targetMarkerCount: 6
        )

        #expect(markers.map(\.label) == ["-00:20", "-00:10", "00:00", "00:10", "00:20", "00:30", "00:40"])
        #expect(markers.map(\.time) == [-20, -10, 0, 10, 20, 30, 40])
    }

    @Test
    func timelineMarkerLabelsAreInsetToTheRightOfTickMarks() {
        #expect(TimelineHeaderMarker.labelLeadingPadding == 4)
    }

    @Test
    func timelineMarkerLabelsStayVisibleUntilTheirLeadingEdgeLeavesTheRuler() {
        // A label whose box overflows the right edge stays mounted so the ruler can clip it, letting
        // it scroll out of view instead of vanishing early.
        let overflowingLayout = TimelineHeaderLabelLayout.leading(
            tickX: 112,
            rulerWidth: 120
        )
        // Only once the label's leading edge is past the right edge is there nothing left to show.
        let offscreenLayout = TimelineHeaderLabelLayout.leading(
            tickX: 116,
            rulerWidth: 120
        )

        #expect(overflowingLayout.x == 116)
        #expect(overflowingLayout.isVisible)
        #expect(offscreenLayout.x == 120)
        #expect(!offscreenLayout.isVisible)
    }

    @MainActor
    @Test
    func playbackErrorCanBeClearedAfterPresentation() {
        let controller = PlaybackController()

        controller.setPlaybackError(.engineStartFailed)
        controller.clearPlaybackError()

        #expect(controller.playbackError == nil)
    }

    @MainActor
    @Test
    func trackLimitErrorSummarizesLargeSkippedFileLists() {
        let skippedFileNames = (0..<40).map { "track-\($0).wav" }
        let description = PlaybackError.trackLimitExceeded(
            limit: PlaybackController.maximumTrackCount,
            skippedFileNames: skippedFileNames
        ).localizedDescription

        #expect(description.contains("Takes currently supports up to 32 loaded tracks."))
        #expect(description.contains("Skipped 40 files:"))
        #expect(description.contains("track-0.wav"))
        #expect(description.contains("track-7.wav"))
        #expect(!description.contains("track-8.wav"))
        #expect(description.contains("... and 32 more."))
    }

    @MainActor
    @Test
    func failedFileErrorExplainsLikelyCauses() {
        let url = URL(fileURLWithPath: "/tmp/broken.wav")
        let description = PlaybackError.failedToOpenFile(url).localizedDescription

        #expect(description.contains("Could not load broken.wav."))
        #expect(description.contains("missing, damaged, or in an unsupported audio format"))
        #expect(!description.contains("Could not open file"))
    }

    @Test
    func unsignedTimestampClampsNegativeTimes() {
        #expect(TimeInterval(-12).formattedTimestamp == "00:00")
        #expect(TimeInterval(12).formattedTimestamp == "00:12")
    }

    @Test
    func loadedTrackMetadataSummaryIncludesKeyFacts() {
        let track = makeTrack(name: "master.wav")

        #expect(track.metadataSummary == "02:00 • 44.1 kHz • 256 kbps")
    }

    @Test
    func loadedTrackMetadataSummaryOmitsBitRateWhenUnavailable() {
        var track = makeTrack(name: "lossless.wav")
        track.bitRate = 0

        #expect(track.metadataSummary == "02:00 • 44.1 kHz")
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
        #expect(TakesWindowPolicy.minimumContentHeight == TakesWindowPolicy.contentHeight(displayingTrackRows: 1))
    }

    @Test
    func windowPolicyDefaultsToOneVisibleTrackRow() {
        #expect(TakesWindowPolicy.defaultContentHeight == TakesWindowPolicy.contentHeight(displayingTrackRows: 1))
    }

    @Test
    func windowPolicyAddsNoChromeHeightAboveContent() {
        // The transport bar occupies the hidden-titlebar region (the root view
        // ignores the top safe area), so the window is exactly content-sized.
        #expect(TakesWindowPolicy.windowChromeHeight == 0)
        #expect(TakesWindowPolicy.defaultWindowHeight == TakesWindowPolicy.defaultContentHeight)
    }

    @Test
    func windowPolicyGrowsFrameDownwardForAdditionalTrackRows() {
        let currentFrame = CGRect(x: 80, y: 700, width: 700, height: TakesWindowPolicy.defaultWindowHeight)
        let visibleFrame = CGRect(x: 0, y: 100, width: 1200, height: 800)

        let resizedFrame = TakesWindowPolicy.frame(
            fittingTrackRows: 3,
            currentFrame: currentFrame,
            visibleFrame: visibleFrame
        )

        #expect(resizedFrame.maxY == currentFrame.maxY)
        #expect(resizedFrame.height == TakesWindowPolicy.windowHeight(displayingTrackRows: 3))
        #expect(resizedFrame.minY < currentFrame.minY)
    }

    @Test
    func windowPolicyDefaultsFrameToVisibleScreenTopLeft() {
        let visibleFrame = CGRect(x: 48, y: 80, width: 1200, height: 800)

        let defaultFrame = TakesWindowPolicy.defaultFrame(visibleFrame: visibleFrame)

        #expect(defaultFrame.minX == visibleFrame.minX)
        #expect(defaultFrame.maxY == visibleFrame.maxY)
        #expect(defaultFrame.width == TakesWindowPolicy.defaultWindowWidth)
        #expect(defaultFrame.height == TakesWindowPolicy.defaultWindowHeight)
    }

    @Test
    func windowPolicyResetsLaunchHeightWhilePreservingWidthAndTopLeft() {
        let currentFrame = CGRect(x: 96, y: 360, width: 920, height: TakesWindowPolicy.windowHeight(displayingTrackRows: 4))
        let visibleFrame = CGRect(x: 0, y: 80, width: 1200, height: 800)

        let resetFrame = TakesWindowPolicy.frameResettingHeight(
            currentFrame: currentFrame,
            visibleFrame: visibleFrame
        )

        #expect(resetFrame.minX == currentFrame.minX)
        #expect(resetFrame.maxY == currentFrame.maxY)
        #expect(resetFrame.width == currentFrame.width)
        #expect(resetFrame.height == TakesWindowPolicy.defaultWindowHeight)
    }

    @Test
    func windowPolicyResetSizeUsesDefaultSizeWhilePreservingTopLeft() {
        let currentFrame = CGRect(x: 96, y: 360, width: 920, height: TakesWindowPolicy.windowHeight(displayingTrackRows: 4))
        let visibleFrame = CGRect(x: 0, y: 80, width: 1200, height: 800)

        let resetFrame = TakesWindowPolicy.frameResettingSize(
            currentFrame: currentFrame,
            visibleFrame: visibleFrame
        )

        #expect(resetFrame.minX == currentFrame.minX)
        #expect(resetFrame.maxY == currentFrame.maxY)
        #expect(resetFrame.width == TakesWindowPolicy.defaultWindowWidth)
        #expect(resetFrame.height == TakesWindowPolicy.defaultWindowHeight)
    }

    @Test
    func windowPolicyCapsResizedFrameAtVisibleMonitorBottom() {
        let currentFrame = CGRect(x: 80, y: 300, width: 700, height: TakesWindowPolicy.defaultWindowHeight)
        let visibleFrame = CGRect(x: 0, y: 260, width: 1200, height: 800)

        let resizedFrame = TakesWindowPolicy.frame(
            fittingTrackRows: 8,
            currentFrame: currentFrame,
            visibleFrame: visibleFrame
        )

        #expect(resizedFrame.maxY == currentFrame.maxY)
        #expect(resizedFrame.minY == visibleFrame.minY)
        #expect(resizedFrame.height < TakesWindowPolicy.windowHeight(displayingTrackRows: 8))
    }

    @Test
    func windowPolicyOnlyAutoGrowsWhenTrackRowsAreAdded() {
        let currentWindowHeight = TakesWindowPolicy.windowHeight(displayingTrackRows: 2)

        #expect(TakesWindowPolicy.shouldAutoGrowWindow(
            previousTrackRowCount: 2,
            newTrackRowCount: 3,
            currentWindowHeight: currentWindowHeight
        ))
        #expect(!TakesWindowPolicy.shouldAutoGrowWindow(
            previousTrackRowCount: 6,
            newTrackRowCount: 5,
            currentWindowHeight: currentWindowHeight
        ))
        #expect(!TakesWindowPolicy.shouldAutoGrowWindow(
            previousTrackRowCount: 5,
            newTrackRowCount: 5,
            currentWindowHeight: currentWindowHeight
        ))
    }

    @Test
    func windowPolicyDoesNotAutoGrowWhenAddedRowsAlreadyFitCurrentWindowHeight() {
        let currentWindowHeight = TakesWindowPolicy.windowHeight(displayingTrackRows: 4)

        #expect(!TakesWindowPolicy.shouldAutoGrowWindow(
            previousTrackRowCount: 2,
            newTrackRowCount: 4,
            currentWindowHeight: currentWindowHeight
        ))
    }

    @Test
    func windowPolicyAutoShrinksWhenRemovedRowsFitBelowCurrentWindowHeight() {
        let currentWindowHeight = TakesWindowPolicy.windowHeight(displayingTrackRows: 4)

        #expect(TakesWindowPolicy.shouldAutoShrinkWindow(
            previousTrackRowCount: 4,
            newTrackRowCount: 2,
            currentWindowHeight: currentWindowHeight
        ))
    }

    @Test
    func windowPolicyDoesNotAutoShrinkWhenRemainingRowsNeedCurrentWindowHeight() {
        let currentWindowHeight = TakesWindowPolicy.windowHeight(displayingTrackRows: 4)

        #expect(!TakesWindowPolicy.shouldAutoShrinkWindow(
            previousTrackRowCount: 4,
            newTrackRowCount: 4,
            currentWindowHeight: currentWindowHeight
        ))
        #expect(!TakesWindowPolicy.shouldAutoShrinkWindow(
            previousTrackRowCount: 5,
            newTrackRowCount: 4,
            currentWindowHeight: currentWindowHeight
        ))
    }

    @Test
    func windowPolicyUsesNarrowerMinimumWidthThanDefaultWidth() {
        #expect(TakesWindowPolicy.defaultWindowWidth > TakesWindowPolicy.minimumContentWidth)
    }

    @Test
    func trackInfoColumnPolicyDefaultsNearExistingFixedWidth() {
        #expect(TakesWindowPolicy.defaultTrackInfoColumnWidth == 240)
        #expect(TakesWindowPolicy.minimumTrackInfoColumnWidth == TakesWindowPolicy.defaultTrackInfoColumnWidth - 10)
    }

    @Test
    func trackInfoColumnPolicyClampsToMinimumWidth() {
        let width = TakesWindowPolicy.clampedTrackInfoColumnWidth(
            120,
            sectionWidth: TakesWindowPolicy.defaultWindowWidth
        )

        #expect(width == TakesWindowPolicy.minimumTrackInfoColumnWidth)
    }

    @Test
    func trackInfoColumnPolicyPreservesWaveformMinimumWidth() {
        let width = TakesWindowPolicy.clampedTrackInfoColumnWidth(
            640,
            sectionWidth: TakesWindowPolicy.defaultWindowWidth
        )

        #expect(width == TakesWindowPolicy.defaultWindowWidth - TakesWindowPolicy.minimumWaveformColumnWidth)
    }

    @Test
    func windowPolicyDetectsSavedMainWindowFrame() {
        var defaults: [String: Any] = [:]

        #expect(!TakesWindowPolicy.hasSavedMainWindowFrame { defaults[$0] })

        defaults[TakesWindowPolicy.mainWindowFrameAutosaveName] = "10 20 900 568 0 0 1512 944"

        #expect(TakesWindowPolicy.hasSavedMainWindowFrame { defaults[$0] })
    }

    @Test
    func launchOptionsReadTemporaryDefaultWindowLayoutArgument() {
        #expect(TakesLaunchOptions(arguments: [
            "Takes",
            TakesLaunchOptions.defaultWindowLayoutArgument
        ]).usesDefaultWindowLayout)
        #expect(!TakesLaunchOptions(arguments: ["Takes"]).usesDefaultWindowLayout)
    }

    @Test
    func appearanceThemeOverrideReadsLaunchArgument() {
        #expect(AppSettings.appearanceThemeOverride(arguments: [
            "Takes",
            AppSettings.appearanceThemeOverrideArgument,
            "dark"
        ]) == .dark)
        #expect(AppSettings.appearanceThemeOverride(arguments: [
            "Takes",
            "\(AppSettings.appearanceThemeOverrideArgument)=light"
        ]) == .light)
    }

    @MainActor
    @Test
    func appearanceThemeOverrideDoesNotPersistDuringSettingsInitialization() {
        let defaults = InMemoryAppSettingsDefaults()
        defaults.set(AppearanceTheme.light.rawValue, forKey: AppSettings.appearanceThemeKey)

        let settings = AppSettings(
            defaults: defaults,
            arguments: ["Takes", AppSettings.appearanceThemeOverrideArgument, "dark"]
        )

        #expect(settings.appearanceTheme == .dark)
        #expect(AppSettings.storedAppearanceTheme(defaults) == .light)
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
            .appending(path: "Takes-Info.plist")

        let data = try Data(contentsOf: plistURL)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        let usage = plist["NSAppleEventsUsageDescription"] as? String
        #expect(usage == "Takes needs to get the current selection from Finder and Apple Music.")
    }

    @Test
    func aboutPanelCreditsExposeExactTextAndLinks() throws {
        let credits = TakesAboutPanel.credits

        #expect(credits.string == """
        Lead designer & developer
        Nigel M. Warren: https://nigelwarren.com

        Third-Party Resources
        Sparkle: https://sparkle-project.org/
        yt-dlp: https://github.com/yt-dlp/yt-dlp
        """)

        let expectedLinks: [(label: String, destination: String)] = [
            ("https://nigelwarren.com", "https://nigelwarren.com"),
            ("https://sparkle-project.org/", "https://sparkle-project.org/"),
            ("https://github.com/yt-dlp/yt-dlp", "https://github.com/yt-dlp/yt-dlp")
        ]

        for (label, destination) in expectedLinks {
            let range = try #require(credits.string.range(of: label))
            let linkValue = credits.attribute(.link, at: NSRange(range, in: credits.string).location, effectiveRange: nil)
            let url = try #require(linkValue as? URL)

            #expect(url.absoluteString == destination)
        }
    }

    @Test
    @MainActor
    func ytdlpUpdateStateFormatsCadenceAndLastCheckedDate() {
        let installedAt = Date(timeIntervalSince1970: 100)
        let lastCheckedAt = Date(timeIntervalSince1970: 200)
        let updater = StubYTDLPUpdater(status: YTDLPManagedToolStatus(
            version: "2026.07.04",
            channel: YTDLPManager.stableChannel,
            installedAt: installedAt,
            lastCheckedAt: lastCheckedAt,
            executableURL: URL(fileURLWithPath: "/tmp/yt-dlp_macos")
        ))
        let state = YTDLPUpdateState(updater: updater)

        #expect(state.cadenceDescription == "Weekly")
        #expect(state.lastCheckedDescription == "Last checked \(lastCheckedAt.formatted(date: .abbreviated, time: .shortened))")
    }

    @Test
    @MainActor
    func ytdlpUpdateStateShowsEmptyLastCheckedDate() {
        let state = YTDLPUpdateState(updater: StubYTDLPUpdater(status: nil))

        #expect(state.lastCheckedDescription == "Not checked yet")
    }

    @Test
    @MainActor
    func ytdlpUpdateStateUpdateNowRefreshesStatusAfterSuccess() async {
        let installedAt = Date(timeIntervalSince1970: 100)
        let lastCheckedAt = Date(timeIntervalSince1970: 200)
        let updatedStatus = YTDLPManagedToolStatus(
            version: "2026.07.11",
            channel: YTDLPManager.stableChannel,
            installedAt: installedAt,
            lastCheckedAt: lastCheckedAt,
            executableURL: URL(fileURLWithPath: "/tmp/yt-dlp_macos")
        )
        let updater = StubYTDLPUpdater(status: nil, updatedStatus: updatedStatus)
        let state = YTDLPUpdateState(updater: updater)

        await state.performUpdateNow()

        #expect(updater.updateCallCount == 1)
        #expect(state.toolStatus == updatedStatus)
        #expect(state.updateAlert == .upToDate(version: "2026.07.11"))
        #expect(state.updateAlert?.title == "You're up to date!")
        #expect(state.updateAlert?.message == "yt-dlp 2026.07.11 is currently the newest version available.")
        #expect(!state.isUpdating)
    }

    @Test
    @MainActor
    func ytdlpUpdateStateUpdateNowUsesFriendlyFailureMessage() async {
        let updater = StubYTDLPUpdater(
            status: nil,
            updateError: StreamingTrackImportError.downloaderUnavailable
        )
        let state = YTDLPUpdateState(updater: updater)

        await state.performUpdateNow()

        #expect(updater.updateCallCount == 1)
        #expect(state.updateAlert == .failed)
        #expect(state.updateAlert?.title == "Could Not Update yt-dlp")
        #expect(state.updateAlert?.message == "Check your connection and try again.")
        #expect(!state.isUpdating)
    }

    @Test
    @MainActor
    func cancellingStreamingTrackDuringMetadataAddsNoTrackOrFailureStatus() async throws {
        let statusRecorder = StreamingStatusRecorder()
        let controller = PlaybackController(
            streamingTrackResolver: DelayedStreamingTrackResolver(delay: .seconds(10)),
            ytdlpManager: StubYTDLPManager(url: URL(fileURLWithPath: "/usr/local/bin/yt-dlp"))
        )

        let task = Task {
            await controller.loadStreamingTrack(
                from: "https://open.spotify.com/track/example",
                statusHandler: { status in
                    await statusRecorder.record(status)
                }
            )
        }

        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let didLoad = await task.value
        let statuses = await statusRecorder.statuses()

        #expect(!didLoad)
        #expect(controller.displayedTrackRowCount == 0)
        #expect(!statuses.contains { $0.isFailed })
    }

    @Test
    func infoPlistDeclaresAudioAndFolderDocumentSupportForAppIconDrops() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Config")
            .appending(path: "Takes-Info.plist")

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
    func infoPlistDeclaresTakesAutomationURLScheme() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Config")
            .appending(path: "Takes-Info.plist")

        let data = try Data(contentsOf: plistURL)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let urlTypes = try #require(plist["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = urlTypes.flatMap { urlType in
            urlType["CFBundleURLSchemes"] as? [String] ?? []
        }

        #expect(schemes.contains("takes"))
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
        #expect(controller.playbackError?.localizedDescription.contains("missing-second.wav: The file could not be opened.") == true)
        #expect(controller.playbackError?.localizedDescription.contains("missing-second.wav: Could not open file: missing-second.wav") == false)
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
        #expect(controller.playbackError?.localizedDescription.contains("Takes currently supports up to 32 loaded tracks.") == true)
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
        #expect(controller.playbackError?.localizedDescription.contains("Takes currently supports up to 32 loaded tracks.") == true)
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
    func numericTrackHotkeyNineSelectsNinthTrack() async throws {
        let urls = try (0..<10).map { try makeTemporaryAudioFile(name: "track-\($0).wav") }
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
    func numericTrackHotkeyZeroSelectsLastTrack() async throws {
        let urls = try (0..<3).map { try makeTemporaryAudioFile(name: "track-\($0).wav") }
        defer {
            for url in urls {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }

        let controller = PlaybackController()
        await controller.loadImportedFiles(urls)

        let ids = controller.session.tracks.map(\.id)

        controller.selectTrackForHotkey(0)
        #expect(controller.session.activeTrackID == ids[2])
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
    func enablingBlindListeningModeShufflesVisibleOrderAndSelectsFirstTrack() async throws {
        let urls = try (0..<3).map { try makeTemporaryAudioFile(name: "blind-\($0).wav") }
        defer {
            for url in urls {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }

        let controller = PlaybackController()
        await controller.loadImportedFiles(urls)
        let ids = controller.session.tracks.map(\.id)
        controller.selectActiveTrack(ids[1])
        controller.seek(to: 0.5)

        controller.setBlindListeningMode(true) { tracks in
            [tracks[2], tracks[1], tracks[0]]
        }

        #expect(controller.session.isBlindListeningModeEnabled)
        #expect(controller.session.tracks.map(\.id) == [ids[2], ids[1], ids[0]])
        #expect(controller.session.activeTrackID == ids[2])
        #expect(controller.session.transportPosition == 0.5)
    }

    @MainActor
    @Test
    func disablingBlindListeningModeKeepsShuffledOrder() async throws {
        let urls = try (0..<3).map { try makeTemporaryAudioFile(name: "blind-off-\($0).wav") }
        defer {
            for url in urls {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }

        let controller = PlaybackController()
        await controller.loadImportedFiles(urls)
        let ids = controller.session.tracks.map(\.id)

        controller.setBlindListeningMode(true) { tracks in
            [tracks[1], tracks[2], tracks[0]]
        }
        controller.setBlindListeningMode(false)

        #expect(!controller.session.isBlindListeningModeEnabled)
        #expect(controller.session.tracks.map(\.id) == [ids[1], ids[2], ids[0]])
    }

    @MainActor
    @Test
    func blindListeningModeFallbackChangesOrderWhenShuffleReturnsSameOrder() async throws {
        let urls = try (0..<3).map { try makeTemporaryAudioFile(name: "blind-same-\($0).wav") }
        defer {
            for url in urls {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }

        let controller = PlaybackController()
        await controller.loadImportedFiles(urls)
        let ids = controller.session.tracks.map(\.id)

        controller.setBlindListeningMode(true) { $0 }

        #expect(controller.session.tracks.map(\.id) == [ids[1], ids[2], ids[0]])
    }

    @MainActor
    @Test
    func preEnabledBlindListeningModeShufflesTracksAfterLoad() async throws {
        let urls = try (0..<3).map { try makeTemporaryAudioFile(name: "blind-preload-\($0).wav") }
        defer {
            for url in urls {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }

        let controller = PlaybackController()
        controller.setBlindListeningMode(true)

        await controller.loadImportedFiles(urls) { tracks in
            [tracks[2], tracks[0], tracks[1]]
        }

        #expect(controller.session.isBlindListeningModeEnabled)
        #expect(controller.session.tracks.map { $0.loadedTrack.displayName } == [
            "blind-preload-2.wav",
            "blind-preload-0.wav",
            "blind-preload-1.wav"
        ])
        #expect(controller.session.activeTrackID == controller.session.tracks[0].id)
    }

    @MainActor
    @Test
    func removingActiveTrackKeepsPlayingAndSelectsNextOrPrevious() async throws {
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

        #expect(controller.session.isPlaying)
        #expect(controller.session.activeTrackID == ids[2])

        controller.removeTrack(ids[2])

        #expect(controller.session.isPlaying)
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
    func settingUnchangedOffsetWhilePlayingDoesNotRestartPlaybackClock() async throws {
        let url = try makeTemporaryAudioFile(name: "unchanged-offset.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let controller = PlaybackController()
        await controller.loadImportedFiles([url])
        let id = try #require(controller.session.tracks.first?.id)
        controller.play()

        try await Task.sleep(for: .milliseconds(120))
        controller.setOffset(id, seconds: 0)
        try await Task.sleep(for: .milliseconds(120))
        controller.pause()

        #expect(controller.session.transportPosition >= 0.2)
    }

    @MainActor
    @Test
    func settingOffsetWhilePlayingReschedulesFromCurrentTransport() async throws {
        let url = try makeTemporaryAudioFile(name: "changed-offset.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let controller = PlaybackController()
        await controller.loadImportedFiles([url])
        let id = try #require(controller.session.tracks.first?.id)
        controller.play()

        try await Task.sleep(for: .milliseconds(120))
        controller.setOffset(id, seconds: 0.1)

        #expect(controller.session.transportPosition >= 0.1)
        controller.pause()
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
    func importedFilesAppendWhilePausedPreservesPlayheadPosition() async throws {
        let first = try makeTemporaryAudioFile(name: "paused-first.wav")
        let second = try makeTemporaryAudioFile(name: "paused-second.wav")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }

        let controller = PlaybackController()
        await controller.loadImportedFiles([first])
        controller.seek(to: 0.5)

        await controller.loadImportedFiles([second])

        #expect(controller.session.isPlaying == false)
        #expect(controller.session.transportPosition == 0.5)
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

    @MainActor
    @Test
    func audioEngineConfigurationChangeReschedulesWhilePlaying() async throws {
        let url = try makeTemporaryAudioFile(name: "device-change.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let controller = PlaybackController()
        await controller.loadImportedFiles([url])
        controller.play()
        controller.seek(to: 0.35)

        controller.handleAudioEngineConfigurationChange()

        #expect(controller.session.isPlaying == true)
        #expect(controller.session.transportPosition >= 0.35)
        #expect(controller.playbackError == nil)
        controller.pause()
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

    @MainActor
    @Test
    func beginLoopForcesSwitchAndRepeatAndMovesPlayheadToStart() async throws {
        let url = try makeTemporaryAudioFile(name: "loop.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = PlaybackController()
        await controller.loadImportedFiles([url])

        controller.beginLoop(LoopRegion(start: 0.2, end: 0.5))

        #expect(controller.session.loopRegion == LoopRegion(start: 0.2, end: 0.5))
        #expect(controller.session.repeatMode == .switchAndRepeat)
        #expect(abs(controller.session.transportPosition - 0.2) < 0.0001)
    }

    @MainActor
    @Test
    func creatingLoopAroundPausedPlayheadKeepsPlaybackPosition() async throws {
        let url = try makeTemporaryAudioFile(name: "loop-paused-playhead.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = PlaybackController()
        await controller.loadImportedFiles([url])

        controller.seek(to: 0.4)

        controller.beginLoop(LoopRegion(start: 0.3, end: 0.8))

        #expect(!controller.session.isPlaying)
        #expect(controller.session.loopRegion == LoopRegion(start: 0.3, end: 0.8))
        #expect(controller.session.repeatMode == .switchAndRepeat)
        #expect(abs(controller.session.transportPosition - 0.4) < 0.0001)
    }

    @MainActor
    @Test
    func replacingActiveLoopAroundPlayingPlayheadKeepsPlaybackPosition() async throws {
        let url = try makeTemporaryAudioFile(name: "loop-replace-playhead.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = PlaybackController()
        await controller.loadImportedFiles([url])

        controller.beginLoop(LoopRegion(start: 0.1, end: 0.5))
        controller.seek(to: 0.4)
        controller.play()

        controller.beginLoop(LoopRegion(start: 0.3, end: 0.8))

        #expect(controller.session.isPlaying)
        #expect(controller.session.loopRegion == LoopRegion(start: 0.3, end: 0.8))
        #expect(controller.session.repeatMode == .switchAndRepeat)
        #expect(controller.session.transportPosition >= 0.4)
        #expect(controller.session.transportPosition < 0.8)
    }

    @MainActor
    @Test
    func deselectLoopTurnsRepeatOff() async throws {
        let url = try makeTemporaryAudioFile(name: "loop.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = PlaybackController()
        await controller.loadImportedFiles([url])

        controller.setRepeatMode(.one)
        controller.beginLoop(LoopRegion(start: 0.2, end: 0.5))
        controller.deselectLoop()

        #expect(controller.session.loopRegion == nil)
        #expect(controller.session.repeatMode == .off)
    }

    @MainActor
    @Test
    func deselectLoopWhilePlayingKeepsPlaybackRunning() async throws {
        let url = try makeTemporaryAudioFile(name: "loop-playing.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = PlaybackController()
        await controller.loadImportedFiles([url])

        controller.beginLoop(LoopRegion(start: 0.2, end: 0.8))
        controller.play()
        controller.deselectLoop()

        #expect(controller.session.isPlaying)
        #expect(controller.session.loopRegion == nil)
        #expect(controller.session.repeatMode == .off)
    }

    @MainActor
    @Test
    func zoomToFitShowsFullTimeline() async throws {
        let url = try makeTemporaryAudioFile(name: "zoom-fit.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = PlaybackController()
        await controller.loadImportedFiles([url])
        controller.zoomVisibleSpan(to: TimelineViewport.minimumVisibleSpan)

        controller.zoomToFit()

        #expect(abs(controller.visibleStart - controller.session.timelineStart) < 0.0001)
        #expect(abs(controller.visibleSpan - controller.session.duration) < 0.0001)
    }

    @MainActor
    @Test
    func zoomToSelectionShowsLoopRegion() async throws {
        let url = try makeTemporaryAudioFile(name: "zoom-selection.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = PlaybackController()
        await controller.loadImportedFiles([url])
        controller.beginLoop(LoopRegion(start: 0.2, end: 0.8))

        controller.zoomToSelection()

        #expect(abs(controller.visibleStart - 0.2) < 0.0001)
        #expect(abs(controller.visibleSpan - 0.6) < 0.0001)
    }

    @MainActor
    @Test
    func zoomToSelectionLeavesViewportUnchangedWithoutLoopRegion() async throws {
        let url = try makeTemporaryAudioFile(name: "zoom-no-selection.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = PlaybackController()
        await controller.loadImportedFiles([url])
        controller.zoomVisibleSpan(to: TimelineViewport.minimumVisibleSpan)
        let visibleStart = controller.visibleStart
        let visibleSpan = controller.visibleSpan

        controller.zoomToSelection()

        #expect(controller.visibleStart == visibleStart)
        #expect(controller.visibleSpan == visibleSpan)
    }

    @MainActor
    @Test
    func playFromEndRewindsToStart() async throws {
        let url = try makeTemporaryAudioFile(name: "loop.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = PlaybackController()
        await controller.loadImportedFiles([url])

        controller.seek(to: controller.session.timelineEnd)
        #expect(controller.session.transportPosition == controller.session.timelineEnd)

        controller.play()
        #expect(controller.session.transportPosition < 0.01)
        controller.pause()
    }

    @MainActor
    @Test
    func seekClampsWithinActiveLoop() async throws {
        let url = try makeTemporaryAudioFile(name: "loop.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = PlaybackController()
        await controller.loadImportedFiles([url])

        controller.beginLoop(LoopRegion(start: 0.2, end: 0.5))
        controller.seek(to: 0.9)
        #expect(abs(controller.session.transportPosition - 0.5) < 0.0001)
        controller.seek(to: 0.0)
        #expect(abs(controller.session.transportPosition - 0.2) < 0.0001)
    }

    @MainActor
    @Test
    func clearingTracksDropsLoopAndTurnsRepeatOff() async throws {
        let url = try makeTemporaryAudioFile(name: "loop.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = PlaybackController()
        await controller.loadImportedFiles([url])

        controller.setRepeatMode(.one)
        controller.beginLoop(LoopRegion(start: 0.2, end: 0.5))
        controller.clearTracks()

        #expect(controller.session.loopRegion == nil)
        #expect(controller.session.repeatMode == .off)
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
        #expect(offsetConfig.steppedValue(from: 0, direction: 1, largeStep: false) == 100)
        #expect(offsetConfig.steppedValue(from: 0, direction: -1, largeStep: true) == -500)
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

        #expect(offsetConfig.steppedValue(fromText: "20", fallbackValue: 0, direction: 1, largeStep: false) == 120)
        #expect(offsetConfig.steppedValue(fromText: "30", fallbackValue: 0, direction: 1, largeStep: true) == 530)
        #expect(offsetConfig.steppedValue(fromText: "530", fallbackValue: 0, direction: -1, largeStep: true) == 30)
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
    func switchTrackButtonTreatsShiftModifierAsPreviousTrack() {
        #expect(SwitchTrackModifierPolicy.selectsPreviousTrack(currentEventFlags: [], fallbackFlags: []) == false)
        #expect(SwitchTrackModifierPolicy.selectsPreviousTrack(currentEventFlags: .shift, fallbackFlags: []) == true)
        #expect(SwitchTrackModifierPolicy.selectsPreviousTrack(currentEventFlags: [], fallbackFlags: .shift) == true)
        #expect(SwitchTrackModifierPolicy.selectsPreviousTrack(currentEventFlags: [.command, .shift], fallbackFlags: []) == true)
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

        #expect(stepped == 520)
        #expect(editState.committedValue == 520)
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

        #expect(stepped == 120)
        #expect(editState.committedValue == 120)
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
    func cursorResetPolicyRestoresArrowOnlyOutsideTextInputs() {
        let container = NSView(frame: .zero)
        let textField = NSTextField(frame: .zero)
        container.addSubview(textField)
        let button = NSButton(frame: .zero)
        container.addSubview(button)

        #expect(CursorResetPolicy.shouldUseArrowCursor(currentCursor: NSCursor.iBeam, hitView: button) == true)
        #expect(CursorResetPolicy.shouldUseArrowCursor(currentCursor: NSCursor.iBeam, hitView: textField) == false)
        #expect(CursorResetPolicy.shouldUseArrowCursor(currentCursor: NSCursor.iBeam, hitView: nil) == true)
        #expect(CursorResetPolicy.shouldUseArrowCursor(currentCursor: NSCursor.arrow, hitView: button) == false)
        #expect(CursorResetPolicy.shouldUseArrowCursor(currentCursor: NSCursor.resizeLeftRight, hitView: button) == false)
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
        #expect(TrackNumberHotkey.hotkey(forKeyCode: 29, modifierFlags: []) == 0)
        #expect(TrackNumberHotkey.hotkey(forKeyCode: 83, modifierFlags: []) == 1)
        #expect(TrackNumberHotkey.hotkey(forKeyCode: 91, modifierFlags: []) == 8)
        #expect(TrackNumberHotkey.hotkey(forKeyCode: 92, modifierFlags: []) == 9)
        #expect(TrackNumberHotkey.hotkey(forKeyCode: 82, modifierFlags: []) == 0)
    }

    @Test
    func trackNumberHotkeyIgnoresModifiedNumberKeys() {
        #expect(TrackNumberHotkey.hotkey(forKeyCode: 18, modifierFlags: .shift) == nil)
        #expect(TrackNumberHotkey.hotkey(forKeyCode: 18, modifierFlags: .command) == nil)
        #expect(TrackNumberHotkey.hotkey(forKeyCode: 18, modifierFlags: .control) == nil)
        #expect(TrackNumberHotkey.hotkey(forKeyCode: 18, modifierFlags: .option) == nil)
        #expect(TrackNumberHotkey.hotkey(forKeyCode: 29, modifierFlags: .shift) == nil)
    }

    @Test
    func trackSwitchArrowHotkeyMapsPlainUpAndDownArrows() {
        #expect(TrackSwitchArrowHotkey.direction(forKeyCode: 126, modifierFlags: []) == .previous)
        #expect(TrackSwitchArrowHotkey.direction(forKeyCode: 125, modifierFlags: []) == .next)
    }

    @Test
    func trackSwitchArrowHotkeyIgnoresModifiedAndHorizontalArrows() {
        #expect(TrackSwitchArrowHotkey.direction(forKeyCode: 126, modifierFlags: .shift) == nil)
        #expect(TrackSwitchArrowHotkey.direction(forKeyCode: 126, modifierFlags: .command) == nil)
        #expect(TrackSwitchArrowHotkey.direction(forKeyCode: 126, modifierFlags: .control) == nil)
        #expect(TrackSwitchArrowHotkey.direction(forKeyCode: 126, modifierFlags: .option) == nil)
        #expect(TrackSwitchArrowHotkey.direction(forKeyCode: 123, modifierFlags: []) == nil)
        #expect(TrackSwitchArrowHotkey.direction(forKeyCode: 124, modifierFlags: []) == nil)
    }

    private func makeTrack(name: String) -> LoadedTrack {
        LoadedTrack(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            displayName: name,
            fileFormatDescription: "WAV",
            duration: 120,
            sampleRate: 44_100,
            channelCount: 2,
            bitRate: 256_000,
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

    func loadTrackMetadata(from url: URL) async throws -> LoadedTrack {
        if failingURLs.contains(url) {
            throw PlaybackError.failedToOpenFile(url)
        }
        if delayedMetadataURLs.contains(url) {
            try await Task.sleep(for: .seconds(metadataDelay))
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

private final class InMemoryAppSettingsDefaults: AppSettingsDefaults {
    private var values: [String: Any] = [:]

    func object(forKey defaultName: String) -> Any? {
        values[defaultName]
    }

    func string(forKey defaultName: String) -> String? {
        values[defaultName] as? String
    }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }
}

private final class StubYTDLPUpdater: YTDLPUpdating, @unchecked Sendable {
    private(set) var updateCallCount = 0
    private var status: YTDLPManagedToolStatus?
    private let updatedStatus: YTDLPManagedToolStatus?
    private let updateError: Error?

    init(
        status: YTDLPManagedToolStatus?,
        updatedStatus: YTDLPManagedToolStatus? = nil,
        updateError: Error? = nil
    ) {
        self.status = status
        self.updatedStatus = updatedStatus
        self.updateError = updateError
    }

    func managedToolStatus() -> YTDLPManagedToolStatus? {
        status
    }

    func updateManagedExecutableNow() async throws -> URL {
        updateCallCount += 1
        if let updateError {
            throw updateError
        }
        if let updatedStatus {
            status = updatedStatus
        }
        return status?.executableURL ?? URL(fileURLWithPath: "/tmp/yt-dlp_macos")
    }
}

private struct StubYTDLPManager: YTDLPManaging {
    let url: URL

    func executableURL() async throws -> URL {
        url
    }
}

private struct DelayedStreamingTrackResolver: StreamingTrackResolving {
    let delay: Duration

    func resolveYouTubeMatch(
        for sourceURL: URL,
        using downloaderURL: URL,
        statusHandler: @escaping @Sendable (StreamingURLPromptStatus) async -> Void
    ) async throws -> StreamingYouTubeMatch {
        try await Task.sleep(for: delay)
        return StreamingYouTubeMatch(
            url: URL(string: "https://www.youtube.com/watch?v=XPL_qGqSJxA")!,
            title: "Example",
            confidence: 1,
            downloadFilenameBase: "Example"
        )
    }
}

private actor StreamingStatusRecorder {
    private var recordedStatuses: [StreamingURLPromptStatus] = []

    func record(_ status: StreamingURLPromptStatus) {
        recordedStatuses.append(status)
    }

    func statuses() -> [StreamingURLPromptStatus] {
        recordedStatuses
    }
}
