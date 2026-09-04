import Foundation

/// The repeat modes used while the workspace is playing its ordered playlist.
/// Comparison repeat behavior continues to use ``RepeatMode``.
enum PlaylistRepeatMode: String, CaseIterable, Codable, Equatable {
    case off
    case one
    case all

    var next: PlaylistRepeatMode {
        switch self {
        case .off: return .one
        case .one: return .all
        case .all: return .off
        }
    }
}

/// The persisted root view of the workspace.
enum PlaylistWorkspaceView: Codable, Equatable {
    case playlist
    case comparison(itemID: UUID)

    var itemID: UUID? {
        guard case let .comparison(itemID) = self else { return nil }
        return itemID
    }
}

/// A persisted playlist position. The position is always measured in file
/// seconds, so comparison offsets never leak into workspace playback state.
struct PlaylistListeningState: Codable, Equatable {
    var itemID: UUID
    var versionID: UUID
    var filePosition: TimeInterval

    init(itemID: UUID, versionID: UUID, filePosition: TimeInterval = 0) {
        self.itemID = itemID
        self.versionID = versionID
        self.filePosition = filePosition
    }
}

/// A file reference retained by the workspace. Audio data is never owned by
/// this value; workspace-owned downloads are identified by the flag so the
/// coordinator can manage their lifecycle later.
struct PlaylistFileReference: Codable, Equatable {
    var storedURL: URL
    var bookmarkData: Data?
    var isWorkspaceOwned: Bool

    init(
        storedURL: URL,
        bookmarkData: Data? = nil,
        isWorkspaceOwned: Bool = false
    ) {
        self.storedURL = storedURL
        self.bookmarkData = bookmarkData
        self.isWorkspaceOwned = isWorkspaceOwned
    }

    /// The identity used for duplicate detection. It deliberately follows
    /// symlinks so aliases of one local file cannot be imported twice.
    var canonicalURL: URL {
        Self.canonicalURL(for: storedURL)
    }

    static func canonicalURL(for url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

/// Metadata kept with a playlist version independently of audio-engine state.
struct PlaylistMetadata: Codable, Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var duration: TimeInterval
    var sampleRate: Double
    var channelCount: UInt32
    var bitRate: Double
    var fileFormatDescription: String
    var displayName: String

    init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        duration: TimeInterval = 0,
        sampleRate: Double = 0,
        channelCount: UInt32 = 0,
        bitRate: Double = 0,
        fileFormatDescription: String = "",
        displayName: String = ""
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitRate = bitRate
        self.fileFormatDescription = fileFormatDescription
        self.displayName = displayName
    }
}

/// Adjustments and view state belonging to one comparison item.
struct PlaylistComparisonConfiguration: Codable, Equatable {
    var repeatMode: RepeatMode
    var loopRegion: LoopRegion?
    var isBlindListeningModeEnabled: Bool
    var visibleStart: TimeInterval?
    var visibleSpan: TimeInterval?

    init(
        repeatMode: RepeatMode = .off,
        loopRegion: LoopRegion? = nil,
        isBlindListeningModeEnabled: Bool = false,
        visibleStart: TimeInterval? = nil,
        visibleSpan: TimeInterval? = nil
    ) {
        self.repeatMode = repeatMode
        self.loopRegion = loopRegion
        self.isBlindListeningModeEnabled = isBlindListeningModeEnabled
        self.visibleStart = visibleStart
        self.visibleSpan = visibleSpan
    }
}

/// One audio file inside a playlist item. The ID is also used as the
/// corresponding ``SessionTrack.id`` when comparison is prepared.
struct PlaylistVersion: Identifiable, Codable, Equatable {
    let id: UUID
    var file: PlaylistFileReference
    var metadata: PlaylistMetadata
    var gainDB: Float
    var offsetSeconds: TimeInterval

    init(
        id: UUID = UUID(),
        file: PlaylistFileReference,
        metadata: PlaylistMetadata,
        gainDB: Float = 0,
        offsetSeconds: TimeInterval = 0
    ) {
        self.id = id
        self.file = file
        self.metadata = metadata
        self.gainDB = gainDB
        self.offsetSeconds = offsetSeconds
    }
}

