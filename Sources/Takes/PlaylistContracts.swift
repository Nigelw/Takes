import Foundation

/// Captured before asynchronous UI or import work begins.
enum PlaylistImportDestination: Equatable, Sendable {
    case playlist
    case item(UUID)
}

/// A new identity is issued even when reactivating the same item.
struct PlaylistRuntimeContext: Equatable, Sendable {
    let activationID: UUID
    let itemID: UUID?

    init(itemID: UUID?, activationID: UUID = UUID()) {
        self.itemID = itemID
        self.activationID = activationID
    }
}

enum PlaylistWorkspaceRestoreResult {
    case absent
    case restored(PlaylistWorkspace)
    case recovered(PlaylistWorkspace, warning: String)
}

/// Throws for unreadable or unsupported snapshots; only missing storage is absent.
/// Implementations serialize writes and retain a validated last-known-good copy.
@MainActor
protocol PlaylistWorkspacePersisting {
    func load() async throws -> PlaylistWorkspaceRestoreResult
    func save(_ workspace: PlaylistWorkspace) async throws
}
