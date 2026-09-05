import Foundation

/// The JSON envelope written for both the primary and last-known-good
/// snapshots. Keeping the schema marker outside the workspace makes a newer
/// snapshot distinguishable from malformed data before it is decoded.
struct PlaylistWorkspaceSnapshotEnvelope: Codable, Equatable {
    let schemaVersion: Int
    let workspace: PlaylistWorkspace

    init(schemaVersion: Int, workspace: PlaylistWorkspace) {
        self.schemaVersion = schemaVersion
        self.workspace = workspace
    }
}

/// The result of resolving a persisted file reference. A missing case keeps
/// the original reference so callers can offer repair without dropping its
/// playlist item.
enum PlaylistFileReferenceState: Equatable {
    case available(URL)
    case missing(PlaylistFileReference)

    var resolvedURL: URL? {
        guard case let .available(url) = self else { return nil }
        return url
    }

    var isMissing: Bool {
        if case .missing = self { return true }
        return false
    }
}

/// Errors from workspace snapshot I/O and restoration protection.
enum PlaylistWorkspaceStoreError: Error, Equatable, LocalizedError {
    case snapshotCorrupt(URL)
    case unsupportedSchema(version: Int, URL)
    case recoveryUnavailable
    case automaticSaveBlocked
    case writeFailed(URL)
    case invalidWorkspace(PlaylistWorkspaceError)

    var errorDescription: String? {
        switch self {
        case let .snapshotCorrupt(url):
            return "The workspace snapshot is corrupt: \(url.path)."
        case let .unsupportedSchema(version, url):
            return "The workspace snapshot uses unsupported schema version \(version): \(url.path)."
        case .recoveryUnavailable:
            return "No acknowledged workspace recovery is available."
        case .automaticSaveBlocked:
            return "Automatic workspace saving is blocked until snapshot recovery is acknowledged."
        case let .writeFailed(url):
            return "The workspace snapshot could not be written: \(url.path)."
        case let .invalidWorkspace(error):
            return "The workspace is invalid: \(error.localizedDescription)"
        }
    }
}

private actor PlaylistWorkspaceWriteQueue {
    func write(
        _ data: Data,
        to snapshotURL: URL,
        lastKnownGoodURL: URL,
        directoryURL: URL
    ) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            // Publish the fallback first. If the primary write fails, the
            // previous primary remains readable and the new fallback is still
            // a complete, validated snapshot.
            try data.write(to: lastKnownGoodURL, options: [.atomic])
            try data.write(to: snapshotURL, options: [.atomic])
        } catch {
            throw PlaylistWorkspaceStoreError.writeFailed(snapshotURL)
        }
    }

    /// A FIFO barrier for callers that need all earlier writes settled before
    /// reading the files back.
    func barrier() {}

    func preserveIfPresent(_ sourceURL: URL, in directoryURL: URL) throws -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else { return nil }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let destinationURL = directoryURL.appendingPathComponent(
            "workspace.recovery-\(UUID().uuidString).json"
        )
        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        } catch {
            throw PlaylistWorkspaceStoreError.writeFailed(destinationURL)
        }
    }
}

/// Main-actor persistence boundary for the playlist workspace.
///
/// Disk writes are serialized by a private actor. The primary snapshot and a
/// separately named last-known-good copy are both versioned JSON envelopes.
/// A failed restore never gets repaired implicitly: the unreadable primary is
/// left untouched and subsequent automatic saves are blocked.
@MainActor
final class PlaylistWorkspaceStore: PlaylistWorkspacePersisting {
    nonisolated static let currentSchemaVersion = 1
    nonisolated static let snapshotFileName = "workspace.json"
    nonisolated static let lastKnownGoodFileName = "workspace.last-known-good.json"
    nonisolated static let downloadsDirectoryName = "Downloads"