/// A playlist row containing one or more versions of the same song.
struct PlaylistItem: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var versions: [PlaylistVersion]
    var selectedVersionID: UUID?
    var comparison: PlaylistComparisonConfiguration

    init(
        id: UUID = UUID(),
        title: String,
        versions: [PlaylistVersion] = [],
        selectedVersionID: UUID? = nil,
        comparison: PlaylistComparisonConfiguration = .init()
    ) {
        self.id = id
        self.title = title
        self.versions = versions
        self.selectedVersionID = selectedVersionID ?? versions.first?.id
        self.comparison = comparison
    }

    var selectedVersion: PlaylistVersion? {
        guard let selectedVersionID else { return versions.first }
        return versions.first { $0.id == selectedVersionID } ?? versions.first
    }
}

/// Errors raised by workspace validation and organization operations.
enum PlaylistWorkspaceError: Error, Equatable, LocalizedError {
    case noItemsSelected
    case itemNotFound(UUID)
    case versionNotFound(UUID)
    case versionNotInItem(versionID: UUID, itemID: UUID)
    case duplicateItemID(UUID)
    case duplicateVersionID(UUID)
    case duplicateFile(URL)
    case emptyItem(UUID)
    case versionLimitExceeded(itemID: UUID, limit: Int)
    case selectedVersionNotFound(itemID: UUID, versionID: UUID)
    case invalidActiveItem(UUID)
    case invalidListeningItem(UUID)
    case invalidListeningVersion(itemID: UUID, versionID: UUID)
    case invalidDestinationIndex(Int)
    case invalidItemOrder
    case cannotSeparateOnlyVersion(UUID)
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case .noItemsSelected:
            return "At least one playlist item must be selected."
        case let .itemNotFound(id):
            return "Playlist item \(id.uuidString) was not found."
        case let .versionNotFound(id):
            return "Playlist version \(id.uuidString) was not found."
        case let .versionNotInItem(versionID, itemID):
            return "Playlist version \(versionID.uuidString) is not in item \(itemID.uuidString)."
        case let .duplicateItemID(id):
            return "Playlist item ID \(id.uuidString) is used more than once."
        case let .duplicateVersionID(id):
            return "Playlist version ID \(id.uuidString) is used more than once."
        case let .duplicateFile(url):
            return "The file is already present in the workspace: \(url.path)."
        case let .emptyItem(id):
            return "Playlist item \(id.uuidString) has no versions."
        case let .versionLimitExceeded(itemID, limit):
            return "Playlist item \(itemID.uuidString) cannot contain more than \(limit) versions."
        case let .selectedVersionNotFound(itemID, versionID):
            return "Selected version \(versionID.uuidString) is not in item \(itemID.uuidString)."
        case let .invalidActiveItem(id):
            return "The comparison view refers to missing item \(id.uuidString)."
        case let .invalidListeningItem(id):
            return "Listening state refers to missing item \(id.uuidString)."
        case let .invalidListeningVersion(itemID, versionID):
            return "Listening state refers to missing version \(versionID.uuidString) in item \(itemID.uuidString)."
        case let .invalidDestinationIndex(index):
            return "Destination index \(index) is outside the playlist."
        case .invalidItemOrder:
            return "The reordered item IDs must contain every workspace item exactly once."
        case let .cannotSeparateOnlyVersion(id):
            return "Version \(id.uuidString) is already the only version in its item."
        case let .invalidValue(name):
            return "Workspace value \(name) is invalid."
        }
    }
}

/// Ordered, persisted playlist organization and playback preferences.
///
/// This value contains no audio runtime state. In particular, it has no
/// `isPlaying` flag: playing/paused state belongs to the coordinator and is
/// transferred across navigation, while ``listeningState`` stores only a file
/// position for restoration and handoff.
struct PlaylistWorkspace: Codable, Equatable {
    static let maximumVersionsPerItem = 32

    var items: [PlaylistItem]
    var activeView: PlaylistWorkspaceView
    var listeningState: PlaylistListeningState?
    var playlistRepeatMode: PlaylistRepeatMode
    var isShuffleEnabled: Bool

    init(
        items: [PlaylistItem] = [],
        activeView: PlaylistWorkspaceView = .playlist,
        listeningState: PlaylistListeningState? = nil,
        playlistRepeatMode: PlaylistRepeatMode = .off,
        isShuffleEnabled: Bool = false
    ) {
        self.items = items
        self.activeView = activeView
        self.listeningState = listeningState
        self.playlistRepeatMode = playlistRepeatMode
        self.isShuffleEnabled = isShuffleEnabled
    }

