import Foundation
import Observation

/// Saves on content/transport events and checkpoints file time without writing
/// a ticking position back into the observed workspace.
@MainActor
@Observable
final class PlaylistPersistenceController {
    private(set) var restorationComplete = false
    private(set) var savesEnabled = false
    private(set) var recoveryAvailable = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let coordinator: PlaylistCoordinator
    @ObservationIgnored private let store: any PlaylistWorkspacePersisting
    @ObservationIgnored private var started = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var checkpointTask: Task<Void, Never>?

    init(coordinator: PlaylistCoordinator, store: any PlaylistWorkspacePersisting) {
        self.coordinator = coordinator
        self.store = store
    }

    func start() async {
        guard !started else { return }
        started = true
        do {
            var recovered = false
            switch try await store.load() {
            case .absent:
                break
            case let .restored(workspace):
                try await coordinator.restoreWorkspace(workspace)
            case let .recovered(workspace, warning):
                try await coordinator.restoreWorkspace(workspace)
                errorMessage = warning
                recovered = true
                recoveryAvailable = (store as? PlaylistWorkspaceStore)?.recoveryAvailable == true
            }
            savesEnabled = !recovered
            observeChanges()
            checkpointTask?.cancel()
            checkpointTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    guard let self else { return }
                    if self.coordinator.isPlaying { await self.flush() }
                }
            }
        } catch {
            // Do not turn recovery failure into an empty persisted workspace.
            errorMessage = "The saved playlist could not be restored. Automatic saving is paused to preserve it. \(error.localizedDescription)"
        }
        restorationComplete = true
    }

    @discardableResult
    func flush() async -> Bool {
        guard savesEnabled else { return true }
        saveTask?.cancel()
        saveTask = nil
        do {
            try await store.save(coordinator.snapshotForPersistence())
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = "The playlist could not be saved. \(error.localizedDescription)"
            return false
        }
    }

    func dismissError() { errorMessage = nil }

    func acceptRecoveredWorkspace() async {
        guard recoveryAvailable, let diskStore = store as? PlaylistWorkspaceStore else { return }
        do {
            try await diskStore.acknowledgeRecovery()
            recoveryAvailable = false
            errorMessage = nil
            savesEnabled = true
            observeChanges()
            await flush()
        } catch {
            errorMessage = "The recovered playlist could not be saved. \(error.localizedDescription)"
        }
    }

    func retryRestoration() async {
        guard !savesEnabled else { return }
        started = false
        errorMessage = nil
        restorationComplete = false
        await start()
    }

    private func observeChanges() {
        guard savesEnabled else { return }
        _ = withObservationTracking {
            coordinator.snapshotForPersistence()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.savesEnabled else { return }
                self.observeChanges()
                self.saveTask?.cancel()
                self.saveTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    guard let self else { return }
                    // Do not call flush here: it cancels the explicit pending save.
                    do { try await self.store.save(self.coordinator.snapshotForPersistence()) }
                    catch is CancellationError { }
                    catch { self.errorMessage = "The playlist could not be saved. \(error.localizedDescription)" }
                }
            }
        }
    }
}