    let directoryURL: URL
    let snapshotURL: URL
    let lastKnownGoodURL: URL
    let workspaceOwnedDownloadsDirectoryURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let writeQueue = PlaylistWorkspaceWriteQueue()
    private var hasLoaded = false
    private var automaticSavesBlocked = false
    private var lastKnownGoodWorkspace: PlaylistWorkspace?

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let directory = (rootURL ?? Self.defaultDirectoryURL(fileManager: fileManager)).standardizedFileURL
        self.directoryURL = directory
        self.snapshotURL = directory.appendingPathComponent(Self.snapshotFileName)
        self.lastKnownGoodURL = directory.appendingPathComponent(Self.lastKnownGoodFileName)
        self.workspaceOwnedDownloadsDirectoryURL = directory.appendingPathComponent(
            Self.downloadsDirectoryName,
            isDirectory: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    /// The app's Application Support directory, with a Takes subdirectory.
    /// The directory is created lazily by save and download-directory helpers.
    nonisolated static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["TAKES_PLAYLIST_WORKSPACE_DIRECTORY"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if environment["XCTestConfigurationFilePath"] != nil {
            return fileManager.temporaryDirectory.appendingPathComponent(
                "Takes-Test-Workspace-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true
            )
        }
        #endif
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return applicationSupport.appendingPathComponent("Takes", isDirectory: true)
    }

    nonisolated static func defaultDownloadsDirectoryURL(fileManager: FileManager = .default) -> URL {
        defaultDirectoryURL(fileManager: fileManager).appendingPathComponent(
            downloadsDirectoryName,
            isDirectory: true
        )
    }

    /// Exposed for restoration UI and tests; it does not mutate the filesystem.
    var isAutomaticSaveBlocked: Bool { automaticSavesBlocked }

    /// The in-memory last-known-good value, if one has been loaded or saved.
    var validatedLastKnownGoodWorkspace: PlaylistWorkspace? { lastKnownGoodWorkspace }

    /// Whether a recovered fallback can be explicitly acknowledged. Newer
    /// schemas intentionally report false so they cannot be downgraded.
    var recoveryAvailable: Bool {
        guard automaticSavesBlocked, lastKnownGoodWorkspace != nil else { return false }
        guard case .unsupportedSchema? = recoveryError else { return true }
        return false
    }

    /// The original restoration problem retained for recovery UI.
    private(set) var recoveryError: PlaylistWorkspaceStoreError?

    /// Human-readable context retained alongside ``recoveryError``.
    private(set) var recoveryWarning: String?

    /// The preserved unreadable snapshot after recovery is acknowledged.
    private(set) var preservedRecoveryURL: URL?

    /// Create a reference for a local file. Existing files receive a bookmark
    /// when the platform permits one; the stored path is always retained as a
    /// fallback. Missing files intentionally produce a path-only reference.
    nonisolated static func makeFileReference(
        for url: URL,
        isWorkspaceOwned: Bool = false,
        fileManager: FileManager = .default
    ) -> PlaylistFileReference {
        let bookmarkData: Data?
        if url.isFileURL, fileManager.fileExists(atPath: url.path) {
            bookmarkData = try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } else {
            bookmarkData = nil
        }
        return PlaylistFileReference(
            storedURL: url,
            bookmarkData: bookmarkData,
            isWorkspaceOwned: isWorkspaceOwned
        )
    }

    /// Resolve a bookmark first, then fall back to the persisted path. Missing
    /// files remain represented by their original reference for repair.
    nonisolated static func resolveFileReference(
        _ reference: PlaylistFileReference,
        fileManager: FileManager = .default
    ) -> PlaylistFileReferenceState {
        if let bookmarkData = reference.bookmarkData {
            var isStale = false
            if let resolvedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), Self.isReadableRegularFile(resolvedURL, fileManager: fileManager) {
                return .available(resolvedURL)
            }
        }

        if Self.isReadableRegularFile(reference.storedURL, fileManager: fileManager) {
            return .available(reference.storedURL)
        }
        return .missing(reference)
    }