    var activeItemID: UUID? { activeView.itemID }

    var allVersions: [PlaylistVersion] {
        items.flatMap(\.versions)
    }

    /// Validate persisted data before accepting a snapshot or an organization
    /// edit. The method is intentionally callable by the persistence layer.
    func validate() throws {
        var itemIDs = Set<UUID>()
        var versionIDs = Set<UUID>()
        var canonicalFiles = Set<String>()

        for item in items {
            guard itemIDs.insert(item.id).inserted else {
                throw PlaylistWorkspaceError.duplicateItemID(item.id)
            }
            guard !item.versions.isEmpty else {
                throw PlaylistWorkspaceError.emptyItem(item.id)
            }
            guard item.versions.count <= Self.maximumVersionsPerItem else {
                throw PlaylistWorkspaceError.versionLimitExceeded(
                    itemID: item.id,
                    limit: Self.maximumVersionsPerItem
                )
            }
            if let selectedVersionID = item.selectedVersionID,
               !item.versions.contains(where: { $0.id == selectedVersionID }) {
                throw PlaylistWorkspaceError.selectedVersionNotFound(
                    itemID: item.id,
                    versionID: selectedVersionID
                )
            }
            try Self.validate(comparison: item.comparison)

            for version in item.versions {
                guard versionIDs.insert(version.id).inserted else {
                    throw PlaylistWorkspaceError.duplicateVersionID(version.id)
                }
                guard version.file.storedURL.isFileURL else {
                    throw PlaylistWorkspaceError.invalidValue("file.storedURL")
                }
                let canonicalURL = version.file.canonicalURL
                guard canonicalFiles.insert(canonicalURL.absoluteString).inserted else {
                    throw PlaylistWorkspaceError.duplicateFile(canonicalURL)
                }
                try Self.validate(version: version)
            }
        }

        if case let .comparison(itemID) = activeView,
           !itemIDs.contains(itemID) {
            throw PlaylistWorkspaceError.invalidActiveItem(itemID)
        }

        if let listeningState {
            guard let item = items.first(where: { $0.id == listeningState.itemID }) else {
                throw PlaylistWorkspaceError.invalidListeningItem(listeningState.itemID)
            }
            guard let version = item.versions.first(where: { $0.id == listeningState.versionID }) else {
                throw PlaylistWorkspaceError.invalidListeningVersion(
                    itemID: listeningState.itemID,
                    versionID: listeningState.versionID
                )
            }
            guard listeningState.filePosition.isFinite,
                  listeningState.filePosition >= 0,
                  listeningState.filePosition <= version.metadata.duration else {
                throw PlaylistWorkspaceError.invalidValue("listeningState.filePosition")
            }
        }
    }

    var isValid: Bool {
        (try? validate()) != nil
    }

    /// Append every supplied version as a new item, preserving the supplied
    /// order. Duplicate canonical files and all other errors are checked before
    /// this value is changed.
    @discardableResult
    mutating func appendSeparateItems(_ versions: [PlaylistVersion]) throws -> [PlaylistItem.ID] {
        guard !versions.isEmpty else { return [] }

        var candidate = self
        var existingFiles = Set(candidate.items.flatMap { item in
            item.versions.map { $0.file.canonicalURL.absoluteString }
        })
        var newItemIDs: [PlaylistItem.ID] = []
        var newVersionIDs = Set<UUID>()

        for version in versions {
            guard newVersionIDs.insert(version.id).inserted else {
                throw PlaylistWorkspaceError.duplicateVersionID(version.id)
            }
            let canonicalURL = version.file.canonicalURL
            guard existingFiles.insert(canonicalURL.absoluteString).inserted else {
                throw PlaylistWorkspaceError.duplicateFile(canonicalURL)
            }
            let title = Self.defaultTitle(for: version)
            let item = PlaylistItem(title: title, versions: [version])
            candidate.items.append(item)
            newItemIDs.append(item.id)
        }

        try candidate.validate()
        self = candidate
        return newItemIDs
    }

