import Foundation
import Testing
@testable import Takes

@MainActor
struct PlaylistPersistenceControllerTests {
    @Test func workspaceEditsSaveAutomaticallyAndObservationRearms() async throws {
        let store = RecordingWorkspaceStore()
        let coordinator = PlaylistCoordinator()
        let persistence = PlaylistPersistenceController(coordinator: coordinator, store: store)
        await persistence.start()

        coordinator.setPlaylistRepeatMode(.all)
        for _ in 0..<100 {
            if store.saved.last?.playlistRepeatMode == .all { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.saved.last?.playlistRepeatMode == .all)

        coordinator.setShuffleEnabled(true)
        for _ in 0..<100 {
            if store.saved.last?.isShuffleEnabled == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.saved.last?.isShuffleEnabled == true)
        #expect(store.saved.last?.playlistRepeatMode == .all)
        #expect(store.saved.count == 2)
    }

    @Test func absentSnapshotEnablesEventSaves() async {
        let store = RecordingWorkspaceStore()
        let coordinator = PlaylistCoordinator()
        let persistence = PlaylistPersistenceController(coordinator: coordinator, store: store)
        await persistence.start()
        await persistence.flush()
        #expect(persistence.restorationComplete)
        #expect(persistence.savesEnabled)
        #expect(store.saved.count == 1)
        #expect(store.saved.first == PlaylistWorkspace())
    }

    @Test func failedRestoreNeverWritesEmptyWorkspace() async {
        let store = RecordingWorkspaceStore()
        store.failLoad = true
        let persistence = PlaylistPersistenceController(coordinator: PlaylistCoordinator(), store: store)
        await persistence.start()
        await persistence.flush()
        #expect(persistence.restorationComplete)
        #expect(!persistence.savesEnabled)
        #expect(persistence.errorMessage != nil)
        #expect(store.saved.isEmpty)
    }

    @Test func fallbackRecoveryWaitsForExplicitAcceptance() async {
        let store = RecordingWorkspaceStore()
        store.result = .recovered(PlaylistWorkspace(), warning: "Recovered copy")
        let persistence = PlaylistPersistenceController(coordinator: PlaylistCoordinator(), store: store)
        await persistence.start()
        await persistence.flush()
        #expect(!persistence.savesEnabled)
        #expect(persistence.errorMessage == "Recovered copy")
        #expect(store.saved.isEmpty)
    }

    @Test func failedFlushReportsFailureToTerminationCaller() async {
        let store = RecordingWorkspaceStore()
        let persistence = PlaylistPersistenceController(coordinator: PlaylistCoordinator(), store: store)
        await persistence.start()
        store.failSave = true
        let didSave = await persistence.flush()
        #expect(!didSave)
        #expect(persistence.errorMessage != nil)
        #expect(store.saved.isEmpty)
    }
}

@MainActor
private final class RecordingWorkspaceStore: PlaylistWorkspacePersisting {
    var result: PlaylistWorkspaceRestoreResult = .absent
    var failLoad = false
    var failSave = false
    var saved: [PlaylistWorkspace] = []
    func load() async throws -> PlaylistWorkspaceRestoreResult {
        if failLoad { throw PlaylistWorkspaceStoreError.automaticSaveBlocked }
        return result
    }
    func save(_ workspace: PlaylistWorkspace) async throws {
        if failSave { throw PlaylistWorkspaceStoreError.automaticSaveBlocked }
        saved.append(workspace)
    }
}
