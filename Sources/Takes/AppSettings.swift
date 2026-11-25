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

/// Whether playlist imports group tracks by title.
enum AutomaticGroupingMode: String {
    case off
    case automatic

    var explanation: String {
        switch self {
        case .off:
            return "Add every file as a separate playlist item."
        case .automatic:
            return "Group tracks with similar titles, using filenames when title tags are missing."
        }
    }
}

enum TrackMetadataField: String, CaseIterable, Identifiable {
    case artist, album, format, sampleRate, bitrate

    static let compareFields: [Self] = [.format, .sampleRate, .bitrate]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .artist: return "Artist"
        case .album: return "Album"
        case .format: return "Format"
        case .sampleRate: return "Sample Rate"
        case .bitrate: return "Bitrate"
        }
    }
}

/// User-facing preferences that persist across launches.
///
/// The offset nudge amounts are stored here so they can be adjusted from the
/// Settings window. The defaults mirror `NumericControlConfiguration.offset`,
/// keeping a single source of truth for the shipped values.
protocol AppSettingsDefaults {
    func object(forKey defaultName: String) -> Any?
    func string(forKey defaultName: String) -> String?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: AppSettingsDefaults {}

struct WorkspaceVisibility: Equatable {
    enum Region: CaseIterable {
        case artwork, player, playlist
    }

    private(set) var showsArtwork: Bool
    private(set) var showsPlayer: Bool
    private(set) var showsPlaylist: Bool

    init(showsArtwork: Bool = true, showsPlayer: Bool = true, showsPlaylist: Bool = true) {
        self.showsArtwork = showsArtwork
        self.showsPlayer = showsPlayer || !showsArtwork
        self.showsPlaylist = showsPlaylist
    }

    subscript(region: Region) -> Bool {
        switch region {
        case .artwork: showsArtwork
        case .player: showsPlayer
        case .playlist: showsPlaylist
        }
    }

    func canToggle(_ region: Region) -> Bool {
        switch region {
        case .artwork: showsPlayer
        case .player: showsArtwork
        case .playlist: true
        }
    }

