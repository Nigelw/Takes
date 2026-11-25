import AVFoundation
import AppKit
import Foundation
import Testing
@testable import Takes

struct SessionTests {
    @MainActor
    @Test
    func automaticGroupingModeDefaultsPersistsAndRecoversFromInvalidStorage() {
        let defaults = InMemoryAppSettingsDefaults()
        let settings = AppSettings(defaults: defaults)

        #expect(settings.automaticGroupingMode == .automatic)
        settings.automaticGroupingMode = .off
        #expect(defaults.string(forKey: AppSettings.automaticGroupingModeKey) == "off")
        #expect(AppSettings.storedAutomaticGroupingMode(defaults) == .off)

        defaults.set("samePerformance", forKey: AppSettings.automaticGroupingModeKey)
        #expect(AppSettings.storedAutomaticGroupingMode(defaults) == .automatic)

        defaults.set("unsupported", forKey: AppSettings.automaticGroupingModeKey)
        #expect(AppSettings.storedAutomaticGroupingMode(defaults) == .automatic)
        settings.restoreDefaults()
        #expect(settings.automaticGroupingMode == .automatic)
    }

    @MainActor
    @Test
    func playlistMetadataFieldsPersistAndRestoreDefaults() {
        let defaults = InMemoryAppSettingsDefaults()
        let settings = AppSettings(defaults: defaults)

        #expect(settings.playlistMetadataFields == [.artist])
        settings.playlistMetadataFields = [.album, .sampleRate]
        #expect(AppSettings(defaults: defaults).playlistMetadataFields == [.album, .sampleRate])
        #expect(!settings.settingsAreDefault)

        settings.playlistMetadataFields = []
        #expect(AppSettings(defaults: defaults).playlistMetadataFields.isEmpty)

        settings.restoreDefaults()
        #expect(settings.settingsAreDefault)
        #expect(AppSettings(defaults: defaults).playlistMetadataFields == [.artist])
    }

    @MainActor
    @Test
    func compareMetadataFieldsPersistIndependentlyAndRestoreDefaults() {
        let defaults = InMemoryAppSettingsDefaults()
        let settings = AppSettings(defaults: defaults)

        #expect(settings.compareMetadataFields == [.format, .sampleRate, .bitrate])
        settings.compareMetadataFields = [.sampleRate]
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.compareMetadataFields == [.sampleRate])
        #expect(reloaded.playlistMetadataFields == [.artist])
        #expect(!settings.settingsAreDefault)

