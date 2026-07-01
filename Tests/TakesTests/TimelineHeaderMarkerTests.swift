import Testing
@testable import Takes

struct TimelineHeaderMarkerTests {
    private let target = 7

    // MARK: - Interval selection

    @Test(arguments: [
        (0.5, 0.1),
        (2.0, 0.5),
        (20.0, 5.0),
        (120.0, 30.0),
        (600.0, 120.0),
        (3600.0, 600.0)
    ])
    func readableIntervalPicksNiceLadderValue(span: TimeInterval, expected: TimeInterval) {
        let interval = TimelineHeaderMarker.readableInterval(for: span / Double(target))
        #expect(interval == expected)
    }

    @Test(arguments: [0.5, 2.0, 20.0, 120.0, 600.0, 3600.0, 84.0])
    func tickCountStaysNearTarget(span: TimeInterval) {
        // Worst-case alignment: start the window just after a tick boundary.
        let markers = TimelineHeaderMarker.markers(
            timelineStart: 0.01,
            timelineEnd: 0.01 + span,
            targetMarkerCount: target
        )
        #expect((4...9).contains(markers.count))
    }

    @Test
    func readableIntervalClampsToLadderEnds() {
        #expect(TimelineHeaderMarker.readableInterval(for: 0.0001) == 0.1)
        #expect(TimelineHeaderMarker.readableInterval(for: 1_000_000) == 86400)
    }

    @Test
    func readableIntervalGuardsNonFiniteAndNonPositive() {
        #expect(TimelineHeaderMarker.readableInterval(for: 0) == 0.1)
        #expect(TimelineHeaderMarker.readableInterval(for: -5) == 0.1)
        #expect(TimelineHeaderMarker.readableInterval(for: .nan) == 0.1)
        #expect(TimelineHeaderMarker.readableInterval(for: .infinity) == 0.1)
    }

    // MARK: - Sub-second labels

    @Test
    func subSecondIntervalLabelsTenths() {
        #expect((3.5).formattedSignedTimestamp(forInterval: 0.5) == "0:03.5")
        #expect((63.2).formattedSignedTimestamp(forInterval: 0.1) == "1:03.2")
    }

    @Test
    func subSecondLabelsKeepSign() {
        #expect((-0.5).formattedSignedTimestamp(forInterval: 0.5) == "-0:00.5")
    }

    // MARK: - Integer labels unchanged

    @Test
    func wholeSecondIntervalLabelsMatchExistingFormat() {
        #expect((3.0).formattedSignedTimestamp(forInterval: 1) == "00:03")
        #expect((3.0).formattedSignedTimestamp(forInterval: 1) == (3.0).formattedSignedTimestamp)
        #expect((3725.0).formattedSignedTimestamp(forInterval: 30) == "1:02:05")
        #expect((-65.0).formattedSignedTimestamp(forInterval: 5) == "-01:05")
    }

    // MARK: - First-tick alignment

    @Test
    func firstMarkerIsSmallestIntervalMultipleAtOrAboveStart() {
        let start: TimeInterval = 7.3
        let end: TimeInterval = 50
        let markers = TimelineHeaderMarker.markers(
            timelineStart: start,
            timelineEnd: end,
            targetMarkerCount: target
        )
        let interval = TimelineHeaderMarker.readableInterval(for: (end - start) / Double(target))
        let first = try! #require(markers.first)

        #expect(first.time >= start)
        #expect(first.time - interval < start)
        for marker in markers {
            #expect(marker.time >= start)
            #expect(marker.time <= end + 0.0001)
        }
    }

    // MARK: - Degenerate spans

    @Test
    func zeroOrNegativeSpanYieldsNoMarkers() {
        #expect(TimelineHeaderMarker.markers(timelineStart: 5, timelineEnd: 5, targetMarkerCount: target).isEmpty)
        #expect(TimelineHeaderMarker.markers(timelineStart: 5, timelineEnd: 1, targetMarkerCount: target).isEmpty)
    }

