import Foundation
import Sparkle

/// The persisted choice to include beta builds in Sparkle update checks.
enum BetaUpdatePreference {
    /// The Sparkle channel beta appcast items are published to.
    static let betaChannel = "beta"

    static let key = "includeBetaBuilds"
    static let includesBetaBuildsDefault = false

    static func includesBetaBuilds(in defaults: AppSettingsDefaults = UserDefaults.standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? includesBetaBuildsDefault
    }

    static func allowedSparkleChannels(in defaults: AppSettingsDefaults = UserDefaults.standard) -> Set<String> {
        includesBetaBuilds(in: defaults) ? [betaChannel] : []
    }
}

/// Supplies the user's selected update channel when Sparkle starts a check.
///
/// Sparkle retains its updater delegate weakly, so `SoftwareUpdater` owns this
/// object for the controller's lifetime.
@MainActor
final class UpdateChannelUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private let defaults: AppSettingsDefaults

    init(defaults: AppSettingsDefaults) {
        self.defaults = defaults
    }

    /// Sparkle asks for the allowed channels on every appcast parse, so this
    /// reads the stored preference each time: toggling it takes effect on the
    /// next check without restarting the updater.
    func currentAllowedChannels() -> Set<String> {
        BetaUpdatePreference.allowedSparkleChannels(in: defaults)
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        currentAllowedChannels()
    }
}

/// How often Takes checks for new versions automatically.
enum UpdateCheckFrequency: Int, CaseIterable, Identifiable {
    case daily
    case weekly
    case monthly

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }

    var interval: TimeInterval {
        switch self {
        case .daily: return 60 * 60 * 24
        case .weekly: return 60 * 60 * 24 * 7
        case .monthly: return 60 * 60 * 24 * 30
        }
    }

    /// The frequency whose interval is closest to a stored Sparkle interval.
    static func closest(to interval: TimeInterval) -> UpdateCheckFrequency {
        allCases.min(by: { abs($0.interval - interval) < abs($1.interval - interval) }) ?? .weekly
    }
}

/// Bridges Sparkle's `SPUUpdater` to SwiftUI, exposing the update preferences
/// and actions the Settings window needs.
///
/// Only the beta-channel preference is read from the injected `defaults`;
/// Sparkle keeps its own settings in the standard user defaults regardless.
@MainActor
final class SoftwareUpdater: ObservableObject {
    private let defaults: AppSettingsDefaults
    private let updateChannelDelegate: UpdateChannelUpdaterDelegate
    private let controller: SPUStandardUpdaterController
    private var updater: SPUUpdater { controller.updater }
    private var observers: [NSKeyValueObservation] = []

    @Published var includesBetaBuilds: Bool {
        didSet {
            defaults.set(includesBetaBuilds, forKey: BetaUpdatePreference.key)
        }
    }

    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            if !automaticallyChecksForUpdates {
                automaticallyDownloadsUpdates = false
            }
            guard updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    @Published var automaticallyDownloadsUpdates: Bool {
        didSet {
            guard updater.automaticallyDownloadsUpdates != automaticallyDownloadsUpdates else { return }
            updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        }
    }

    @Published var checkFrequency: UpdateCheckFrequency {
        didSet {
            guard updater.updateCheckInterval != checkFrequency.interval else { return }
            updater.updateCheckInterval = checkFrequency.interval
        }
    }

    @Published private(set) var lastUpdateCheckDate: Date?
    @Published private(set) var canCheckForUpdates: Bool
    @Published private(set) var allowsAutomaticUpdates: Bool

    init(defaults: AppSettingsDefaults = UserDefaults.standard) {
        self.defaults = defaults
        updateChannelDelegate = UpdateChannelUpdaterDelegate(defaults: defaults)
        includesBetaBuilds = BetaUpdatePreference.includesBetaBuilds(in: defaults)
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: updateChannelDelegate,
            userDriverDelegate: nil
        )

        let updater = controller.updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        checkFrequency = .closest(to: updater.updateCheckInterval)
        lastUpdateCheckDate = updater.lastUpdateCheckDate
        canCheckForUpdates = updater.canCheckForUpdates
        allowsAutomaticUpdates = updater.allowsAutomaticUpdates

        observers.append(
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated {
                    self?.canCheckForUpdates = updater.canCheckForUpdates
                    self?.lastUpdateCheckDate = updater.lastUpdateCheckDate
                }
            }
        )

        observers.append(
            updater.observe(\.allowsAutomaticUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated {
                    self?.allowsAutomaticUpdates = updater.allowsAutomaticUpdates
                    if !updater.allowsAutomaticUpdates {
                        self?.automaticallyDownloadsUpdates = false
                    }
                }
            }
        )
    }

    /// Starts a user-initiated update check, showing Sparkle's standard UI.
    func checkForUpdates() {
        updater.checkForUpdates()
    }

    /// Reads the latest check timestamp from Sparkle (it does not always post KVO).
    func refreshLastCheckDate() {
        lastUpdateCheckDate = updater.lastUpdateCheckDate
    }
}

@MainActor
final class YTDLPUpdateState: ObservableObject {
    static let cadenceDescription = "Weekly"

    private let updater: YTDLPUpdating

    @Published private(set) var toolStatus: YTDLPManagedToolStatus?
    @Published private(set) var isUpdating = false
    @Published var updateAlert: YTDLPUpdateAlert?

    init(updater: YTDLPUpdating = YTDLPManager()) {
        self.updater = updater
        refresh()
    }

    var cadenceDescription: String {
        Self.cadenceDescription
    }

    var lastCheckedDescription: String {
        guard let date = toolStatus?.lastCheckedAt else {
            return "Not checked yet"
        }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    func refresh() {
        toolStatus = updater.managedToolStatus()
    }

    func updateNow() {
        Task {
            await performUpdateNow()
        }
    }

    func performUpdateNow() async {
        guard !isUpdating else { return }
        isUpdating = true
        updateAlert = nil
        defer { isUpdating = false }

        do {
            _ = try await updater.updateManagedExecutableNow()
            refresh()
            updateAlert = .upToDate(version: toolStatus?.version)
        } catch {
            refresh()
            updateAlert = .failed
        }
    }
}

struct YTDLPUpdateAlert: Identifiable, Equatable {
    enum Kind: Equatable {
        case upToDate(version: String?)
        case failed
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .upToDate(let version):
            return "upToDate-\(version ?? "unknown")"
        case .failed:
            return "failed"
        }
    }

    var title: String {
        switch kind {
        case .upToDate:
            return "You're up to date!"
        case .failed:
            return "Could Not Update yt-dlp"
        }
    }

    var message: String {
        switch kind {
        case .upToDate(let version):
            if let version {
                return "yt-dlp \(version) is currently the newest version available."
            }
            return "yt-dlp is currently the newest version available."
        case .failed:
            return "Check your connection and try again."
        }
    }

    static func upToDate(version: String?) -> Self {
        Self(kind: .upToDate(version: version))
    }

    static let failed = Self(kind: .failed)
}
