import AVFoundation
import Foundation
import Testing
@testable import Takes

struct PlaylistCoordinatorTests {
    @Test func unchangedOrganizationPreservesShuffleProgress() {
        let ids = [UUID(), UUID(), UUID()]
        var traversal = PlaylistTraversal(itemIDs: ids, shuffleEnabled: true, shuffleProvider: { $0 })
        traversal.reset(currentID: ids[0])
        #expect(traversal.next(from: ids[0]) == ids[1])
        // Renaming an item must not rotate the cycle and replay earlier items.
        traversal.updateItemIDs(ids)
        #expect(traversal.next(from: ids[1]) == ids[2])
        #expect(traversal.next(from: ids[2]) == nil)
    }

    @Test func removingItemPreservesRepeatedHistoryOccurrence() {
        let ids = [UUID(), UUID(), UUID()]
        var traversal = PlaylistTraversal(itemIDs: ids, repeatMode: .all)
        traversal.reset(currentID: ids[0])
        #expect(traversal.next(from: ids[0]) == ids[1])
        #expect(traversal.next(from: ids[1]) == ids[2])
        #expect(traversal.next(from: ids[2]) == ids[0])
        traversal.updateItemIDs([ids[0], ids[2]])
        #expect(traversal.previous(from: ids[0]) == ids[2])
    }

    @Test
    func traversalSupportsSequentialHistoryRepeatAndManualNext() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        var sequential = PlaylistTraversal(
            itemIDs: [first, second, third],
            repeatMode: .off,
            shuffleProvider: { $0 }
        )
        sequential.reset(currentID: first)
        #expect(sequential.next(from: first) == second)
        #expect(sequential.next(from: second) == third)
        #expect(sequential.next(from: third) == nil)
        #expect(sequential.previous(from: third) == second)
        #expect(sequential.previous(from: second) == first)
        #expect(sequential.previous(from: first) == nil)

        var repeatOne = PlaylistTraversal(
            itemIDs: [first, second],
            repeatMode: .one,
            shuffleProvider: { $0 }
        )
        repeatOne.reset(currentID: first)
        #expect(repeatOne.next(from: first, atNaturalEnd: true) == first)
        #expect(repeatOne.next(from: first) == second)
        #expect(repeatOne.previous(from: second) == first)