    mutating func toggle(_ region: Region) {
        guard canToggle(region) else { return }
        switch region {
        case .artwork: showsArtwork.toggle()
        case .player: showsPlayer.toggle()
        case .playlist: showsPlaylist.toggle()
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    nonisolated static let offsetStepDefault = NumericControlConfiguration.offset.step
    nonisolated static let offsetLargeStepDefault = NumericControlConfiguration.offset.largeStep
    nonisolated static let offsetStepRange = 1...10_000
    nonisolated static let alignTracksOnOpenDefault = false
    nonisolated static let appearanceThemeDefault: AppearanceTheme = .system
    nonisolated static let automaticGroupingModeDefault: AutomaticGroupingMode = .automatic
    nonisolated static let playlistMetadataFieldsDefault: Set<TrackMetadataField> = [.artist]
    nonisolated static let compareMetadataFieldsDefault = Set(TrackMetadataField.compareFields)

    nonisolated static let offsetStepKey = "offsetNudgeStep"
    nonisolated static let offsetLargeStepKey = "offsetLargeNudgeStep"
    nonisolated static let alignTracksOnOpenKey = "alignTracksOnOpen"
    nonisolated static let appearanceThemeKey = "appearanceTheme"
    nonisolated static let automaticGroupingModeKey = "automaticGroupingMode"
    nonisolated static let playlistMetadataFieldsKey = "playlistMetadataFields"
    nonisolated static let compareMetadataFieldsKey = "compareMetadataFields"
    nonisolated static let showsArtworkKey = "showsArtwork"
    nonisolated static let showsPlayerKey = "showsPlayer"
    nonisolated static let showsPlaylistKey = "showsPlaylist"
    nonisolated static let appearanceThemeOverrideArgument = "--appearance-theme"

    private let defaults: AppSettingsDefaults

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

    /// Whether playlist imports group tracks from descriptive metadata.
    @Published var automaticGroupingMode: AutomaticGroupingMode {
        didSet { defaults.set(automaticGroupingMode.rawValue, forKey: Self.automaticGroupingModeKey) }
    }

    @Published var playlistMetadataFields: Set<TrackMetadataField> {
        didSet { defaults.set(playlistMetadataFields.map(\.rawValue).sorted(), forKey: Self.playlistMetadataFieldsKey) }
    }

    @Published var compareMetadataFields: Set<TrackMetadataField> {
        didSet { defaults.set(compareMetadataFields.map(\.rawValue).sorted(), forKey: Self.compareMetadataFieldsKey) }
    }

    /// Shared by playlist and comparison. Settings' Restore Defaults leaves
    /// the window layout alone.
    @Published var windowVisibility: WorkspaceVisibility {
        didSet {
            defaults.set(windowVisibility.showsArtwork, forKey: Self.showsArtworkKey)
            defaults.set(windowVisibility.showsPlayer, forKey: Self.showsPlayerKey)
            defaults.set(windowVisibility.showsPlaylist, forKey: Self.showsPlaylistKey)
        }
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
        defaults: AppSettingsDefaults = UserDefaults.standard,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        self.defaults = defaults
        offsetStep = Self.storedOffsetStep(defaults)
        offsetLargeStep = Self.storedOffsetLargeStep(defaults)
        alignTracksOnOpen = Self.storedAlignTracksOnOpen(defaults)
        appearanceTheme = Self.appearanceThemeOverride(arguments: arguments) ?? Self.storedAppearanceTheme(defaults)
        automaticGroupingMode = Self.storedAutomaticGroupingMode(defaults)
        playlistMetadataFields = Self.storedMetadataFields(defaults, key: Self.playlistMetadataFieldsKey)
            ?? Self.playlistMetadataFieldsDefault
        compareMetadataFields = Self.storedMetadataFields(defaults, key: Self.compareMetadataFieldsKey)?
            .intersection(Self.compareMetadataFieldsDefault) ?? Self.compareMetadataFieldsDefault
        windowVisibility = WorkspaceVisibility(
            showsArtwork: defaults.object(forKey: Self.showsArtworkKey) as? Bool ?? true,
            showsPlayer: defaults.object(forKey: Self.showsPlayerKey) as? Bool ?? true,
            showsPlaylist: defaults.object(forKey: Self.showsPlaylistKey) as? Bool ?? true
        )
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
        automaticGroupingMode = Self.automaticGroupingModeDefault
        playlistMetadataFields = Self.playlistMetadataFieldsDefault
        compareMetadataFields = Self.compareMetadataFieldsDefault
        transportAppearance = TransportAppearance()
        indexBadgeAppearance = IndexBadgeAppearance()
    }

    var settingsAreDefault: Bool {
        offsetStep == Self.offsetStepDefault
            && offsetLargeStep == Self.offsetLargeStepDefault
            && alignTracksOnOpen == Self.alignTracksOnOpenDefault
            && appearanceTheme == Self.appearanceThemeDefault
            && automaticGroupingMode == Self.automaticGroupingModeDefault
            && playlistMetadataFields == Self.playlistMetadataFieldsDefault
            && compareMetadataFields == Self.compareMetadataFieldsDefault
            && transportAppearance == TransportAppearance()
            && indexBadgeAppearance == IndexBadgeAppearance()
    }

    nonisolated static func clamp(_ value: Int) -> Int {
        min(max(value, offsetStepRange.lowerBound), offsetStepRange.upperBound)
    }

    private static func storedMetadataFields(_ defaults: AppSettingsDefaults, key: String) -> Set<TrackMetadataField>? {
        guard let fields = defaults.object(forKey: key) as? [String] else { return nil }
        return Set(fields.compactMap(TrackMetadataField.init(rawValue:)))
    }

    nonisolated static func storedOffsetStep(_ defaults: AppSettingsDefaults = UserDefaults.standard) -> Int {
        clamp(defaults.object(forKey: offsetStepKey) as? Int ?? offsetStepDefault)
    }

    nonisolated static func storedOffsetLargeStep(_ defaults: AppSettingsDefaults = UserDefaults.standard) -> Int {
        clamp(defaults.object(forKey: offsetLargeStepKey) as? Int ?? offsetLargeStepDefault)
    }

    nonisolated static func storedAlignTracksOnOpen(_ defaults: AppSettingsDefaults = UserDefaults.standard) -> Bool {
        defaults.object(forKey: alignTracksOnOpenKey) as? Bool ?? alignTracksOnOpenDefault
    }

    nonisolated static func storedAppearanceTheme(_ defaults: AppSettingsDefaults = UserDefaults.standard) -> AppearanceTheme {
        defaults.string(forKey: appearanceThemeKey).flatMap(AppearanceTheme.init(rawValue:)) ?? appearanceThemeDefault
    }

    nonisolated static func storedAutomaticGroupingMode(_ defaults: AppSettingsDefaults = UserDefaults.standard) -> AutomaticGroupingMode {
        guard let stored = defaults.string(forKey: automaticGroupingModeKey) else {
            return automaticGroupingModeDefault
        }
        if let mode = AutomaticGroupingMode(rawValue: stored) { return mode }
        // Migrate preferences written by the retired audio-analysis modes.
        if stored == "sameRecording" || stored == "samePerformance" { return .automatic }
        return automaticGroupingModeDefault
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
