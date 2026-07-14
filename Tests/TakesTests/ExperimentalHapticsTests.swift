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
    func patternOptionMapsLevelChangeToNativeFeedback() {
        #expect(ExperimentalHapticPatternOption.levelChange.feedbackPattern == .levelChange)
    }
}
