import Foundation
import Testing
@testable import Takes

@MainActor
struct PlaylistWorkspaceStoreTests {
    @Test
    func emptyDirectoryLoadsAsAbsent() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let store = PlaylistWorkspaceStore(rootURL: root)

        let result = try await store.load()

        guard case .absent = result else {
            Issue.record("Expected an absent workspace")
            return
        }
        #expect(!store.isAutomaticSaveBlocked)
    }

    @Test
    func workspaceRoundTripsThroughVersionedPrimaryAndFallbackSnapshots() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let itemID = UUID()
        let versionID = UUID()
        let workspace = PlaylistWorkspace(
            items: [
                PlaylistItem(
                    id: itemID,
                    title: "Song",
                    versions: [makeVersion("song", id: versionID, offsetSeconds: 2)],
                    selectedVersionID: versionID,
                    comparison: PlaylistComparisonConfiguration(
                        repeatMode: .one,
                        loopRegion: LoopRegion(start: 2, end: 6),
                        isBlindListeningModeEnabled: true,
                        visibleStart: -2,
                        visibleSpan: 12
                    )
                )
            ],
            activeView: .comparison(itemID: itemID),
            listeningState: PlaylistListeningState(itemID: itemID, versionID: versionID, filePosition: 10),
            playlistRepeatMode: .all,
            isShuffleEnabled: true
        )
        let store = PlaylistWorkspaceStore(rootURL: root)

        try await store.save(workspace)

        #expect(FileManager.default.fileExists(atPath: store.snapshotURL.path))
        #expect(FileManager.default.fileExists(atPath: store.lastKnownGoodURL.path))
        let envelope = try JSONDecoder().decode(
            PlaylistWorkspaceSnapshotEnvelope.self,
            from: Data(contentsOf: store.snapshotURL)
        )
        #expect(envelope.schemaVersion == PlaylistWorkspaceStore.currentSchemaVersion)
        #expect(envelope.workspace == workspace)

        let restoredStore = PlaylistWorkspaceStore(rootURL: root)
        let result = try await restoredStore.load()
        guard case let .restored(restoredWorkspace) = result else {
            Issue.record("Expected a restored workspace")
            return
        }
        #expect(restoredWorkspace == workspace)
        #expect(restoredStore.validatedLastKnownGoodWorkspace == workspace)
        #expect(!restoredStore.isAutomaticSaveBlocked)
    }

    @Test
    func corruptPrimaryRecoversFallbackAndPreservesCorruptOriginal() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let workspace = makeWorkspace("healthy")
        let store = PlaylistWorkspaceStore(rootURL: root)
        try await store.save(workspace)

        let corruptPrimary = Data("{ this is not JSON }\n".utf8)
        try corruptPrimary.write(to: store.snapshotURL, options: [.atomic])

        let recoveringStore = PlaylistWorkspaceStore(rootURL: root)
        let result = try await recoveringStore.load()
        guard case let .recovered(recoveredWorkspace, warning) = result else {
            Issue.record("Expected fallback recovery")
            return
        }
        #expect(recoveredWorkspace == workspace)
        #expect(warning.contains("last-known-good"))
        #expect(try Data(contentsOf: store.snapshotURL) == corruptPrimary)
        #expect(recoveringStore.isAutomaticSaveBlocked)
    }

    @Test
    func recoveredStoreBlocksAutomaticSaveUntilExplicitRecovery() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let store = PlaylistWorkspaceStore(rootURL: root)
        try await store.save(makeWorkspace("healthy"))
        let corruptPrimary = Data("corrupt primary".utf8)
        try corruptPrimary.write(to: store.snapshotURL, options: [.atomic])

        let recoveringStore = PlaylistWorkspaceStore(rootURL: root)
        _ = try await recoveringStore.load()

        await #expect(throws: PlaylistWorkspaceStoreError.automaticSaveBlocked) {
            try await recoveringStore.save(makeWorkspace("replacement"))
        }
        #expect(try Data(contentsOf: store.snapshotURL) == corruptPrimary)
    }

    @Test
    func acknowledgingCorruptRecoveryPreservesOriginalAndAllowsLaterSave() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let store = PlaylistWorkspaceStore(rootURL: root)
        try await store.save(makeWorkspace("healthy"))
        let corruptPrimary = Data("corrupt primary".utf8)
        try corruptPrimary.write(to: store.snapshotURL, options: [.atomic])

        let recoveringStore = PlaylistWorkspaceStore(rootURL: root)
        _ = try await recoveringStore.load()
        try await recoveringStore.acknowledgeRecovery()

        let preservedURL = try #require(recoveringStore.preservedRecoveryURL)
        #expect(try Data(contentsOf: preservedURL) == corruptPrimary)
        #expect(!recoveringStore.isAutomaticSaveBlocked)
        #expect(!recoveringStore.recoveryAvailable)

        let replacement = makeWorkspace("replacement")
        try await recoveringStore.save(replacement)
        let restored = try await PlaylistWorkspaceStore(rootURL: root).load()
        guard case let .restored(restoredWorkspace) = restored else {
            Issue.record("Expected the acknowledged replacement to restore")
            return
        }
        #expect(restoredWorkspace == replacement)
        #expect(try Data(contentsOf: preservedURL) == corruptPrimary)
    }

    @Test
    func newStoreCannotOverwriteCorruptPrimaryWithoutLoading() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let initialStore = PlaylistWorkspaceStore(rootURL: root)
        try await initialStore.save(makeWorkspace("healthy"))
        let corruptPrimary = Data("corrupt primary".utf8)
        let corruptFallback = Data("corrupt fallback".utf8)
        try corruptPrimary.write(to: initialStore.snapshotURL, options: [.atomic])
        try corruptFallback.write(to: initialStore.lastKnownGoodURL, options: [.atomic])

        let newStore = PlaylistWorkspaceStore(rootURL: root)
        await #expect(throws: PlaylistWorkspaceStoreError.automaticSaveBlocked) {
            try await newStore.save(makeWorkspace("replacement"))
        }
        #expect(try Data(contentsOf: initialStore.snapshotURL) == corruptPrimary)
        #expect(try Data(contentsOf: initialStore.lastKnownGoodURL) == corruptFallback)
        #expect(newStore.isAutomaticSaveBlocked)
    }

    @Test
    func newerPrimaryRecoversFallbackAndProtectsNewerSchema() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let workspace = makeWorkspace("healthy")
        let store = PlaylistWorkspaceStore(rootURL: root)
        try await store.save(workspace)

        let newerEnvelope = PlaylistWorkspaceSnapshotEnvelope(
            schemaVersion: PlaylistWorkspaceStore.currentSchemaVersion + 1,
            workspace: workspace
        )
        let newerData = try JSONEncoder().encode(newerEnvelope)
        try newerData.write(to: store.snapshotURL, options: [.atomic])

        let recoveringStore = PlaylistWorkspaceStore(rootURL: root)
        let result = try await recoveringStore.load()
        guard case let .recovered(recoveredWorkspace, warning) = result else {
            Issue.record("Expected fallback recovery from a newer primary")
            return
        }
        #expect(recoveredWorkspace == workspace)
        #expect(warning.contains("unsupported schema version"))
        #expect(try Data(contentsOf: store.snapshotURL) == newerData)
        #expect(recoveringStore.isAutomaticSaveBlocked)
        await #expect(throws: PlaylistWorkspaceStoreError.automaticSaveBlocked) {
            try await recoveringStore.save(makeWorkspace("replacement"))
        }
        #expect(try Data(contentsOf: store.snapshotURL) == newerData)
        #expect(!recoveringStore.recoveryAvailable)
        await #expect(throws: PlaylistWorkspaceStoreError.automaticSaveBlocked) {
            try await recoveringStore.acknowledgeRecovery()
        }
        #expect(try Data(contentsOf: store.snapshotURL) == newerData)
    }

    @Test
    func newerPrimaryWithoutFallbackFailsAndFreshStoreSaveIsProtected() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let workspace = makeWorkspace("healthy")
        let encoder = JSONEncoder()
        let newerData = try encoder.encode(
            PlaylistWorkspaceSnapshotEnvelope(
                schemaVersion: PlaylistWorkspaceStore.currentSchemaVersion + 1,
                workspace: workspace
            )
        )
        let primaryURL = root.appendingPathComponent(PlaylistWorkspaceStore.snapshotFileName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try newerData.write(to: primaryURL, options: [.atomic])

        let newStore = PlaylistWorkspaceStore(rootURL: root)
        await #expect(throws: PlaylistWorkspaceStoreError.unsupportedSchema(
            version: PlaylistWorkspaceStore.currentSchemaVersion + 1,
            primaryURL
        )) {
            try await newStore.load()
        }
        #expect(newStore.isAutomaticSaveBlocked)
        await #expect(throws: PlaylistWorkspaceStoreError.automaticSaveBlocked) {
            try await newStore.save(makeWorkspace("replacement"))
        }
        #expect(try Data(contentsOf: primaryURL) == newerData)
    }

    @Test
    func missingFileReferenceFallsBackToStoredPathAndPreservesRepairState() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let missingURL = root.appendingPathComponent("missing-song.wav")
        let reference = PlaylistWorkspaceStore.makeFileReference(for: missingURL)
        let state = PlaylistWorkspaceStore.resolveFileReference(reference)

        #expect(state == .missing(reference))
        #expect(state.resolvedURL == nil)
        #expect(state.isMissing)

        let workspace = PlaylistWorkspace(
            items: [PlaylistItem(title: "Missing", versions: [makeVersion("missing", url: missingURL)])]
        )
        let store = PlaylistWorkspaceStore(rootURL: root.appendingPathComponent("store", isDirectory: true))
        try await store.save(workspace)
        let result = try await PlaylistWorkspaceStore(rootURL: store.directoryURL).load()
        guard case let .restored(restoredWorkspace) = result else {
            Issue.record("Expected missing reference to restore")
            return
        }
        #expect(restoredWorkspace.items[0].versions[0].file.storedURL == missingURL)
        #expect(PlaylistWorkspaceStore.resolveFileReference(restoredWorkspace.items[0].versions[0].file).isMissing)
    }

    @Test
    func existingFileReferenceResolvesWithStoredPathFallback() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let fileURL = root.appendingPathComponent("song.wav")
        try Data([0, 1, 2]).write(to: fileURL)
        let reference = PlaylistFileReference(storedURL: fileURL)

        let state = PlaylistWorkspaceStore.resolveFileReference(reference)

        #expect(state.resolvedURL == fileURL)
        #expect(!state.isMissing)
    }

    @Test
    func downloadsDirectoryIsRetainedForWorkspaceOwnedFiles() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let store = PlaylistWorkspaceStore(rootURL: root)
        let downloadsURL = try store.ensureWorkspaceOwnedDownloadsDirectory()
        let retainedFile = downloadsURL.appendingPathComponent("download.m4a")
        try Data([1, 2, 3]).write(to: retainedFile)

        _ = try store.ensureWorkspaceOwnedDownloadsDirectory()

        #expect(FileManager.default.fileExists(atPath: downloadsURL.path))
        #expect(FileManager.default.fileExists(atPath: retainedFile.path))
        #expect(store.directoryURL == root.standardizedFileURL)
    }

    private func makeWorkspace(_ name: String) -> PlaylistWorkspace {
        let version = makeVersion(name)
        let item = PlaylistItem(title: name, versions: [version])
        return PlaylistWorkspace(
            items: [item],
            listeningState: PlaylistListeningState(
                itemID: item.id,
                versionID: version.id,
                filePosition: 0
            )
        )
    }

    private func makeVersion(
        _ name: String,
        id: UUID = UUID(),
        url: URL? = nil,
        offsetSeconds: TimeInterval = 0
    ) -> PlaylistVersion {
        let fileURL = url ?? URL(fileURLWithPath: "/tmp/Takes Workspace Store Tests/\(name).wav")
        return PlaylistVersion(
            id: id,
            file: PlaylistFileReference(storedURL: fileURL),
            metadata: PlaylistMetadata(
                title: name,
                duration: 120,
                sampleRate: 44_100,
                channelCount: 2,
                bitRate: 192_000,
                fileFormatDescription: "WAV",
                displayName: name
            ),
            offsetSeconds: offsetSeconds
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Takes Playlist Workspace Store Tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func removeTemporaryDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
