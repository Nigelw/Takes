import Foundation

/// User-facing preferences that persist across launches.
///
/// The offset nudge amounts are stored here so they can be adjusted from the
/// Settings window. The defaults mirror `NumericControlConfiguration.offset`,
/// keeping a single source of truth for the shipped values.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    nonisolated static let offsetStepDefault = NumericControlConfiguration.offset.step
    nonisolated static let offsetLargeStepDefault = NumericControlConfiguration.offset.largeStep
    nonisolated static let offsetStepRange = 1...10_000

    nonisolated static let offsetStepKey = "offsetNudgeStep"
    nonisolated static let offsetLargeStepKey = "offsetLargeNudgeStep"

    private let defaults: UserDefaults

    @Published var offsetStep: Int {
        didSet {
            let clamped = Self.clamp(offsetStep)
            guard clamped == offsetStep else {
                offsetStep = clamped
                return
            }
            defaults.set(offsetStep, forKey: Self.offsetStepKey)
        }
    }

    @Published var offsetLargeStep: Int {
        didSet {
            let clamped = Self.clamp(offsetLargeStep)
            guard clamped == offsetLargeStep else {
                offsetLargeStep = clamped
                return
            }
            defaults.set(offsetLargeStep, forKey: Self.offsetLargeStepKey)
        }
    }

    /// When enabled, the main window overlays each major UI component with a
    /// labelled badge naming its region. A developer aid for discussing the
    /// layout during redesign work; toggled from the Help menu. Intentionally
    /// not persisted so it never leaks into a normal launch.
    @Published var showsComponentDebugLabels = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        offsetStep = Self.storedOffsetStep(defaults)
        offsetLargeStep = Self.storedOffsetLargeStep(defaults)
    }

    /// The offset control configuration reflecting the user's chosen nudge amounts.
    var offsetConfiguration: NumericControlConfiguration {
        NumericControlConfiguration(
            range: NumericControlConfiguration.offset.range,
            step: offsetStep,
            largeStep: offsetLargeStep,
            suffix: NumericControlConfiguration.offset.suffix
        )
    }

    func restoreOffsetDefaults() {
        offsetStep = Self.offsetStepDefault
        offsetLargeStep = Self.offsetLargeStepDefault
    }

    var offsetAmountsAreDefault: Bool {
        offsetStep == Self.offsetStepDefault && offsetLargeStep == Self.offsetLargeStepDefault
    }

    nonisolated static func clamp(_ value: Int) -> Int {
        min(max(value, offsetStepRange.lowerBound), offsetStepRange.upperBound)
    }

    nonisolated static func storedOffsetStep(_ defaults: UserDefaults = .standard) -> Int {
        clamp(defaults.object(forKey: offsetStepKey) as? Int ?? offsetStepDefault)
    }

    nonisolated static func storedOffsetLargeStep(_ defaults: UserDefaults = .standard) -> Int {
        clamp(defaults.object(forKey: offsetLargeStepKey) as? Int ?? offsetLargeStepDefault)
    }
}