    /// Append pre-grouped items, preserving both item and version order.
    @discardableResult
    mutating func appendItems(_ newItems: [PlaylistItem]) throws -> [PlaylistItem.ID] {
        guard !newItems.isEmpty else { return [] }
        var candidate = self
        candidate.items.append(contentsOf: newItems)
        try candidate.validate()
        self = candidate
        return newItems.map(\.id)
    }

    /// Merge selected items into the row that appears earliest in the current
    /// order. The earliest item's title and comparison configuration survive;
    /// incoming versions are translated relative to each group's selected
    /// reference version.
    @discardableResult
    mutating func groupItems(
        _ itemIDs: [PlaylistItem.ID],
        playingVersionID: PlaylistVersion.ID? = nil
    ) throws -> PlaylistItem.ID {
        guard !itemIDs.isEmpty else { throw PlaylistWorkspaceError.noItemsSelected }
        var candidate = self
        try candidate.validate()

        let selectedIDs = Set(itemIDs)
        guard selectedIDs.count == itemIDs.count else {
            throw PlaylistWorkspaceError.invalidItemOrder
        }
        let selectedIndexes = candidate.items.indices.filter { selectedIDs.contains(candidate.items[$0].id) }
        guard selectedIndexes.count == selectedIDs.count else {
            let missingID = itemIDs.first { requestedID in
                !candidate.items.contains { item in item.id == requestedID }
            }
            throw PlaylistWorkspaceError.itemNotFound(missingID ?? itemIDs[0])
        }

        let destinationIndex = selectedIndexes[0]
        let destination = candidate.items[destinationIndex]
        let destinationID = destination.id
        let destinationOffset = Self.referenceOffset(for: destination)
        let flattened: [PlaylistVersion] = selectedIndexes.flatMap { index in
            let item = candidate.items[index]
            let delta = index == destinationIndex ? 0 : destinationOffset - Self.referenceOffset(for: item)
            return item.versions.map { version in
                var translated = version
                translated.offsetSeconds += delta
                return translated
            }
        }

        // `listeningState` is persisted paused state, so it is not evidence
        // that a version is currently playing. A coordinator may pass an
        // explicit playing ID; an ID outside this grouping is simply ignored.
        let effectivePlayingVersionID = playingVersionID.flatMap { playingID in
            flattened.contains(where: { $0.id == playingID }) ? playingID : nil
        }

        var merged = destination
        merged.versions = flattened
        merged.selectedVersionID = effectivePlayingVersionID
            ?? (destination.selectedVersionID.flatMap { id in flattened.contains(where: { $0.id == id }) ? id : nil })
            ?? flattened.first?.id

        var rebuiltItems: [PlaylistItem] = []
        rebuiltItems.reserveCapacity(candidate.items.count - selectedIndexes.count + 1)
        for index in candidate.items.indices {
            if index == destinationIndex {
                rebuiltItems.append(merged)
            } else if !selectedIDs.contains(candidate.items[index].id) {
                rebuiltItems.append(candidate.items[index])
            }
        }
        candidate.items = rebuiltItems

        if case let .comparison(activeItemID) = candidate.activeView,
           selectedIDs.contains(activeItemID) {
            candidate.activeView = .comparison(itemID: destinationID)
        }
        if var state = candidate.listeningState, selectedIDs.contains(state.itemID) {
            state.itemID = destinationID
            candidate.listeningState = state
        }

        try candidate.validate()
        self = candidate
        return destinationID
    }

