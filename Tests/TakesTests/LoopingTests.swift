import Foundation
import Testing
@testable import Takes

struct LoopingTests {
    // MARK: - RepeatMode

    @Test
    func repeatModeCyclesOffOneSwitch() {
        #expect(RepeatMode.off.next == .one)
        #expect(RepeatMode.one.next == .switchAndRepeat)
        #expect(RepeatMode.switchAndRepeat.next == .off)
    }

    // MARK: - advanceAtEnd

    @Test
    func advanceAtEndStopsWhenRepeatOff() {
        #expect(PlaybackController.advanceAtEnd(mode: .off, canSwitch: false) == .stop)
        #expect(PlaybackController.advanceAtEnd(mode: .off, canSwitch: true) == .stop)
    }

    @Test
    func advanceAtEndRestartsForRepeatOne() {
        #expect(PlaybackController.advanceAtEnd(mode: .one, canSwitch: false) == .restart)
        #expect(PlaybackController.advanceAtEnd(mode: .one, canSwitch: true) == .restart)
    }

    @Test
    func advanceAtEndSwitchesOnlyWhenMoreThanOneTrack() {
        #expect(PlaybackController.advanceAtEnd(mode: .switchAndRepeat, canSwitch: true) == .switchThenRestart)
        // A single track has nothing to switch to, so it just restarts.
        #expect(PlaybackController.advanceAtEnd(mode: .switchAndRepeat, canSwitch: false) == .restart)
    }

    // MARK: - LoopRegion.normalized

    @Test
    func normalizedOrdersEndpointsAndKeepsWithinTimeline() {
        let region = LoopRegion.normalized(start: 8, end: 3, timelineStart: 0, timelineEnd: 20)
        #expect(region == LoopRegion(start: 3, end: 8))
    }

    @Test
    func normalizedClampsToTimelineBounds() {
        let region = LoopRegion.normalized(start: -5, end: 100, timelineStart: 0, timelineEnd: 20)
        #expect(region == LoopRegion(start: 0, end: 20))
    }

    @Test
    func normalizedWidensTinyDragToMinimumLength() {
        let region = try! #require(LoopRegion.normalized(start: 5, end: 5.001, timelineStart: 0, timelineEnd: 20))
        #expect(region.end - region.start >= LoopRegion.minimumLength)
        #expect(region.start == 5)
    }

    @Test
    func normalizedPullsMinimumLengthLoopBackFromTheEnd() {
        // A tiny drag at the very end still fits by moving the start left.
        let region = try! #require(LoopRegion.normalized(start: 20, end: 20, timelineStart: 0, timelineEnd: 20))
        #expect(region.end == 20)
        #expect(region.start == 20 - LoopRegion.minimumLength)
    }

    @Test
    func normalizedReturnsNilWhenTimelineTooShort() {
        #expect(LoopRegion.normalized(start: 0, end: 0.01, timelineStart: 0, timelineEnd: 0.01) == nil)
    }

    // MARK: - Session playback bounds

    @Test
    func playbackBoundsFollowTimelineWithoutLoop() {
        var session = ComparisonSession()
        session.timelineStart = -4
        session.timelineEnd = 30
        #expect(session.playbackStart == -4)
        #expect(session.playbackEnd == 30)
    }

    @Test
    func playbackBoundsFollowLoopWhenActive() {
        var session = ComparisonSession()
        session.timelineStart = 0
        session.timelineEnd = 30
        session.loopRegion = LoopRegion(start: 5, end: 12)
        #expect(session.playbackStart == 5)
        #expect(session.playbackEnd == 12)
    }
}