    @Test
    func zeroOrNegativeSpanYieldsEmptyRuler() {
        let ruler = TimelineHeaderMarker.ruler(timelineStart: 5, timelineEnd: 5, targetMarkerCount: target)
        #expect(ruler.majorTicks.isEmpty)
        #expect(ruler.minorTicks.isEmpty)
        #expect(ruler.minorInterval == 0)
    }

    // MARK: - Minor ticks

    @Test
    func minorDivisionsKeepMinorStepsRound() {
        // Every ladder interval divided by its chosen divisor must yield another ladder-grade value.
        for interval in TimelineHeaderMarker.niceIntervals {
            let divisions = TimelineHeaderMarker.minorDivisions(for: interval)
            #expect(divisions >= 1)
            #expect(interval.truncatingRemainder(dividingBy: interval / Double(divisions)) < interval * 0.0001)
        }
    }

    @Test
    func minorTicksSubdivideMajorIntervalAndSkipMajors() {
        // span 20 → major interval 5, divisor 5 → minor every 1 s.
        let ruler = TimelineHeaderMarker.ruler(timelineStart: 0, timelineEnd: 20, targetMarkerCount: target)
        #expect(ruler.majorTicks.map(\.time) == [0, 5, 10, 15, 20])
        #expect(ruler.minorInterval == 1)
        // Minor ticks fill every whole second except those that coincide with a major tick.
        let expectedMinors = (0...20).map(Double.init).filter { $0.truncatingRemainder(dividingBy: 5) != 0 }
        #expect(ruler.minorTicks == expectedMinors)
        // No minor tick ever lands on a major tick.
        let majorTimes = Set(ruler.majorTicks.map(\.time))
        #expect(ruler.minorTicks.allSatisfy { !majorTimes.contains($0) })
    }

    @Test
    func leadingMajorTicksEmitLabelsBeforeTheWindowWithoutChangingSpacing() {
        // span 20 → major interval 5. Baseline first tick is 0.
        let baseline = TimelineHeaderMarker.ruler(timelineStart: 0, timelineEnd: 20, targetMarkerCount: target)
        #expect(baseline.majorTicks.map(\.time) == [0, 5, 10, 15, 20])

        // Requesting a leading tick prepends one interval before the window so its label can clip at
        // the left edge; the interval and all in-window ticks are unchanged.
        let extended = TimelineHeaderMarker.ruler(
            timelineStart: 0,
            timelineEnd: 20,
            targetMarkerCount: target,
            leadingMajorTicks: 1
        )
        #expect(extended.majorTicks.map(\.time) == [-5, 0, 5, 10, 15, 20])
        #expect(extended.minorInterval == baseline.minorInterval)
        // Minor ticks are unaffected — only labeled major ticks reach past the edge.
        #expect(extended.minorTicks == baseline.minorTicks)
    }

    @Test
    func leadingMajorTicksStepBackFromTheFirstInWindowTick() {
        // Window starting off a tick boundary: first in-window major tick is 6, so the leading tick
        // is exactly one interval (2 s) earlier at 4 — not `timelineStart`.
        let ruler = TimelineHeaderMarker.ruler(
            timelineStart: 5,
            timelineEnd: 17,
            targetMarkerCount: target,
            leadingMajorTicks: 1
        )
        let interval = TimelineHeaderMarker.readableInterval(for: (17.0 - 5.0) / Double(target))
        let times = ruler.majorTicks.map(\.time)
        let first = try! #require(times.first)
        let second = try! #require(times.dropFirst().first)
        #expect(second - first == interval)
        #expect(first < 5)
    }

    @Test
    func minorTicksStayWithinVisibleWindow() {
        let start: TimeInterval = 3.4
        let end: TimeInterval = 47.8
        let ruler = TimelineHeaderMarker.ruler(timelineStart: start, timelineEnd: end, targetMarkerCount: target)
        #expect(!ruler.minorTicks.isEmpty)
        for tick in ruler.minorTicks {
            #expect(tick >= start - 0.0001)
            #expect(tick <= end + 0.0001)
        }
    }
}
