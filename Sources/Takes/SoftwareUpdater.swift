import Foundation
import Sparkle

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
@MainActor
final class SoftwareUpdater: ObservableObject {
    private let controller: SPUStandardUpdaterController
    private var updater: SPUUpdater { controller.updater }
    private var observers: [NSKeyValueObservation] = []

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

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
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