    /// Move a version to another item. `at` is an insertion index in the
    /// destination after the source version has been removed; nil appends it.
    /// Moving the last version removes the now-empty source item.
    mutating func moveVersion(
        _ versionID: PlaylistVersion.ID,
        from sourceItemID: PlaylistItem.ID,
        to destinationItemID: PlaylistItem.ID,
        at destinationIndex: Int? = nil,
        playingVersionID: PlaylistVersion.ID? = nil
    ) throws {
        var candidate = self
        try candidate.validate()
        guard let sourceIndex = candidate.items.firstIndex(where: { $0.id == sourceItemID }) else {
            throw PlaylistWorkspaceError.itemNotFound(sourceItemID)
        }
        guard let destinationIndexInItems = candidate.items.firstIndex(where: { $0.id == destinationItemID }) else {
            throw PlaylistWorkspaceError.itemNotFound(destinationItemID)
        }
        guard let sourceVersionIndex = candidate.items[sourceIndex].versions.firstIndex(where: { $0.id == versionID }) else {
            throw PlaylistWorkspaceError.versionNotInItem(versionID: versionID, itemID: sourceItemID)
        }

        if sourceItemID == destinationItemID {
            var item = candidate.items[sourceIndex]
            let movedVersion = item.versions.remove(at: sourceVersionIndex)
            let insertionIndex = destinationIndex ?? item.versions.count
            guard (0...item.versions.count).contains(insertionIndex) else {
                throw PlaylistWorkspaceError.invalidDestinationIndex(insertionIndex)
            }
            item.versions.insert(movedVersion, at: insertionIndex)
            candidate.items[sourceIndex] = item
            try candidate.validate()
            self = candidate
            return
        }

        let sourceReferenceOffset = Self.referenceOffset(for: candidate.items[sourceIndex])
        let destinationReferenceOffset = Self.referenceOffset(for: candidate.items[destinationIndexInItems])
        var source = candidate.items[sourceIndex]
        let movedVersion = source.versions.remove(at: sourceVersionIndex)
        var translatedVersion = movedVersion
        translatedVersion.offsetSeconds += destinationReferenceOffset - sourceReferenceOffset
        let sourceWasSelected = source.selectedVersionID == versionID
        if source.versions.isEmpty {
            candidate.items.remove(at: sourceIndex)
        } else {
            if sourceWasSelected {
                source.selectedVersionID = Self.fallbackVersionID(in: source, preferredIndex: sourceVersionIndex)
            }
            candidate.items[sourceIndex] = source
        }

        guard let destinationIndexAfterRemoval = candidate.items.firstIndex(where: { $0.id == destinationItemID }) else {
            throw PlaylistWorkspaceError.itemNotFound(destinationItemID)
        }
        var destination = candidate.items[destinationIndexAfterRemoval]
        guard destination.versions.count < Self.maximumVersionsPerItem else {
            throw PlaylistWorkspaceError.versionLimitExceeded(
                itemID: destination.id,
                limit: Self.maximumVersionsPerItem
            )
        }
        let insertionIndex = destinationIndex ?? destination.versions.count
        guard (0...destination.versions.count).contains(insertionIndex) else {
            throw PlaylistWorkspaceError.invalidDestinationIndex(insertionIndex)
        }
        destination.versions.insert(translatedVersion, at: insertionIndex)
        if sourceWasSelected || playingVersionID == versionID || destination.selectedVersionID == nil {
            destination.selectedVersionID = versionID
        }
        candidate.items[destinationIndexAfterRemoval] = destination

        if case let .comparison(activeItemID) = candidate.activeView,
           activeItemID == sourceItemID,
           !candidate.items.contains(where: { $0.id == sourceItemID }) {
            candidate.activeView = .comparison(itemID: destinationItemID)
        }
        if var state = candidate.listeningState, state.versionID == versionID {
            state.itemID = destinationItemID
            candidate.listeningState = state
        }

        try candidate.validate()
        self = candidate
    }

    /// Move a version when its source item can be inferred from its ID.
    mutating func moveVersion(
        _ versionID: PlaylistVersion.ID,
        to destinationItemID: PlaylistItem.ID,
        at destinationIndex: Int? = nil,
        playingVersionID: PlaylistVersion.ID? = nil
    ) throws {
        guard let sourceItemID = items.first(where: { item in
            item.versions.contains(where: { $0.id == versionID })
        })?.id else {
            throw PlaylistWorkspaceError.versionNotFound(versionID)
        }
        try moveVersion(
            versionID,
            from: sourceItemID,
            to: destinationItemID,
            at: destinationIndex,
            playingVersionID: playingVersionID
        )
    }

