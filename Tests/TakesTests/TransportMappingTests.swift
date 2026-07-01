import AVFoundation
import Testing
@testable import Takes

struct TransportMappingTests {
    @Test
    func timelineRangeIncludesZeroAndLoadedTrackRangeForSingleTrack() throws {
        let track = makeTrack(duration: 10, offset: 6)

        let range = try #require(TransportMapping.timelineRange(tracks: [track]))

        #expect(range.lowerBound == 0)
        #expect(range.upperBound == 16)
    }

    @Test
    func timelineRangeExpandsBelowZeroForNegativeOffsetsAcrossManyTracks() throws {
        let first = makeTrack(duration: 10, offset: 0)
        let second = makeTrack(duration: 8, offset: -12)
        let third = makeTrack(duration: 4, offset: 20)

        let range = try #require(TransportMapping.timelineRange(tracks: [first, second, third]))

        #expect(range.lowerBound == -12)
        #expect(range.upperBound == 24)
    }

    @Test
    func timelineRangeReturnsNilWithoutTracks() {
        #expect(TransportMapping.timelineRange(tracks: []) == nil)
    }

    @Test
    func filePositionUsesSignedGlobalTimeAndTrackOffset() {
        #expect(TransportMapping.filePosition(forGlobalTime: -8, offset: -10) == 2)
        #expect(TransportMapping.filePosition(forGlobalTime: 3, offset: 5) == -2)
        #expect(TransportMapping.filePosition(forGlobalTime: 9, offset: 5) == 4)
    }

    @Test
    func audibilityUsesSignedGlobalTime() {
        let track = makeTrack(duration: 5, offset: -2)

        #expect(!TransportMapping.isTrackAudible(track, atGlobalTime: -2.01))
        #expect(TransportMapping.isTrackAudible(track, atGlobalTime: -2))
        #expect(TransportMapping.isTrackAudible(track, atGlobalTime: 3))
        #expect(!TransportMapping.isTrackAudible(track, atGlobalTime: 3.01))
    }

    @Test
    func clampTransportAllowsNegativeTimelineBounds() {
        #expect(TransportMapping.clampedTransport(-20, timelineStart: -10, timelineEnd: 12) == -10)
        #expect(TransportMapping.clampedTransport(-5, timelineStart: -10, timelineEnd: 12) == -5)
        #expect(TransportMapping.clampedTransport(20, timelineStart: -10, timelineEnd: 12) == 12)
    }

    @Test
    func normalizedPositionMapsSignedTimeIntoDisplaySpan() {
        #expect(TransportMapping.normalizedPosition(globalTime: -10, timelineStart: -10, timelineEnd: 10) == 0)
        #expect(TransportMapping.normalizedPosition(globalTime: 0, timelineStart: -10, timelineEnd: 10) == 0.5)
        #expect(TransportMapping.normalizedPosition(globalTime: 10, timelineStart: -10, timelineEnd: 10) == 1)
    }

    @Test
    func dbConversionMatchesExpectedLinearGain() {
        #expect(abs(TransportMapping.linearGain(fromDB: 6) - 1.9952623) < 0.0001)
    }

    private func makeTrack(duration: TimeInterval, offset: TimeInterval) -> LoadedTrack {
        LoadedTrack(
            url: URL(fileURLWithPath: "/tmp/test.wav"),
            displayName: "test.wav",
            fileFormatDescription: "WAV",
            duration: duration,
            sampleRate: 44_100,
            channelCount: 2,
            gainDB: 0,
            offsetSeconds: offset
        )
    }
}

struct TimelineViewportTests {
    @Test
    func fitIsVisibleSpanEqualToContentSpan() {
        #expect(TimelineViewport.isFit(visibleSpan: 100, contentSpan: 100))
        #expect(TimelineViewport.isFit(visibleSpan: 0, contentSpan: 0))
        #expect(!TimelineViewport.isFit(visibleSpan: 20, contentSpan: 100))
    }

    @Test
    func zoomIsContentSpanOverVisibleSpan() {
        #expect(TimelineViewport.zoom(visibleSpan: 20, contentSpan: 100) == 5)
        #expect(TimelineViewport.zoom(visibleSpan: 100, contentSpan: 100) == 1)
        // Never reports below 1 (fully zoomed out).
        #expect(TimelineViewport.zoom(visibleSpan: 200, contentSpan: 100) == 1)
    }

