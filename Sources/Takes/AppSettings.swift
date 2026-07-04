import AppKit

/// The app's overall light/dark appearance. `.system` defers to the OS setting.
enum AppearanceTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The AppKit appearance to force, or `nil` to follow the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Visual treatment for the transport time readout.
enum ReadoutStyle: String, CaseIterable, Identifiable {
    static let allCases: [ReadoutStyle] = [.glass, .retro]

    /// A convex glass tile resting directly on the transport bar: no bezel, a
    /// domed highlight where the glass catches the light, edges dipping just
    /// below the surrounding surface.
    case glass

    /// Seven-segment LED/LCD display behind dark glass, styled like an 80s rack
    /// unit's counter — glowing digits in dark mode, an amber-backlit LCD in light.
    case retro

    var id: String { rawValue }

    var title: String {
        switch self {
        case .retro: return "Retro"
        case .glass: return "Glass"
        }
    }
}

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
    nonisolated static let alignTracksOnOpenDefault = false
    nonisolated static let appearanceThemeDefault: AppearanceTheme = .system
    nonisolated static let readoutStyleDefault: ReadoutStyle = .glass

    nonisolated static let offsetStepKey = "offsetNudgeStep"
    nonisolated static let offsetLargeStepKey = "offsetLargeNudgeStep"
    nonisolated static let alignTracksOnOpenKey = "alignTracksOnOpen"
    nonisolated static let appearanceThemeKey = "appearanceTheme"
    nonisolated static let readoutStyleKey = "readoutStyle"
    nonisolated static let appearanceThemeOverrideArgument = "--appearance-theme"

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

    @Published var alignTracksOnOpen: Bool {
        didSet { defaults.set(alignTracksOnOpen, forKey: Self.alignTracksOnOpenKey) }
    }

    /// The app's light/dark appearance. Persisted; applied app-wide via
    /// `NSApp.appearance`.
    @Published var appearanceTheme: AppearanceTheme {
        didSet { defaults.set(appearanceTheme.rawValue, forKey: Self.appearanceThemeKey) }
    }

    /// The transport readout's visual style. Persisted.
    @Published var readoutStyle: ReadoutStyle {
        didSet { defaults.set(readoutStyle.rawValue, forKey: Self.readoutStyleKey) }
    }

    /// When enabled, the main window overlays each major UI component with a
    /// labelled badge naming its region. A developer aid for discussing the
    /// layout during redesign work; toggled from the Help menu. Intentionally
    /// not persisted so it never leaks into a normal launch.
    @Published var showsComponentDebugLabels = false

    /// Live-tunable transport button surface treatment (separate primary and
    /// secondary values), adjusted from the Appearance Tuner. Session-only.
    @Published var transportAppearance = TransportAppearance()

    /// Live-tunable index-badge bevel/shadow, adjusted from the Appearance
    /// Tuner. Session-only (not persisted) — a developer aid.
    @Published var indexBadgeAppearance = IndexBadgeAppearance()

    init(
        defaults: UserDefaults = .standard,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        self.defaults = defaults
        offsetStep = Self.storedOffsetStep(defaults)
        offsetLargeStep = Self.storedOffsetLargeStep(defaults)
        alignTracksOnOpen = Self.storedAlignTracksOnOpen(defaults)
        appearanceTheme = Self.appearanceThemeOverride(arguments: arguments) ?? Self.storedAppearanceTheme(defaults)
        readoutStyle = Self.storedReadoutStyle(defaults)
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

    func restoreDefaults() {
        offsetStep = Self.offsetStepDefault
        offsetLargeStep = Self.offsetLargeStepDefault
        alignTracksOnOpen = Self.alignTracksOnOpenDefault
        appearanceTheme = Self.appearanceThemeDefault
        readoutStyle = Self.readoutStyleDefault
        transportAppearance = TransportAppearance()
        indexBadgeAppearance = IndexBadgeAppearance()
    }

    var settingsAreDefault: Bool {
        offsetStep == Self.offsetStepDefault
            && offsetLargeStep == Self.offsetLargeStepDefault
            && alignTracksOnOpen == Self.alignTracksOnOpenDefault
            && appearanceTheme == Self.appearanceThemeDefault
            && readoutStyle == Self.readoutStyleDefault
            && transportAppearance == TransportAppearance()
            && indexBadgeAppearance == IndexBadgeAppearance()
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

    nonisolated static func storedAlignTracksOnOpen(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: alignTracksOnOpenKey) as? Bool ?? alignTracksOnOpenDefault
    }

    nonisolated static func storedAppearanceTheme(_ defaults: UserDefaults = .standard) -> AppearanceTheme {
        defaults.string(forKey: appearanceThemeKey).flatMap(AppearanceTheme.init(rawValue:)) ?? appearanceThemeDefault
    }

    nonisolated static func storedReadoutStyle(_ defaults: UserDefaults = .standard) -> ReadoutStyle {
        defaults.string(forKey: readoutStyleKey).flatMap(ReadoutStyle.init(rawValue:)) ?? readoutStyleDefault
    }

    nonisolated static func appearanceThemeOverride(arguments: [String]) -> AppearanceTheme? {
        for (index, argument) in arguments.enumerated() {
            if argument == appearanceThemeOverrideArgument,
               arguments.indices.contains(index + 1),
               let theme = AppearanceTheme(rawValue: arguments[index + 1].lowercased()) {
                return theme
            }

            let prefix = "\(appearanceThemeOverrideArgument)="
            if argument.hasPrefix(prefix) {
                let value = String(argument.dropFirst(prefix.count))
                if let theme = AppearanceTheme(rawValue: value.lowercased()) {
                    return theme
                }
            }
        }

        return nil
    }
}