    /// Split a version into a new adjacent item. The version ID and gain are
    /// retained; its offset and the new item's loop are reset.
    @discardableResult
    mutating func separateVersion(
        _ versionID: PlaylistVersion.ID,
        from itemID: PlaylistItem.ID? = nil,
        playingVersionID: PlaylistVersion.ID? = nil
    ) throws -> PlaylistItem.ID {
        var candidate = self
        try candidate.validate()
        let sourceIndex: Int
        if let itemID {
            guard let index = candidate.items.firstIndex(where: { $0.id == itemID }) else {
                throw PlaylistWorkspaceError.itemNotFound(itemID)
            }
            sourceIndex = index
        } else {
            guard let index = candidate.items.firstIndex(where: { item in
                item.versions.contains(where: { $0.id == versionID })
            }) else {
                throw PlaylistWorkspaceError.versionNotFound(versionID)
            }
            sourceIndex = index
        }
        guard let versionIndex = candidate.items[sourceIndex].versions.firstIndex(where: { $0.id == versionID }) else {
            throw PlaylistWorkspaceError.versionNotInItem(versionID: versionID, itemID: candidate.items[sourceIndex].id)
        }
        guard candidate.items[sourceIndex].versions.count > 1 else {
            throw PlaylistWorkspaceError.cannotSeparateOnlyVersion(versionID)
        }

        if let playingVersionID,
           !candidate.allVersions.contains(where: { $0.id == playingVersionID }) {
            throw PlaylistWorkspaceError.versionNotFound(playingVersionID)
        }

        var source = candidate.items[sourceIndex]
        var separatedVersion = source.versions.remove(at: versionIndex)
        let sourceWasSelected = source.selectedVersionID == versionID
        if sourceWasSelected {
            source.selectedVersionID = Self.fallbackVersionID(in: source, preferredIndex: versionIndex)
        }
        separatedVersion.offsetSeconds = 0
        candidate.items[sourceIndex] = source

        var comparison = source.comparison
        comparison.loopRegion = nil
        let newItem = PlaylistItem(
            title: Self.defaultTitle(for: separatedVersion),
            versions: [separatedVersion],
            selectedVersionID: separatedVersion.id,
            comparison: comparison
        )
        candidate.items.insert(newItem, at: sourceIndex + 1)

        if var state = candidate.listeningState, state.versionID == versionID {
            state.itemID = newItem.id
            candidate.listeningState = state
        }

        try candidate.validate()
        self = candidate
        return newItem.id
    }

    /// Rename an item while preserving its identity and all versions.
    mutating func renameItem(_ itemID: PlaylistItem.ID, to title: String) throws {
        var candidate = self
        try candidate.validate()
        guard let index = candidate.items.firstIndex(where: { $0.id == itemID }) else {
            throw PlaylistWorkspaceError.itemNotFound(itemID)
        }
        candidate.items[index].title = title
        try candidate.validate()
        self = candidate
    }

    /// Select a version within an item, retaining both stable IDs.
    mutating func selectVersion(_ versionID: PlaylistVersion.ID, in itemID: PlaylistItem.ID) throws {
        var candidate = self
        try candidate.validate()
        guard let index = candidate.items.firstIndex(where: { $0.id == itemID }) else {
            throw PlaylistWorkspaceError.itemNotFound(itemID)
        }
        guard candidate.items[index].versions.contains(where: { $0.id == versionID }) else {
            throw PlaylistWorkspaceError.versionNotInItem(versionID: versionID, itemID: itemID)
        }
        candidate.items[index].selectedVersionID = versionID
        try candidate.validate()
        self = candidate
    }

    /// Move an item to its final zero-based index.
    mutating func moveItem(_ itemID: PlaylistItem.ID, to destinationIndex: Int) throws {
        var candidate = self
        try candidate.validate()
        guard let sourceIndex = candidate.items.firstIndex(where: { $0.id == itemID }) else {
            throw PlaylistWorkspaceError.itemNotFound(itemID)
        }
        var remaining = candidate.items
        let moved = remaining.remove(at: sourceIndex)
        guard (0...remaining.count).contains(destinationIndex) else {
            throw PlaylistWorkspaceError.invalidDestinationIndex(destinationIndex)
        }
        remaining.insert(moved, at: destinationIndex)
        candidate.items = remaining
        try candidate.validate()
        self = candidate
    }

    /// Reorder all items by supplying their complete desired ID order.
    mutating func reorderItems(_ orderedItemIDs: [PlaylistItem.ID]) throws {
        var candidate = self
        try candidate.validate()
        guard orderedItemIDs.count == candidate.items.count,
              Set(orderedItemIDs).count == candidate.items.count,
              Set(orderedItemIDs) == Set(candidate.items.map(\.id)) else {
            throw PlaylistWorkspaceError.invalidItemOrder
        }
        candidate.items = orderedItemIDs.compactMap { id in candidate.items.first { $0.id == id } }
        try candidate.validate()
        self = candidate
    }