    @Test
    func maximumZoomUsesMinimumVisibleSpan() {
        #expect(TimelineViewport.maximumZoom(contentSpan: 100) == 200)
        // Content shorter than the minimum span cannot be zoomed.
        #expect(TimelineViewport.maximumZoom(contentSpan: 0.25) == 1)
    }

    @Test
    func clampedWindowKeepsSpanInsideContent() {
        let result = TimelineViewport.clampedWindow(
            visibleStart: 90,
            visibleSpan: 20,
            contentStart: 0,
            contentEnd: 100
        )
        #expect(result.span == 20)
        #expect(result.start == 80)
    }

    @Test
    func clampedWindowShrinksSpanLargerThanContent() {
        let result = TimelineViewport.clampedWindow(
            visibleStart: -10,
            visibleSpan: 250,
            contentStart: 0,
            contentEnd: 100
        )
        #expect(result.span == 100)
        #expect(result.start == 0)
    }

    @Test
    func anchorPrefersOnScreenPlayhead() {
        let anchor = TimelineViewport.anchor(transport: 50, visibleStart: 0, visibleSpan: 100)
        #expect(anchor.time == 50)
        #expect(anchor.fraction == 0.5)
    }

    @Test
    func anchorFallsBackToViewCentreWhenPlayheadOffScreen() {
        let anchor = TimelineViewport.anchor(transport: 95, visibleStart: 0, visibleSpan: 40)
        #expect(anchor.time == 20)
        #expect(anchor.fraction == 0.5)
    }

    @Test
    func rezoomKeepsAnchorAtSameOnScreenFraction() {
        let result = TimelineViewport.rezoom(
            newSpan: 20,
            anchorTime: 50,
            anchorFraction: 0.5,
            contentStart: 0,
            contentEnd: 100
        )
        #expect(result.span == 20)
        #expect(result.start == 40)
    }

    @Test
    func rezoomClampsToMaximumZoom() {
        // Below the 0.5 s minimum span gets clamped up to it.
        let result = TimelineViewport.rezoom(
            newSpan: 0.1,
            anchorTime: 50,
            anchorFraction: 0.5,
            contentStart: 0,
            contentEnd: 100
        )
        #expect(result.span == TimelineViewport.minimumVisibleSpan)
    }

