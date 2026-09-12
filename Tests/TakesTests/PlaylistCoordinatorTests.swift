import AVFoundation
import Foundation
import Testing
@testable import Takes

struct PlaylistCoordinatorTests {
    @MainActor
    @Test func synchronousFollowUpEditDoesNotCancelRequiredRuntimeRefresh() async throws {
        let firstURL = try makeTemporaryAudioFile(name: "removed-runtime.wav")
        let secondURL = try makeTemporaryAudioFile(name: "successor-runtime.wav")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }
        let loader = CoordinatorTestAudioLoader(tracks: [
            firstURL: makeLoadedTrack(for: firstURL),
            secondURL: makeLoadedTrack(for: secondURL)
        ])
        let coordinator = PlaylistCoordinator(loader: loader)
        let imported = await coordinator.importFiles([firstURL, secondURL], destination: .playlist)
        let firstItemID = try #require(imported.first)
        let secondItemID = try #require(imported.last)
        let firstVersionID = try #require(coordinator.workspace.items.first?.selectedVersionID)
        let secondVersionID = try #require(coordinator.workspace.items.last?.selectedVersionID)
        await coordinator.playItem(id: firstItemID)

        #expect(coordinator.removeItem(firstItemID))
        #expect(coordinator.renameItem(secondItemID, to: "Renamed successor"))
        for _ in 0..<100 {
            if coordinator.controller.session.activeTrackID == secondVersionID { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(coordinator.workspace.items.map(\.id) == [secondItemID])
        #expect(coordinator.currentItemID == secondItemID)
        #expect(coordinator.currentVersionID == secondVersionID)
        #expect(coordinator.controller.session.activeTrackID == secondVersionID)
        #expect(coordinator.controller.session.activeTrackID != firstVersionID)
        #expect(coordinator.controller.runtimeTrackCount == 1)
        #expect(!coordinator.isPlaying)
    }

    @MainActor
    @Test func clearUndoRedoRestoresPausedRuntimeAndFilePosition() async throws {
        let url = try makeTemporaryAudioFile(name: "undo-runtime.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = CoordinatorTestAudioLoader(tracks: [url: makeLoadedTrack(for: url)])
        let coordinator = PlaylistCoordinator(loader: loader)
        let imported = await coordinator.importFiles([url], destination: .playlist)
        let itemID = try #require(imported.first)
        await coordinator.playItem(id: itemID)
        coordinator.pause()
        coordinator.seek(to: 1)
        let versionID = coordinator.currentVersionID
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        #expect(coordinator.clearPlaylist(undoManager: undo))
        undo.endUndoGrouping()
        #expect(coordinator.controller.runtimeTrackCount == 0)

        undo.undo()
        for _ in 0..<100 {
            if coordinator.controller.runtimeTrackCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(coordinator.controller.runtimeTrackCount == 1)
        #expect(coordinator.controller.session.activeTrackID == versionID)
        #expect(coordinator.controller.session.transportPosition == 1)
        #expect(!coordinator.isPlaying)
        #expect(coordinator.errorMessage == nil)

        undo.redo()
        #expect(coordinator.workspace.items.isEmpty)
        #expect(coordinator.controller.runtimeTrackCount == 0)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

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
    func hundredItemWorkspaceLoadsOnlyCurrentItemAndThirtyTwoVersionComparison() async throws {
        let urls = try (0...PlaylistWorkspace.maximumVersionsPerItem).map { index in
            try makeTemporaryAudioFile(name: "scale-\(index).wav", duration: 0.05)
        }
        defer {
            for url in urls {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }
        let tracks = Dictionary(uniqueKeysWithValues: urls.map { url in
            (url, makeLoadedTrack(for: url, duration: 0.05))
        })
        let versions = urls.map { url in
            PlaylistVersion(
                file: PlaylistWorkspaceStore.makeFileReference(for: url),
                metadata: PlaylistMetadata(
                    title: url.deletingPathExtension().lastPathComponent,
                    duration: 0.05,
                    sampleRate: 44_100,
                    channelCount: 1,
                    fileFormatDescription: "WAV",
                    displayName: url.lastPathComponent
                )
            )
        }
        let comparisonItem = PlaylistItem(
            title: "32 versions",
            versions: Array(versions.prefix(PlaylistWorkspace.maximumVersionsPerItem))
        )
        let comparisonVersionID = try #require(comparisonItem.selectedVersionID)
        let playlistVersion = try #require(versions.last)
        let playlistItem = PlaylistItem(title: "Playlist item", versions: [playlistVersion])
        let missingItems = (0..<98).map { index in
            PlaylistItem(title: "Inactive \(index)", versions: [makeVersion("inactive-\(index).wav")])
        }
        let workspace = PlaylistWorkspace(items: [comparisonItem, playlistItem] + missingItems)
        let coordinator = PlaylistCoordinator(
            workspace: workspace,
            loader: CoordinatorTestAudioLoader(tracks: tracks)
        )

        await coordinator.playItem(id: playlistItem.id)
        coordinator.pause()
        #expect(coordinator.workspace.items.count == 100)
        #expect(coordinator.controller.runtimeTrackCount == 1)
        #expect(coordinator.controller.session.tracks.map(\.id) == [playlistVersion.id])

        await coordinator.enterComparison(itemID: comparisonItem.id)
        #expect(coordinator.controller.runtimeTrackCount == PlaylistWorkspace.maximumVersionsPerItem)
        #expect(Set(coordinator.controller.session.tracks.map(\.id)) == Set(comparisonItem.versions.map(\.id)))
        #expect(coordinator.runtimeContext?.itemID == comparisonItem.id)

        await coordinator.backToPlaylist()
        #expect(coordinator.controller.runtimeTrackCount == 1)
        #expect(coordinator.controller.session.tracks.map(\.id) == [comparisonVersionID])
        #expect(!coordinator.isPlaying)
    }

    @MainActor
    @Test
    func naturalEndSkipsMissingItemAndContinuesWithNextPlayableItem() async throws {
        let firstURL = try makeTemporaryAudioFile(name: "natural-first.wav", duration: 0.05)
        let thirdURL = try makeTemporaryAudioFile(name: "natural-third.wav", duration: 2)
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: thirdURL.deletingLastPathComponent())
        }
        let firstVersion = PlaylistVersion(
            file: PlaylistWorkspaceStore.makeFileReference(for: firstURL),
            metadata: PlaylistMetadata(
                title: "First", duration: 0.05, sampleRate: 44_100, channelCount: 1,
                fileFormatDescription: "WAV", displayName: firstURL.lastPathComponent
            )
        )
        let missingVersion = makeVersion("missing-middle.wav")
        let thirdVersion = PlaylistVersion(
            file: PlaylistWorkspaceStore.makeFileReference(for: thirdURL),
            metadata: PlaylistMetadata(
                title: "Third", duration: 2, sampleRate: 44_100, channelCount: 1,
                fileFormatDescription: "WAV", displayName: thirdURL.lastPathComponent
            )
        )
        let first = PlaylistItem(title: "First", versions: [firstVersion])
        let missing = PlaylistItem(title: "Missing", versions: [missingVersion])
        let third = PlaylistItem(title: "Third", versions: [thirdVersion])
        let loader = CoordinatorTestAudioLoader(tracks: [
            firstURL: makeLoadedTrack(for: firstURL, duration: 0.05),
            thirdURL: makeLoadedTrack(for: thirdURL)
        ])
        let coordinator = PlaylistCoordinator(
            workspace: PlaylistWorkspace(items: [first, missing, third]),
            loader: loader
        )
        defer { coordinator.pause() }

        await coordinator.playItem(id: first.id)
        for _ in 0..<200 {
            if coordinator.currentItemID == third.id { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(coordinator.workspace.items.map(\.id) == [first.id, missing.id, third.id])
        #expect(coordinator.currentItemID == third.id)
        #expect(coordinator.currentVersionID == thirdVersion.id)
        #expect(coordinator.controller.session.activeTrackID == thirdVersion.id)
        #expect(coordinator.controller.runtimeTrackCount == 1)
        #expect(coordinator.isPlaying)
        #expect(coordinator.errorMessage != nil)
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

    @MainActor
    @Test
    func automaticImportGroupsTwoPairsAndUndoesAsOneTransaction() async {
        let urls = ["song-a-master.wav", "song-a-mp3.wav", "song-b-master.wav", "song-b-mp3.wav"]
            .map { URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-\($0)") }
        let tracks = Dictionary(uniqueKeysWithValues: urls.map { ($0, makeLoadedTrack(for: $0)) })
        let analyzer = CoordinatorSimilarityAnalyzer(matches: [
            (urls[0].lastPathComponent, urls[1].lastPathComponent),
            (urls[2].lastPathComponent, urls[3].lastPathComponent)
        ])
        let coordinator = PlaylistCoordinator(
            loader: CoordinatorTestAudioLoader(tracks: tracks),
            similarityAnalyzer: analyzer
        )
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()

        let imported = await coordinator.importFiles(
            urls,
            destination: .playlist,
            automaticGroupingMode: .sameRecording,
            undoManager: undoManager
        )
        undoManager.endUndoGrouping()

        #expect(imported.count == 2)
        #expect(coordinator.workspace.items.map(\.versions.count) == [2, 2])
        #expect(coordinator.importSummaryMessage?.contains("4 files added as 2 playlist items") == true)
        undoManager.undo()
        #expect(coordinator.workspace.items.isEmpty)
    }

    @MainActor
    @Test
    func automaticImportUsesTheSelectedSimilarityLevel() async {
        let firstURL = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-mix.wav")
        let secondURL = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-edit.wav")
        let tracks = [
            firstURL: makeLoadedTrack(for: firstURL),
            secondURL: makeLoadedTrack(for: secondURL)
        ]
        let analyzer = CoordinatorSimilarityAnalyzer(
            evidence: [
                CoordinatorSimilarityAnalyzer.key(firstURL.lastPathComponent, secondURL.lastPathComponent):
                    TrackSimilarityEvidence(
                        sameRecording: .mismatch,
                        samePerformance: .match,
                        diagnostic: "Same performance, different edit."
                    )
            ]
        )
        let conservative = PlaylistCoordinator(
            loader: CoordinatorTestAudioLoader(tracks: tracks),
            similarityAnalyzer: analyzer
        )
        let broad = PlaylistCoordinator(
            loader: CoordinatorTestAudioLoader(tracks: tracks),
            similarityAnalyzer: analyzer
        )

        await conservative.importFiles(
            [firstURL, secondURL], destination: .playlist,
            automaticGroupingMode: .sameRecording
        )
        await broad.importFiles(
            [firstURL, secondURL], destination: .playlist,
            automaticGroupingMode: .samePerformance
        )

        #expect(conservative.workspace.items.map(\.versions.count) == [1, 1])
        #expect(broad.workspace.items.map(\.versions.count) == [2])
    }

    @MainActor
    @Test
    func analysisTimeoutFallsBackToSeparateItemsAndReportsIt() async {
        let urls = ["timeout-a.wav", "timeout-b.wav"].map {
            URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-\($0)")
        }
        let coordinator = PlaylistCoordinator(
            loader: CoordinatorTestAudioLoader(
                tracks: Dictionary(uniqueKeysWithValues: urls.map { ($0, makeLoadedTrack(for: $0)) })
            ),
            similarityAnalyzer: CoordinatorSimilarityAnalyzer(evidence: [:], timedOut: true)
        )

        let imported = await coordinator.importFiles(
            urls, destination: .playlist,
            automaticGroupingMode: .sameRecording
        )

        #expect(imported.count == 2)
        #expect(coordinator.workspace.items.map(\.versions.count) == [1, 1])
        #expect(coordinator.importSummaryMessage?.contains("could not be analyzed") == true)
    }

    @MainActor
    @Test
    func uniqueExistingMatchAppendsWithoutInterruptingThePlaylist() async throws {
        let existingURL = try makeTemporaryAudioFile(name: "existing-master.wav")
        let unrelatedURL = try makeTemporaryAudioFile(name: "unrelated.wav")
        let incomingURL = try makeTemporaryAudioFile(name: "existing-mp3.wav")
        defer {
            try? FileManager.default.removeItem(at: existingURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: unrelatedURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: incomingURL.deletingLastPathComponent())
        }
        let existingVersion = makePlaylistVersion(url: existingURL, title: "Existing")
        let unrelatedVersion = makePlaylistVersion(url: unrelatedURL, title: "Unrelated")
        let target = PlaylistItem(title: "Existing", versions: [existingVersion])
        let unrelated = PlaylistItem(title: "Unrelated", versions: [unrelatedVersion])
        let analyzer = CoordinatorSimilarityAnalyzer(matches: [
            (existingURL.lastPathComponent, incomingURL.lastPathComponent)
        ])
        let tracks = [existingURL, unrelatedURL, incomingURL].reduce(into: [URL: LoadedTrack]()) {
            $0[$1] = makeLoadedTrack(for: $1)
        }
        let coordinator = PlaylistCoordinator(
            workspace: PlaylistWorkspace(items: [target, unrelated]),
            loader: CoordinatorTestAudioLoader(tracks: tracks),
            similarityAnalyzer: analyzer
        )
        defer { coordinator.pause() }

        let imported = await coordinator.importFiles(
            [incomingURL], destination: .playlist,
            automaticGroupingMode: .sameRecording
        )

        #expect(imported == [target.id])
        #expect(coordinator.workspace.items[0].versions.count == 2)
        #expect(coordinator.workspace.items[1].versions.count == 1)
        #expect(coordinator.mode == .playlist)
        #expect(coordinator.controller.runtimeTrackCount == 0)
    }

    @MainActor
    @Test
    func singleGroupedItemInAnEmptyPlaylistOpensComparison() async throws {
        let firstURL = try makeTemporaryAudioFile(name: "single-group-first.wav")
        let secondURL = try makeTemporaryAudioFile(name: "single-group-second.wav")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }
        let loader = CoordinatorTestAudioLoader(tracks: [
            firstURL: makeLoadedTrack(for: firstURL),
            secondURL: makeLoadedTrack(for: secondURL)
        ])
        let coordinator = PlaylistCoordinator(
            loader: loader,
            similarityAnalyzer: CoordinatorSimilarityAnalyzer(matches: [
                (firstURL.lastPathComponent, secondURL.lastPathComponent)
            ])
        )
        defer { coordinator.pause() }

        let imported = await coordinator.importFiles(
            [firstURL, secondURL], destination: .playlist,
            automaticGroupingMode: .sameRecording
        )

        let itemID = try #require(imported.first)
        #expect(imported.count == 1)
        #expect(coordinator.mode == .comparison(itemID: itemID))
        #expect(coordinator.controller.runtimeTrackCount == 2)
    }

    @MainActor
    @Test
    func cancellingDuringSimilarityAnalysisPreventsTheAtomicCommit() async {
        let urls = ["cancel-a.wav", "cancel-b.wav"].map {
            URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-\($0)")
        }
        let gate = CoordinatorSimilarityGate()
        let coordinator = PlaylistCoordinator(
            loader: CoordinatorTestAudioLoader(
                tracks: Dictionary(uniqueKeysWithValues: urls.map { ($0, makeLoadedTrack(for: $0)) })
            ),
            similarityAnalyzer: GatedCoordinatorSimilarityAnalyzer(gate: gate)
        )
        let task = Task { @MainActor in
            await coordinator.importFiles(
                urls, destination: .playlist,
                automaticGroupingMode: .sameRecording
            )
        }

        await gate.waitUntilStarted()
        coordinator.cancelCurrentImports()
        await gate.release()
        let imported = await task.value

        #expect(imported.isEmpty)
        #expect(coordinator.workspace.items.isEmpty)
        #expect(!coordinator.isLoading)
    }

    @MainActor
    @Test
    func workspaceMembershipChangeRefusesAStaleExistingAssignment() async throws {
        let existingURL = try makeTemporaryAudioFile(name: "stale-existing.wav")
        let incomingURL = try makeTemporaryAudioFile(name: "stale-incoming.wav")
        defer {
            try? FileManager.default.removeItem(at: existingURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: incomingURL.deletingLastPathComponent())
        }
        let existing = PlaylistItem(
            title: "Existing",
            versions: [makePlaylistVersion(url: existingURL, title: "Existing")]
        )
        let gate = CoordinatorSimilarityGate()
        let coordinator = PlaylistCoordinator(
            workspace: PlaylistWorkspace(items: [existing]),
            loader: CoordinatorTestAudioLoader(tracks: [incomingURL: makeLoadedTrack(for: incomingURL)]),
            similarityAnalyzer: GatedCoordinatorSimilarityAnalyzer(gate: gate, matchesEveryPair: true)
        )
        let task = Task { @MainActor in
            await coordinator.importFiles(
                [incomingURL], destination: .playlist,
                automaticGroupingMode: .sameRecording
            )
        }

        await gate.waitUntilStarted()
        #expect(coordinator.removeItem(existing.id))
        await gate.release()
        let imported = await task.value

        #expect(imported.count == 1)
        #expect(imported.first != existing.id)
        #expect(coordinator.workspace.items.count == 1)
        #expect(coordinator.workspace.items[0].versions.map(\.file.canonicalURL) == [incomingURL])
    }

    @MainActor
    @Test
    func changedFileIdentityInvalidatesSimilarityEvidenceBeforeCommit() async throws {
        let firstURL = try makeTemporaryAudioFile(name: "identity-first.wav")
        let secondURL = try makeTemporaryAudioFile(name: "identity-second.wav")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }
        let gate = CoordinatorSimilarityGate()
        let coordinator = PlaylistCoordinator(
            loader: CoordinatorTestAudioLoader(tracks: [
                firstURL: makeLoadedTrack(for: firstURL),
                secondURL: makeLoadedTrack(for: secondURL)
            ]),
            similarityAnalyzer: GatedCoordinatorSimilarityAnalyzer(gate: gate, matchesEveryPair: true)
        )
        let task = Task { @MainActor in
            await coordinator.importFiles(
                [firstURL, secondURL], destination: .playlist,
                automaticGroupingMode: .sameRecording
            )
        }

        await gate.waitUntilStarted()
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)],
            ofItemAtPath: secondURL.path
        )
        await gate.release()
        _ = await task.value

        #expect(coordinator.workspace.items.map(\.versions.count) == [1, 1])
        #expect(coordinator.importSummaryMessage?.contains("could not be analyzed") == true)
    }

    @MainActor
    @Test
    func playlistImportJoiningActiveComparisonRefreshesItsRuntime() async throws {
        let firstURL = try makeTemporaryAudioFile(name: "active-first.wav")
        let secondURL = try makeTemporaryAudioFile(name: "active-second.wav")
        let incomingURL = try makeTemporaryAudioFile(name: "active-incoming.wav")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: incomingURL.deletingLastPathComponent())
        }
        let first = makePlaylistVersion(url: firstURL, title: "Active")
        let second = makePlaylistVersion(url: secondURL, title: "Active")
        let item = PlaylistItem(title: "Active", versions: [first, second])
        let tracks = [firstURL, secondURL, incomingURL].reduce(into: [URL: LoadedTrack]()) {
            $0[$1] = makeLoadedTrack(for: $1)
        }
        let analyzer = CoordinatorSimilarityAnalyzer(matches: [
            (incomingURL.lastPathComponent, firstURL.lastPathComponent),
            (incomingURL.lastPathComponent, secondURL.lastPathComponent)
        ])
        let loader = CoordinatorTestAudioLoader(tracks: tracks)
        let coordinator = PlaylistCoordinator(
            workspace: PlaylistWorkspace(items: [item]),
            controller: PlaybackController(loader: loader),
            loader: loader,
            similarityAnalyzer: analyzer
        )
        defer { coordinator.pause() }
        await coordinator.enterComparison(itemID: item.id)
        #expect(coordinator.controller.runtimeTrackCount == 2)

        await coordinator.importFiles(
            [incomingURL], destination: .playlist,
            automaticGroupingMode: .sameRecording
        )
        for _ in 0..<100 {
            if coordinator.controller.runtimeTrackCount == 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(coordinator.mode == .comparison(itemID: item.id))
        #expect(coordinator.workspace.items[0].versions.count == 3)
        #expect(coordinator.controller.runtimeTrackCount == 3)
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

    private func makePlaylistVersion(url: URL, title: String) -> PlaylistVersion {
        PlaylistVersion(
            file: PlaylistWorkspaceStore.makeFileReference(for: url),
            metadata: PlaylistMetadata(
                title: title,
                duration: 2,
                sampleRate: 44_100,
                channelCount: 1,
                fileFormatDescription: "WAV",
                displayName: url.lastPathComponent
            )
        )
    }

    private func makeLoadedTrack(
        for url: URL,
        title: String? = nil,
        duration: TimeInterval = 2
    ) -> LoadedTrack {
        LoadedTrack(
            url: url,
            displayName: url.lastPathComponent,
            fileFormatDescription: "WAV",
            duration: duration,
            sampleRate: 44_100,
            channelCount: 1,
            title: title
        )
    }

    private func makeTemporaryAudioFile(name: String, duration: TimeInterval = 2) throws -> URL {
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
        let frameCount = AVAudioFrameCount(max(1, Int((44_100 * duration).rounded())))
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

private struct CoordinatorSimilarityAnalyzer: TrackSimilarityAnalyzing {
    let evidence: [String: TrackSimilarityEvidence]
    var timedOut = false

    init(evidence: [String: TrackSimilarityEvidence], timedOut: Bool = false) {
        self.evidence = evidence
        self.timedOut = timedOut
    }

    init(matches: [(String, String)]) {
        evidence = Dictionary(uniqueKeysWithValues: matches.map { first, second in
            (
                Self.key(first, second),
                TrackSimilarityEvidence(
                    sameRecording: .match,
                    samePerformance: .match,
                    diagnostic: "Test match."
                )
            )
        })
    }

    func analyze(_ request: TrackSimilarityRequest) async -> TrackSimilarityAnalysis {
        let names = Dictionary(uniqueKeysWithValues: request.sources.map { ($0.id, $0.url.lastPathComponent) })
        var result = TrackSimilarityAnalysis(timedOut: timedOut)
        for pair in request.pairs {
            guard let first = names[pair.firstID], let second = names[pair.secondID] else { continue }
            result.evidence[pair] = evidence[Self.key(first, second)]
                ?? TrackSimilarityEvidence(
                    sameRecording: .mismatch,
                    samePerformance: .mismatch,
                    diagnostic: "Test mismatch."
                )
        }
        return result
    }

    static func key(_ first: String, _ second: String) -> String {
        [first, second].sorted().joined(separator: "|")
    }
}

private actor CoordinatorSimilarityGate {
    private var started = false
    private var released = false

    func markStarted() { started = true }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func waitUntilReleased() async {
        while !released { await Task.yield() }
    }

    func release() { released = true }
}

private struct GatedCoordinatorSimilarityAnalyzer: TrackSimilarityAnalyzing {
    let gate: CoordinatorSimilarityGate
    var matchesEveryPair = false

    func analyze(_ request: TrackSimilarityRequest) async -> TrackSimilarityAnalysis {
        await gate.markStarted()
        await gate.waitUntilReleased()
        guard matchesEveryPair else { return TrackSimilarityAnalysis() }
        return TrackSimilarityAnalysis(evidence: Dictionary(uniqueKeysWithValues: request.pairs.map {
            (
                $0,
                TrackSimilarityEvidence(
                    sameRecording: .match,
                    samePerformance: .match,
                    diagnostic: "Gated test match."
                )
            )
        }))
    }
}

private enum CoordinatorTestError: Error {
    case audioFormat
}