    /// SwiftUI-compatible reorder operation. The destination is interpreted as
    /// an insertion offset in the original array, just like Array.move.
    mutating func reorderItems(fromOffsets offsets: IndexSet, toOffset destinationOffset: Int) throws {
        var candidate = self
        try candidate.validate()
        guard !offsets.isEmpty,
              offsets.allSatisfy({ candidate.items.indices.contains($0) }),
              (0...candidate.items.count).contains(destinationOffset) else {
            throw PlaylistWorkspaceError.invalidDestinationIndex(destinationOffset)
        }
        let moving = offsets.map { candidate.items[$0] }
        var remaining = candidate.items.enumerated()
            .filter { !offsets.contains($0.offset) }
            .map(\.element)
        let removedBeforeDestination = offsets.filter { $0 < destinationOffset }.count
        let insertionIndex = destinationOffset - removedBeforeDestination
        guard (0...remaining.count).contains(insertionIndex) else {
            throw PlaylistWorkspaceError.invalidDestinationIndex(destinationOffset)
        }
        remaining.insert(contentsOf: moving, at: insertionIndex)
        candidate.items = remaining
        try candidate.validate()
        self = candidate
    }

    /// Remove items in workspace order and return them for an Undo manager.
    @discardableResult
    mutating func removeItems(_ itemIDs: [PlaylistItem.ID]) throws -> [PlaylistItem] {
        guard !itemIDs.isEmpty else { return [] }
        var candidate = self
        try candidate.validate()
        let requested = Set(itemIDs)
        guard requested.count == itemIDs.count else { throw PlaylistWorkspaceError.invalidItemOrder }
        let removedIndexes = candidate.items.indices.filter { requested.contains(candidate.items[$0].id) }
        guard removedIndexes.count == requested.count else {
            let missing = itemIDs.first { requestedID in
                !candidate.items.contains { item in item.id == requestedID }
            }
            throw PlaylistWorkspaceError.itemNotFound(missing ?? itemIDs[0])
        }
        let removedItems = removedIndexes.map { candidate.items[$0] }
        let firstRemovedIndex = removedIndexes[0]
        let listeningOriginalIndex = candidate.listeningState.flatMap { state in
            candidate.items.firstIndex(where: { $0.id == state.itemID })
        }
        candidate.items.removeAll { requested.contains($0.id) }

        if case let .comparison(activeItemID) = candidate.activeView,
           requested.contains(activeItemID) {
            candidate.activeView = .playlist
        }
        if let state = candidate.listeningState, requested.contains(state.itemID) {
            let removedBeforeListening = listeningOriginalIndex.map { originalIndex in
                removedIndexes.filter { $0 < originalIndex }.count
            } ?? 0
            candidate.listeningState = Self.replacementListeningState(
                in: candidate.items,
                preferredIndex: (listeningOriginalIndex ?? firstRemovedIndex) - removedBeforeListening
            )
        }

        try candidate.validate()
        self = candidate
        return removedItems
    }

    @discardableResult
    mutating func removeItem(_ itemID: PlaylistItem.ID) throws -> PlaylistItem? {
        try removeItems([itemID]).first
    }