    @Test
    func pagingStaysPutWhilePlayheadInsidePage() {
        #expect(TimelineViewport.pagedStart(
            transport: 30,
            visibleStart: 20,
            visibleSpan: 20,
            contentStart: 0,
            contentEnd: 100
        ) == nil)
    }

    @Test
    func pagingJumpsPlayheadToLeftEdgeWhenItReachesTheRightEdge() {
        #expect(TimelineViewport.pagedStart(
            transport: 40,
            visibleStart: 20,
            visibleSpan: 20,
            contentStart: 0,
            contentEnd: 100
        ) == 40)
    }

    @Test
    func pagingClampsTheFinalPageToContentEnd() {
        #expect(TimelineViewport.pagedStart(
            transport: 85,
            visibleStart: 60,
            visibleSpan: 20,
            contentStart: 0,
            contentEnd: 100
        ) == 80)
        // Window already pinned at the end: the playhead runs to the edge
        // without paging further.
        #expect(TimelineViewport.pagedStart(
            transport: 95,
            visibleStart: 80,
            visibleSpan: 20,
            contentStart: 0,
            contentEnd: 100
        ) == nil)
    }

    @Test
    func pagingBringsBackwardSeekIntoView() {
        #expect(TimelineViewport.pagedStart(
            transport: 5,
            visibleStart: 40,
            visibleSpan: 20,
            contentStart: 0,
            contentEnd: 100
        ) == 5)
    }

    @Test
    func contentChangeRefitsWhileZoomedOut() {
        let result = TimelineViewport.adjustedForContentChange(
            visibleStart: 0,
            visibleSpan: 100,
            previousContentSpan: 100,
            contentStart: 0,
            contentEnd: 160
        )
        #expect(result.start == 0)
        #expect(result.span == 160)
    }

    @Test
    func contentChangeKeepsSpanWhileZoomedIn() {
        let result = TimelineViewport.adjustedForContentChange(
            visibleStart: 40,
            visibleSpan: 20,
            previousContentSpan: 100,
            contentStart: 0,
            contentEnd: 160
        )
        #expect(result.start == 40)
        #expect(result.span == 20)
    }

    @Test
    func sliderValueRoundTripsThroughVisibleSpan() {
        let span = TimelineViewport.visibleSpan(sliderValue: 0.3038, contentSpan: 100)
        #expect(abs(span - 20) < 0.05)

        let value = TimelineViewport.sliderValue(visibleSpan: 20, contentSpan: 100)
        #expect(abs(value - 0.3038) < 0.001)
    }

    @Test
    func sliderEndsMapToFitAndMaximumZoom() {
        #expect(TimelineViewport.visibleSpan(sliderValue: 0, contentSpan: 100) == 100)
        #expect(abs(TimelineViewport.visibleSpan(sliderValue: 1, contentSpan: 100) - 0.5) < 0.0001)
    }

    @Test
    func stepZoomAppliesFixedMultiplicativeIncrement() {
        #expect(TimelineViewport.steppedVisibleSpan(visibleSpan: 30, zoomingIn: true) == 30 / 1.5)
        #expect(TimelineViewport.steppedVisibleSpan(visibleSpan: 30, zoomingIn: false) == 30 * 1.5)
    }

    @Test
    func pinchZoomScalesContinuouslyForZoomInAndOut() {
        #expect(TimelineViewport.magnifiedVisibleSpan(visibleSpan: 30, magnification: 0.5) < 30)
        #expect(TimelineViewport.magnifiedVisibleSpan(visibleSpan: 30, magnification: -0.5) > 30)
        #expect(TimelineViewport.magnifiedVisibleSpan(visibleSpan: 30, magnification: -1).isFinite)
    }

    @Test
    func scrollGeometryMapsVisibleStartToNativeOffset() {
        let scale = TimelineScrollGeometry.pointsPerSecond(viewportWidth: 800, visibleSpan: 20)
        #expect(scale == 40)

        let offset = TimelineScrollGeometry.scrollOffset(
            visibleStart: 35,
            contentStart: -5,
            pointsPerSecond: scale
        )
        #expect(offset == 1600)

        let start = TimelineScrollGeometry.visibleStart(
            scrollOffset: offset,
            contentStart: -5,
            pointsPerSecond: scale
        )
        #expect(start == 35)
    }

    @Test
    func scrollGeometrySnapsSubpixelOffsetsToContentEdges() {
        let scale = TimelineScrollGeometry.pointsPerSecond(viewportWidth: 800, visibleSpan: 20)

        let start = TimelineScrollGeometry.visibleStart(
            scrollOffset: 0.25,
            contentStart: 0,
            contentEnd: 100,
            visibleSpan: 20,
            pointsPerSecond: scale
        )
        #expect(start == 0)

        let end = TimelineScrollGeometry.visibleStart(
            scrollOffset: 3200.25,
            contentStart: 0,
            contentEnd: 100,
            visibleSpan: 20,
            pointsPerSecond: scale
        )
        #expect(end == 80)
    }

    @Test
    func scrollGeometryDocumentWidthTracksZoom() {
        #expect(TimelineScrollGeometry.documentWidth(contentSpan: 100, visibleSpan: 100, viewportWidth: 800) == 800)
        #expect(TimelineScrollGeometry.documentWidth(contentSpan: 100, visibleSpan: 20, viewportWidth: 800) == 4000)
    }

    @Test
    func scrollGeometryViewportFractionSubtractsVisibleOrigin() {
        #expect(TimelineScrollGeometry.viewportFraction(locationX: 1800, visibleOriginX: 1400, viewportWidth: 800) == 0.5)
        #expect(TimelineScrollGeometry.viewportFraction(locationX: 1390, visibleOriginX: 1400, viewportWidth: 800) == 0)
        #expect(TimelineScrollGeometry.viewportFraction(locationX: 2210, visibleOriginX: 1400, viewportWidth: 800) == 1)
    }
}
