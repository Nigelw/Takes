import Foundation
import Testing
@testable import Takes

struct PlaylistWorkspaceTests {
    @Test
    func workspaceValuesRoundTripThroughCodable() throws {
        let itemID = UUID()
        let versionID = UUID()
        let version = makeVersion(
            "master.wav",
            id: versionID,
            title: "Song",
            artist: "Artist",
            album: "Album",
            duration: 123.5,
            sampleRate: 48_000,
            channelCount: 2,
            bitRate: 256_000,
            fileFormatDescription: "Linear PCM",
            gainDB: -1.5,
            offsetSeconds: 2.25
        )
        let comparison = PlaylistComparisonConfiguration(
            repeatMode: .one,
            loopRegion: LoopRegion(start: 3, end: 8),
            isBlindListeningModeEnabled: true,
            visibleStart: -2,
            visibleSpan: 18
        )
        let item = PlaylistItem(
            id: itemID,
            title: "Song",
            versions: [version],
            selectedVersionID: versionID,
            comparison: comparison
        )
        let workspace = PlaylistWorkspace(
            items: [item],
            activeView: .comparison(itemID: itemID),
            listeningState: PlaylistListeningState(
                itemID: itemID,
                versionID: versionID,
                filePosition: 42.5
            ),
            playlistRepeatMode: .all,
            isShuffleEnabled: true
        )

        try workspace.validate()
        let data = try JSONEncoder().encode(workspace)
        let decoded = try JSONDecoder().decode(PlaylistWorkspace.self, from: data)

        #expect(decoded == workspace)
        #expect(decoded.items[0].versions[0].id == versionID)
        #expect(decoded.listeningState?.filePosition == 42.5)
        #expect(decoded.playlistRepeatMode == .all)
        #expect(decoded.isShuffleEnabled)
    }

    @Test
    func appendSeparateItemsPreservesOrderAndUsesMetadataTitle() throws {
        var workspace = PlaylistWorkspace()
        let first = makeVersion("first.wav", title: "First")
        let second = makeVersion("second.wav", title: nil)

        let itemIDs = try workspace.appendSeparateItems([first, second])

        #expect(itemIDs == workspace.items.map(\.id))
        #expect(workspace.items.map(\.title) == ["First", "second.wav"])
        #expect(workspace.items.flatMap(\.versions).map(\.id) == [first.id, second.id])
        try workspace.validate()
    }

    @Test
    func appendSeparateItemsHasNoWorkspaceItemLimit() throws {
        var workspace = PlaylistWorkspace()
        let versions = (0..<100).map { makeVersion("item-\($0)") }

        let itemIDs = try workspace.appendSeparateItems(versions)

        #expect(itemIDs.count == 100)
        #expect(workspace.items.count == 100)
        #expect(workspace.items.flatMap(\.versions).map(\.id) == versions.map(\.id))
        try workspace.validate()
    }