    nonisolated private static func isReadableRegularFile(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        guard url.isFileURL, fileManager.isReadableFile(atPath: url.path) else { return false }
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    /// Create the retained workspace-owned download directory. No cleanup is
    /// performed here: later garbage collection must account for Undo history.
    func ensureWorkspaceOwnedDownloadsDirectory() throws -> URL {
        do {
            try fileManager.createDirectory(
                at: workspaceOwnedDownloadsDirectoryURL,
                withIntermediateDirectories: true
            )
            return workspaceOwnedDownloadsDirectoryURL
        } catch {
            throw PlaylistWorkspaceStoreError.writeFailed(workspaceOwnedDownloadsDirectoryURL)
        }
    }

    func load() async throws -> PlaylistWorkspaceRestoreResult {
        await writeQueue.barrier()

        switch readSnapshot(at: snapshotURL) {
        case let .valid(workspace):
            hasLoaded = true
            automaticSavesBlocked = false
            lastKnownGoodWorkspace = workspace
            recoveryError = nil
            recoveryWarning = nil
            preservedRecoveryURL = nil
            return .restored(workspace)

        case .absent:
            switch readSnapshot(at: lastKnownGoodURL) {
            case .absent:
                hasLoaded = true
                automaticSavesBlocked = false
                lastKnownGoodWorkspace = nil
                recoveryError = nil
                recoveryWarning = nil
                preservedRecoveryURL = nil
                return .absent
            case let .valid(workspace):
                hasLoaded = true
                automaticSavesBlocked = true
                lastKnownGoodWorkspace = workspace
                recoveryError = .snapshotCorrupt(snapshotURL)
                recoveryWarning = "The primary workspace snapshot was missing; the last-known-good snapshot was restored."
                return .recovered(
                    workspace,
                    warning: "The primary workspace snapshot was missing; the last-known-good snapshot was restored."
                )
            case let .failure(failure):
                return try markRestoreFailureAndThrow(failure, at: lastKnownGoodURL)
            }

        case let .failure(primaryFailure):
            switch readSnapshot(at: lastKnownGoodURL) {
            case let .valid(workspace):
                hasLoaded = true
                automaticSavesBlocked = true
                lastKnownGoodWorkspace = workspace
                recoveryError = storeError(for: primaryFailure, at: snapshotURL)
                recoveryWarning = warning(for: primaryFailure, at: snapshotURL)
                return .recovered(
                    workspace,
                    warning: warning(for: primaryFailure, at: snapshotURL)
                )
            case .absent:
                return try markRestoreFailureAndThrow(primaryFailure, at: snapshotURL)
            case .failure:
                // Keep the primary error as the externally visible cause. Both
                // files remain untouched and save protection is engaged.
                return try markRestoreFailureAndThrow(primaryFailure, at: snapshotURL)
            }
        }
    }

    func save(_ workspace: PlaylistWorkspace) async throws {
        do {
            try workspace.validate()
        } catch let error as PlaylistWorkspaceError {
            throw PlaylistWorkspaceStoreError.invalidWorkspace(error)
        }

        try prepareForSave()
        let envelope = PlaylistWorkspaceSnapshotEnvelope(
            schemaVersion: Self.currentSchemaVersion,
            workspace: workspace
        )
        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            throw PlaylistWorkspaceStoreError.writeFailed(snapshotURL)
        }

        try await writeQueue.write(
            data,
            to: snapshotURL,
            lastKnownGoodURL: lastKnownGoodURL,
            directoryURL: directoryURL
        )
        hasLoaded = true
        automaticSavesBlocked = false
        lastKnownGoodWorkspace = workspace
    }

    /// Explicitly acknowledge recovery from a corrupt or missing primary.
    /// The unreadable primary is copied to a unique recovery file before saves
    /// are unblocked. A newer schema cannot be overwritten through this path.
    func acknowledgeRecovery() async throws {
        guard automaticSavesBlocked, let recoveredWorkspace = lastKnownGoodWorkspace else {
            throw PlaylistWorkspaceStoreError.recoveryUnavailable
        }
        if let recoveryError,
           case .unsupportedSchema = recoveryError {
            throw PlaylistWorkspaceStoreError.automaticSaveBlocked
        }
        preservedRecoveryURL = try await writeQueue.preserveIfPresent(
            snapshotURL,
            in: directoryURL
        )
        hasLoaded = true
        automaticSavesBlocked = false
        lastKnownGoodWorkspace = recoveredWorkspace
    }

