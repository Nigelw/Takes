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
            versions: [secondReference, secondOther]
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
        #expect(workspace.items[0].keyVersion?.id == firstReference.id)
        try workspace.validate()
    }

    @Test
    func groupingKeepsDestinationKeyAndMovesWorkspaceState() throws {
        let first = PlaylistItem(title: "First", versions: [makeVersion("first")])
        let playing = makeVersion("playing", offsetSeconds: -2)
        let second = PlaylistItem(title: "Second", versions: [playing])
        var workspace = PlaylistWorkspace(
            items: [first, second],
            activeView: .comparison(itemID: second.id),
            listeningState: PlaylistListeningState(itemID: second.id, versionID: playing.id, filePosition: 19)
        )

        try workspace.groupItems([second.id, first.id])

        #expect(workspace.items.count == 1)
        #expect(workspace.items[0].keyVersion?.id == first.versions[0].id)
        #expect(workspace.activeView == .comparison(itemID: first.id))
        #expect(workspace.listeningState == PlaylistListeningState(itemID: first.id, versionID: playing.id, filePosition: 19))
    }

    @Test
    func groupingDoesNotTreatPausedListeningStateAsPlayingSelection() throws {
        let firstVersion = makeVersion("first")
        let secondVersion = makeVersion("second")
        let first = PlaylistItem(title: "First", versions: [firstVersion])
        let second = PlaylistItem(title: "Second", versions: [secondVersion])
        var workspace = PlaylistWorkspace(
            items: [first, second],
            listeningState: PlaylistListeningState(itemID: second.id, versionID: secondVersion.id, filePosition: 10)
        )

        try workspace.groupItems([first.id, second.id])

        #expect(workspace.items[0].keyVersion?.id == firstVersion.id)
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
            versions: [moved, remaining]
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
        #expect(workspace.items[0].keyVersion?.id == remaining.id)
        #expect(workspace.items[1].versions.map(\.id) == [moved.id, destinationVersion.id])
        #expect(workspace.items[1].keyVersion?.id == moved.id)
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

    @Test func batchMoveUsesOriginalReferencesAndSuppliedOrder() throws {
        let reference = makeVersion("source-ref", offsetSeconds: 4)
        let other = makeVersion("other", offsetSeconds: 9)
        let kept = makeVersion("kept", offsetSeconds: 11)
        let source = PlaylistItem(title: "Source", versions: [reference, other, kept])
        let destRef = makeVersion("destination-ref", offsetSeconds: -2)
        let anchor = makeVersion("anchor")
        let destination = PlaylistItem(title: "Destination", versions: [destRef, anchor])
        var workspace = PlaylistWorkspace(items: [source, destination])
        let ids = [reference.id, destRef.id, other.id]
        try workspace.moveVersions(ids, to: destination.id, before: anchor.id)
        #expect(workspace.items[0].keyVersion?.id == kept.id)
        #expect(workspace.items[1].versions.map(\.id) == ids + [anchor.id])
        #expect(workspace.items[1].versions.map(\.offsetSeconds) == [-2, -2, 3, 0])
        #expect(workspace.items[1].keyVersion?.id == reference.id)
    }

    @Test func dragGroupingPreservesExplicitDestinationAndSourceOrder() throws {
        let a = makeVersion("a", offsetSeconds: 5)
        let b = makeVersion("b", offsetSeconds: 8)
        let first = PlaylistItem(title: "First", versions: [a, b])
        let second = PlaylistItem(title: "Second", versions: [makeVersion("second")])
        let target = PlaylistItem(title: "Target", versions: [makeVersion("target", offsetSeconds: -1)])
        var workspace = PlaylistWorkspace(items: [first, second, target])
        try workspace.groupItems([second.id, first.id], into: target.id)
        #expect(workspace.items.map(\.id) == [target.id])
        #expect(workspace.items[0].versions.map(\.id) == (target.versions + second.versions + first.versions).map(\.id))
        #expect(workspace.items[0].versions.map(\.offsetSeconds) == [-1, -1, -1, 2])
        #expect(workspace.items[0].keyVersion?.id == target.versions[0].id)
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
            comparison: configuration
        )
        var workspace = PlaylistWorkspace(items: [source])

        let separatedItemID = try workspace.separateVersion(separated.id, from: source.id)
        let separatedItem = try #require(workspace.items.first { $0.id == separatedItemID })

        #expect(workspace.items.map(\.id) == [source.id, separatedItemID])
        #expect(workspace.items[0].versions.map(\.id) == [kept.id])
        #expect(workspace.items[0].keyVersion?.id == kept.id)
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

    // MARK: Culling

    @Test
    func keyVersionIsFirstNonRejectedVersion() {
        var first = makeVersion("first")
        let second = makeVersion("second")
        let third = makeVersion("third")
        var item = PlaylistItem(title: "Song", versions: [first, second, third])
        #expect(item.keyVersion?.id == first.id)

        first.isRejected = true
        item.versions[0] = first
        #expect(item.keyVersion?.id == second.id)

        // Rejecting a later version doesn't change the key.
        item.versions[2].isRejected = true
        #expect(item.keyVersion?.id == second.id)
    }

    @Test
    func keyVersionFallsBackToFirstWhenEveryVersionIsRejected() {
        let versions = ["a", "b"].map { makeVersion($0) }.map { version -> PlaylistVersion in
            var rejected = version
            rejected.isRejected = true
            return rejected
        }
        let item = PlaylistItem(title: "Song", versions: versions)
        #expect(item.keyVersion?.id == versions[0].id)
        #expect(!item.isRejected)
    }

    @Test
    func missingKeyVersionStaysKey() {
        // Availability does not enter into the rule: a version whose file is
        // gone stays the key, so unplugging a drive never moves the row.
        let missing = makeVersion("missing", url: URL(fileURLWithPath: "/nonexistent/Takes/missing.wav"))
        let present = makeVersion("present")
        let item = PlaylistItem(title: "Song", versions: [missing, present])
        #expect(PlaylistWorkspaceStore.resolveFileReference(missing.file).isMissing)
        #expect(item.keyVersion?.id == missing.id)
    }

    @Test
    func rejectingSetsOnlyTheNamedFlagsAndMovesNothing() throws {
        let a = makeVersion("a"), b = makeVersion("b")
        let item = PlaylistItem(title: "Song", versions: [a, b])
        let other = PlaylistItem(title: "Other", versions: [makeVersion("other")])
        var workspace = PlaylistWorkspace(items: [item, other])

        try workspace.setRejected(true, itemIDs: [item.id])
        #expect(workspace.items[0].isRejected)
        #expect(workspace.items[0].versions.allSatisfy { !$0.isRejected })
        #expect(workspace.items.map(\.id) == [item.id, other.id])

        try workspace.setRejected(true, versionIDs: [a.id])
        #expect(workspace.items[0].versions.map(\.isRejected) == [true, false])
        #expect(workspace.items[0].versions.map(\.id) == [a.id, b.id])
        #expect(workspace.items[0].keyVersion?.id == b.id)

        // Clearing one flag never clears the other.
        try workspace.setRejected(false, itemIDs: [item.id])
        #expect(!workspace.items[0].isRejected)
        #expect(workspace.items[0].versions[0].isRejected)

        let before = workspace
        #expect(throws: PlaylistWorkspaceError.versionNotFound(other.id)) {
            try workspace.setRejected(true, versionIDs: [other.id])
        }
        #expect(workspace == before)
    }

    @Test
    func movingVersionsKeepsEveryFlag() throws {
        var moved = makeVersion("moved")
        moved.isRejected = true
        let staying = makeVersion("staying")
        let source = PlaylistItem(title: "Source", versions: [moved, staying], isRejected: true)
        let destination = PlaylistItem(title: "Destination", versions: [makeVersion("destination")])
        var workspace = PlaylistWorkspace(items: [source, destination])

        try workspace.moveVersions([moved.id], to: destination.id)

        #expect(workspace.items[0].isRejected)
        #expect(!workspace.items[1].isRejected)
        #expect(workspace.items[1].versions.last?.id == moved.id)
        #expect(workspace.items[1].versions.last?.isRejected == true)
        #expect(workspace.items[1].keyVersion?.id == destination.versions[0].id)
    }

    @Test
    func groupingKeepsVersionFlagsAndOnlyTheDestinationFlag() throws {
        var rejectedVersion = makeVersion("rejected-version")
        rejectedVersion.isRejected = true
        let destination = PlaylistItem(title: "Destination", versions: [makeVersion("destination")])
        let absorbed = PlaylistItem(title: "Absorbed", versions: [rejectedVersion], isRejected: true)
        var workspace = PlaylistWorkspace(items: [destination, absorbed])

        try workspace.groupItems([destination.id, absorbed.id])

        #expect(workspace.items.count == 1)
        #expect(!workspace.items[0].isRejected)
        #expect(workspace.items[0].versions.map(\.isRejected) == [false, true])

        var rejectedDestination = PlaylistWorkspace(items: [
            PlaylistItem(title: "Destination", versions: [makeVersion("d2")], isRejected: true),
            PlaylistItem(title: "Incoming", versions: [makeVersion("i2")])
        ])
        try rejectedDestination.groupItems(rejectedDestination.items.map(\.id))
        #expect(rejectedDestination.items[0].isRejected)
    }

    @Test
    func separatingStartsTheNewTrackUnrejectedAndKeepsTheVersionFlag() throws {
        var separated = makeVersion("separated")
        separated.isRejected = true
        let kept = makeVersion("kept")
        let source = PlaylistItem(title: "Group", versions: [kept, separated], isRejected: true)
        var workspace = PlaylistWorkspace(items: [source])

        let newID = try workspace.separateVersion(separated.id, from: source.id)
        let newItem = try #require(workspace.items.first { $0.id == newID })

        #expect(workspace.items[0].isRejected)
        #expect(!newItem.isRejected)
        #expect(newItem.versions[0].isRejected)
    }

    @Test
    func flagsRoundTripThroughCodingAndDefaultToFalse() throws {
        var version = makeVersion("version")
        version.isRejected = true
        let item = PlaylistItem(title: "Song", versions: [version, makeVersion("other")], isRejected: true)
        let workspace = PlaylistWorkspace(items: [item])
        let data = try JSONEncoder().encode(workspace)
        #expect(try JSONDecoder().decode(PlaylistWorkspace.self, from: data) == workspace)

        // Encoding never writes the retired stored key version.
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("selectedVersionID"))

        // Older values without the flags decode as not rejected.
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var items = try #require(object["items"] as? [[String: Any]])
        items[0].removeValue(forKey: "isRejected")
        var versions = try #require(items[0]["versions"] as? [[String: Any]])
        versions[0].removeValue(forKey: "isRejected")
        items[0]["versions"] = versions
        object["items"] = items
        let stripped = try JSONDecoder().decode(
            PlaylistWorkspace.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(!stripped.items[0].isRejected)
        #expect(stripped.items[0].versions.allSatisfy { !$0.isRejected })
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
