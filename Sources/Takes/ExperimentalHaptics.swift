import AppKit
import SwiftUI

enum ExperimentalHapticPatternOption: String, CaseIterable, Identifiable {
    case off
    case alignment
    case levelChange
    case generic

    var id: String { rawValue }

    var feedbackPattern: NSHapticFeedbackManager.FeedbackPattern? {
        switch self {
        case .off: return nil
        case .alignment: return .alignment
        case .levelChange: return .levelChange
        case .generic: return .generic
        }
    }
}

enum ExperimentalHapticTriggerGate {
    private static let fitTolerance = 0.0001
    private static let maximumTolerance = 0.9999

    static func zoomThresholdBucket(for progress: Double) -> Int {
        let clamped = clamp(progress)
        switch clamped {
        case ...fitTolerance:
            return 0
        case ..<0.25:
            return 1
        case ..<0.5:
            return 2
        case ..<0.75:
            return 3
        case ..<maximumTolerance:
            return 4
        default:
            return 5
        }
    }

    private static func clamp(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
        return min(max(progress, 0), 1)
    }
}

@MainActor
final class ExperimentalHapticsController: ObservableObject {
    private var zoomThresholdBucket: Int?
    private let performer: NSHapticFeedbackPerformer
    private let zoomControlPattern = ExperimentalHapticPatternOption.levelChange

    init(performer: NSHapticFeedbackPerformer = NSHapticFeedbackManager.defaultPerformer) {
        self.performer = performer
    }

    func syncZoomProgress(_ progress: Double) {
        zoomThresholdBucket = ExperimentalHapticTriggerGate.zoomThresholdBucket(for: progress)
    }

    func updateZoomProgress(_ progress: Double) {
        let bucket = ExperimentalHapticTriggerGate.zoomThresholdBucket(for: progress)
        defer { zoomThresholdBucket = bucket }
        guard let previousBucket = zoomThresholdBucket, previousBucket != bucket else { return }
        perform(zoomControlPattern)
    }

    private func perform(_ pattern: ExperimentalHapticPatternOption) {
        guard let feedbackPattern = pattern.feedbackPattern else { return }
        performer.perform(feedbackPattern, performanceTime: .now)
    }
}