        var repeatAll = PlaylistTraversal(
            itemIDs: [first, second],
            repeatMode: .all,
            shuffleProvider: { $0 }
        )
        repeatAll.reset(currentID: first)
        #expect(repeatAll.next(from: first) == second)
        #expect(repeatAll.next(from: second, atNaturalEnd: true) == first)
    }

    @Test
    func shuffleVisitsEachItemOnceAndPreviousFollowsItsHistory() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        var traversal = PlaylistTraversal(
            itemIDs: [first, second, third],
            shuffleEnabled: true,
            repeatMode: .off,
            shuffleProvider: { ids in [ids[2], ids[0], ids[1]] }
        )
        traversal.reset()

        let visited = [
            traversal.next(from: nil),
            traversal.next(from: third),
            traversal.next(from: first)
        ]
        #expect(visited.compactMap { $0 } == [third, first, second])
        #expect(Set(visited.compactMap { $0 }) == Set([first, second, third]))
        #expect(traversal.next(from: second) == nil)
        #expect(traversal.previous(from: second) == first)
        #expect(traversal.previous(from: first) == third)
    }

    @MainActor
    @Test
    func importUsesMetadataAndHasNoWorkspaceItemLimit() async {
        let urls = (0..<40).map { index in
            URL(fileURLWithPath: "/tmp/coordinator-import-\(index).wav")
        }
        let tracks = Dictionary(uniqueKeysWithValues: urls.enumerated().map { index, url in
            (
                url,
                LoadedTrack(
                    url: url,
                    displayName: url.lastPathComponent,
                    fileFormatDescription: "WAV",
                    duration: 2,
                    sampleRate: 48_000,
                    channelCount: 2,
                    bitRate: 256_000,
                    title: "Title \(index)",
                    artist: "Artist \(index)",
                    album: "Album \(index)"
                )
            )
        })
        let coordinator = PlaylistCoordinator(
            loader: CoordinatorTestAudioLoader(tracks: tracks)
        )

        let imported = await coordinator.importFiles(urls, destination: .playlist)

        #expect(imported.count == urls.count)
        #expect(coordinator.workspace.items.count == urls.count)
        #expect(coordinator.workspace.items.first?.title == "Title 0")
        #expect(coordinator.workspace.items.first?.versions.first?.metadata.artist == "Artist 0")
        #expect(coordinator.workspace.items.last?.versions.first?.metadata.album == "Album 39")
    }

    @MainActor
    @Test
    func capturedItemDestinationDoesNotRerouteAfterDeletion() async {
        let destinationID = UUID()
        let destination = PlaylistItem(
            id: destinationID,
            title: "Destination",
            versions: [makeVersion("destination.wav")]
        )
        let importedURL = URL(fileURLWithPath: "/tmp/coordinator-delayed.wav")
        let gate = CoordinatorLoadGate()
        let loader = CoordinatorTestAudioLoader(
            tracks: [importedURL: makeLoadedTrack(for: importedURL)],
            gate: gate
        )
        let coordinator = PlaylistCoordinator(
            workspace: PlaylistWorkspace(items: [destination]),
            loader: loader
        )
        let importTask = Task { @MainActor in
            await coordinator.importFiles(
                [importedURL],
                destination: .item(destinationID)
            )
        }

        await gate.waitUntilStarted()
        #expect(coordinator.removeItem(destinationID))
        await gate.release()
        let importedIDs = await importTask.value

        #expect(importedIDs.isEmpty)
        #expect(coordinator.workspace.items.isEmpty)
        #expect(coordinator.errorMessage?.contains("was not found") == true)
    }

    @MainActor
    @Test
    func organizationMutationsAreAtomicAndVersionReorderUsesStableIDs() {
        let first = makeVersion("first.wav")
        let second = makeVersion("second.wav")
        let item = PlaylistItem(
            title: "Song",
            versions: [first, second],
            selectedVersionID: first.id
        )
        let coordinator = PlaylistCoordinator(workspace: PlaylistWorkspace(items: [item]))
        let before = coordinator.workspace

        #expect(!coordinator.removeVersions([first.id, UUID()]))
        #expect(coordinator.workspace == before)
        #expect(coordinator.errorMessage != nil)

        #expect(coordinator.reorderVersion(second.id, before: first.id))
        #expect(coordinator.workspace.items[0].versions.map(\.id) == [second.id, first.id])
    }

    @MainActor
    @Test
    func undoAndRedoRestoreWorkspaceSnapshots() {
        let item = PlaylistItem(title: "Original", versions: [makeVersion("undo.wav")])
        let coordinator = PlaylistCoordinator(workspace: PlaylistWorkspace(items: [item]))
        let undoManager = UndoManager()

        #expect(coordinator.renameItem(item.id, to: "Renamed", undoManager: undoManager))
        #expect(coordinator.workspace.items[0].title == "Renamed")
        undoManager.undo()
        #expect(coordinator.workspace.items[0].title == "Original")
        undoManager.redo()
        #expect(coordinator.workspace.items[0].title == "Renamed")
    }

    @MainActor
    @Test
    func locatingFileRetainsVersionIdentityAndClearsDownloadOwnership() async {
        let versionID = UUID()
        let missingURL = URL(fileURLWithPath: "/tmp/coordinator-missing.wav")
        let replacementURL = URL(fileURLWithPath: "/tmp/coordinator-replacement.wav")
        let version = PlaylistVersion(
            id: versionID,
            file: PlaylistFileReference(
                storedURL: missingURL,
                isWorkspaceOwned: true
            ),
            metadata: PlaylistMetadata(
                duration: 1,
                sampleRate: 44_100,
                channelCount: 1,
                fileFormatDescription: "WAV",
                displayName: "missing.wav"
            )
        )
        let item = PlaylistItem(id: UUID(), title: "Song", versions: [version])
        let loader = CoordinatorTestAudioLoader(
            tracks: [replacementURL: makeLoadedTrack(for: replacementURL, title: "Repaired")]
        )
        let coordinator = PlaylistCoordinator(
            workspace: PlaylistWorkspace(items: [item]),
            loader: loader
        )

        await coordinator.locateFile(versionID: versionID, url: replacementURL)

        let repaired = coordinator.workspace.allVersions.first { $0.id == versionID }
        #expect(repaired?.id == versionID)
        #expect(repaired?.file.storedURL == replacementURL)
        #expect(repaired?.file.isWorkspaceOwned == false)
        #expect(repaired?.metadata.title == "Repaired")
        #expect(coordinator.errorMessage == nil)
    }

    @MainActor
    @Test
    func selectingActivePlaylistVersionReloadsRuntimeAndBackKeepsChoice() async throws {
        let firstURL = try makeTemporaryAudioFile(name: "coordinator-first.wav")
        let secondURL = try makeTemporaryAudioFile(name: "coordinator-second.wav")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }

        let firstID = UUID()
        let secondID = UUID()
        let firstTrack = makeLoadedTrack(for: firstURL)
        let secondTrack = makeLoadedTrack(for: secondURL)
        let firstVersion = PlaylistVersion(
            id: firstID,
            file: PlaylistWorkspaceStore.makeFileReference(for: firstURL),
            metadata: PlaylistMetadata(
                title: "First",
                duration: firstTrack.duration,
                sampleRate: firstTrack.sampleRate,
                channelCount: firstTrack.channelCount,
                fileFormatDescription: firstTrack.fileFormatDescription,
                displayName: firstTrack.displayName
            )
        )
        let secondVersion = PlaylistVersion(
            id: secondID,
            file: PlaylistWorkspaceStore.makeFileReference(for: secondURL),
            metadata: PlaylistMetadata(
                title: "Second",
                duration: secondTrack.duration,
                sampleRate: secondTrack.sampleRate,
                channelCount: secondTrack.channelCount,
                fileFormatDescription: secondTrack.fileFormatDescription,
                displayName: secondTrack.displayName
            )
        )
        let item = PlaylistItem(
            id: UUID(),
            title: "Song",
            versions: [firstVersion, secondVersion],
            selectedVersionID: firstID,
            comparison: PlaylistComparisonConfiguration(
                repeatMode: .one,
                loopRegion: LoopRegion(start: 0.5, end: 1.5),
                isBlindListeningModeEnabled: true,
                visibleStart: 0.25,
                visibleSpan: 1.25
            )
        )
        let loader = CoordinatorTestAudioLoader(
            tracks: [firstURL: firstTrack, secondURL: secondTrack]
        )
        let controller = PlaybackController(loader: loader)
        let coordinator = PlaylistCoordinator(
            workspace: PlaylistWorkspace(items: [item]),
            controller: controller,
            loader: loader
        )

        await coordinator.playItem(id: item.id, versionID: firstID)
        #expect(coordinator.mode == .playlist)
        #expect(controller.session.activeTrackID == firstID)
        #expect(coordinator.isPlaying)

        coordinator.pause()
        await coordinator.selectPlaybackVersion(secondID, in: item.id)
        #expect(!coordinator.isPlaying)
        #expect(controller.session.activeTrackID == secondID)
        #expect(coordinator.workspace.items[0].selectedVersionID == secondID)

        coordinator.play()
        #expect(coordinator.isPlaying)
        await coordinator.selectPlaybackVersion(firstID, in: item.id)
        #expect(coordinator.isPlaying)
        #expect(controller.session.activeTrackID == firstID)

        coordinator.pause()
        coordinator.seek(to: 1)
        await coordinator.enterComparison(itemID: item.id)
        #expect(coordinator.mode == .comparison(itemID: item.id))
        #expect(controller.session.isBlindListeningModeEnabled)
        #expect(controller.session.loopRegion == LoopRegion(start: 0.5, end: 1.5))
        #expect(controller.visibleStart == 0.25)
        #expect(controller.visibleSpan == 1.25)
        await coordinator.selectPlaybackVersion(secondID, in: item.id)
        await coordinator.backToPlaylist()
        #expect(coordinator.mode == .playlist)
        #expect(coordinator.workspace.items[0].selectedVersionID == secondID)
        #expect(controller.session.activeTrackID == secondID)
    }

    @MainActor
    @Test
    func restoreKeepsMissingWorkspaceAndDoesNotCreateRuntimeTracks() async throws {
        let version = makeVersion("restore-missing.wav")
        let itemID = UUID()
        let workspace = PlaylistWorkspace(
            items: [PlaylistItem(id: itemID, title: "Restore", versions: [version])],
            listeningState: PlaylistListeningState(
                itemID: itemID,
                versionID: version.id
            )
        )
        let coordinator = PlaylistCoordinator()

        try await coordinator.restoreWorkspace(workspace)

        #expect(coordinator.workspace == workspace)
        #expect(coordinator.runtimeTrackCount == 0)
        #expect(coordinator.controller.session.tracks.isEmpty)
        #expect(coordinator.errorMessage != nil)
    }

    @MainActor
    @Test
    func snapshotForPersistenceDoesNotChangeWorkspaceWithoutRuntime() {
        let version = makeVersion("snapshot.wav")
        let item = PlaylistItem(title: "Snapshot", versions: [version])
        let coordinator = PlaylistCoordinator(workspace: PlaylistWorkspace(items: [item]))
        let before = coordinator.workspace

        let snapshot = coordinator.snapshotForPersistence()

        #expect(snapshot == before)
        #expect(coordinator.workspace == before)
    }

    private func makeVersion(_ name: String, id: UUID = UUID()) -> PlaylistVersion {
        PlaylistVersion(
            id: id,
            file: PlaylistFileReference(
                storedURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-\(name)")
            ),
            metadata: PlaylistMetadata(
                title: name.replacingOccurrences(of: ".wav", with: ""),
                duration: 2,
                sampleRate: 44_100,
                channelCount: 1,
                fileFormatDescription: "WAV",
                displayName: name
            )
        )
    }

    private func makeLoadedTrack(
        for url: URL,
        title: String? = nil
    ) -> LoadedTrack {
        LoadedTrack(
            url: url,
            displayName: url.lastPathComponent,
            fileFormatDescription: "WAV",
            duration: 2,
            sampleRate: 44_100,
            channelCount: 1,
            title: title
        )
    }

    private func makeTemporaryAudioFile(name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(name)
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: 44_100,
            channels: 1
        ) else {
            throw CoordinatorTestError.audioFormat
        }
        let frameCount = AVAudioFrameCount(44_100 * 2)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ) else {
            throw CoordinatorTestError.audioFormat
        }
        buffer.frameLength = frameCount
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

private actor CoordinatorLoadGate {
    private var started = false
    private var released = false

    func markStarted() {
        started = true
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func waitUntilReleased() async {
        while !released {
            await Task.yield()
        }
    }

    func release() {
        released = true
    }
}

private struct CoordinatorTestAudioLoader: AudioFileLoading {
    let tracks: [URL: LoadedTrack]
    var gate: CoordinatorLoadGate?

    func loadTrackMetadata(from url: URL) async throws -> LoadedTrack {
        if let gate {
            await gate.markStarted()
            await gate.waitUntilReleased()
        }
        guard let track = tracks[url] else {
            throw PlaybackError.failedToOpenFile(url)
        }
        return track
    }

    func makeAudioFile(from url: URL) throws -> AVAudioFile {
        try AVAudioFile(forReading: url)
    }
}

private enum CoordinatorTestError: Error {
    case audioFormat
}