        settings.compareMetadataFields = []
        #expect(AppSettings(defaults: defaults).compareMetadataFields.isEmpty)
        settings.restoreDefaults()
        #expect(settings.settingsAreDefault)
        #expect(AppSettings(defaults: defaults).compareMetadataFields == [.format, .sampleRate, .bitrate])
    }

    /// The control bar theme and readout frame settings were removed with
    /// the Teenage Engineering theme and the Retro frame; preferences that
    /// still hold them must load as defaults.
    @MainActor
    @Test
    func retiredControlBarPreferencesLoadAsDefaults() {
        let defaults = InMemoryAppSettingsDefaults()
        defaults.set("teenageEngineering", forKey: "controlBarTheme")
        defaults.set("retro", forKey: "readoutStyle")
        let settings = AppSettings(defaults: defaults)

        #expect(settings.settingsAreDefault)
    }

    @Test
    func playlistReadoutTitleUsesTheVersionTagThenItsFilename() {
        var version = PlaylistVersion(
            file: PlaylistFileReference(storedURL: URL(fileURLWithPath: "/tmp/01 Taxman (Mono).flac")),
            metadata: PlaylistMetadata(title: "Taxman (1967 Mono Mix)", displayName: "Display Name")
        )
        #expect(ControlBarReadoutTitle.playlist(version) == "Taxman (1967 Mono Mix)")

        version.metadata.title = "  "
        #expect(ControlBarReadoutTitle.playlist(version) == "01 Taxman (Mono)")

        version.metadata.title = nil
        #expect(ControlBarReadoutTitle.playlist(version) == "01 Taxman (Mono)")
        #expect(ControlBarReadoutTitle.playlist(nil) == "")
    }

    @MainActor
    @Test
    func marqueeOnlyRunsOnItsOwnKeyWindowClock() throws {
        let frame = NSRect(x: 0, y: 0, width: 120, height: 20)
        let first = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let marquee = DotMatrixMarqueeView(frame: frame)
        first.contentView = marquee
        marquee.configure(text: "A long scrolling title", columns: 5, metrics: ControlBarReadoutLine.titleMetrics,
                          sharedPeriod: nil, reduceMotion: false)
        let bitmap = try #require(marquee.layer?.sublayers?.first { $0.animation(forKey: "marquee") != nil })
        let center = NotificationCenter.default
        #expect(bitmap.speed == 0)
        center.post(name: NSWindow.didBecomeKeyNotification, object: second)
        #expect(bitmap.speed == 0)
        center.post(name: NSWindow.didBecomeKeyNotification, object: first)
        #expect(bitmap.speed == 1)
        center.post(name: NSWindow.didResignKeyNotification, object: first)
        let now = CACurrentMediaTime()
        #expect(bitmap.convertTime(now, from: nil) == bitmap.convertTime(now + 1, from: nil))
        second.contentView = marquee
        center.post(name: NSWindow.didBecomeKeyNotification, object: first)
        #expect(bitmap.speed == 0)
        center.post(name: NSWindow.didBecomeKeyNotification, object: second)
        #expect(bitmap.speed == 1)
    }

    @MainActor
    @Test
    func playlistVersionTitleFollowsAppearanceAfterConfiguration() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        let cell = PlaylistVersionCellView()

        light.performAsCurrentDrawingAppearance {
            cell.configure(title: "Alternate Mix", format: "FLAC", duration: "2:41", mark: .none, toolTip: "")
        }
        let titleColor = try #require(cell.textField?.textColor)

        for appearance in [light, dark] {
            appearance.performAsCurrentDrawingAppearance {
                #expect(titleColor.usingColorSpace(.sRGB) == NSColor.labelColor.usingColorSpace(.sRGB))
            }
        }
    }

    /// The title face sits just under the elapsed digits (canvas: 16 px
    /// Doto beside 14 pt digits), and the playlist readout starts its first
    /// dot row on a whole point.
    @Test
    func readoutTitleFaceMatchesTheDigitsAndSitsOnThePixelGrid() {
        let metrics = ControlBarReadoutLine.titleMetrics
        #expect(metrics.lineHeight == 13)
        #expect(metrics.lineHeight < ControlBarReadoutLine.digitHeight)
        #expect(metrics.cellAdvance == 11)

        let inset = PlaylistControlBarReadout.contentTopInset
        let titleTop = inset + ControlBarReadoutLine.digitHeight - metrics.lineHeight
        #expect(titleTop == titleTop.rounded())
        #expect(titleTop == 9)
    }

    /// The playlist readout keeps 8 pt above the digits, 6 pt to the meter
    /// and 8 pt below it, with every edge on a whole point: the digits, the
    /// title on their bottom edge, and the meter.
    @Test
    func playlistReadoutSpacingSitsOnWholePoints() {
        let readout = PlaylistControlBarReadout.self
        let digitsTop = readout.contentTopInset
        let digitsBottom = digitsTop + ControlBarReadoutLine.digitHeight
        let titleTop = digitsBottom - ControlBarReadoutLine.titleMetrics.lineHeight
        let meterTop = digitsTop + ControlBarReadoutLine.height + readout.lineSpacing
        let meterBottom = meterTop + readout.meterHeight

        #expect(readout.height == 41)
        #expect(ControlBarReadoutLine.height == ControlBarReadoutLine.digitHeight)
        #expect(digitsTop == 8)
        #expect(meterTop - digitsBottom == 6)
        #expect(readout.height - meterBottom == 8)
        for edge in [digitsTop, titleTop, meterTop] {
            #expect(edge == edge.rounded())
        }
    }

    // MARK: A2 compare info bar

    /// Compare's control bar ends 10 pt under the transport row (no
    /// readout), so it is 51 pt shorter than the playlist's, whose readout
    /// keeps 10 + 41 + 10 pt below the row.
    @MainActor
    @Test
    func compareControlBarEndsUnderTheTransportRow() {
        let transportRow = ControlBarMetrics.primaryDiameter
        #expect(ControlBarMetrics.transportRowBottomPadding == 10)
        #expect(TakesWindowPolicy.compareControlBarHeight(showsArtwork: true)
            == TakesWindowPolicy.controlBarTopPadding(showsArtwork: true) + transportRow
                + ControlBarMetrics.transportRowBottomPadding + ControlBarDivider.height)
        #expect(TakesWindowPolicy.compareControlBarHeight(showsArtwork: true) == 79)
        #expect(TakesWindowPolicy.compareControlBarHeight(showsArtwork: false) == 91)

        #expect(ControlBarMetrics.readoutTopSpacing == 10)
        #expect(ControlBarMetrics.readoutBottomPadding == 10)
        let playlistBelowRow = ControlBarMetrics.readoutTopSpacing + PlaylistControlBarReadout.height
            + ControlBarMetrics.readoutBottomPadding
        #expect(playlistBelowRow == 61)
        #expect(playlistBelowRow - ControlBarMetrics.transportRowBottomPadding == 51)
    }

    /// Below the divider, the 32 pt info bar replaces the 30 pt readout and
    /// its 12 pt gap above the divider, so the ruler starts 10 pt higher.
    @MainActor
    @Test
    func compareInfoBarGeometry() {
        #expect(CompareInfoBarMetrics.height == 32)
        #expect(CompareInfoBarMetrics.edgeInset == 10)
        #expect(CompareInfoBarTime.height == 24)
        #expect(CompareInfoBarTime.cornerRadius == 6)
        #expect(CompareInfoBarTime.horizontalPadding == 9)
        #expect(CompareDoneButtonStyle.height == 22)
        #expect(CompareDoneButtonStyle.cornerRadius == 5)
        #expect(CompareDoneButtonStyle.horizontalPadding == 12)
        // The old row (10 + 30 pt readout + 12) gives way to 10 above the
        // divider and the info bar below it: the ruler starts 10 pt higher.
        let oldBelowRow: CGFloat = 10 + 30 + 12
        #expect(oldBelowRow - (ControlBarMetrics.transportRowBottomPadding + CompareInfoBarMetrics.height) == 10)

        // The centre column stays centred: both sides get the same width.
        let side = CompareInfoBarRow.sideWidth(barWidth: 340, centerWidth: 60)
        #expect(side == 140 - CompareInfoBarRow.columnSpacing)
        #expect(side * 2 + 60 + CompareInfoBarRow.columnSpacing * 2 == 340)
        #expect(CompareInfoBarRow.sideWidth(barWidth: 40, centerWidth: 60) == 0)
        let narrowBar = TakesWindowPolicy.minimumWidth - 2 * CompareInfoBarMetrics.edgeInset
        let availableClockWidth = CompareInfoBarRow.centerWidth(barWidth: narrowBar, sideWidth: 56)
        #expect(CompareInfoBarRow.sideWidth(barWidth: narrowBar, centerWidth: availableClockWidth) == 56)
        #expect(availableClockWidth < SevenSegmentDisplay.width(of: "-123:45:56", digitHeight: 14) + 18)
    }

    @Test
    func compareTakeCountIsSingularForOneTake() {
        #expect(CompareInfoBarText.takeCount(1) == "1 take")
        #expect(CompareInfoBarText.takeCount(2) == "2 takes")
        #expect(CompareInfoBarText.takeCount(32) == "32 takes")
    }

    /// The ruler labels' digits start level with their major notch's top,
    /// 2 pt below the ruler's top, and end inside the ruler. The playhead
    /// grabber may overlap them.
    @Test
    func rulerLabelTopsAlignWithTheMajorNotches() {
        #expect(TimelineRulerMetrics.majorTickTop == 2)
        let glyphs = TimelineRulerMetrics.labelGlyphBand()
        #expect(abs(glyphs.lowerBound - TimelineRulerMetrics.majorTickTop) < 0.0001)
        #expect(glyphs.upperBound <= CompareLaneLayout.rulerHeight)
        #expect(TimelineRulerMetrics.labelTopInset > 0)
        #expect(TimelineRulerMetrics.labelTopInset < 1)
    }

    @MainActor
    @Test
    func playlistMeterHasAboutEightyCellsAndItsHeadCoversOnlyTheLeadingOne() {
        // A 360 pt window's readout (340 pt) less its 10 pt insets.
        let geometry = DotMatrixProgressView.barGeometry(
            width: 320, metrics: PlaylistControlBarReadout.meterMetrics,
            barHeight: PlaylistControlBarReadout.meterHeight, scale: 2
        )
        // No endcaps: every element is a cell, 80 across, as on the canvas.
        #expect(geometry.litRightEdges.count == 80)
        #expect(geometry.cellRects.count == 80)
        // 80 cells and 79 gaps make 319 pt, centred in the 320.
        #expect(geometry.cellRects.first?.minX == 0.5)
        #expect(geometry.cellRects.last?.maxX == 319.5)
        #expect(geometry.frameHeight == PlaylistControlBarReadout.meterHeight)

        for lit in 1...geometry.litRightEdges.count {
            let headRight = geometry.fillWidth(litCount: lit)
            let headLeft = headRight - geometry.headWidth
            #expect(headRight > geometry.litRightEdges[lit - 1])
            if lit >= 2 { #expect(headLeft >= geometry.litRightEdges[lit - 2]) }
            if lit < geometry.litRightEdges.count {
                // The next element starts more than a gap past this one's edge.
                #expect(headRight < geometry.litRightEdges[lit - 1] + geometry.gap)
            }
        }
    }

    /// The canvas's LED: unlit cells at 9% in dark (light's LCD keeps 22%),
    /// a 2 pt glow at 50% on the lit run and a 5 pt glow on the leading cell.
    /// The run's glow shows only lit cells' halos; the head's follows the
    /// leading cell and hides when nothing is lit.
    @MainActor
    @Test
    func playlistMeterGlowsLikeTheCanvasLED() {
        typealias View = DotMatrixProgressView
        #expect(View.unlitOpacity(isDark: true, hovered: false) == 0.09)
        #expect(View.unlitOpacity(isDark: true, hovered: true) > 0.09)
        #expect(View.unlitOpacity(isDark: false, hovered: false) == 0.22)
        #expect(View.GlowMetrics.runBlur == 2)
        #expect(View.GlowMetrics.runOpacity == 0.5)
        #expect(View.GlowMetrics.headBlur == 5)
        #expect(View.GlowMetrics.headOpacity == 1)

        let geometry = View.barGeometry(
            width: 320, metrics: PlaylistControlBarReadout.meterMetrics,
            barHeight: PlaylistControlBarReadout.meterHeight, scale: 2
        )
        let runBleed = View.GlowMetrics.bleed(blur: View.GlowMetrics.runBlur)
        let headBleed = View.GlowMetrics.bleed(blur: View.GlowMetrics.headBlur)
        #expect(View.runGlowClipWidth(geometry: geometry, litCount: 0) == 0)
        for lit in [1, 24, 80] {
            // The clip starts one bleed left of the bar and ends past the
            // last lit cell, before the next cell starts.
            let clipEnd = View.runGlowClipWidth(geometry: geometry, litCount: lit) - runBleed
            #expect(clipEnd > geometry.litRightEdges[lit - 1])
            if lit < 80 { #expect(clipEnd < geometry.cellRects[lit].minX) }
            // The head glow's image ends one bleed past the leading cell.
            #expect(View.headGlowX(geometry: geometry, litCount: lit) - headBleed * 2
                == geometry.litRightEdges[lit - 1])
        }
        #expect(View.headGlowX(geometry: geometry, litCount: 0) < -1000)

        let image = View.glowImage(
            cells: [CGRect(x: 10, y: 10, width: 3, height: 5)], size: CGSize(width: 23, height: 25),
            scale: 2, blur: 5, color: .cyan
        )
        #expect(image?.width == 46)
        #expect(image?.height == 50)
    }

    @Test
    func betaBuildsAreExcludedByDefault() {
        let defaults = InMemoryAppSettingsDefaults()

        #expect(!BetaUpdatePreference.includesBetaBuilds(in: defaults))
        #expect(BetaUpdatePreference.allowedSparkleChannels(in: defaults).isEmpty)
    }

    @Test
    func includingBetaBuildsAllowsTheBetaChannel() {
        let defaults = InMemoryAppSettingsDefaults()
        defaults.set(true, forKey: BetaUpdatePreference.key)

        #expect(BetaUpdatePreference.includesBetaBuilds(in: defaults))
        #expect(
            BetaUpdatePreference.allowedSparkleChannels(in: defaults)
                == [BetaUpdatePreference.betaChannel]
        )
    }

    @MainActor
    @Test
    func updateChannelDelegateFollowsTheStoredPreference() {
        let defaults = InMemoryAppSettingsDefaults()
        let delegate = UpdateChannelUpdaterDelegate(defaults: defaults)

        #expect(delegate.currentAllowedChannels().isEmpty)

        defaults.set(true, forKey: BetaUpdatePreference.key)
        #expect(delegate.currentAllowedChannels() == [BetaUpdatePreference.betaChannel])

        defaults.set(false, forKey: BetaUpdatePreference.key)
        #expect(delegate.currentAllowedChannels().isEmpty)
    }

    @Test
    func sessionReadinessUsesOrderedTracks() {
        var session = ComparisonSession()
        #expect(!session.isPlayable)
        #expect(!session.canSwitchPlayback)
        #expect(!session.canToggleBlindListeningMode)
        #expect(session.activeTrackID == nil)
        #expect(session.activeTrack == nil)

        let first = SessionTrack(loadedTrack: makeTrack(name: "a.wav"))
        session.tracks = [first]
        session.activeTrackID = first.id
        session.timelineEnd = 12

        #expect(session.isPlayable)
        #expect(!session.canSwitchPlayback)
        #expect(session.canToggleBlindListeningMode)
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
    func windowPolicyUsesTheA2SizesInBothArtworkStates() {
        #expect(TakesWindowPolicy.defaultSize(showsArtwork: true) == CGSize(width: 360, height: 760))
        #expect(TakesWindowPolicy.defaultSize(showsArtwork: false) == CGSize(width: 360, height: 412))
        #expect(TakesWindowPolicy.artworkCollapseHeight(coverHeight: 360) == 348)
        #expect(TakesWindowPolicy.controlBarTopPadding(showsArtwork: true) == 12)
        #expect(TakesWindowPolicy.controlBarTopPadding(showsArtwork: false) == 24)
    }

    @Test
    func windowPolicyMinimumsSitBelowTheDefaultsAndDifferByTheCover() {
        for showsArtwork in [true, false] {
            let minimum = TakesWindowPolicy.minimumSize(showsArtwork: showsArtwork)
            let defaultSize = TakesWindowPolicy.defaultSize(showsArtwork: showsArtwork)
            #expect(minimum.width == 260)
            #expect(minimum.height <= defaultSize.height)
        }
        #expect(
            TakesWindowPolicy.minimumHeight(showsArtwork: true) - TakesWindowPolicy.minimumHeight(showsArtwork: false)
                == TakesWindowPolicy.artworkCollapseHeight(coverHeight: TakesWindowPolicy.minimumWidth)
        )
    }

    @Test
    func windowPolicyDefaultsFrameToVisibleScreenTopLeft() {
        let visibleFrame = CGRect(x: 48, y: 80, width: 1200, height: 800)

        let defaultFrame = TakesWindowPolicy.defaultFrame(showsArtwork: true, visibleFrame: visibleFrame)

        #expect(defaultFrame.minX == visibleFrame.minX)
        #expect(defaultFrame.maxY == visibleFrame.maxY)
        #expect(defaultFrame.size == TakesWindowPolicy.defaultSize(showsArtwork: true))
    }

    @Test
    func windowPolicyHidingArtworkShrinksFromTheBottomKeepingWidthAndTopEdge() {
        let currentFrame = CGRect(x: 96, y: 100, width: 420, height: 900)
        let visibleFrame = CGRect(x: 0, y: 40, width: 1440, height: 1000)

        let hidden = TakesWindowPolicy.frameTogglingArtwork(
            currentFrame: currentFrame, showsArtwork: false, visibleFrame: visibleFrame
        )

        #expect(hidden.maxY == currentFrame.maxY)
        #expect(hidden.minX == currentFrame.minX)
        #expect(hidden.width == currentFrame.width)
        #expect(hidden.height == currentFrame.height - TakesWindowPolicy.artworkCollapseHeight(coverHeight: 420))

        let shown = TakesWindowPolicy.frameTogglingArtwork(
            currentFrame: hidden, showsArtwork: true, visibleFrame: visibleFrame
        )
        #expect(shown == currentFrame)
    }

    @Test
    func artworkRevealKeepsTransportAtTheSameDistanceFromTheWindowBottom() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let hidden = CGRect(x: 0, y: 488, width: 420, height: 412)
        var resize = TakesWindowPolicy.ArtworkResize(from: hidden, showsArtwork: true, visibleFrame: screen)
        #expect(resize.followsWindow)
        #expect(resize.coverHeight == 420)
        for height: CGFloat in [412, 500, 616, 690, 820] {
            let fraction = resize.fraction(at: height)
            let transportTop = resize.coverHeight * fraction + TakesWindowPolicy.controlBarTopPadding(artworkFraction: fraction)
            #expect(abs(height - transportTop - 388) < 0.001)
        }
        resize.showsArtwork = false
        #expect(resize.fraction(at: 616) == 0.5)
        #expect(resize.targetFrame == hidden)
    }

    @Test
    func artworkRevealStillTravelsFullyWhenTheWindowIsScreenClamped() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 700)
        let hidden = CGRect(x: 0, y: 100, width: 360, height: 600)
        var resize = TakesWindowPolicy.ArtworkResize(from: hidden, showsArtwork: true, visibleFrame: screen)
        #expect(!resize.followsWindow)
        #expect(resize.targetFrame.height == 700)
        #expect(resize.fraction(at: 700) == 1)
        resize.showsArtwork = false
        #expect(resize.targetFrame == hidden)
        #expect(resize.fraction(at: 600) == 0)
    }

    @Test
    func windowPolicyShowingArtworkNearTheScreenBottomMovesUpOnlyAsFarAsNeeded() {
        let visibleFrame = CGRect(x: 0, y: 40, width: 1440, height: 860)
        let currentFrame = CGRect(origin: CGPoint(x: 96, y: 100), size: TakesWindowPolicy.defaultSize(showsArtwork: false))

        let shown = TakesWindowPolicy.frameTogglingArtwork(
            currentFrame: currentFrame, showsArtwork: true, visibleFrame: visibleFrame
        )

        #expect(shown.height == 760)
        #expect(shown.minY == visibleFrame.minY)
        #expect(shown.maxY == visibleFrame.minY + 760)
    }

    @Test
    func windowPolicyCapsAFrameTallerThanTheScreen() {
        let visibleFrame = CGRect(x: 0, y: 40, width: 1440, height: 600)
        let currentFrame = CGRect(origin: CGPoint(x: 96, y: 200), size: TakesWindowPolicy.defaultSize(showsArtwork: false))

        let shown = TakesWindowPolicy.frameTogglingArtwork(
            currentFrame: currentFrame, showsArtwork: true, visibleFrame: visibleFrame
        )

        #expect(shown.height == visibleFrame.height)
        #expect(shown.minY == visibleFrame.minY)
    }

    @Test
    func artworkScalesWithWidthAndKeepsRoomForTheControls() {
        #expect(TakesWindowPolicy.artworkHeight(in: CGSize(width: 260, height: 530)) == 260)
        #expect(TakesWindowPolicy.artworkHeight(in: CGSize(width: 500, height: 800)) == 500)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 700)
        let shown = CGRect(x: 50, y: 0, width: 900, height: 700)
        #expect(TakesWindowPolicy.artworkHeight(in: shown.size) == 441)
        let hidden = TakesWindowPolicy.frameTogglingArtwork(
            currentFrame: shown, showsArtwork: false, visibleFrame: visibleFrame
        )
        #expect(hidden == CGRect(x: 50, y: 429, width: 900, height: 271))
    }

    @Test
    func windowPolicyHidingArtworkNeverGoesBelowTheHiddenMinimum() {
        let visibleFrame = CGRect(x: 0, y: 40, width: 1440, height: 1000)
        let currentFrame = CGRect(x: 96, y: 300, width: 360, height: 500)

        let hidden = TakesWindowPolicy.frameTogglingArtwork(
            currentFrame: currentFrame, showsArtwork: false, visibleFrame: visibleFrame
        )

        #expect(hidden.height == TakesWindowPolicy.minimumHeight(showsArtwork: false))
        #expect(hidden.maxY == currentFrame.maxY)
    }

    @Test
    func windowPolicyResetSizeUsesDefaultSizeWhilePreservingTopLeft() {
        let currentFrame = CGRect(x: 96, y: 100, width: 920, height: 700)
        let visibleFrame = CGRect(x: 0, y: 40, width: 1440, height: 1000)

        let resetFrame = TakesWindowPolicy.frameResettingSize(
            currentFrame: currentFrame, showsArtwork: false, visibleFrame: visibleFrame
        )

        #expect(resetFrame.minX == currentFrame.minX)
        #expect(resetFrame.maxY == currentFrame.maxY)
        #expect(resetFrame.size == TakesWindowPolicy.defaultSize(showsArtwork: false))
    }

    @Test
    func debugResetSizeUsesTheDefaultWidthAndTheGivenHeight() {
        let currentFrame = CGRect(x: 96, y: 100, width: 920, height: 700)
        let visibleFrame = CGRect(x: 0, y: 40, width: 1440, height: 1000)
        let resetFrame = TakesWindowPolicy.frameResettingSize(
            currentFrame: currentFrame, height: 760, visibleFrame: visibleFrame
        )
        #expect(resetFrame == CGRect(x: 96, y: 40, width: 360, height: 760))
    }

    @Test
    func compareTreatsMissingVersionsAsSilentLanes() {
        var missing = LoadedTrack(url: URL(fileURLWithPath: "/missing.flac"), displayName: "Missing",
                                  fileFormatDescription: "FLAC", duration: 10, sampleRate: 44100, channelCount: 2)
        missing.isMissing = true
        let present = LoadedTrack(url: URL(fileURLWithPath: "/present.flac"), displayName: "Present",
                                  fileFormatDescription: "FLAC", duration: 10, sampleRate: 44100, channelCount: 2)
        var session = ComparisonSession(tracks: [SessionTrack(loadedTrack: missing)], timelineStart: 0, timelineEnd: 10)
        #expect(!session.isPlayable)
        session.tracks.append(SessionTrack(loadedTrack: present))
        #expect(session.isPlayable)
        // The error band covers the track's extent, clamped to the lane.
        #expect(LaneWaveformRenderer.trackExtent(width: 200, trackStart: 0, trackDuration: 10,
                                                 visibleStart: 0, visibleSpan: 20) == 0...100)
        #expect(LaneWaveformRenderer.trackExtent(width: 200, trackStart: -5, trackDuration: 30,
                                                 visibleStart: 0, visibleSpan: 20) == -1...201)
        #expect(LaneWaveformRenderer.trackExtent(width: 200, trackStart: 30, trackDuration: 10,
                                                 visibleStart: 0, visibleSpan: 20) == nil)
    }

    @MainActor
    @Test
    func windowVisibilityPersistsAndSurvivesRestoreDefaults() {
        let defaults = InMemoryAppSettingsDefaults()
        let settings = AppSettings(defaults: defaults)

        #expect(settings.windowVisibility == WorkspaceVisibility())
        settings.windowVisibility.toggle(.artwork)
        settings.windowVisibility.toggle(.playlist)
        #expect(defaults.object(forKey: AppSettings.showsArtworkKey) as? Bool == false)
        #expect(defaults.object(forKey: AppSettings.showsPlayerKey) as? Bool == true)
        #expect(defaults.object(forKey: AppSettings.showsPlaylistKey) as? Bool == false)
        #expect(AppSettings(defaults: defaults).windowVisibility == settings.windowVisibility)

        let visibility = settings.windowVisibility
        settings.restoreDefaults()
        #expect(settings.windowVisibility == visibility)
        #expect(settings.settingsAreDefault)

        defaults.set(false, forKey: AppSettings.showsPlayerKey)
        #expect(AppSettings(defaults: defaults).windowVisibility == visibility)
    }

    @Test
    func windowVisibilityKeepsArtworkOrPlayerAvailable() {
        var visibility = WorkspaceVisibility()
        visibility.toggle(.player)
        #expect(!visibility.canToggle(.artwork))
        visibility.toggle(.artwork)
        visibility.toggle(.playlist)
        #expect(visibility == WorkspaceVisibility(showsPlayer: false, showsPlaylist: false))

        visibility.toggle(.player)
        visibility.toggle(.artwork)
        #expect(!visibility.canToggle(.player))
        visibility.toggle(.player)
        #expect(visibility == WorkspaceVisibility(showsArtwork: false, showsPlaylist: false))
    }

    @MainActor
    @Test
    func compactWindowHeightsFollowTheVisibleRegions() {
        let artworkOnly = WorkspaceVisibility(showsPlayer: false, showsPlaylist: false)
        #expect(TakesWindowPolicy.defaultSize(for: artworkOnly) == CGSize(width: 360, height: 360))
        #expect(TakesWindowPolicy.minimumSize(for: artworkOnly, isComparison: true) == CGSize(width: 260, height: 260))

        let playerOnly = WorkspaceVisibility(showsArtwork: false, showsPlaylist: false)
        #expect(TakesWindowPolicy.defaultSize(for: playerOnly).height == 141)
        #expect(TakesWindowPolicy.minimumSize(for: playerOnly, isComparison: true).height == 90)

        let artworkAndPlaylist = WorkspaceVisibility(showsPlayer: false)
        #expect(TakesWindowPolicy.minimumSize(for: artworkAndPlaylist, isComparison: true).height == 441)
    }

    @Test
    func windowPolicyDetectsSavedMainWindowFrame() {
        var defaults: [String: Any] = [:]

        #expect(!TakesWindowPolicy.hasSavedMainWindowFrame { defaults[$0] })

        defaults[TakesWindowPolicy.mainWindowFrameDefaultsKey] = "10 20 360 760 0 0 1512 944"

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
        Designed & developed by
        Nigel M. Warren: https://nigelwarren.com

        Third-Party Resources
        Sparkle: https://sparkle-project.org
        yt-dlp: https://github.com/yt-dlp/yt-dlp
        Tabler Icons: https://tabler.io/icons
        """)

        let expectedLinks: [(label: String, destination: String)] = [
            ("https://nigelwarren.com", "https://nigelwarren.com"),
            ("https://sparkle-project.org", "https://sparkle-project.org"),
            ("https://github.com/yt-dlp/yt-dlp", "https://github.com/yt-dlp/yt-dlp"),
            ("https://tabler.io/icons", "https://tabler.io/icons")
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
    func nudgingActiveTrackOffsetUsesConfiguredSettingsSteps() async throws {
        let url = try makeTemporaryAudioFile(name: "nudged-offset.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let defaults = InMemoryAppSettingsDefaults()
        defaults.set(37, forKey: AppSettings.offsetStepKey)
        defaults.set(420, forKey: AppSettings.offsetLargeStepKey)

        let controller = PlaybackController()
        let settings = AppSettings(defaults: defaults)
        controller.settings = settings
        await controller.loadImportedFiles([url])
        let trackID = try #require(controller.session.activeTrackID)

        controller.nudgeActiveTrackOffset(direction: 1, largeStep: false)
        #expect(controller.session.activeTrack?.loadedTrack.offsetSeconds == 0.037)

        controller.nudgeActiveTrackOffset(direction: 1, largeStep: true)
        #expect(controller.session.activeTrack?.loadedTrack.offsetSeconds == 0.457)

        controller.nudgeActiveTrackOffset(direction: -1, largeStep: false)
        #expect(controller.session.activeTrack?.loadedTrack.offsetSeconds == 0.42)
        #expect(controller.session.activeTrackID == trackID)
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
        controller.pause()
    }

    @MainActor
    @Test
    func togglingRepeatModeWhilePlayingKeepsPlaybackRunning() async throws {
        // Exercises the pre-queue arm/tear-down path in setRepeatMode: Off (no
        // wrap) → One (wrap, arm) → Off (tear down).
        let url = try makeTemporaryAudioFile(name: "repeat-toggle.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = PlaybackController()
        await controller.loadImportedFiles([url])

        controller.play()
        #expect(controller.session.isPlaying)

        controller.setRepeatMode(.one)
        #expect(controller.session.isPlaying)
        #expect(controller.session.repeatMode == .one)

        controller.setRepeatMode(.off)
        #expect(controller.session.isPlaying)
        #expect(controller.session.repeatMode == .off)

        controller.pause()
    }

    @MainActor
    @Test
    func changingOffsetWhileLoopingKeepsPlaybackWithinLoop() async throws {
        // setOffsets while a loop is active must reschedule and re-arm the
        // gapless pre-queue without disturbing the loop or the playhead.
        let first = try makeTemporaryAudioFile(name: "offset-loop-1.wav")
        let second = try makeTemporaryAudioFile(name: "offset-loop-2.wav")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        let controller = PlaybackController()
        await controller.loadImportedFiles([first, second])
        let secondID = try #require(controller.session.tracks.last?.id)

        controller.beginLoop(LoopRegion(start: 0.2, end: 0.8))
        controller.play()
        controller.setOffset(secondID, seconds: 0.1)

        #expect(controller.session.isPlaying)
        #expect(controller.session.loopRegion == LoopRegion(start: 0.2, end: 0.8))
        #expect(controller.session.transportPosition >= 0.2)
        #expect(controller.session.transportPosition < 0.8)
        controller.pause()
    }

    @MainActor
    @Test
    func switchAndRepeatLoopWithMultipleTracksPlays() async throws {
        let first = try makeTemporaryAudioFile(name: "switch-loop-1.wav")
        let second = try makeTemporaryAudioFile(name: "switch-loop-2.wav")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        let controller = PlaybackController()
        await controller.loadImportedFiles([first, second])
        let firstID = try #require(controller.session.tracks.first?.id)

        controller.beginLoop(LoopRegion(start: 0.2, end: 0.5))
        controller.play()

        #expect(controller.session.isPlaying)
        #expect(controller.session.repeatMode == .switchAndRepeat)
        #expect(controller.session.activeTrackID == firstID)
        controller.pause()
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
    func waveformTrackSelectionMapsClicksToTrackRows() {
        #expect(WaveformTrackSelectionPolicy.trackIndex(atY: 0, rowStep: 97, trackCount: 3) == 0)
        #expect(WaveformTrackSelectionPolicy.trackIndex(atY: 96, rowStep: 97, trackCount: 3) == 0)
        #expect(WaveformTrackSelectionPolicy.trackIndex(atY: 97, rowStep: 97, trackCount: 3) == 1)
        #expect(WaveformTrackSelectionPolicy.trackIndex(atY: 289, rowStep: 97, trackCount: 3) == 2)
    }

    @Test
    func waveformTrackSelectionRejectsOutOfBoundsClicks() {
        #expect(WaveformTrackSelectionPolicy.trackIndex(atY: -1, rowStep: 97, trackCount: 3) == nil)
        #expect(WaveformTrackSelectionPolicy.trackIndex(atY: 291, rowStep: 97, trackCount: 3) == nil)
        #expect(WaveformTrackSelectionPolicy.trackIndex(atY: 0, rowStep: 0, trackCount: 3) == nil)
        #expect(WaveformTrackSelectionPolicy.trackIndex(atY: 0, rowStep: 97, trackCount: 0) == nil)
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
    func timelineLaneGestureChoosesPlayheadOnlyWithinItsMouseDownHitStrip() {
        #expect(TimelineLaneGesturePolicy.dragMode(startX: 94, playheadX: 100, playheadHitWidth: 12) == .playhead)
        #expect(TimelineLaneGesturePolicy.dragMode(startX: 100, playheadX: 100, playheadHitWidth: 12) == .playhead)
        #expect(TimelineLaneGesturePolicy.dragMode(startX: 106, playheadX: 100, playheadHitWidth: 12) == .playhead)
        #expect(TimelineLaneGesturePolicy.dragMode(startX: 93.99, playheadX: 100, playheadHitWidth: 12) == .loopSelection)
        #expect(TimelineLaneGesturePolicy.dragMode(startX: 106.01, playheadX: 100, playheadHitWidth: 12) == .loopSelection)
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

    @Test
    func renderableRowRangeTracksViewportWithOverscan() {
        // Viewport shows rows 0–2 (3 × 100pt): overscan extends the tail.
        #expect(ContentView.renderableRowRange(contentMinY: 0, viewportHeight: 300, rowStep: 100) == 0...5)
        // Scrolled 250pt down: rows 2–5 visible, ±2 overscan → 0...7.
        #expect(ContentView.renderableRowRange(contentMinY: -250, viewportHeight: 300, rowStep: 100) == 0...7)
        // Deep scroll clamps nothing at the top anymore.
        #expect(ContentView.renderableRowRange(contentMinY: -1000, viewportHeight: 300, rowStep: 100) == 8...15)
        // Degenerate geometry stays fully open (nothing culled).
        #expect(ContentView.renderableRowRange(contentMinY: 0, viewportHeight: 0, rowStep: 100) == 0...Int.max)
    }

    // MARK: A2 compact compare (milestone 4)

    /// The compare section below the control bar in a window `height` tall
    /// with the artwork shown: less the 360 pt cover and the 119 pt bar.
    @Test
    func compareRulerSeatsTheLanesBelowItsBorder() {
        #expect(CompareLaneLayout.rulerHeight == 21)
        #expect(CompareLaneLayout.dividerHeight == 1)
        #expect(CompareLaneLayout.seatBottom == 22)
        #expect(CompareLaneLayout.stripHeight == 21)
    }

    @Test
    func compareLanesKeepOneFixedHeight() {
        #expect(CompareLaneLayout.laneStep == 96)
        #expect(CompareLaneLayout.laneHeight == 95)
        // The height five versions shared in a 986 pt window with milestone
        // 4's 119 pt control bar and 27 pt ruler seat: exactly filled.
        #expect(CompareLaneLayout.contentHeight(laneCount: 5) == CGFloat(986 - 360 - 119 - 27))
        // Lane count never changes a lane, so removing one never resizes the rest.
        #expect(CompareLaneLayout.contentHeight(laneCount: 4) == 384)
        #expect(CompareLaneLayout.contentHeight(laneCount: 32) == 3072)
        #expect(CompareLaneLayout.contentHeight(laneCount: 0) == 0)
        #expect(CompareLaneLayout.contentHeight(laneCount: -1) == 0)
    }

    @Test
    func compareWaveformIsCentredBelowTheStrip() {
        let band = CompareLaneLayout.waveformBand()
        #expect(band.minY == 26)
        #expect(band.height == 64)
        // Centred in the 74 pt under the strip: 21 + 74 / 2.
        #expect(band.minY + band.height / 2 == 58)

        // A lane no taller than its strip collapses the band instead of
        // inverting it.
        let collapsed = CompareLaneLayout.waveformBand(laneHeight: 15)
        #expect(collapsed.minY == 21)
        #expect(collapsed.height == 0)
    }

    @Test
    func compareStripSitsCentredBetweenTheDividerAndTheWaveform() {
        // The strip's frame runs from the lane's top to the waveform band,
        // and its contents centre in it.
        #expect(CompareLaneLayout.stripFrameHeight == CompareLaneLayout.waveformBand().minY)
        #expect(CompareLaneLayout.stripFrameHeight / 2 == 13)
    }

    @Test
    func controlBarSideButtonsSitMidwayToThePlaylistCentreGroup() {
        #expect(ControlBarMetrics.playlistCenterGroupWidth == 160)
        // 360 pt window: the group spans 100…260, so the side buttons centre
        // at 50 and 310 — in compare too, whose centre group is narrower.
        #expect(ControlBarMetrics.sideButtonCenterX(barWidth: 360) == 50)
        #expect(ControlBarMetrics.sideButtonCenterX(barWidth: 600) == 110)
        let minimum = TakesWindowPolicy.minimumWidth
        let center = ControlBarMetrics.sideButtonCenterX(barWidth: minimum)
        let halfSlot = ControlBarMetrics.sideSlotSize.width / 2
        #expect(center - halfSlot == ControlBarMetrics.edgeInset)
        #expect((minimum - ControlBarMetrics.playlistCenterGroupWidth) / 2 - center - halfSlot
            == ControlBarMetrics.edgeInset)
        // Never closer to the edge than half a slot.
        #expect(ControlBarMetrics.sideButtonCenterX(barWidth: 100) == 15)
    }

    @Test
    func compareRepeatGlyphNamesEachMode() {
        #expect(ControlBarRepeatSymbol.compare(.off) == "repeat")
        #expect(ControlBarRepeatSymbol.compare(.one) == "repeat.1")
        #expect(ControlBarRepeatSymbol.compare(.switchAndRepeat)
            == "point.topright.arrow.triangle.backward.to.point.bottomleft.scurvepath.fill")
    }

    @Test
    func sideButtonAppearanceDefaultsMatchTheSpec() {
        let appearance = TransportAppearance()
        #expect(appearance.darkSideButton.glyphGlow.count == 3)
        #expect(appearance.lightSideButton.glyphGlow.count == 3)
        #expect(appearance.lightSideButton.glyphGlow[2].opacity == 0)
        #expect(appearance.lightSideButton.offGlyph == nil)
        #expect(appearance.sideButton(for: .dark) == appearance.darkSideButton)
        #expect(appearance.sideButton(for: .light) == appearance.lightSideButton)
    }

    @Test
    func compareCoverFollowsTheAudibleVersionUnlessBlind() {
        func version(_ file: String) -> PlaylistVersion {
            PlaylistVersion(
                file: PlaylistFileReference(storedURL: URL(fileURLWithPath: "/tmp/\(file)")),
                metadata: PlaylistMetadata(title: nil, fileFormatDescription: "FLAC", displayName: file)
            )
        }
        let mono = version("mono.flac"), stereo = version("stereo.flac")
        let item = PlaylistItem(title: "Taxman", versions: [mono, stereo])

        #expect(CoverVersionRule.comparison(item: item, audibleVersionID: stereo.id, isBlind: false)?.id == stereo.id)
        // Blind: the key version stays up whichever version is audible.
        #expect(CoverVersionRule.comparison(item: item, audibleVersionID: stereo.id, isBlind: true)?.id == mono.id)
        #expect(CoverVersionRule.comparison(item: item, audibleVersionID: nil, isBlind: false)?.id == mono.id)

        #expect(CoverVersionRule.playlist(item: item, currentVersionID: stereo.id)?.id == stereo.id)
        #expect(CoverVersionRule.playlist(item: item, currentVersionID: nil)?.id == mono.id)
    }

    @Test
    func rulerNotchesHangFromTheBottomEdgeAndLabelsSitBesideThem() {
        #expect(TimelineRulerMetrics.majorTickHeight == 19)
        #expect(TimelineRulerMetrics.minorTickHeight == 8)

        let major = TimelineRulerMetrics.tickFrame(x: 40, height: TimelineRulerMetrics.majorTickHeight)
        #expect(major == CGRect(x: 40, y: 2, width: 1, height: 19))
        #expect(major.maxY == CompareLaneLayout.rulerHeight)
        let minor = TimelineRulerMetrics.tickFrame(x: 52, height: TimelineRulerMetrics.minorTickHeight)
        #expect(minor == CGRect(x: 52, y: 13, width: 1, height: 8))

        #expect(TimelineRulerMetrics.labelOrigin(tickX: 40, rulerWidth: 360)
            == CGPoint(x: 44, y: TimelineRulerMetrics.labelTopInset))
        // A label whose start runs past the ruler isn't drawn.
        #expect(TimelineRulerMetrics.labelOrigin(tickX: 357, rulerWidth: 360) == nil)
    }

    @Test
    func playheadGrabberTipSitsOnTheRulersBottomEdgeWhereTheLineStarts() {
        #expect(PlayheadGeometry.handleWidth == 14)
        #expect(PlayheadGeometry.handleHeight == 16)

        // The line lives in the lanes' scroll content, which starts at the
        // ruler's bottom edge, and runs through every lane.
        let line = PlayheadGeometry.lineFrame(lineHeight: CompareLaneLayout.contentHeight(laneCount: 5))
        #expect(line == CGRect(x: -1, y: 0, width: 2, height: 480))
        #expect(PlayheadGeometry.lineFrame(lineHeight: -4).height == 0)

        let seat = CompareLaneLayout.seatBottom
        let padding: CGFloat = 4
        let grabber = PlayheadGeometry.grabberFrame(seatBottom: seat, padding: padding)
        // The unpadded art ends exactly at the ruler's bottom edge.
        #expect(grabber.maxY - padding == seat)
        #expect(grabber.minY + padding == seat - 16)
        #expect(grabber.midX == 0)
        #expect(grabber.width == 14 + padding * 2)
    }

    @MainActor
    @Test
    func laneOffsetFieldGrowsWithItsText() {
        let one = LaneOffsetField.fieldWidth(for: "0")
        let four = LaneOffsetField.fieldWidth(for: "1250")
        let longest = LaneOffsetField.fieldWidth(for: "-300000")
        #expect(one < four)
        #expect(four < longest)
        // A cleared field keeps a digit's room.
        #expect(LaneOffsetField.fieldWidth(for: "") == one)
    }

    @Test
    func laneStripNamesVersionsLikeTheVersionRows() {
        var tagged = makeTrack(name: "05 Taxman.flac")
        tagged.title = "  Taxman (2009 Stereo Mix) "
        #expect(LaneStripText.name(for: tagged, index: 1, isBlind: false) == "Taxman (2009 Stereo Mix)")

        let untagged = makeTrack(name: "05 Taxman.flac")
        #expect(LaneStripText.name(for: untagged, index: 1, isBlind: false) == "05 Taxman")

        let format = LaneStripText.format(for: tagged, isBlind: false, fields: AppSettings.compareMetadataFieldsDefault)
        #expect(format == "WAV • 44.1 kHz • 256 kbps")

        let tip = LaneStripText.toolTip(for: tagged, isBlind: false, format: format)
        #expect(tip == "Taxman (2009 Stereo Mix)\nWAV • 44.1 kHz • 256 kbps · 2:00\n05 Taxman.flac")
    }

    @Test
    func laneStripShowsOnlyEnabledAudioMetadataWithValues() {
        var track = makeTrack(name: "Take.wav")
        track.bitRate = 0
        let format = LaneStripText.format(for: track, isBlind: false, fields: [.sampleRate, .bitrate])
        #expect(format == "44.1 kHz")
        #expect(LaneStripText.toolTip(for: track, isBlind: false, format: format) == "Take\n44.1 kHz · 2:00\nTake.wav")

        let hiddenFormat = LaneStripText.format(for: track, isBlind: false, fields: [])
        #expect(hiddenFormat.isEmpty)
        #expect(LaneStripText.toolTip(for: track, isBlind: false, format: hiddenFormat) == "Take\n2:00\nTake.wav")
    }

    @Test
    func laneStripRevealsNothingWhileBlind() {
        var track = makeTrack(name: "05 Taxman.flac")
        track.title = "Taxman (2009 Stereo Mix)"
        #expect(LaneStripText.name(for: track, index: 2, isBlind: true) == "Track 3")
        let format = LaneStripText.format(for: track, isBlind: true, fields: AppSettings.compareMetadataFieldsDefault)
        #expect(format.isEmpty)
        #expect(LaneStripText.toolTip(for: track, isBlind: true, format: format) == nil)

        let blindMenu = LaneStripMenuActions(isBlind: true, hasOffset: true, remove: {}, revealInFinder: {}, resetOffset: {})
        #expect(!blindMenu.canRevealInFinder)
        let menu = LaneStripMenuActions(isBlind: false, hasOffset: false, remove: {}, revealInFinder: {}, resetOffset: {})
        #expect(menu.canRevealInFinder)
    }

    @Test
    func retiredTrackInfoColumnWidthIsRemovedOnLaunch() {
        #expect(TakesWindowPolicy.retiredLayoutDefaultsKeys.contains("trackInfoColumnWidth"))
    }

    // MARK: A2 bottom bars (milestone 5)

    private func makeSummaryItem(_ title: String, durations: [TimeInterval], playback: Int = 0) -> PlaylistItem {
        // Versions above the playback one are rejected, so it is the key.
        let versions = durations.enumerated().map { index, duration in
            PlaylistVersion(
                file: PlaylistFileReference(storedURL: URL(fileURLWithPath: "/tmp/\(title)-\(index).flac")),
                metadata: PlaylistMetadata(duration: duration, fileFormatDescription: "FLAC", displayName: "\(title)-\(index).flac"),
                isRejected: index < playback
            )
        }
        return PlaylistItem(title: title, versions: versions)
    }

    @Test
    func playlistSummaryCountsItemsAndAddsUpTheirPlaybackVersions() {
        // Each item counts once, at its playback version's duration.
        let taxman = makeSummaryItem("Taxman", durations: [159, 161], playback: 1)
        let rigby = makeSummaryItem("Eleanor Rigby", durations: [127.4])
        #expect(PlaylistSummaryText.text(for: [taxman, rigby]) == "2 tracks · 4:48")
        #expect(PlaylistSummaryText.accessibilityText(for: [taxman, rigby]) == "2 tracks, 4:48 in total")

        #expect(PlaylistSummaryText.text(for: [rigby]) == "1 track · 2:07")
        #expect(PlaylistSummaryText.text(for: []).isEmpty)

        // Past an hour the total gains an hours field, as the rows' durations do.
        let long = (0..<16).map { makeSummaryItem("Side \($0)", durations: [240]) }
        #expect(PlaylistSummaryText.text(for: long) == "16 tracks · 1:04:00")

        // A version without a known duration adds nothing.
        let unknown = makeSummaryItem("Unknown", durations: [.nan])
        #expect(PlaylistSummaryText.totalDuration(of: [rigby, unknown]) == 127.4)
    }

    @Test
    func playlistSummaryLeavesOutRejectedTracks() {
        // Culling §8 Q2: rejected tracks are excluded from the count and the
        // total; rejected versions only change which version counts (the key).
        let taxman = makeSummaryItem("Taxman", durations: [159, 161], playback: 1)
        var rigby = makeSummaryItem("Eleanor Rigby", durations: [127.4])
        rigby.isRejected = true
        #expect(PlaylistSummaryText.text(for: [taxman, rigby]) == "1 track · 2:41")
        #expect(PlaylistSummaryText.accessibilityText(for: [taxman, rigby]) == "1 track, 2:41 in total")
        #expect(PlaylistSummaryText.text(for: [rigby]) == "0 tracks · 0:00")
    }

    @MainActor
    @Test
    func playlistBottomBarFollowsTheSelectionCommands() {
        let empty = PlaylistCommandContext(
            coordinator: PlaylistCoordinator(), presentation: PlaylistPresentationState(), undoManager: nil
        )
        #expect(PlaylistBottomBarState(context: empty) == PlaylistBottomBarState(itemCount: 0, canRemoveSelection: false))
        #expect(!PlaylistBottomBarState(context: empty).canShowActions)

        let taxman = makeSummaryItem("Taxman", durations: [159, 161])
        let rigby = makeSummaryItem("Eleanor Rigby", durations: [127])
        let presentation = PlaylistPresentationState()
        let context = PlaylistCommandContext(
            coordinator: PlaylistCoordinator(workspace: PlaylistWorkspace(items: [taxman, rigby])),
            presentation: presentation,
            undoManager: nil
        )
        // Nothing selected: nothing to remove, but Clear Playlist is in the
        // pull-down.
        var state = PlaylistBottomBarState(context: context)
        #expect(!state.canRemove)
        #expect(state.canShowActions)

        presentation.selection = [.item(rigby.id)]
        state = PlaylistBottomBarState(context: context)
        #expect(state.canRemove)

        presentation.selection = [.version(taxman.versions[1].id)]
        #expect(PlaylistBottomBarState(context: context).canRemove)
    }

    @Test
    func compareBottomBarFollowsTheCompareCommands() {
        let ready = CompareBottomBarState(hasActiveVersion: true, canSwitchPlayback: true, isAligning: false, canZoomTimeline: true)
        #expect(ready.canRemove && ready.canAlign && ready.canZoom)

        // Remove Active Version stays available on an item's last version, as
        // the lane strip's Remove Version and Delete are.
        let single = CompareBottomBarState(hasActiveVersion: true, canSwitchPlayback: false, isAligning: false, canZoomTimeline: true)
        #expect(single.canRemove)
        #expect(!single.canAlign)

        let aligning = CompareBottomBarState(hasActiveVersion: true, canSwitchPlayback: true, isAligning: true, canZoomTimeline: true)
        #expect(!aligning.canAlign)
        #expect(aligning.canRemove)

        let empty = CompareBottomBarState(hasActiveVersion: false, canSwitchPlayback: false, isAligning: false, canZoomTimeline: false)
        #expect(!empty.canRemove && !empty.canAlign && !empty.canZoom)
    }

    @MainActor
    @Test
    func compareBottomBarReadsAnEmptyControllerAsDisabled() {
        let state = CompareBottomBarState(controller: PlaybackController())
        #expect(state == CompareBottomBarState(hasActiveVersion: false, canSwitchPlayback: false, isAligning: false, canZoomTimeline: false))
    }

    @Test
    func alignmentOfferNamesNoFileWhileBlind() {
        let first = UUID(), second = UUID(), third = UUID()
        let names = ["take 2.wav", "take 3.wav"]
        #expect(AlignmentOfferText.trackNames(
            offerTrackIDs: [second, third], offerTrackNames: names, sessionTrackIDs: [first, second, third], isBlind: false
        ) == names)
        // Blind: the lane positions, as the strips show them.
        #expect(AlignmentOfferText.trackNames(
            offerTrackIDs: [third, first], offerTrackNames: names, sessionTrackIDs: [second, third, first], isBlind: true
        ) == ["Track 2", "Track 3"])
        // A version removed since the run is dropped rather than named.
        #expect(AlignmentOfferText.trackNames(
            offerTrackIDs: [UUID()], offerTrackNames: ["gone.wav"], sessionTrackIDs: [first], isBlind: true
        ).isEmpty)
    }

    @MainActor
    @Test
    func zoomSliderSharesTheTimelineZoomModel() async throws {
        let url = try makeTemporaryAudioFile(name: "zoom-slider.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = PlaybackController()
        await controller.loadImportedFiles([url])
        let contentSpan = controller.session.duration
        #expect(abs(controller.zoomSliderValue) < 0.0001)

        // The slider sets the span through the log mapping and reads it back.
        controller.setZoomSliderValue(0.5)
        #expect(abs(controller.visibleSpan - TimelineViewport.visibleSpan(sliderValue: 0.5, contentSpan: contentSpan)) < 0.0001)
        #expect(abs(controller.zoomSliderValue - 0.5) < 0.0001)
        controller.setZoomSliderValue(1)
        #expect(abs(controller.visibleSpan - TimelineViewport.minimumVisibleSpan) < 0.0001)
        #expect(abs(controller.zoomSliderValue - 1) < 0.0001)

        // ⌘− and Zoom to Fit move it, so the slider follows the menus and pinch.
        controller.stepZoom(zoomingIn: false)
        let stepped = TimelineViewport.sliderValue(
            visibleSpan: TimelineViewport.minimumVisibleSpan * TimelineViewport.zoomButtonStep, contentSpan: contentSpan
        )
        #expect(abs(controller.zoomSliderValue - stepped) < 0.0001)
        controller.zoomToFit()
        #expect(abs(controller.zoomSliderValue) < 0.0001)

        // Out-of-range positions clamp to the zoom range.
        controller.setZoomSliderValue(4)
        #expect(abs(controller.zoomSliderValue - 1) < 0.0001)
    }

    @MainActor
    @Test
    func viewportSaveRevisionChangesOnlyWhenTimelineScrollSettles() async throws {
        let url = try makeTemporaryAudioFile(name: "viewport-save.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = PlaybackController()
        await controller.loadImportedFiles([url])
        controller.zoomVisibleSpan(to: 0.5)
        let revision = controller.settledViewportRevision

        controller.setTimelineScrollActive(true)
        controller.scrollTimeline(toVisibleStart: 0.1)
        controller.scrollTimeline(toVisibleStart: 0.2)
        #expect(controller.visibleStart == 0.2)
        #expect(controller.settledViewportRevision == revision)

        controller.setTimelineScrollActive(false)
        #expect(controller.settledViewportRevision == revision + 1)
    }

    @Test
    func windowMinimumHeightHoldsTheBarsAndOneWholeLane() {
        // Compare control bar under the titlebar, info bar, ruler, one lane,
        // bottom bar.
        #expect(TakesWindowPolicy.compareControlBarHeight(showsArtwork: false) == 91)
        #expect(BottomBarMetrics.height == 30)
        #expect(TakesWindowPolicy.minimumHeightWithoutArtwork == 271)
        #expect(TakesWindowPolicy.minimumHeight(showsArtwork: false) == 271)
        #expect(TakesWindowPolicy.minimumHeight(showsArtwork: true) == 519)

        for showsArtwork in [true, false] {
            let lanes = { (windowHeight: CGFloat) in
                (windowHeight - (showsArtwork ? TakesWindowPolicy.artworkHeight(
                    in: CGSize(width: TakesWindowPolicy.defaultWidth, height: windowHeight)
                ) : 0)
                    - TakesWindowPolicy.compareControlBarHeight(showsArtwork: showsArtwork)
                    - CompareInfoBarMetrics.height
                    - CompareLaneLayout.seatBottom - BottomBarMetrics.height) / CompareLaneLayout.laneStep
            }
            // Exactly one lane at the minimum; about two and a half (237 pt)
            // by default.
            #expect(lanes(TakesWindowPolicy.minimumHeight(showsArtwork: showsArtwork)) == 1)
            #expect(lanes(TakesWindowPolicy.defaultHeight(showsArtwork: showsArtwork)) == 237.0 / 96)
        }
    }

    // MARK: Fitting the window to its tracks (v2.9.0's resize)

    @MainActor
    @Test
    func windowFittingHeightsCoverEveryRowOrLane() {
        #expect(TakesWindowPolicy.playlistControlBarHeight(showsArtwork: true) == 130)
        #expect(TakesWindowPolicy.playlistControlBarHeight(showsArtwork: false) == 142)
        // 360 + 130 + 6 + 4 × 46 + 2 × 30 + 6 + 30.
        #expect(TakesWindowPolicy.playlistFittingHeight(itemRows: 4, versionRows: 2, showsArtwork: true, width: 360) == 776)
        #expect(TakesWindowPolicy.playlistFittingHeight(itemRows: 4, versionRows: 2, showsArtwork: false, width: 360) == 428)
        // Few or no rows never go below the minimum.
        #expect(TakesWindowPolicy.playlistFittingHeight(itemRows: 0, versionRows: 0, showsArtwork: true, width: 260) == 519)
        #expect(TakesWindowPolicy.compareFittingHeight(laneCount: 0, showsArtwork: true, width: 360) == 619)
        #expect(TakesWindowPolicy.compareFittingHeight(laneCount: 1, showsArtwork: false, width: 360) == 271)
        #expect(TakesWindowPolicy.compareFittingHeight(laneCount: 3, showsArtwork: false, width: 360) == 463)
    }

    @Test
    func windowGrowsOnlyWhenAddedTracksDoNotFit() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: 100, y: 200, width: 360, height: 620)
        let grown = TakesWindowPolicy.frameFittingContent(
            previousTrackCount: 2, newTrackCount: 3, fittingHeight: 700, currentFrame: frame, visibleFrame: screen
        )
        #expect(grown == CGRect(x: 100, y: 120, width: 360, height: 700))
        // Already tall enough: unchanged, so a window the user enlarged stays.
        #expect(TakesWindowPolicy.frameFittingContent(
            previousTrackCount: 2, newTrackCount: 3, fittingHeight: 600, currentFrame: frame, visibleFrame: screen
        ) == nil)
        // Growth stops at the bottom of the screen, top edge fixed.
        #expect(TakesWindowPolicy.frameFittingContent(
            previousTrackCount: 2, newTrackCount: 30, fittingHeight: 2000, currentFrame: frame, visibleFrame: screen
        ) == CGRect(x: 100, y: 0, width: 360, height: 820))
        // A window already reaching the screen's bottom doesn't move.
        let low = CGRect(x: 100, y: 0, width: 360, height: 620)
        #expect(TakesWindowPolicy.frameFittingContent(
            previousTrackCount: 2, newTrackCount: 3, fittingHeight: 700, currentFrame: low, visibleFrame: screen
        ) == nil)
    }

    @Test
    func windowShrinksOnlyWhenRemovedTracksLeaveItTooTall() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: 100, y: 100, width: 360, height: 800)
        #expect(TakesWindowPolicy.frameFittingContent(
            previousTrackCount: 5, newTrackCount: 4, fittingHeight: 715, currentFrame: frame, visibleFrame: screen
        ) == CGRect(x: 100, y: 185, width: 360, height: 715))
        // The rest still need the height: unchanged.
        #expect(TakesWindowPolicy.frameFittingContent(
            previousTrackCount: 5, newTrackCount: 4, fittingHeight: 900, currentFrame: frame, visibleFrame: screen
        ) == nil)
        // An add never shrinks, a remove never grows.
        #expect(TakesWindowPolicy.frameFittingContent(
            previousTrackCount: 4, newTrackCount: 5, fittingHeight: 600, currentFrame: frame, visibleFrame: screen
        ) == nil)
        #expect(TakesWindowPolicy.frameFittingContent(
            previousTrackCount: 5, newTrackCount: 4, fittingHeight: 850, currentFrame: frame, visibleFrame: screen
        ) == nil)
    }

    // MARK: Mode heights

    @Test
    func playlistHeightIsStoredWithoutTheCover() throws {
        let defaults = try #require(UserDefaults(suiteName: "SessionTests.playlistHeight.\(UUID())"))
        #expect(TakesWindowPolicy.storedPlaylistHeight(defaults: defaults) == nil)
        TakesWindowPolicy.storePlaylistHeight(CGSize(width: 400, height: 840), showsArtwork: true, defaults: defaults)
        #expect(TakesWindowPolicy.storedPlaylistHeight(defaults: defaults) == 452)
        TakesWindowPolicy.storePlaylistHeight(CGSize(width: 400, height: 500), showsArtwork: false, defaults: defaults)
        #expect(TakesWindowPolicy.storedPlaylistHeight(defaults: defaults) == 500)
        // Never stored below the minimum.
        TakesWindowPolicy.storePlaylistHeight(CGSize(width: 400, height: 100), showsArtwork: false, defaults: defaults)
        #expect(TakesWindowPolicy.storedPlaylistHeight(defaults: defaults) == 271)
        // Compare's height, from an earlier build, is retired.
        #expect(TakesWindowPolicy.retiredLayoutDefaultsKeys.contains("main.a2.height.compare"))
    }

    @Test
    func restoringThePlaylistHeightKeepsTheTopEdgeOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: 100, y: 200, width: 400, height: 620)
        // The cover is added back when shown; width and top edge stay.
        #expect(TakesWindowPolicy.frameRestoringPlaylistHeight(452, showsArtwork: true, currentFrame: frame, visibleFrame: screen)
            == CGRect(x: 100, y: 0, width: 400, height: 820))
        #expect(TakesWindowPolicy.frameRestoringPlaylistHeight(452, showsArtwork: false, currentFrame: frame, visibleFrame: screen)
            == CGRect(x: 100, y: 368, width: 400, height: 452))
        // Stops at the bottom of the screen, never below the minimum.
        #expect(TakesWindowPolicy.frameRestoringPlaylistHeight(2000, showsArtwork: false, currentFrame: frame, visibleFrame: screen)
            == CGRect(x: 100, y: 0, width: 400, height: 820))
        #expect(TakesWindowPolicy.frameRestoringPlaylistHeight(10, showsArtwork: true, currentFrame: frame, visibleFrame: screen)
            == CGRect(x: 100, y: 161, width: 400, height: 659))
        let fitted = CGRect(x: 100, y: 160, width: 400, height: 660)
        #expect(TakesWindowPolicy.frameRestoringPlaylistHeight(272, showsArtwork: true, currentFrame: fitted, visibleFrame: screen)
            == nil)
    }

    @Test
    func enteringCompareSizesTheWindowToItsLanes() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let tall = CGRect(x: 100, y: 0, width: 360, height: 880)
        // Shrinks to three lanes (619 + 2 × 96 = 811) even from a taller window.
        let three = TakesWindowPolicy.compareFittingHeight(laneCount: 3, showsArtwork: true, width: 360)
        #expect(TakesWindowPolicy.frameSettingHeight(three, showsArtwork: true, currentFrame: tall, visibleFrame: screen)
            == CGRect(x: 100, y: 69, width: 360, height: 811))
        // Grows to the lanes, stopping at the bottom of the screen.
        let short = CGRect(x: 100, y: 300, width: 360, height: 619)
        let many = TakesWindowPolicy.compareFittingHeight(laneCount: 10, showsArtwork: true, width: 360)
        #expect(TakesWindowPolicy.frameSettingHeight(many, showsArtwork: true, currentFrame: short, visibleFrame: screen)
            == CGRect(x: 100, y: 0, width: 360, height: 919))
        // One lane at the minimum height: unchanged.
        let one = TakesWindowPolicy.compareFittingHeight(laneCount: 1, showsArtwork: true, width: 360)
        #expect(TakesWindowPolicy.frameSettingHeight(one, showsArtwork: true, currentFrame: short, visibleFrame: screen) == nil)
    }

    // MARK: A2 playlist rows (milestone 3)

    @Test
    func playlistRowMetricsAlignThumbnailsChecksAndTitles() {
        typealias M = PlaylistRowMetrics
        #expect(M.itemHeight == 46)
        #expect(M.versionHeight == 30)
        // Chevron slot at 14, thumbnail (and the version check column) at 32,
        // titles of both row kinds at 76 — the canvas's arrangement.
        #expect(M.disclosureX == 14)
        #expect(M.thumbnailX == 32)
        #expect(M.titleX == 76)
        // Highlights keep the 10 pt edge inset at any window width.
        for width: CGFloat in [360, 520, 900] {
            let rect = M.highlightRect(in: NSRect(x: 0, y: 0, width: width, height: M.itemHeight))
            #expect(rect.minX == 10)
            #expect(rect.maxX == width - 10)
            #expect(M.trailingX(rowWidth: width) == width - 18)
        }
        // The far stacked card's strip reaches 4 pt above and right of the tile.
        #expect(PlaylistThumbnailView.stackExtent == 4)
    }

    @Test
    func playlistVersionNamesUseTheTitleTagThenTheFilenameStem() {
        func version(title: String?, file: String) -> PlaylistVersion {
            PlaylistVersion(
                file: PlaylistFileReference(storedURL: URL(fileURLWithPath: "/tmp/\(file)")),
                metadata: PlaylistMetadata(title: title, fileFormatDescription: "FLAC", displayName: file)
            )
        }
        #expect(PlaylistRowText.versionName(version(title: "Eleanor Rigby (2009 Stereo Mix)", file: "02 eleanor.flac"))
            == "Eleanor Rigby (2009 Stereo Mix)")
        #expect(PlaylistRowText.versionName(version(title: "  ", file: "02 eleanor.flac")) == "02 eleanor")
        #expect(PlaylistRowText.versionName(version(title: nil, file: "take.final.wav")) == "take.final")
        #expect(PlaylistRowText.formatName(version(title: nil, file: "a.flac").metadata) == "FLAC")

        let tagged = version(title: "Stereo Mix", file: "stereo.wav")
        let untagged = version(title: nil, file: "Alternate Mix.wav")
        var item = PlaylistItem(title: "Original Track Title", versions: [tagged, untagged])
        #expect(PlaylistRowText.itemTitle(item) == "Stereo Mix")
        // Rejecting the first version makes the next one the key.
        item.versions[0].isRejected = true
        #expect(PlaylistRowText.itemTitle(item) == "Alternate Mix")
    }

    @Test
    func playlistMetadataLineJoinsOnlyEnabledFieldsWithValues() {
        var metadata = PlaylistMetadata(
            artist: " Artist Name ", album: "Album Title", sampleRate: 44_100,
            bitRate: 319_500, fileFormatDescription: "FLAC"
        )
        let allFields = Set(TrackMetadataField.allCases)
        #expect(PlaylistRowText.metadataLine(metadata, fields: allFields)
            == "Artist Name • Album Title • FLAC • 44.1 kHz • 320 kbps")
        #expect(PlaylistRowText.metadataLine(metadata, fields: [.bitrate, .album]) == "Album Title • 320 kbps")
        #expect(PlaylistRowText.metadataLine(metadata, fields: []).isEmpty)

        metadata.artist = nil
        metadata.album = "  "
        metadata.sampleRate = 0
        metadata.bitRate = .infinity
        #expect(PlaylistRowText.metadataLine(metadata, fields: allFields) == "FLAC")
        #expect(PlaylistRowText.metadataLine(nil, fields: allFields).isEmpty)
    }

    @MainActor
    @Test
    func playlistWarningTooltipsUseTheLoadErrorAndClearWhenTheFilePlays() {
        let message = PlaybackError.failedToOpenFile(URL(fileURLWithPath: "/tmp/missing.wav")).localizedDescription
        let thumbnail = PlaylistThumbnailView(frame: .zero)
        thumbnail.configure(image: nil, isStacked: false, status: .warning(message))
        #expect(thumbnail.toolTip == message)
        let glyphs = thumbnail.subviews.flatMap(\.subviews).compactMap { $0 as? NSImageView }
        #expect(glyphs.filter { !$0.isHidden && $0.image != nil }.count == 1)
        thumbnail.image = nil
        #expect(glyphs.filter { !$0.isHidden && $0.image != nil }.count == 1)
        thumbnail.configure(image: nil, isStacked: false, status: .playing)
        #expect(thumbnail.toolTip == nil)

        let version = PlaylistVersionCellView()
        version.configure(title: "Missing", format: "WAV", duration: "0:35", mark: .warning(message), toolTip: "")
        #expect(version.subviews.contains { ($0 as? NSImageView)?.toolTip == message })
        version.configure(title: "Available", format: "WAV", duration: "0:35", mark: .none, toolTip: "")
        #expect(!version.subviews.contains { ($0 as? NSImageView)?.toolTip == message })
    }

    // MARK: Record placeholder

    @Test
    func recordPlaceholderCoverSquareIsTheCentredMinimumSquare() {
        typealias R = RecordPlaceholder
        #expect(R.coverSquare(in: CGSize(width: 360, height: 360)) == CGRect(x: 0, y: 0, width: 360, height: 360))
        // Wide and shallow: height limits the square, centred horizontally.
        #expect(R.coverSquare(in: CGSize(width: 600, height: 240)) == CGRect(x: 180, y: 0, width: 240, height: 240))
        // Narrow and tall, below 360 pt.
        #expect(R.coverSquare(in: CGSize(width: 260, height: 400)) == CGRect(x: 0, y: 70, width: 260, height: 260))
        // Above 360 pt.
        #expect(R.coverSquare(in: CGSize(width: 720, height: 720)) == CGRect(x: 0, y: 0, width: 720, height: 720))
        #expect(R.coverSquare(in: .zero) == .zero)

        // The ground's centre and radius follow the square, not the cover.
        let wide = CGSize(width: 600, height: 240)
        let square = R.coverSquare(in: wide)
        let center = R.groundCenter(square: square, in: wide)
        #expect(abs(center.x - 0.5) < 1e-9)
        #expect(abs(center.y - 0.38) < 1e-9)
        #expect(abs(R.groundRadius(square: square) - hypot(120, 240 * 0.62)) < 1e-9)
        #expect(R.groundStops(isDark: true).count == 3)
    }

    @MainActor
    @Test
    func recordPlaceholderThumbnailShowsWithoutArtworkExceptInTheWarningState() throws {
        let record = try #require(RecordPlaceholder.thumbnail)
        let artwork = NSImage(size: NSSize(width: 4, height: 4))
        typealias T = PlaylistThumbnailView
        #expect(T.tileImage(artwork: nil, status: .none) === record)
        #expect(T.tileImage(artwork: nil, status: .playing) === record)
        #expect(T.tileImage(artwork: nil, status: .paused) === record)
        #expect(T.tileImage(artwork: nil, status: .warning("Missing")) == nil)
        #expect(T.tileImage(artwork: artwork, status: .none) === artwork)
        #expect(T.tileImage(artwork: artwork, status: .warning("Missing")) === artwork)

        let thumbnail = PlaylistThumbnailView(frame: .zero)
        thumbnail.configure(image: nil, isStacked: true, status: .none)
        #expect(thumbnail.displayedImage === record)
        thumbnail.configure(image: nil, isStacked: false, status: .warning("Missing"))
        #expect(thumbnail.displayedImage == nil)
        thumbnail.configure(image: artwork, isStacked: false, status: .none)
        #expect(thumbnail.displayedImage === artwork)
        thumbnail.image = nil
        #expect(thumbnail.displayedImage === record)
    }

    @MainActor
    @Test
    func recordPlaceholderBitmapsResolveOnePerAppearance() throws {
        let thumbnail = try #require(RecordPlaceholder.thumbnail)
        let cover = try #require(NSImage(named: RecordPlaceholder.coverImageName))
        for (image, side) in [(thumbnail, RecordPlaceholder.thumbnailPixelSide), (cover, RecordPlaceholder.coverPixelSide)] {
            let light = try #require(RecordPlaceholderPixels(image, dark: false))
            let dark = try #require(RecordPlaceholderPixels(image, dark: true))
            #expect(light.width == side && light.height == side)
            #expect(dark.width == side && dark.height == side)
            #expect(light.bytes != dark.bytes)
        }
        // The thumbnail carries its ground: light corners, dark corners.
        let lightThumbnail = try #require(RecordPlaceholderPixels(thumbnail, dark: false))
        let darkThumbnail = try #require(RecordPlaceholderPixels(thumbnail, dark: true))
        #expect(lightThumbnail.pixel(0, 0).r > 180 && lightThumbnail.pixel(0, 0).a == 255)
        #expect(darkThumbnail.pixel(0, 0).r < 40 && darkThumbnail.pixel(0, 0).a == 255)
        // The cover is transparent outside the record and its shadows.
        let darkCover = try #require(RecordPlaceholderPixels(cover, dark: true))
        #expect(darkCover.pixel(2, 2).a == 0)
    }

    /// The disc is round to the edge (the lead-in no longer clips it flat),
    /// the label sits at its diameter, and the lead-in is a smooth band out
    /// to the disc's edge, in both exports.
    @MainActor
    @Test
    func recordPlaceholderCoverExportMatchesTheSpecGeometry() throws {
        typealias R = RecordPlaceholder
        let cover = try #require(NSImage(named: R.coverImageName))
        let scale = CGFloat(R.coverPixelSide) / R.referenceSide
        let discRadius = R.discDiameter / 2 * scale
        let labelRadius = R.labelDiameter / 2 * scale
        for dark in [false, true] {
            let pixels = try #require(RecordPlaceholderPixels(cover, dark: dark))
            let center = CGFloat(pixels.width) / 2
            func sample(_ degrees: Double, _ radius: CGFloat) -> RecordPlaceholderPixels.Pixel {
                let t = degrees * .pi / 180
                return pixels.pixel(Int(center + radius * CGFloat(sin(t))), Int(center - radius * CGFloat(cos(t))))
            }
            for degrees in stride(from: 0.0, to: 360, by: 7.5) {
                // Disc edge: the first pixel out from the centre that isn't
                // opaque (the cast shadow outside never reaches 100%).
                let edge = (500...620).first { sample(degrees, CGFloat($0) + 0.5).a < 250 }
                let discEdge = try #require(edge.map(CGFloat.init))
                #expect(abs(discEdge - discRadius) <= 1.5, "disc edge \(discEdge) at \(degrees)°")

                // Label edge: the outermost indigo pixel.
                let labelEdge = (150...260).last { radius in
                    let p = sample(degrees, CGFloat(radius) + 0.5)
                    return Int(p.b) > Int(p.r) + 60 && p.b > 120
                }
                let measured = try #require(labelEdge.map(CGFloat.init))
                #expect(abs(measured + 1 - labelRadius) <= 2.5, "label edge \(measured) at \(degrees)°")
            }
            // The lead-in (inside the 2.2 pt rim) is smooth vinyl: no grooves
            // or bands, so its brightness barely changes along a radius.
            // Sampled where the sheen is clear.
            let leadInInner = discRadius - R.leadInWidth * scale
            let rimInner = discRadius - 2.2 * scale
            for degrees in [120.0, 150, 300, 330] {
                let values = stride(from: leadInInner + 3, through: rimInner - 3, by: 1).map {
                    Int(sample(degrees, $0).g)
                }
                #expect(values.max()! - values.min()! <= 3, "lead-in at \(degrees)°: \(values)")
            }
        }
    }

    @MainActor
    @Test
    func thumbnailsLoadOnlyForTheLatestVisibleRowsTwoAtATime() async throws {
        let gate = ThumbnailLoadGate()
        let store = PlaylistArtworkStore { url, size in await gate.load(url, size: size) }
        var loaded: [UUID] = []
        store.onThumbnailLoaded = { loaded.append($0) }
        let rows = (0..<6).map { (id: UUID(), url: URL(fileURLWithPath: "/tmp/thumb-\($0).m4a")) }

        store.requestThumbnails(rows)
        try await waitUntil { await gate.callCount == 2 }
        #expect(store.thumbnailLoadsInFlight == PlaylistArtworkStore.maximumConcurrentThumbnailLoads)
        // Scrolled: only the last row is still visible. Rows 2–4 are never read.
        store.requestThumbnails([rows[5]])
        await gate.releaseAll()
        try await waitUntil { loaded.count == 3 }
        let calls = await gate.calls
        #expect(calls.count == 3)
        #expect(Set(calls.map(\.url)) == [rows[0].url, rows[1].url, rows[5].url])
        #expect(await gate.calls.allSatisfy { $0.size == .thumbnail })
        #expect(store.thumbnail(for: rows[3].id, url: rows[3].url) == .unknown)
        guard case let .image(image) = store.thumbnail(for: rows[5].id, url: rows[5].url) else {
            Issue.record("Expected a thumbnail")
            return
        }
        #expect(image.size.width == CGFloat(PlaylistArtworkStore.thumbnailPixelSize))
        // A relocated file is a different thumbnail.
        #expect(store.thumbnail(for: rows[5].id, url: URL(fileURLWithPath: "/tmp/elsewhere.m4a")) == .unknown)
    }

    @MainActor
    @Test
    func finishedCoverWaitsForThumbnailCapacityAndCurrentVisibility() async throws {
        let url = try makeTemporaryAudioFile(name: "queued-cover.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = ThumbnailLoadGate()
        let store = PlaylistArtworkStore { url, size in await gate.load(url, size: size) }
        let version = PlaylistVersion(
            file: PlaylistWorkspaceStore.makeFileReference(for: url),
            metadata: PlaylistMetadata(fileFormatDescription: "WAV", displayName: url.lastPathComponent)
        )
        let rows = (0..<2).map { (id: UUID(), url: URL(fileURLWithPath: "/tmp/busy-\($0).wav")) }
        store.load(for: version)
        try await waitUntil { await gate.callCount == 1 }
        store.requestThumbnails([(version.id, url)] + rows)
        try await waitUntil { await gate.callCount == 3 }

        await gate.releaseFirst()
        try await waitUntil { store.hasResolvedArtwork(for: version.id) }
        #expect(store.thumbnailLoadsInFlight == 2)
        #expect(store.thumbnail(for: version.id, url: url) == .unknown)

        store.requestThumbnails(rows)
        await gate.releaseAll()
        try await waitUntil { store.thumbnailLoadsInFlight == 0 }
        #expect(store.thumbnail(for: version.id, url: url) == .unknown)
        store.requestThumbnails([(version.id, url)])
        try await waitUntil { store.thumbnail(for: version.id, url: url) != .unknown }
        #expect(await gate.callCount == 3)
    }

    @Test
    func coverCropsOnlyNearlySquareArtAndDecodesEnoughPixels() {
        #expect(CoverArtworkLayout.crops(CGSize(width: 1000, height: 1000)))
        #expect(CoverArtworkLayout.crops(CGSize(width: 1100, height: 1000)))
        #expect(!CoverArtworkLayout.crops(CGSize(width: 1600, height: 900)))
        #expect(!CoverArtworkLayout.crops(CGSize(width: 900, height: 1600)))
        // A cropped cover's short edge reaches 720 px; a fitted one's long edge.
        #expect(ArtworkDecodeTarget.cover.longEdge(width: 1000, height: 1000) == 720)
        #expect(ArtworkDecodeTarget.cover.longEdge(width: 1100, height: 1000) == 792)
        #expect(ArtworkDecodeTarget.cover.longEdge(width: 1600, height: 900) == 720)
        // Thumbnails always crop, so their long edge grows, capped at 4:1.
        #expect(ArtworkDecodeTarget.thumbnail.longEdge(width: 1600, height: 900) == 121)
        #expect(ArtworkDecodeTarget.thumbnail.longEdge(width: 5000, height: 500) == 272)
    }

    @MainActor
    @Test
    func thumbnailCacheIsBoundedAndKeepsMisses() async throws {
        let store = PlaylistArtworkStore { url, size in
            url.lastPathComponent.hasPrefix("none") ? nil : Self.makeImage(side: size.side)
        }
        var loaded = 0
        store.onThumbnailLoaded = { _ in loaded += 1 }
        let miss = (id: UUID(), url: URL(fileURLWithPath: "/tmp/none.m4a"))
        let rows = (0...PlaylistArtworkStore.thumbnailCapacity).map { (id: UUID(), url: URL(fileURLWithPath: "/tmp/art-\($0).m4a")) }
        store.requestThumbnails([miss] + rows)
        try await waitUntil { loaded == rows.count + 1 }
        // One over capacity: exactly one of the earliest images was evicted.
        let evicted = rows.indices.filter { store.thumbnail(for: rows[$0].id, url: rows[$0].url) == .unknown }
        #expect(evicted.count == 1)
        #expect(evicted.allSatisfy { $0 < 2 })
        #expect(store.thumbnail(for: miss.id, url: miss.url) == PlaylistArtworkStore.Thumbnail.none)
        if case .image = store.thumbnail(for: rows[rows.count - 1].id, url: rows[rows.count - 1].url) {} else {
            Issue.record("The most recent thumbnail should be cached")
        }
    }

    @MainActor
    @Test
    func thumbnailReusesTheCoverDecodeOfTheSameVersion() async throws {
        let url = try makeTemporaryAudioFile(name: "cover.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = ThumbnailLoadGate()
        let store = PlaylistArtworkStore { url, size in await gate.load(url, size: size) }
        var loaded: [UUID] = []
        store.onThumbnailLoaded = { loaded.append($0) }
        let version = PlaylistVersion(
            file: PlaylistWorkspaceStore.makeFileReference(for: url),
            metadata: PlaylistMetadata(fileFormatDescription: "WAV", displayName: url.lastPathComponent)
        )

        // Asked for while the cover is still decoding: it waits for it.
        store.load(for: version)
        try await waitUntil { await gate.callCount == 1 }
        store.requestThumbnails([(version.id, url)])
        await gate.releaseAll()
        try await waitUntil { loaded == [version.id] }
        #expect(await gate.calls.map(\.size) == [.cover])
        #expect(store.artwork(for: version.id) != nil)
        guard case let .image(image) = store.thumbnail(for: version.id, url: url) else {
            Issue.record("Expected a thumbnail scaled from the cover")
            return
        }
        #expect(image.size.width == CGFloat(PlaylistArtworkStore.thumbnailPixelSize))
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for condition")
    }

    fileprivate static func makeImage(side: Int) -> CGImage? {
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context?.makeImage()
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

/// Holds thumbnail and cover loads until released, recording each call.
private actor ThumbnailLoadGate {
    private(set) var calls: [(url: URL, size: ArtworkDecodeTarget)] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    var callCount: Int { calls.count }

    func load(_ url: URL, size: ArtworkDecodeTarget) async -> CGImage? {
        calls.append((url, size))
        if !isOpen { await withCheckedContinuation { waiting.append($0) } }
        return SessionTests.makeImage(side: size.side)
    }

    func releaseFirst() {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume()
    }

    /// Releases every waiting load, and lets later ones through.
    func releaseAll() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting.removeAll()
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

final class InMemoryAppSettingsDefaults: AppSettingsDefaults {
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

/// A record placeholder variant drawn into a known RGBA buffer (row 0 at
/// the top), for pixel checks.
struct RecordPlaceholderPixels {
    struct Pixel { var r, g, b, a: UInt8 }

    let width: Int
    let height: Int
    let bytes: [UInt8]

    @MainActor
    init?(_ image: NSImage, dark: Bool) {
        var resolved: CGImage?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            resolved = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard let cgImage = resolved,
              let context = CGContext(data: nil, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8,
                                      bytesPerRow: cgImage.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard let data = context.data else { return nil }
        width = cgImage.width
        height = cgImage.height
        bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }

    func pixel(_ x: Int, _ y: Int) -> Pixel {
        let o = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        return Pixel(r: bytes[o], g: bytes[o + 1], b: bytes[o + 2], a: bytes[o + 3])
    }
}