    private enum SnapshotReadResult {
        case absent
        case valid(PlaylistWorkspace)
        case failure(SnapshotReadFailure)
    }

    private enum SnapshotReadFailure {
        case corrupt
        case unsupportedSchema(Int)
    }

    private func readSnapshot(at url: URL) -> SnapshotReadResult {
        guard fileManager.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url) else { return .failure(.corrupt) }

        struct SnapshotHeader: Decodable {
            let schemaVersion: Int
        }
        let header: SnapshotHeader
        do {
            header = try decoder.decode(SnapshotHeader.self, from: data)
        } catch {
            return .failure(.corrupt)
        }
        guard header.schemaVersion == Self.currentSchemaVersion else {
            return .failure(.unsupportedSchema(header.schemaVersion))
        }

        let envelope: PlaylistWorkspaceSnapshotEnvelope
        do {
            envelope = try decoder.decode(PlaylistWorkspaceSnapshotEnvelope.self, from: data)
        } catch {
            return .failure(.corrupt)
        }
        guard envelope.schemaVersion == Self.currentSchemaVersion else {
            return .failure(.unsupportedSchema(envelope.schemaVersion))
        }
        do {
            try envelope.workspace.validate()
        } catch {
            return .failure(.corrupt)
        }
        return .valid(envelope.workspace)
    }

    private func prepareForSave() throws {
        if automaticSavesBlocked {
            throw PlaylistWorkspaceStoreError.automaticSaveBlocked
        }
        guard !hasLoaded else { return }

        // A fresh store must inspect an existing primary before overwriting it.
        // This closes the protection hole where a failed restoration was
        // followed by a new store instance that had never called load().
        switch readSnapshot(at: snapshotURL) {
        case let .valid(workspace):
            hasLoaded = true
            lastKnownGoodWorkspace = workspace
            recoveryError = nil
            recoveryWarning = nil
        case .absent:
            switch readSnapshot(at: lastKnownGoodURL) {
            case .absent:
                hasLoaded = true
                recoveryError = nil
                recoveryWarning = nil
            case .valid:
                automaticSavesBlocked = true
                recoveryError = .snapshotCorrupt(snapshotURL)
                recoveryWarning = "The primary workspace snapshot was missing while a last-known-good snapshot was present."
                throw PlaylistWorkspaceStoreError.automaticSaveBlocked
            case .failure:
                automaticSavesBlocked = true
                recoveryError = .snapshotCorrupt(snapshotURL)
                recoveryWarning = "The primary workspace snapshot was missing and its fallback could not be restored."
                throw PlaylistWorkspaceStoreError.automaticSaveBlocked
            }
        case let .failure(failure):
            automaticSavesBlocked = true
            recoveryError = storeError(for: failure, at: snapshotURL)
            recoveryWarning = recoveryError?.localizedDescription
            throw PlaylistWorkspaceStoreError.automaticSaveBlocked
        }
    }

    private func markRestoreFailureAndThrow(
        _ failure: SnapshotReadFailure,
        at url: URL
    ) throws -> PlaylistWorkspaceRestoreResult {
        hasLoaded = true
        automaticSavesBlocked = true
        recoveryError = storeError(for: failure, at: url)
        recoveryWarning = recoveryError?.localizedDescription
        throw storeError(for: failure, at: url)
    }

    private func storeError(for failure: SnapshotReadFailure, at url: URL) -> PlaylistWorkspaceStoreError {
        switch failure {
        case .corrupt:
            return .snapshotCorrupt(url)
        case let .unsupportedSchema(version):
            return .unsupportedSchema(version: version, url)
        }
    }

    private func warning(for failure: SnapshotReadFailure, at url: URL) -> String {
        storeError(for: failure, at: url).localizedDescription
            + " The last-known-good snapshot was restored; automatic saving is blocked."
    }
}