    @Test
    func appendRejectsCanonicalDuplicatesAtomically() throws {
        let originalURL = URL(fileURLWithPath: "/tmp/Takes Playlist/../Takes Playlist/song.wav")
        let canonicalURL = originalURL.standardizedFileURL.resolvingSymlinksInPath()
        let existing = makeVersion("existing", url: originalURL)
        var workspace = PlaylistWorkspace(items: [PlaylistItem(title: "Existing", versions: [existing])])
        let before = workspace

        #expect(throws: PlaylistWorkspaceError.duplicateFile(canonicalURL)) {
            try workspace.appendSeparateItems([
                makeVersion("duplicate", url: URL(fileURLWithPath: "/tmp/Takes Playlist/song.wav")),
                makeVersion("new", url: URL(fileURLWithPath: "/tmp/Takes Playlist/new.wav"))
            ])
        }
        #expect(workspace == before)
    }

    @Test
    func groupingUsesEarliestRowAndTranslatesIncomingOffsets() throws {
        let firstID = UUID()
        let firstReference = makeVersion("first-reference", offsetSeconds: 5)
        let firstOther = makeVersion("first-other", offsetSeconds: 7)
        let first = PlaylistItem(
            id: firstID,
            title: "Destination title",
            versions: [firstReference, firstOther],
            selectedVersionID: firstReference.id,
            comparison: PlaylistComparisonConfiguration(
                repeatMode: .one,
                loopRegion: LoopRegion(start: 4, end: 9),
                visibleStart: -1,
                visibleSpan: 20
            )
        )
        let secondReference = makeVersion("second-reference", offsetSeconds: 1)
        let secondOther = makeVersion("second-other", offsetSeconds: 3)
        let second = PlaylistItem(
            title: "Incoming title",
            versions: [secondReference, secondOther],
            selectedVersionID: secondReference.id
        )
        let untouched = PlaylistItem(title: "Untouched", versions: [makeVersion("untouched")])
        var workspace = PlaylistWorkspace(items: [first, untouched, second])

        let resultID = try workspace.groupItems([second.id, first.id])

        #expect(resultID == firstID)
        #expect(workspace.items.map(\.id) == [first.id, untouched.id])
        #expect(workspace.items[0].title == "Destination title")
        #expect(workspace.items[0].comparison == first.comparison)
        #expect(workspace.items[0].versions.map(\.id) == [firstReference.id, firstOther.id, secondReference.id, secondOther.id])
        #expect(workspace.items[0].versions[2].offsetSeconds == 5)
        #expect(workspace.items[0].versions[3].offsetSeconds == 7)
        #expect(workspace.items[0].selectedVersionID == firstReference.id)
        try workspace.validate()
    }

    @Test
    func groupingSelectsPlayingVersionAndMovesWorkspaceState() throws {
        let first = PlaylistItem(title: "First", versions: [makeVersion("first")])
        let playing = makeVersion("playing", offsetSeconds: -2)
        let second = PlaylistItem(title: "Second", versions: [playing])
        var workspace = PlaylistWorkspace(
            items: [first, second],
            activeView: .comparison(itemID: second.id),
            listeningState: PlaylistListeningState(itemID: second.id, versionID: playing.id, filePosition: 19)
        )

        try workspace.groupItems([second.id, first.id], playingVersionID: playing.id)

        #expect(workspace.items.count == 1)
        #expect(workspace.items[0].selectedVersionID == playing.id)
        #expect(workspace.activeView == .comparison(itemID: first.id))
        #expect(workspace.listeningState == PlaylistListeningState(itemID: first.id, versionID: playing.id, filePosition: 19))
    }

    @Test
    func groupingDoesNotTreatPausedListeningStateAsPlayingSelection() throws {
        let firstVersion = makeVersion("first")
        let secondVersion = makeVersion("second")
        let first = PlaylistItem(title: "First", versions: [firstVersion])
        let second = PlaylistItem(title: "Second", versions: [secondVersion], selectedVersionID: secondVersion.id)
        var workspace = PlaylistWorkspace(
            items: [first, second],
            listeningState: PlaylistListeningState(itemID: second.id, versionID: secondVersion.id, filePosition: 10)
        )

        try workspace.groupItems([first.id, second.id])

        #expect(workspace.items[0].selectedVersionID == firstVersion.id)
        #expect(workspace.listeningState?.versionID == secondVersion.id)
    }

    @Test
    func groupingOverVersionLimitFailsWithoutChangingWorkspace() throws {
        let destinationVersions = (0..<PlaylistWorkspace.maximumVersionsPerItem).map {
            makeVersion("destination-\($0)")
        }
        let destination = PlaylistItem(title: "Destination", versions: destinationVersions)
        let incomingVersion = makeVersion("incoming")
        let incoming = PlaylistItem(title: "Incoming", versions: [incomingVersion])
        var workspace = PlaylistWorkspace(items: [destination, incoming])
        let before = workspace

        #expect(throws: PlaylistWorkspaceError.versionLimitExceeded(itemID: destination.id, limit: PlaylistWorkspace.maximumVersionsPerItem)) {
            try workspace.groupItems([destination.id, incoming.id])
        }
        #expect(workspace == before)
    }

    @Test
    func movingVersionPreservesIdentitySelectionAndFilePosition() throws {
        let moved = makeVersion("moved", gainDB: -2, offsetSeconds: 4)
        let remaining = makeVersion("remaining")
        let source = PlaylistItem(
            title: "Source",
            versions: [moved, remaining],
            selectedVersionID: moved.id
        )
        let destinationVersion = makeVersion("destination")
        let destination = PlaylistItem(title: "Destination", versions: [destinationVersion])
        var workspace = PlaylistWorkspace(
            items: [source, destination],
            activeView: .comparison(itemID: source.id),
            listeningState: PlaylistListeningState(itemID: source.id, versionID: moved.id, filePosition: 15)
        )

        try workspace.moveVersion(moved.id, from: source.id, to: destination.id, at: 0)

        #expect(workspace.items[0].versions.map(\.id) == [remaining.id])
        #expect(workspace.items[0].selectedVersionID == remaining.id)
        #expect(workspace.items[1].versions.map(\.id) == [moved.id, destinationVersion.id])
        #expect(workspace.items[1].selectedVersionID == moved.id)
        #expect(workspace.items[1].versions[0].gainDB == -2)
        #expect(workspace.items[1].versions[0].offsetSeconds == 0)
        #expect(workspace.listeningState == PlaylistListeningState(itemID: destination.id, versionID: moved.id, filePosition: 15))
        #expect(workspace.activeView == .comparison(itemID: source.id))
    }

    @Test
    func movingLastVersionRemovesSourceAndRetargetsComparisonView() throws {
        let moved = makeVersion("moved")
        let source = PlaylistItem(title: "Source", versions: [moved])
        let destination = PlaylistItem(title: "Destination", versions: [makeVersion("destination")])
        var workspace = PlaylistWorkspace(items: [source, destination], activeView: .comparison(itemID: source.id))

        try workspace.moveVersion(moved.id, from: source.id, to: destination.id)

        #expect(workspace.items.map(\.id) == [destination.id])
        #expect(workspace.items[0].versions.map(\.id) == [destination.versions[0].id, moved.id])
        #expect(workspace.activeView == .comparison(itemID: destination.id))
    }

    @Test
    func separatingVersionResetsOffsetAndLoopButRetainsGainAndID() throws {
        let kept = makeVersion("kept")
        let separated = makeVersion("separated", gainDB: 1.75, offsetSeconds: -3.5)
        let configuration = PlaylistComparisonConfiguration(
            repeatMode: .one,
            loopRegion: LoopRegion(start: 2, end: 6),
            isBlindListeningModeEnabled: true,
            visibleStart: 1,
            visibleSpan: 8
        )
        let source = PlaylistItem(
            title: "Group",
            versions: [kept, separated],
            selectedVersionID: separated.id,
            comparison: configuration
        )
        var workspace = PlaylistWorkspace(items: [source])

        let separatedItemID = try workspace.separateVersion(separated.id, from: source.id)
        let separatedItem = try #require(workspace.items.first { $0.id == separatedItemID })

        #expect(workspace.items.map(\.id) == [source.id, separatedItemID])
        #expect(workspace.items[0].versions.map(\.id) == [kept.id])
        #expect(workspace.items[0].selectedVersionID == kept.id)
        #expect(separatedItem.versions[0].id == separated.id)
        #expect(separatedItem.versions[0].gainDB == 1.75)
        #expect(separatedItem.versions[0].offsetSeconds == 0)
        #expect(separatedItem.comparison.repeatMode == .one)
        #expect(separatedItem.comparison.isBlindListeningModeEnabled)
        #expect(separatedItem.comparison.loopRegion == nil)
    }

    @Test
    func groupingFourFilesThenSeparatingAndRegroupingRetainsAllVersionIDs() throws {
        let versions = (0..<4).map { makeVersion("four-\($0)") }
        var workspace = PlaylistWorkspace()
        try workspace.appendSeparateItems(versions)
        let originalItemIDs = workspace.items.map(\.id)

        let firstGroupID = try workspace.groupItems([originalItemIDs[0], originalItemIDs[1]])
        let secondGroupID = try workspace.groupItems([originalItemIDs[2], originalItemIDs[3]])
        #expect(workspace.items.map(\.id) == [firstGroupID, secondGroupID])
        #expect(workspace.items.map { $0.versions.map(\.id) } == [[versions[0].id, versions[1].id], [versions[2].id, versions[3].id]])

        let separatedID = try workspace.separateVersion(versions[1].id, from: firstGroupID)
        #expect(workspace.items.flatMap(\.versions).map(\.id) == versions.map(\.id))

        try workspace.groupItems([firstGroupID, separatedID])
        #expect(workspace.items.count == 2)
        #expect(workspace.items[0].versions.map(\.id) == [versions[0].id, versions[1].id])
        #expect(workspace.items[1].versions.map(\.id) == [versions[2].id, versions[3].id])
    }

    @Test
    func reorderRenameAndRemovePreserveRemainingIDs() throws {
        let first = PlaylistItem(title: "First", versions: [makeVersion("first")])
        let second = PlaylistItem(title: "Second", versions: [makeVersion("second")])
        let third = PlaylistItem(title: "Third", versions: [makeVersion("third")])
        var workspace = PlaylistWorkspace(
            items: [first, second, third],
            listeningState: PlaylistListeningState(itemID: second.id, versionID: second.versions[0].id, filePosition: 12)
        )

        try workspace.reorderItems(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        try workspace.renameItem(first.id, to: "Renamed")
        let removed = try workspace.removeItem(second.id)

        #expect(removed?.id == second.id)
        #expect(workspace.items.map(\.id) == [third.id, first.id])
        #expect(workspace.items[1].title == "Renamed")
        #expect(workspace.listeningState == PlaylistListeningState(itemID: third.id, versionID: third.versions[0].id, filePosition: 0))
        try workspace.validate()
    }

    @Test
    func removingLaterListeningItemChoosesItsSurvivingSuccessor() throws {
        let items = (0..<6).map { index in
            PlaylistItem(title: "Item \(index)", versions: [makeVersion("remove-\(index)")])
        }
        var workspace = PlaylistWorkspace(
            items: items,
            listeningState: PlaylistListeningState(
                itemID: items[2].id,
                versionID: items[2].versions[0].id,
                filePosition: 20
            )
        )

        try workspace.removeItems([items[0].id, items[2].id])

        #expect(workspace.items.map(\.id) == [items[1].id, items[3].id, items[4].id, items[5].id])
        #expect(workspace.listeningState == PlaylistListeningState(
            itemID: items[3].id,
            versionID: items[3].versions[0].id,
            filePosition: 0
        ))
    }

    @Test
    func invalidOrganizationRequestsAreAtomic() throws {
        let version = makeVersion("version")
        let item = PlaylistItem(title: "Item", versions: [version])
        var workspace = PlaylistWorkspace(items: [item])
        let before = workspace

        #expect(throws: PlaylistWorkspaceError.invalidDestinationIndex(2)) {
            try workspace.moveItem(item.id, to: 2)
        }
        #expect(workspace == before)
        #expect(throws: PlaylistWorkspaceError.cannotSeparateOnlyVersion(version.id)) {
            try workspace.separateVersion(version.id, from: item.id)
        }
        #expect(workspace == before)
    }

    @Test
    func validationRejectsBadReferencesAndNonFiniteValues() throws {
        let version = makeVersion("version")
        let itemID = UUID()
        let invalidSelection = PlaylistItem(
            id: itemID,
            title: "Item",
            versions: [version],
            selectedVersionID: UUID()
        )
        let invalidWorkspace = PlaylistWorkspace(items: [invalidSelection])
        #expect(throws: PlaylistWorkspaceError.selectedVersionNotFound(itemID: itemID, versionID: invalidSelection.selectedVersionID!)) {
            try invalidWorkspace.validate()
        }

        var invalidAdjustment = version
        invalidAdjustment.offsetSeconds = .infinity
        let invalidValues = PlaylistWorkspace(items: [PlaylistItem(title: "Item", versions: [invalidAdjustment])])
        #expect(throws: PlaylistWorkspaceError.invalidValue("offsetSeconds")) {
            try invalidValues.validate()
        }

        let missingComparison = PlaylistWorkspace(activeView: .comparison(itemID: UUID()))
        #expect(throws: PlaylistWorkspaceError.invalidActiveItem(missingComparison.activeItemID!)) {
            try missingComparison.validate()
        }

        let nonFile = PlaylistVersion(
            file: PlaylistFileReference(storedURL: URL(string: "https://example.com/audio.wav")!),
            metadata: PlaylistMetadata(duration: 10)
        )
        let nonFileWorkspace = PlaylistWorkspace(items: [PlaylistItem(title: "Item", versions: [nonFile])])
        #expect(throws: PlaylistWorkspaceError.invalidValue("file.storedURL")) {
            try nonFileWorkspace.validate()
        }

        let item = PlaylistItem(title: "Item", versions: [version])
        let outOfBoundsPosition = PlaylistWorkspace(
            items: [item],
            listeningState: PlaylistListeningState(
                itemID: item.id,
                versionID: version.id,
                filePosition: 61
            )
        )
        #expect(throws: PlaylistWorkspaceError.invalidValue("listeningState.filePosition")) {
            try outOfBoundsPosition.validate()
        }
    }

    private func makeVersion(
        _ name: String,
        id: UUID = UUID(),
        url: URL? = nil,
        title: String? = nil,
        artist: String? = "Artist",
        album: String? = "Album",
        duration: TimeInterval = 60,
        sampleRate: Double = 44_100,
        channelCount: UInt32 = 2,
        bitRate: Double = 192_000,
        fileFormatDescription: String = "WAV",
        gainDB: Float = 0,
        offsetSeconds: TimeInterval = 0
    ) -> PlaylistVersion {
        let storedURL = url ?? URL(fileURLWithPath: "/tmp/Takes Playlist Tests/\(name).wav")
        return PlaylistVersion(
            id: id,
            file: PlaylistFileReference(storedURL: storedURL),
            metadata: PlaylistMetadata(
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                sampleRate: sampleRate,
                channelCount: channelCount,
                bitRate: bitRate,
                fileFormatDescription: fileFormatDescription,
                displayName: name
            ),
            gainDB: gainDB,
            offsetSeconds: offsetSeconds
        )
    }
}