    /// Remove one version. Removing an item's last version removes that item.
    @discardableResult
    mutating func removeVersion(
        _ versionID: PlaylistVersion.ID,
        from itemID: PlaylistItem.ID? = nil
    ) throws -> PlaylistVersion {
        var candidate = self
        try candidate.validate()
        let sourceIndex: Int
        if let itemID {
            guard let index = candidate.items.firstIndex(where: { $0.id == itemID }) else {
                throw PlaylistWorkspaceError.itemNotFound(itemID)
            }
            sourceIndex = index
        } else {
            guard let index = candidate.items.firstIndex(where: { $0.versions.contains(where: { $0.id == versionID }) }) else {
                throw PlaylistWorkspaceError.versionNotFound(versionID)
            }
            sourceIndex = index
        }
        guard let versionIndex = candidate.items[sourceIndex].versions.firstIndex(where: { $0.id == versionID }) else {
            throw PlaylistWorkspaceError.versionNotInItem(versionID: versionID, itemID: candidate.items[sourceIndex].id)
        }

        let sourceItemID = candidate.items[sourceIndex].id
        let removedVersion = candidate.items[sourceIndex].versions[versionIndex]
        let wasListeningVersion = candidate.listeningState?.versionID == versionID
        var source = candidate.items[sourceIndex]
        source.versions.remove(at: versionIndex)
        if source.versions.isEmpty {
            candidate.items.remove(at: sourceIndex)
            if case let .comparison(activeItemID) = candidate.activeView, activeItemID == sourceItemID {
                candidate.activeView = .playlist
            }
            if wasListeningVersion {
                candidate.listeningState = Self.replacementListeningState(
                    in: candidate.items,
                    preferredIndex: sourceIndex
                )
            }
        } else {
            if source.selectedVersionID == versionID {
                source.selectedVersionID = Self.fallbackVersionID(in: source, preferredIndex: versionIndex)
            }
            candidate.items[sourceIndex] = source
            if wasListeningVersion {
                let replacementID = source.selectedVersionID ?? source.versions.first?.id
                if let replacementID {
                    candidate.listeningState = PlaylistListeningState(
                        itemID: sourceItemID,
                        versionID: replacementID,
                        filePosition: 0
                    )
                }
            }
        }

        try candidate.validate()
        self = candidate
        return removedVersion
    }

    private static func validate(version: PlaylistVersion) throws {
        guard version.gainDB.isFinite else { throw PlaylistWorkspaceError.invalidValue("gainDB") }
        guard version.offsetSeconds.isFinite else { throw PlaylistWorkspaceError.invalidValue("offsetSeconds") }
        let metadata = version.metadata
        guard metadata.duration.isFinite, metadata.duration >= 0 else {
            throw PlaylistWorkspaceError.invalidValue("metadata.duration")
        }
        guard metadata.sampleRate.isFinite, metadata.sampleRate >= 0 else {
            throw PlaylistWorkspaceError.invalidValue("metadata.sampleRate")
        }
        guard metadata.bitRate.isFinite, metadata.bitRate >= 0 else {
            throw PlaylistWorkspaceError.invalidValue("metadata.bitRate")
        }
        guard (version.offsetSeconds + metadata.duration).isFinite else {
            throw PlaylistWorkspaceError.invalidValue("offsetSeconds + metadata.duration")
        }
    }

    private static func validate(comparison: PlaylistComparisonConfiguration) throws {
        if let loop = comparison.loopRegion {
            guard loop.start.isFinite, loop.end.isFinite, loop.start < loop.end else {
                throw PlaylistWorkspaceError.invalidValue("comparison.loopRegion")
            }
        }
        if let visibleStart = comparison.visibleStart, !visibleStart.isFinite {
            throw PlaylistWorkspaceError.invalidValue("comparison.visibleStart")
        }
        if let visibleSpan = comparison.visibleSpan,
           (!visibleSpan.isFinite || visibleSpan <= 0) {
            throw PlaylistWorkspaceError.invalidValue("comparison.visibleSpan")
        }
    }

    private static func referenceOffset(for item: PlaylistItem) -> TimeInterval {
        item.selectedVersion?.offsetSeconds ?? 0
    }

    private static func fallbackVersionID(in item: PlaylistItem, preferredIndex: Int) -> UUID? {
        guard !item.versions.isEmpty else { return nil }
        let index = min(max(preferredIndex, 0), item.versions.count - 1)
        return item.versions[index].id
    }

    private static func replacementListeningState(
        in items: [PlaylistItem],
        preferredIndex: Int
    ) -> PlaylistListeningState? {
        guard !items.isEmpty else { return nil }
        let index = min(max(preferredIndex, 0), items.count - 1)
        let item = items[index]
        guard let version = item.selectedVersion ?? item.versions.first else { return nil }
        return PlaylistListeningState(itemID: item.id, versionID: version.id, filePosition: 0)
    }

    private static func defaultTitle(for version: PlaylistVersion) -> String {
        if let title = version.metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if !version.metadata.displayName.isEmpty {
            return version.metadata.displayName
        }
        let fileName = version.file.storedURL.deletingPathExtension().lastPathComponent
        return fileName.isEmpty ? version.file.storedURL.lastPathComponent : fileName
    }
}
