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
        let firstVersionID = try #require(coordinator.workspace.items.first?.keyVersion?.id)
        let secondVersionID = try #require(coordinator.workspace.items.last?.keyVersion?.id)
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
        let comparisonVersionID = try #require(comparisonItem.keyVersion?.id)
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
        #expect(coordinator.errorMessage == nil)
        #expect(coordinator.fileIssues[missingVersion.id]?.error == .failedToOpenFile(missingVersion.file.storedURL))
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
            versions: [first, second]
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
    @Test func mixedGroupOverLimitLeavesEveryItemAndUndoUnchanged() {
        let destination = PlaylistItem(title: "Destination", versions: (0..<31).map { makeVersion("dest-\($0).wav") })
        let first = makeVersion("loose-one.wav")
        let second = makeVersion("loose-two.wav")
        let source = PlaylistItem(title: "Source", versions: [first, second])
        let before = PlaylistWorkspace(items: [destination, source])
        let coordinator = PlaylistCoordinator(workspace: before)
        let undo = UndoManager()
        let result = coordinator.groupItems([destination.id], looseVersionIDs: [first.id, second.id], undoManager: undo)
        #expect(result == nil)
        #expect(coordinator.workspace == before)
        #expect(!undo.canUndo)
        #expect(coordinator.errorMessage != nil)
    }

    @MainActor
    @Test func moveCommandsFollowTheCurrentSelectionAndRespectEachRowsSiblings() {
        let a = PlaylistItem(title: "A", versions: ["a", "b", "c"].map { makeVersion("\($0).wav") })
        let b = PlaylistItem(title: "B", versions: [makeVersion("d.wav")])
        let c = PlaylistItem(title: "C", versions: [makeVersion("e.wav")])
        let coordinator = PlaylistCoordinator(workspace: PlaylistWorkspace(items: [a, b, c]))
        let presentation = PlaylistPresentationState()
        let undo = UndoManager()
        let context = PlaylistCommandContext(coordinator: coordinator, presentation: presentation, undoManager: undo)

        #expect(!PlaylistOrganizationAvailability(context).canMoveUp)
        presentation.selection = [.item(b.id), .item(c.id), .version(a.versions[1].id)]
        #expect(PlaylistOrganizationAvailability(context).canMoveUp)
        context.moveSelection(.up)
        #expect(coordinator.workspace.items.map(\.id) == [b.id, c.id, a.id])
        #expect(coordinator.workspace.items.last?.versions.map(\.id) ==
                [a.versions[1].id, a.versions[0].id, a.versions[2].id])
        // Reordering versions moves the derived key with the order.
        #expect(coordinator.workspace.items.last?.keyVersion?.id == a.versions[1].id)
        #expect(!PlaylistOrganizationAvailability(context).canMoveUp)
        #expect(PlaylistOrganizationAvailability(context).canMoveDown)
        undo.undo()
        #expect(coordinator.workspace.items == [a, b, c])
    }

    @MainActor
    @Test(arguments: [false, true])
    func compareMoveFollowsTheActiveLaneAndKeepsTheRuntime(blind: Bool) async throws {
        let urls = try ["move-a.wav", "move-b.wav"].map { try makeTemporaryAudioFile(name: $0) }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }
        let versions = urls.map { makePlaylistVersion(url: $0, title: $0.lastPathComponent) }
        let item = PlaylistItem(title: "Pair", versions: versions)
        let coordinator = PlaylistCoordinator(workspace: PlaylistWorkspace(items: [item]))
        await coordinator.enterComparison(itemID: item.id)
        if blind {
            coordinator.controller.setBlindListeningMode(true) { Array($0.reversed()) }
        }
        coordinator.play()
        defer { coordinator.pause() }
        let context = coordinator.runtimeContext
        let activeID = coordinator.controller.session.activeTrackID
        let displayedOrder = coordinator.controller.session.tracks.map(\.id)

        #expect(!coordinator.canMoveActiveComparisonVersion(.up))
        #expect(coordinator.canMoveActiveComparisonVersion(.down))
        coordinator.moveActiveComparisonVersion(.down, undoManager: nil)

        #expect(coordinator.controller.session.tracks.map(\.id) == Array(displayedOrder.reversed()))
        #expect(coordinator.controller.session.activeTrackID == activeID)
        #expect(coordinator.runtimeContext == context)
        #expect(coordinator.isPlaying)
        #expect(coordinator.canMoveActiveComparisonVersion(.up))
        #expect(!coordinator.canMoveActiveComparisonVersion(.down))
        #expect(coordinator.workspace.items.first?.versions.map(\.id) ==
                (blind ? versions.map(\.id) : Array(versions.map(\.id).reversed())))
    }

    @MainActor
    @Test func separateCommandsSelectResultingTracksInPlace() {
        let versions = ["first", "second", "third", "fourth", "fifth"].map { makeVersion("\($0).wav") }
        let item = PlaylistItem(title: "Song", versions: versions)
        let coordinator = PlaylistCoordinator(workspace: PlaylistWorkspace(items: [item]))
        let presentation = PlaylistPresentationState()
        let context = PlaylistCommandContext(coordinator: coordinator, presentation: presentation, undoManager: nil)
        presentation.expanded = [item.id]

        presentation.selection = [.version(versions[1].id)]
        #expect(context.canSeparate)
        context.separate()
        let partial = coordinator.workspace.items
        #expect(partial.map { $0.versions.map(\.id) } ==
                [[versions[0].id, versions[2].id, versions[3].id, versions[4].id], [versions[1].id]])
        #expect(presentation.selection == [.item(partial[1].id)])
        #expect(!context.canSeparate)

        presentation.selection = [.version(versions[2].id), .version(versions[4].id)]
        context.separate()
        let multiple = coordinator.workspace.items
        #expect(multiple.map { $0.versions.map(\.id) } ==
                [[versions[0].id, versions[3].id], [versions[2].id], [versions[4].id], [versions[1].id]])
        #expect(presentation.selection == [.item(multiple[1].id), .item(multiple[2].id)])

        presentation.selection = [.item(item.id), .version(versions[3].id)]
        context.separate()
        let complete = coordinator.workspace.items
        #expect(complete.map { $0.versions.map(\.id) } ==
                [[versions[0].id], [versions[3].id], [versions[2].id], [versions[4].id], [versions[1].id]])
        #expect(presentation.selection == [.item(complete[0].id), .item(complete[1].id)])
        #expect(!context.canSeparate)
    }

    @MainActor
    @Test func groupUsesTheSelectedTrackAndOnlyTheSelectedLooseVersions() {
        let target = PlaylistItem(title: "Target", versions: ["a", "b"].map { makeVersion("\($0).wav") })
        let source = PlaylistItem(title: "Source", versions: ["c", "d"].map { makeVersion("\($0).wav") })
        let coordinator = PlaylistCoordinator(workspace: PlaylistWorkspace(items: [target, source]))
        let presentation = PlaylistPresentationState()
        let context = PlaylistCommandContext(coordinator: coordinator, presentation: presentation, undoManager: nil)

        presentation.selection = [.item(target.id), .version(target.versions[1].id)]
        #expect(!context.canGroup)
        presentation.selection.insert(.version(source.versions[0].id))
        #expect(context.canGroup)
        context.group()

        #expect(coordinator.workspace.items.map(\.id) == [target.id, source.id])
        #expect(coordinator.workspace.items[0].versions == target.versions + [source.versions[0]])
        #expect(coordinator.workspace.items[1].versions == [source.versions[1]])
        #expect(presentation.selection == [.item(target.id)])
        #expect(presentation.expanded == [target.id])
        #expect(!context.canGroup)
    }

    @MainActor
    @Test func dragSeparationAndPlacementUndoTogether() throws {
        let versions = ["a", "b", "c"].map { makeVersion("\($0).wav") }
        let source = PlaylistItem(title: "Source", versions: versions)
        let before = PlaylistWorkspace(items: [source])
        let coordinator = PlaylistCoordinator(workspace: before)
        let undo = UndoManager()
        let ids = [versions[1].id, versions[0].id]
        #expect(coordinator.separateVersions(ids, placement: .beforeItem(UUID()), undoManager: undo) == nil)
        #expect(coordinator.workspace == before)
        #expect(!undo.canUndo)
        let created = try #require(coordinator.separateVersions(ids, placement: .beforeItem(source.id), undoManager: undo))
        #expect(coordinator.workspace.items.map(\.id) == created + [source.id])
        #expect(coordinator.workspace.items.flatMap { $0.versions.map(\.id) } == ids + [versions[2].id])
        undo.undo()
        #expect(coordinator.workspace == before)
        #expect(!undo.canUndo)
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
    func leavingCompareKeepsTheAudibleVersionCurrentWithoutChangingTheKey() async throws {
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
        coordinator.seek(to: 1)
        await coordinator.enterComparison(itemID: item.id)
        #expect(coordinator.mode == .comparison(itemID: item.id))
        #expect(controller.session.isBlindListeningModeEnabled)
        #expect(controller.session.loopRegion == LoopRegion(start: 0.5, end: 1.5))
        #expect(controller.visibleStart == 0.25)
        #expect(controller.visibleSpan == 1.25)
        #expect(controller.session.activeTrackID == firstID)
        controller.selectActiveTrack(secondID)
        await coordinator.backToPlaylist()
        #expect(coordinator.mode == .playlist)
        // The audible version stays the current version, at its file time,
        // but is not stored as the key: the key is still the first version.
        #expect(controller.session.activeTrackID == secondID)
        #expect(coordinator.currentVersionID == secondID)
        #expect(coordinator.workspace.listeningState?.versionID == secondID)
        #expect(coordinator.workspace.items[0].versions.map(\.id) == [firstID, secondID])
        #expect(coordinator.workspace.items[0].keyVersion?.id == firstID)

        // Resuming keeps the current version; playing the track from its
        // row plays the key.
        coordinator.play()
        #expect(controller.session.activeTrackID == secondID)
        coordinator.pause()
        await coordinator.playItem(id: item.id)
        #expect(controller.session.activeTrackID == firstID)
        coordinator.pause()
    }

    @MainActor
    @Test func playingAVersionRowRestartsItWithoutChangingTheKeyVersion() async throws {
        let firstURL = try makeTemporaryAudioFile(name: "key.wav")
        let secondURL = try makeTemporaryAudioFile(name: "alternate.wav")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }
        let key = makePlaylistVersion(url: firstURL, title: "Key")
        let alternate = makePlaylistVersion(url: secondURL, title: "Alternate")
        let item = PlaylistItem(title: "Track", versions: [key, alternate])
        let coordinator = PlaylistCoordinator(workspace: PlaylistWorkspace(items: [item]))
        defer { coordinator.pause() }

        await coordinator.playItem(id: item.id, versionID: alternate.id, fromBeginning: true)
        coordinator.pause()
        coordinator.seek(to: 1)
        #expect(coordinator.controller.session.transportPosition == 1)

        await coordinator.playItem(id: item.id, versionID: alternate.id, fromBeginning: true)
        #expect(coordinator.isPlaying)
        #expect(coordinator.currentVersionID == alternate.id)
        #expect(coordinator.workspace.listeningState?.filePosition ?? 1 < 0.5)
        #expect(coordinator.workspace.items.first?.keyVersion?.id == key.id)

        await coordinator.playItem(id: item.id)
        #expect(coordinator.currentVersionID == key.id)
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
        #expect(coordinator.errorMessage == nil)
        #expect(coordinator.fileIssues[version.id]?.error == .failedToOpenFile(version.file.storedURL))
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
        let titles = ["Song A", "Song A (Remastered 2020)", "Song B", "Song B (Stereo Mix)"]
        let tracks = Dictionary(uniqueKeysWithValues: urls.enumerated().map { index, url in
            (url, makeLoadedTrack(for: url, title: titles[index], artist: "Artist"))
        })
        let coordinator = PlaylistCoordinator(loader: CoordinatorTestAudioLoader(tracks: tracks))
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()

        let imported = await coordinator.importFiles(
            urls,
            destination: .playlist,
            automaticGroupingMode: .automatic,
            undoManager: undoManager
        )
        undoManager.endUndoGrouping()

        #expect(imported.count == 2)
        #expect(coordinator.workspace.items.map(\.versions.count) == [2, 2])
        undoManager.undo()
        #expect(coordinator.workspace.items.isEmpty)
    }

    @MainActor
    @Test
    func separateAlbumImportsUseTheSameGroupingRules() async {
        let urls = ["album-one-a.wav", "album-one-b.wav", "album-two-b.wav", "album-two-a.wav"]
            .map { URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-\($0)") }
        let titles = ["Song A", "Song B", "Song B (Remastered)", "Song A (Stereo Mix)"]
        let tracks = Dictionary(uniqueKeysWithValues: urls.enumerated().map { index, url in
            (url, makeLoadedTrack(for: url, title: titles[index], artist: "Artist"))
        })
        let coordinator = PlaylistCoordinator(loader: CoordinatorTestAudioLoader(tracks: tracks))

        _ = await coordinator.importFiles(
            Array(urls[0...1]), destination: .playlist,
            automaticGroupingMode: .automatic
        )
        _ = await coordinator.importFiles(
            Array(urls[2...3]), destination: .playlist,
            automaticGroupingMode: .automatic
        )

        #expect(coordinator.workspace.items.count == 2)
        #expect(coordinator.workspace.items.map(\.versions.count) == [2, 2])
        #expect(coordinator.workspace.items[0].versions.map(\.metadata.title) == ["Song A", "Song A (Stereo Mix)"])
        #expect(coordinator.workspace.items[1].versions.map(\.metadata.title) == ["Song B", "Song B (Remastered)"])
    }

    @MainActor
    @Test
    func automaticImportCanBeDisabled() async {
        let firstURL = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-mix.wav")
        let secondURL = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-edit.wav")
        let tracks = [
            firstURL: makeLoadedTrack(for: firstURL, title: "Example Song", artist: "Artist"),
            secondURL: makeLoadedTrack(for: secondURL, title: "Example Song", artist: "Artist")
        ]
        let disabled = PlaylistCoordinator(loader: CoordinatorTestAudioLoader(tracks: tracks))
        let automatic = PlaylistCoordinator(loader: CoordinatorTestAudioLoader(tracks: tracks))

        await disabled.importFiles(
            [firstURL, secondURL], destination: .playlist,
            automaticGroupingMode: .off
        )
        await automatic.importFiles(
            [firstURL, secondURL], destination: .playlist,
            automaticGroupingMode: .automatic
        )

        #expect(disabled.workspace.items.map(\.versions.count) == [1, 1])
        #expect(automatic.workspace.items.map(\.versions.count) == [2])
    }

    @MainActor
    @Test
    func filenameFallbackGroupsUntaggedTracks() async {
        let directory = "/tmp/\(UUID().uuidString)"
        let urls = [
            URL(fileURLWithPath: "\(directory)/01 - Artist - Example Song (Remastered 2020).wav"),
            URL(fileURLWithPath: "\(directory)/Artist - Example Song.mp3")
        ]
        let coordinator = PlaylistCoordinator(
            loader: CoordinatorTestAudioLoader(
                tracks: Dictionary(uniqueKeysWithValues: urls.map { ($0, makeLoadedTrack(for: $0)) })
            )
        )

        let imported = await coordinator.importFiles(
            urls, destination: .playlist,
            automaticGroupingMode: .automatic
        )

        #expect(imported.count == 1)
        #expect(coordinator.workspace.items.map(\.versions.count) == [2])
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
        let existingVersion = makePlaylistVersion(url: existingURL, title: "Existing", artist: "Artist")
        let unrelatedVersion = makePlaylistVersion(url: unrelatedURL, title: "Unrelated", artist: "Artist")
        let target = PlaylistItem(title: "Existing", versions: [existingVersion])
        let unrelated = PlaylistItem(title: "Unrelated", versions: [unrelatedVersion])
        let tracks = [
            existingURL: makeLoadedTrack(for: existingURL, title: "Existing", artist: "Artist"),
            unrelatedURL: makeLoadedTrack(for: unrelatedURL, title: "Unrelated", artist: "Artist"),
            incomingURL: makeLoadedTrack(for: incomingURL, title: "Existing (Remastered)", artist: "Artist")
        ]
        let coordinator = PlaylistCoordinator(
            workspace: PlaylistWorkspace(items: [target, unrelated]),
            loader: CoordinatorTestAudioLoader(tracks: tracks)
        )
        defer { coordinator.pause() }

        let imported = await coordinator.importFiles(
            [incomingURL], destination: .playlist,
            automaticGroupingMode: .automatic
        )

        #expect(imported == [target.id])
        #expect(coordinator.workspace.items[0].versions.count == 2)
        #expect(coordinator.workspace.items[1].versions.count == 1)
        #expect(coordinator.mode == .playlist)
        #expect(coordinator.controller.runtimeTrackCount == 0)
    }

    @MainActor
    @Test(arguments: [false, true])
    func singleGroupedItemInAnEmptyPlaylistOpensComparison(alignOnOpen: Bool) async throws {
        let firstURL = try makeTemporaryAudioFile(name: "single-group-first.wav")
        let secondURL = try makeTemporaryAudioFile(name: "single-group-second.wav")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }
        let loader = CoordinatorTestAudioLoader(tracks: [
            firstURL: makeLoadedTrack(for: firstURL, title: "Single Group", artist: "Artist"),
            secondURL: makeLoadedTrack(for: secondURL, title: "Single Group (Stereo Mix)", artist: "Artist")
        ])
        let coordinator = PlaylistCoordinator(loader: loader)
        let settings = AppSettings(defaults: InMemoryAppSettingsDefaults())
        settings.alignTracksOnOpen = alignOnOpen
        coordinator.controller.settings = settings
        defer { coordinator.pause() }

        let imported = await coordinator.importFiles(
            [firstURL, secondURL], destination: .playlist,
            automaticGroupingMode: .automatic
        )

        let itemID = try #require(imported.first)
        #expect(imported.count == 1)
        #expect(coordinator.mode == .comparison(itemID: itemID))
        #expect(coordinator.controller.runtimeTrackCount == 2)
        #expect((coordinator.controller.isAligning || coordinator.controller.alignmentOutcome != nil) == alignOnOpen)
    }

    @MainActor
    @Test
    func hiddenPlaylistBlocksModeNavigationAndImportAutoEntry() async throws {
        let firstURL = try makeTemporaryAudioFile(name: "hidden-playlist-first.wav")
        let secondURL = try makeTemporaryAudioFile(name: "hidden-playlist-second.wav")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }
        let loader = CoordinatorTestAudioLoader(tracks: [
            firstURL: makeLoadedTrack(for: firstURL, title: "Single Group", artist: "Artist"),
            secondURL: makeLoadedTrack(for: secondURL, title: "Single Group (Stereo Mix)", artist: "Artist")
        ])
        let coordinator = PlaylistCoordinator(loader: loader)
        let settings = AppSettings(defaults: InMemoryAppSettingsDefaults())
        coordinator.controller.settings = settings
        settings.windowVisibility.toggle(.playlist)

        let imported = await coordinator.importFiles([firstURL, secondURL], destination: .playlist)
        let itemID = try #require(imported.first)
        #expect(coordinator.workspace.items.first?.versions.count == 2)
        #expect(coordinator.mode == .playlist)
        await coordinator.enterComparison(itemID: itemID)
        #expect(coordinator.mode == .playlist)

        settings.windowVisibility.toggle(.playlist)
        await coordinator.enterComparison(itemID: itemID)
        #expect(coordinator.mode == .comparison(itemID: itemID))

        settings.windowVisibility.toggle(.playlist)
        let context = coordinator.runtimeContext
        await coordinator.backToPlaylist()
        #expect(coordinator.mode == .comparison(itemID: itemID))
        #expect(coordinator.runtimeContext == context)

        settings.windowVisibility.toggle(.playlist)
        await coordinator.backToPlaylist()
        #expect(coordinator.mode == .playlist)
    }

    @MainActor
    @Test
    func comparingAGroupWithAMissingFileKeepsPlayback() async throws {
        let url = try makeTemporaryAudioFile(name: "playing.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let version = makePlaylistVersion(url: url, title: "Playing")
        let playing = PlaylistItem(title: "Playing", versions: [version])
        let missing = PlaylistItem(title: "Missing", versions: [makeVersion("missing.wav")])
        let coordinator = PlaylistCoordinator(workspace: PlaylistWorkspace(items: [missing, playing]))
        await coordinator.playItem(id: playing.id)
        try #require(coordinator.isPlaying)
        defer { coordinator.pause() }

        let group = coordinator.groupItems([missing.id, playing.id])
        #expect(group == missing.id)
        try await waitFor { coordinator.runtimeContext?.itemID == missing.id }
        await coordinator.enterComparison(itemID: missing.id)
        // Compare opens; the missing version is a silent lane, and the
        // playing version stays audible.
        #expect(coordinator.mode == .comparison(itemID: missing.id))
        #expect(coordinator.runtimeContext?.itemID == missing.id)
        #expect(coordinator.controller.session.activeTrackID == version.id)
        #expect(coordinator.controller.session.tracks.map(\.loadedTrack.isMissing) == [true, false])
        #expect(coordinator.controller.runtimeTrackCount == 1)
        #expect(coordinator.isPlaying)
        #expect(coordinator.errorMessage == nil)
    }

    @MainActor
    @Test
    func cancellingDuringMetadataLoadingPreventsTheAtomicCommit() async {
        let urls = ["cancel-a.wav", "cancel-b.wav"].map {
            URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-\($0)")
        }
        let gate = CoordinatorLoadGate()
        let coordinator = PlaylistCoordinator(
            loader: CoordinatorTestAudioLoader(
                tracks: Dictionary(uniqueKeysWithValues: urls.map { ($0, makeLoadedTrack(for: $0)) }),
                gate: gate
            )
        )
        let task = Task { @MainActor in
            await coordinator.importFiles(
                urls, destination: .playlist,
                automaticGroupingMode: .automatic
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
    func playlistImportJoiningActiveComparisonRefreshesItsRuntime() async throws {
        let firstURL = try makeTemporaryAudioFile(name: "active-first.wav")
        let secondURL = try makeTemporaryAudioFile(name: "active-second.wav")
        let incomingURL = try makeTemporaryAudioFile(name: "active-incoming.wav")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: incomingURL.deletingLastPathComponent())
        }
        let first = makePlaylistVersion(url: firstURL, title: "Active", artist: "Artist")
        let second = makePlaylistVersion(url: secondURL, title: "Active", artist: "Artist")
        let item = PlaylistItem(title: "Active", versions: [first, second])
        let tracks = [
            firstURL: makeLoadedTrack(for: firstURL, title: "Active", artist: "Artist"),
            secondURL: makeLoadedTrack(for: secondURL, title: "Active (Remastered)", artist: "Artist"),
            incomingURL: makeLoadedTrack(for: incomingURL, title: "Active (Stereo Mix)", artist: "Artist")
        ]
        let loader = CoordinatorTestAudioLoader(tracks: tracks)
        let coordinator = PlaylistCoordinator(
            workspace: PlaylistWorkspace(items: [item]),
            controller: PlaybackController(loader: loader),
            loader: loader
        )
        defer { coordinator.pause() }
        await coordinator.enterComparison(itemID: item.id)
        #expect(coordinator.controller.runtimeTrackCount == 2)

        await coordinator.importFiles(
            [incomingURL], destination: .playlist,
            automaticGroupingMode: .automatic
        )
        for _ in 0..<100 {
            if coordinator.controller.runtimeTrackCount == 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(coordinator.mode == .comparison(itemID: item.id))
        #expect(coordinator.workspace.items[0].versions.count == 3)
        #expect(coordinator.controller.runtimeTrackCount == 3)
    }

    /// A2 §9: entering compare never starts an item. Another item's playback
    /// stops; the item already playing keeps playing.
    @MainActor
    @Test
    func enteringComparisonStartsNoOtherItemButKeepsTheSameItemPlaying() async throws {
        let urls = try ["playing.wav", "compare-a.wav", "compare-b.wav"].map { try makeTemporaryAudioFile(name: $0) }
        defer { for url in urls { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
        let playingItem = PlaylistItem(title: "Playing", versions: [makePlaylistVersion(url: urls[0], title: "Playing")])
        let compareItem = PlaylistItem(
            title: "Compare",
            versions: [makePlaylistVersion(url: urls[1], title: "Compare"), makePlaylistVersion(url: urls[2], title: "Compare")]
        )
        let loader = CoordinatorTestAudioLoader(tracks: Dictionary(uniqueKeysWithValues: urls.map { ($0, makeLoadedTrack(for: $0)) }))
        let coordinator = PlaylistCoordinator(
            workspace: PlaylistWorkspace(items: [playingItem, compareItem]),
            controller: PlaybackController(loader: loader),
            loader: loader
        )
        defer { coordinator.pause() }

        await coordinator.playItem(id: playingItem.id)
        #expect(coordinator.isPlaying)
        await coordinator.enterComparison(itemID: compareItem.id)
        #expect(coordinator.mode == .comparison(itemID: compareItem.id))
        #expect(!coordinator.isPlaying)

        await coordinator.backToPlaylist()
        await coordinator.playItem(id: compareItem.id)
        #expect(coordinator.isPlaying)
        await coordinator.enterComparison(itemID: compareItem.id)
        #expect(coordinator.mode == .comparison(itemID: compareItem.id))
        #expect(coordinator.isPlaying)
    }

    @MainActor
    @Test func missingComparisonFileRestoresCompareWithAnErrorLane() async throws {
        let version = makeVersion("unavailable.wav")
        let item = PlaylistItem(title: "Unavailable", versions: [version])
        let saved = PlaylistWorkspace(items: [item], activeView: .comparison(itemID: item.id),
                                      listeningState: .init(itemID: item.id, versionID: version.id, filePosition: 1))
        let coordinator = PlaylistCoordinator()
        try await coordinator.restoreWorkspace(saved)
        #expect(coordinator.mode == .comparison(itemID: item.id))
        #expect(coordinator.controller.session.tracks.map(\.loadedTrack.isMissing) == [true])
        #expect(coordinator.controller.runtimeTrackCount == 0)
        // Nothing to play until the file is located.
        #expect(!coordinator.canPlay)
        #expect(!coordinator.controller.session.isPlayable)
        #expect(coordinator.errorMessage == nil)
    }

    @MainActor
    @Test func resetAllComparisonOffsetsPersistsOnlyTheCurrentItemsOffsets() async throws {
        let url = try makeTemporaryAudioFile(name: "offset-reset.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var available = makePlaylistVersion(url: url, title: "Available")
        available.offsetSeconds = -0.25
        var missing = makeVersion("missing.wav")
        missing.offsetSeconds = 0.5
        var unrelated = makeVersion("unrelated.wav")
        unrelated.offsetSeconds = 0.75
        let item = PlaylistItem(title: "Compare", versions: [available, missing])
        let otherItem = PlaylistItem(title: "Other", versions: [unrelated])
        let coordinator = PlaylistCoordinator(workspace: PlaylistWorkspace(items: [item, otherItem]))
        await coordinator.enterComparison(itemID: item.id)
        let runtime = coordinator.runtimeContext
        #expect(coordinator.controller.session.tracks.map(\.loadedTrack.offsetSeconds) == [-0.25, 0.5])

        coordinator.resetAllComparisonOffsets()

        #expect(coordinator.controller.session.tracks.map(\.loadedTrack.offsetSeconds) == [0, 0])
        #expect(coordinator.controller.session.activeTrackID == available.id)
        #expect(coordinator.runtimeContext == runtime)
        #expect(coordinator.workspace.items[0].versions.map(\.offsetSeconds) == [0, 0])
        #expect(coordinator.workspace.items[1].versions.map(\.offsetSeconds) == [0.75])
    }

    @MainActor
    @Test func backLeavesComparisonWhenItsFileDisappears() async throws {
        let url = try makeTemporaryAudioFile(name: "back.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let version = makePlaylistVersion(url: url, title: "Back")
        let item = PlaylistItem(title: "Back", versions: [version])
        let coordinator = PlaylistCoordinator(workspace: PlaylistWorkspace(items: [item]))
        await coordinator.enterComparison(itemID: item.id)
        coordinator.seek(to: 1)
        try FileManager.default.removeItem(at: url)
        await coordinator.backToPlaylist()
        #expect(coordinator.workspace.activeView == .playlist)
        #expect(coordinator.mode == .playlist)
        #expect(coordinator.runtimeContext == nil)
        #expect(coordinator.workspace.listeningState?.filePosition == 1)
        #expect(coordinator.errorMessage == nil)
        #expect(coordinator.fileIssues[version.id]?.error == .failedToOpenFile(version.file.storedURL))
    }

    @MainActor
    @Test func removalWithMissingSuccessorDetachesPlayingFile() async throws {
        let url = try makeTemporaryAudioFile(name: "remove.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = PlaylistItem(title: "Remove", versions: [makePlaylistVersion(url: url, title: "Remove")])
        let successor = PlaylistItem(title: "Missing", versions: [makeVersion("missing.wav")])
        let coordinator = PlaylistCoordinator(workspace: PlaylistWorkspace(items: [item, successor]))
        await coordinator.playItem(id: item.id)
        #expect(coordinator.isPlaying)
        #expect(coordinator.removeItem(item.id))
        #expect(!coordinator.isPlaying)
        let version = successor.versions[0]
        try await waitFor { coordinator.fileIssues[version.id] != nil }
        #expect(coordinator.errorMessage == nil)
        #expect(coordinator.fileIssues[version.id]?.error == .failedToOpenFile(version.file.storedURL))
        #expect(coordinator.currentItemID == successor.id)
        #expect(coordinator.runtimeContext == nil)
        #expect(coordinator.controller.runtimeTrackCount == 0)
    }

    @MainActor
    @Test func reorderUsesLiveKeyboardOffsetForAudibleFileTime() async throws {
        let first = try makeTemporaryAudioFile(name: "first.wav")
        let second = try makeTemporaryAudioFile(name: "second.wav")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        let versions = [makePlaylistVersion(url: first, title: "A"), makePlaylistVersion(url: second, title: "B")]
        let item = PlaylistItem(title: "Pair", versions: versions)
        let coordinator = PlaylistCoordinator(workspace: PlaylistWorkspace(items: [item]))
        await coordinator.enterComparison(itemID: item.id)
        coordinator.seek(to: 1)
        coordinator.controller.nudgeActiveTrackOffset(direction: 1, largeStep: true)
        let expected = coordinator.snapshotForPersistence().listeningState?.filePosition
        let context = coordinator.runtimeContext
        #expect(coordinator.reorderVersion(versions[1].id, before: versions[0].id))
        for _ in 0..<100 where coordinator.runtimeContext == context { await Task.yield() }
        #expect(coordinator.runtimeContext != context)
        #expect(coordinator.snapshotForPersistence().listeningState?.filePosition == expected)
    }

    @MainActor
    @Test func organizationUndoPreservesLaterNavigationPositionAndLocate() async throws {
        let first = try makeTemporaryAudioFile(name: "repaired.wav")
        let second = try makeTemporaryAudioFile(name: "playing.wav")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        let missing = makeVersion("missing.wav")
        let original = PlaylistItem(title: "Original", versions: [missing])
        let playing = PlaylistItem(title: "Playing", versions: [makePlaylistVersion(url: second, title: "B")])
        let loader = CoordinatorTestAudioLoader(tracks: [first: makeLoadedTrack(for: first)])
        let coordinator = PlaylistCoordinator(workspace: PlaylistWorkspace(items: [original, playing]), loader: loader)
        defer { coordinator.pause() }
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        #expect(coordinator.renameItem(original.id, to: "Changed", undoManager: undo))
        undo.endUndoGrouping()
        await coordinator.locateFile(versionID: missing.id, url: first)
        await coordinator.enterComparison(itemID: playing.id)
        coordinator.seek(to: 1)
        coordinator.play()
        let context = coordinator.runtimeContext
        undo.undo()
        #expect(coordinator.workspace.items.first?.title == "Original")
        #expect(coordinator.workspace.items.first?.versions.first?.file.storedURL == first)
        #expect(coordinator.mode == .comparison(itemID: playing.id))
        #expect(coordinator.currentVersionID == playing.keyVersion?.id)
        #expect(coordinator.runtimeContext == context)
        #expect(coordinator.isPlaying)
        #expect(coordinator.controller.displayTransportPosition() >= 1)
    }

    @MainActor
    @Test func groupUndoFollowsAuditionedVersionBackToItsOwner() async throws {
        let first = try makeTemporaryAudioFile(name: "one.wav")
        let second = try makeTemporaryAudioFile(name: "two.wav")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        let original = PlaylistItem(title: "One", versions: [makePlaylistVersion(url: first, title: "A")])
        let moved = makePlaylistVersion(url: second, title: "B")
        let other = PlaylistItem(title: "Two", versions: [moved])
        let coordinator = PlaylistCoordinator(workspace: PlaylistWorkspace(items: [original, other]))
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let grouped = coordinator.groupItems([original.id, other.id], undoManager: undo)
        let group = try #require(grouped)
        undo.endUndoGrouping()
        await coordinator.enterComparison(itemID: group)
        coordinator.controller.selectActiveTrack(moved.id)
        coordinator.seek(to: 1)
        undo.undo()
        for _ in 0..<100 where coordinator.runtimeContext?.itemID != other.id { await Task.yield() }
        #expect(coordinator.mode == .comparison(itemID: other.id))
        #expect(coordinator.runtimeContext?.itemID == other.id)
        #expect(coordinator.controller.session.activeTrackID == moved.id)
        #expect(coordinator.controller.session.transportPosition == 1)
        undo.redo()
        for _ in 0..<100 where coordinator.runtimeContext?.itemID != group { await Task.yield() }
        #expect(coordinator.mode == .comparison(itemID: group))
        #expect(coordinator.runtimeContext?.itemID == group)
        #expect(coordinator.controller.session.activeTrackID == moved.id)
        #expect(coordinator.controller.session.transportPosition == 1)
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

    @MainActor
    @Test
    func previousAndNextTrackBehaveLikeAMediaPlayer() async throws {
        let urls = try ["a.wav", "b.wav"].map { try makeTemporaryAudioFile(name: $0, duration: 6) }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }
        let items = urls.enumerated().map { index, url in
            PlaylistItem(title: "\(index)", versions: [makePlaylistVersion(url: url, title: "\(index)", duration: 6)])
        }
        let coordinator = PlaylistCoordinator(workspace: PlaylistWorkspace(items: items))
        await coordinator.playItem(id: items[1].id)
        coordinator.pause()
        #expect(coordinator.canPrevious && coordinator.canNext)

        // Past the first few seconds, Previous restarts the track.
        coordinator.seek(to: 4)
        coordinator.previous()
        #expect(coordinator.currentItemID == items[1].id)
        #expect(coordinator.controller.displayTransportPosition() == 0)

        // At its start, Previous goes to the track above, in list order.
        coordinator.previous()
        try await waitFor { coordinator.currentItemID == items[0].id && coordinator.runtimeContext?.itemID == items[0].id }

        // At the first track, Previous restarts it.
        coordinator.seek(to: 1)
        coordinator.previous()
        #expect(coordinator.currentItemID == items[0].id)
        #expect(coordinator.controller.displayTransportPosition() == 0)

        // Next past the last track (Repeat off) returns to the first, paused.
        coordinator.next()
        try await waitFor { coordinator.currentItemID == items[1].id && coordinator.runtimeContext?.itemID == items[1].id }
        await coordinator.playItem(id: items[1].id)
        coordinator.next()
        try await waitFor { coordinator.currentItemID == items[0].id && coordinator.runtimeContext?.itemID == items[0].id }
        #expect(!coordinator.isPlaying)
    }

    @MainActor
    @Test func manualTrackNavigationSkipsMissingAndDamagedFilesInBothDirections() async throws {
        let urls = try ["first.wav", "damaged.wav", "last.wav"].map { try makeTemporaryAudioFile(name: $0, duration: 6) }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }
        try Data("not audio".utf8).write(to: urls[1])
        let first = PlaylistItem(title: "First", versions: [makePlaylistVersion(url: urls[0], title: "First", duration: 6)])
        let missing = PlaylistItem(title: "Missing", versions: [makeVersion("skip-missing.wav")])
        let damaged = makePlaylistVersion(url: urls[1], title: "Damaged", duration: 6)
        let last = PlaylistItem(title: "Last", versions: [makePlaylistVersion(url: urls[2], title: "Last", duration: 6)])
        let tail = PlaylistItem(title: "Tail", versions: [makeVersion("skip-tail.wav")])
        let coordinator = PlaylistCoordinator(workspace: PlaylistWorkspace(items: [
            first, missing, PlaylistItem(title: "Damaged", versions: [damaged]), last, tail
        ]))
        defer { coordinator.pause() }

        await coordinator.playItem(id: first.id)
        coordinator.next()
        try await waitFor { coordinator.currentItemID == last.id }
        #expect(coordinator.isPlaying)
        #expect(coordinator.fileIssues[missing.versions[0].id] != nil)
        #expect(coordinator.fileIssues[damaged.id]?.error.fileURL?.lastPathComponent == "damaged.wav")

        await coordinator.playItem(id: last.id, fromBeginning: true)
        coordinator.pause()
        coordinator.previous()
        try await waitFor { coordinator.currentItemID == first.id }
        #expect(!coordinator.isPlaying)

        await coordinator.playItem(id: last.id)
        coordinator.next()
        try await waitFor { coordinator.currentItemID == first.id }
        #expect(!coordinator.isPlaying)
        #expect(coordinator.fileIssues[tail.versions[0].id] != nil)
        #expect(coordinator.errorMessage == nil)
    }

    @MainActor
    @Test func repeatAllExhaustsAnUnavailablePlaylistSilently() async throws {
        let versions = [makeVersion("unavailable-a.wav"), makeVersion("unavailable-b.wav")]
        let coordinator = PlaylistCoordinator(workspace: PlaylistWorkspace(
            items: versions.map { PlaylistItem(title: "Unavailable", versions: [$0]) },
            playlistRepeatMode: .all
        ))
        coordinator.next()
        try await waitFor { coordinator.fileIssues.count == versions.count }
        #expect(coordinator.currentItemID == nil)
        #expect(!coordinator.isPlaying)
        #expect(coordinator.errorMessage == nil)
    }

    // MARK: Culling

    @MainActor
    private func makeCullingPlaylist(
        _ names: [String], rejected: Set<Int>, duration: TimeInterval = 6,
        repeatMode: PlaylistRepeatMode = .off
    ) throws -> (PlaylistCoordinator, [PlaylistItem], [URL]) {
        let urls = try names.map { try makeTemporaryAudioFile(name: "cull-\($0).wav", duration: duration) }
        let items = names.enumerated().map { index, name in
            PlaylistItem(
                title: name, versions: [makePlaylistVersion(url: urls[index], title: name, duration: duration)],
                isRejected: rejected.contains(index)
            )
        }
        let coordinator = PlaylistCoordinator(workspace: PlaylistWorkspace(items: items, playlistRepeatMode: repeatMode))
        return (coordinator, items, urls)
    }

    @MainActor
    @Test func nextAndPreviousSkipRejectedTracksAndKeepThemOutOfHistory() async throws {
        let (coordinator, items, urls) = try makeCullingPlaylist(["a", "b", "c", "d"], rejected: [1, 3])
        defer {
            coordinator.pause()
            urls.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) }
        }
        await coordinator.playItem(id: items[0].id)

        coordinator.next()
        try await waitFor { coordinator.currentItemID == items[2].id && coordinator.runtimeContext?.itemID == items[2].id }
        #expect(coordinator.isPlaying)
        #expect(!coordinator.listeningHistory.contains(items[1].id))

        // Previous (within the restart threshold) walks back past B.
        coordinator.previous()
        try await waitFor { coordinator.currentItemID == items[0].id && coordinator.runtimeContext?.itemID == items[0].id }
        #expect(!coordinator.listeningHistory.contains(items[1].id))

        // Next past the last track returns to the first track that isn't
        // rejected, paused; the rejected last track is passed over.
        coordinator.next()
        try await waitFor { coordinator.currentItemID == items[2].id && coordinator.runtimeContext?.itemID == items[2].id }
        coordinator.next()
        try await waitFor { coordinator.currentItemID == items[0].id && coordinator.runtimeContext?.itemID == items[0].id }
        #expect(!coordinator.isPlaying)
        #expect(!coordinator.listeningHistory.contains(items[3].id))
    }

    @MainActor
    @Test func previousInListOrderSkipsRejectedTracks() async throws {
        let (coordinator, items, urls) = try makeCullingPlaylist(["a", "b", "c"], rejected: [1])
        defer {
            coordinator.pause()
            urls.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) }
        }
        // Start on C with no history, so Previous goes by list order.
        await coordinator.playItem(id: items[2].id)
        coordinator.previous()
        try await waitFor { coordinator.currentItemID == items[0].id && coordinator.runtimeContext?.itemID == items[0].id }
        #expect(coordinator.listeningHistory == [items[0].id])
    }

    @MainActor
    @Test func repeatAllWrapsPastRejectedTracks() async throws {
        let (coordinator, items, urls) = try makeCullingPlaylist(["a", "b", "c", "d"], rejected: [0, 3], repeatMode: .all)
        defer {
            coordinator.pause()
            urls.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) }
        }
        await coordinator.playItem(id: items[2].id)
        coordinator.next()
        try await waitFor { coordinator.currentItemID == items[1].id && coordinator.runtimeContext?.itemID == items[1].id }
        #expect(coordinator.isPlaying)
        #expect(!coordinator.listeningHistory.contains(items[3].id))
        #expect(!coordinator.listeningHistory.contains(items[0].id))
    }

    @MainActor
    @Test func shuffleNeverLandsOnARejectedTrack() async throws {
        let (coordinator, items, urls) = try makeCullingPlaylist(["a", "b", "c", "d", "e"], rejected: [1, 3], repeatMode: .all)
        defer {
            coordinator.pause()
            urls.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) }
        }
        coordinator.setShuffleEnabled(true)
        await coordinator.playItem(id: items[0].id)
        let rejected: Set<UUID> = [items[1].id, items[3].id]
        for _ in 0..<6 {
            let context = coordinator.runtimeContext
            coordinator.next()
            try await waitFor { coordinator.runtimeContext != context && coordinator.runtimeContext?.itemID == coordinator.currentItemID }
            #expect(coordinator.currentItemID != nil)
            #expect(!rejected.contains(coordinator.currentItemID ?? UUID()))
        }
        #expect(coordinator.listeningHistory.allSatisfy { !rejected.contains($0) })
    }

    @MainActor
    @Test func naturalAdvanceSkipsRejectedTracksAndEndsWhenOnlyRejectedRemain() async throws {
        let short = try makeTemporaryAudioFile(name: "cull-short.wav", duration: 0.05)
        let urls = try ["rejected.wav", "kept.wav", "tail.wav"].map { try makeTemporaryAudioFile(name: "cull-\($0)", duration: 2) }
        defer { ([short] + urls).forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }
        let first = PlaylistItem(title: "Short", versions: [makePlaylistVersion(url: short, title: "Short", duration: 0.05)])
        let rejected = PlaylistItem(
            title: "Rejected", versions: [makePlaylistVersion(url: urls[0], title: "Rejected")], isRejected: true
        )
        let kept = PlaylistItem(title: "Kept", versions: [makePlaylistVersion(url: urls[1], title: "Kept")])
        let coordinator = PlaylistCoordinator(workspace: PlaylistWorkspace(items: [first, rejected, kept]))
        defer { coordinator.pause() }

        await coordinator.playItem(id: first.id)
        try await waitFor { coordinator.currentItemID == kept.id }
        #expect(coordinator.isPlaying)
        #expect(!coordinator.listeningHistory.contains(rejected.id))

        // Every remaining track rejected: playback ends at the last one heard.
        let tail = PlaylistItem(
            title: "Tail", versions: [makePlaylistVersion(url: urls[2], title: "Tail")], isRejected: true
        )
        let ending = PlaylistCoordinator(workspace: PlaylistWorkspace(items: [first, tail]))
        defer { ending.pause() }
        await ending.playItem(id: first.id)
        try await waitFor { !ending.isPlaying }
        try await Task.sleep(for: .milliseconds(100))
        #expect(ending.currentItemID == first.id)
        #expect(!ending.isPlaying)
    }

    @MainActor
    @Test func explicitPlayIgnoresTheFlagAndNavigationContinuesFromThere() async throws {
        let (coordinator, items, urls) = try makeCullingPlaylist(["a", "b", "c"], rejected: [1])
        defer {
            coordinator.pause()
            urls.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) }
        }
        await coordinator.playItem(id: items[1].id)
        #expect(coordinator.currentItemID == items[1].id)
        #expect(coordinator.isPlaying)

        coordinator.next()
        try await waitFor { coordinator.currentItemID == items[2].id && coordinator.runtimeContext?.itemID == items[2].id }

        // A rejected version row plays from the beginning too.
        let urlsB = try ["v1.wav", "v2.wav"].map { try makeTemporaryAudioFile(name: "cull-\($0)") }
        defer { urlsB.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }
        var rejectedVersion = makePlaylistVersion(url: urlsB[0], title: "Rejected take")
        rejectedVersion.isRejected = true
        let item = PlaylistItem(title: "Takes", versions: [rejectedVersion, makePlaylistVersion(url: urlsB[1], title: "Key")])
        let versions = PlaylistCoordinator(workspace: PlaylistWorkspace(items: [item]))
        defer { versions.pause() }
        await versions.playItem(id: item.id)
        #expect(versions.currentVersionID == item.versions[1].id)
        await versions.playItem(id: item.id, versionID: rejectedVersion.id, fromBeginning: true)
        #expect(versions.currentVersionID == rejectedVersion.id)
        #expect(versions.isPlaying)
    }

    @MainActor
    @Test func playWithNoCurrentTrackStartsTheFirstTrackThatIsNotRejected() async throws {
        let (coordinator, items, urls) = try makeCullingPlaylist(["a", "b"], rejected: [0])
        defer {
            coordinator.pause()
            urls.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) }
        }
        #expect(coordinator.currentItemID == nil)
        #expect(coordinator.canPlay)
        coordinator.play()
        try await waitFor { coordinator.currentItemID == items[1].id && coordinator.isPlaying }

        let (allRejected, _, moreURLs) = try makeCullingPlaylist(["c"], rejected: [0])
        defer { moreURLs.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }
        #expect(!allRejected.canPlay)
    }

    @MainActor
    @Test func rejectingTheCurrentTrackOrVersionKeepsItPlaying() async throws {
        let (coordinator, items, urls) = try makeCullingPlaylist(["a", "b"], rejected: [])
        defer {
            coordinator.pause()
            urls.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) }
        }
        await coordinator.playItem(id: items[0].id)
        let context = coordinator.runtimeContext
        let presentation = PlaylistPresentationState()
        presentation.selection = [.item(items[0].id)]
        let command = PlaylistCommandContext(coordinator: coordinator, presentation: presentation, undoManager: nil)
        #expect(!command.rejectionClears)
        command.toggleRejection()

        #expect(coordinator.workspace.items[0].isRejected)
        #expect(presentation.selection == [.item(items[0].id)])
        try await Task.sleep(for: .milliseconds(50))
        #expect(coordinator.isPlaying)
        #expect(coordinator.runtimeContext == context)
        #expect(coordinator.currentItemID == items[0].id)
        #expect(command.rejectionClears)

        // The version flag doesn't interrupt the current version either.
        #expect(coordinator.toggleRejection(versionIDs: [items[0].versions[0].id], undoManager: nil))
        try await Task.sleep(for: .milliseconds(50))
        #expect(coordinator.runtimeContext == context)
        #expect(coordinator.isPlaying)

        // Previous within the restart threshold still restarts it.
        coordinator.seek(to: 1)
        coordinator.previous()
        #expect(coordinator.currentItemID == items[0].id)
        #expect(coordinator.controller.displayTransportPosition() < 1)
    }

    @MainActor
    @Test func rejectTargetsFollowTheSelectionAndAMixedSetRejectsAll() {
        let a = PlaylistItem(title: "A", versions: ["a1", "a2"].map { makeVersion("\($0).wav") })
        let b = PlaylistItem(title: "B", versions: [makeVersion("b.wav")], isRejected: true)
        let coordinator = PlaylistCoordinator(workspace: PlaylistWorkspace(items: [a, b]))
        let presentation = PlaylistPresentationState()
        let context = PlaylistCommandContext(coordinator: coordinator, presentation: presentation, undoManager: nil)
        #expect(!PlaylistOrganizationAvailability(context).canReject)

        // A selected item row targets the track only, not its versions.
        presentation.selection = [.item(a.id), .item(b.id)]
        #expect(PlaylistOrganizationAvailability(context).canReject)
        #expect(PlaylistOrganizationAvailability(context).rejectionTitle == "Reject")
        context.toggleRejection()
        #expect(coordinator.workspace.items.map(\.isRejected) == [true, true])
        #expect(coordinator.workspace.allVersions.allSatisfy { !$0.isRejected })
        #expect(PlaylistOrganizationAvailability(context).rejectionTitle == "Clear Rejection")
        context.toggleRejection()
        #expect(coordinator.workspace.items.map(\.isRejected) == [false, false])

        // Selected version rows target those versions.
        presentation.selection = [.version(a.versions[1].id)]
        context.toggleRejection()
        #expect(coordinator.workspace.items[0].versions.map(\.isRejected) == [false, true])
        #expect(!coordinator.workspace.items[0].isRejected)

        // A context menu opened on an unselected row targets that row alone.
        let clicked = PlaylistCommandContext(
            coordinator: coordinator, presentation: presentation, undoManager: nil, rows: [.item(b.id)]
        )
        clicked.toggleRejection()
        #expect(coordinator.workspace.items[1].isRejected)
        #expect(coordinator.workspace.items[0].versions.map(\.isRejected) == [false, true])
    }

    @MainActor
    @Test func rejectUndoesAndRedoesAsOneEdit() {
        let a = PlaylistItem(title: "A", versions: ["a1", "a2"].map { makeVersion("\($0).wav") })
        let coordinator = PlaylistCoordinator(workspace: PlaylistWorkspace(items: [a]))
        let undo = UndoManager()
        undo.groupsByEvent = false

        undo.beginUndoGrouping()
        #expect(coordinator.toggleRejection(itemIDs: [a.id], versionIDs: [a.versions[0].id], undoManager: undo))
        undo.endUndoGrouping()
        #expect(undo.undoActionName == "Reject")
        #expect(coordinator.workspace.items[0].isRejected)
        #expect(coordinator.workspace.items[0].keyVersion?.id == a.versions[1].id)

        undo.undo()
        #expect(!coordinator.workspace.items[0].isRejected)
        #expect(coordinator.workspace.allVersions.allSatisfy { !$0.isRejected })
        #expect(coordinator.workspace.items[0].keyVersion?.id == a.versions[0].id)
        undo.redo()
        #expect(coordinator.workspace.items[0].isRejected)
        #expect(coordinator.workspace.items[0].versions[0].isRejected)

        undo.beginUndoGrouping()
        coordinator.toggleRejection(itemIDs: [a.id], versionIDs: [a.versions[0].id], undoManager: undo)
        undo.endUndoGrouping()
        #expect(undo.undoActionName == "Clear Rejection")
        #expect(!coordinator.workspace.items[0].isRejected)

        // Undo rebases by stable ID: a reorder made since keeps its order.
        undo.undo()
        #expect(coordinator.workspace.items[0].isRejected)
        #expect(coordinator.reorderVersion(a.versions[1].id, before: a.versions[0].id))
        #expect(coordinator.workspace.items[0].versions.map(\.isRejected) == [false, true])
    }

    @MainActor
    @Test func compareSwitchingSkipsRejectedLanesAndRejectingKeepsTheActiveLane() async throws {
        let urls = try ["lane-a.wav", "lane-b.wav", "lane-c.wav"].map { try makeTemporaryAudioFile(name: $0) }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }
        let versions = urls.map { makePlaylistVersion(url: $0, title: $0.lastPathComponent) }
        let ids = versions.map(\.id)
        let item = PlaylistItem(title: "Takes", versions: versions)
        let coordinator = PlaylistCoordinator(workspace: PlaylistWorkspace(items: [item]))
        let controller = coordinator.controller
        let undo = UndoManager()
        undo.groupsByEvent = false
        await coordinator.enterComparison(itemID: item.id)
        let context = coordinator.runtimeContext
        #expect(controller.session.activeTrackID == ids[0])

        // The lane menu targets the right-clicked lane.
        undo.beginUndoGrouping()
        #expect(coordinator.toggleRejection(versionIDs: [ids[1]], undoManager: undo))
        undo.endUndoGrouping()
        #expect(controller.session.tracks.map(\.loadedTrack.isRejected) == [false, true, false])
        #expect(coordinator.runtimeContext == context)

        coordinator.next()
        #expect(controller.session.activeTrackID == ids[2])
        coordinator.next()
        #expect(controller.session.activeTrackID == ids[0])
        coordinator.previous()
        #expect(controller.session.activeTrackID == ids[2])
        // A number hotkey names a lane by position, rejected or not.
        controller.selectTrackForHotkey(2)
        #expect(controller.session.activeTrackID == ids[1])

        // The Playlist menu's command targets the active lane, which stays
        // active and audible.
        controller.selectActiveTrack(ids[0])
        let presentation = PlaylistPresentationState()
        presentation.selection = [.item(item.id)]
        let command = PlaylistCommandContext(coordinator: coordinator, presentation: presentation, undoManager: undo)
        #expect(!command.canToggleRejection)
        #expect(PlaylistOrganizationAvailability(command).canReject)
        command.toggleRejection()
        #expect(coordinator.workspace.items[0].versions.map(\.isRejected) == [false, true, false])
        undo.beginUndoGrouping()
        if let active = coordinator.activeComparisonVersionID {
            #expect(coordinator.toggleRejection(versionIDs: [active], undoManager: undo))
        }
        undo.endUndoGrouping()
        #expect(controller.session.activeTrackID == ids[0])
        #expect(coordinator.runtimeContext == context)
        #expect(coordinator.workspace.items[0].versions.map(\.isRejected) == [true, true, false])
        // From a rejected active lane, Switch Track goes to the next
        // non-rejected lane; with none left to switch to, it is disabled.
        coordinator.next()
        #expect(controller.session.activeTrackID == ids[2])
        #expect(!controller.session.canSwitchPlayback)
        #expect(!coordinator.canNext)

        // Undo clears the flag on the lane in place.
        undo.undo()
        #expect(controller.session.tracks.map(\.loadedTrack.isRejected) == [false, true, false])
        #expect(coordinator.runtimeContext == context)
        #expect(controller.session.canSwitchPlayback)

        // Blind Listening switches in its shuffled, displayed order.
        controller.setBlindListeningMode(true) { Array($0.reversed()) }
        let displayed = controller.session.tracks.map(\.id)
        controller.selectActiveTrack(displayed[0])
        let expected = displayed.dropFirst().first { $0 != ids[1] }
        controller.selectNextTrack()
        #expect(controller.session.activeTrackID == expected)
        #expect(controller.session.activeTrackID != ids[1])

        // Leaving compare: the playlist shows the lane's rejection.
        await coordinator.backToPlaylist()
        #expect(coordinator.workspace.items[0].versions.map(\.isRejected) == [false, true, false])
    }

    @MainActor
    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for the condition")
    }

    private func makePlaylistVersion(url: URL, title: String, artist: String? = nil, duration: TimeInterval = 2) -> PlaylistVersion {
        PlaylistVersion(
            file: PlaylistWorkspaceStore.makeFileReference(for: url),
            metadata: PlaylistMetadata(
                title: title,
                artist: artist,
                duration: duration,
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
        artist: String? = nil,
        duration: TimeInterval = 2
    ) -> LoadedTrack {
        LoadedTrack(
            url: url,
            displayName: url.lastPathComponent,
            fileFormatDescription: "WAV",
            duration: duration,
            sampleRate: 44_100,
            channelCount: 1,
            title: title,
            artist: artist
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

private enum CoordinatorTestError: Error {
    case audioFormat
}
