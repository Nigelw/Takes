import Testing
@testable import Takes

struct ExperimentalHapticsTests {
    @Test(arguments: [
        (-1.0, 0),
        (0.0, 0),
        (0.0001, 0),
        (0.01, 1),
        (0.24, 1),
        (0.25, 2),
        (0.49, 2),
        (0.5, 3),
        (0.74, 3),
        (0.75, 4),
        (0.99, 4),
        (1.0, 5),
        (.infinity, 0)
    ])
    func zoomThresholdBucketUsesFitQuarterAndMaxStops(progress: Double, expectedBucket: Int) {
        #expect(ExperimentalHapticTriggerGate.zoomThresholdBucket(for: progress) == expectedBucket)
    }

    @Test
    func edgeEntryOnlyFiresWhenEnteringANewEdge() {
        #expect(!ExperimentalHapticTriggerGate.shouldFireOnEntry(previous: nil as ExperimentalHapticEdge?, current: nil))
        #expect(ExperimentalHapticTriggerGate.shouldFireOnEntry(previous: nil as ExperimentalHapticEdge?, current: .leading))
        #expect(!ExperimentalHapticTriggerGate.shouldFireOnEntry(
            previous: ExperimentalHapticEdge.leading,
            current: ExperimentalHapticEdge.leading
        ))
        #expect(ExperimentalHapticTriggerGate.shouldFireOnEntry(
            previous: ExperimentalHapticEdge.leading,
            current: ExperimentalHapticEdge.trailing
        ))
        #expect(!ExperimentalHapticTriggerGate.shouldFireOnEntry(
            previous: ExperimentalHapticEdge.trailing,
            current: nil as ExperimentalHapticEdge?
        ))
    }

    @Test
    func hoverOnlyFiresOnInactiveToActiveTransition() {
        #expect(!ExperimentalHapticTriggerGate.shouldFireHover(previous: false, current: false))
        #expect(ExperimentalHapticTriggerGate.shouldFireHover(previous: false, current: true))
        #expect(!ExperimentalHapticTriggerGate.shouldFireHover(previous: true, current: true))
        #expect(!ExperimentalHapticTriggerGate.shouldFireHover(previous: true, current: false))
    }
}
