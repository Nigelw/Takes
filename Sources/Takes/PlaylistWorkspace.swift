import Foundation

/// The repeat modes used while the workspace is playing its ordered playlist.
/// Comparison repeat behavior continues to use ``RepeatMode``.
/// Ordered Off → All → One, as the Repeat button cycles and the menu lists
/// them. Stored by raw value, so the order is free to change.
enum PlaylistRepeatMode: String, CaseIterable, Codable, Equatable {
    case off
    case all
    case one

    var next: PlaylistRepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
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

    /// Menu grouping retains the earliest selected item. A drop retains its explicit target.
    /// Append whole source items in supplied order, followed by individually selected versions.
    @discardableResult
    mutating func groupItems(
        _ itemIDs: [PlaylistItem.ID],
        looseVersionIDs: [PlaylistVersion.ID] = [],
        into explicitDestination: PlaylistItem.ID? = nil,
        playingVersionID: PlaylistVersion.ID? = nil
    ) throws -> PlaylistItem.ID {
        let selected = Set(itemIDs)
        guard selected.count == itemIDs.count else { throw PlaylistWorkspaceError.invalidItemOrder }
        let selectedItems = items.filter { selected.contains($0.id) }
        var byID = [UUID: PlaylistItem]()
        for item in selectedItems { byID[item.id] = item }
        let ordered = try itemIDs.map { id in
            guard let item = byID[id] else { throw PlaylistWorkspaceError.itemNotFound(id) }
            return item
        }
        guard let destination = explicitDestination ?? selectedItems.first?.id else {
            throw PlaylistWorkspaceError.noItemsSelected
        }
        let incoming = ordered.filter { $0.id != destination }.flatMap { $0.versions.map(\.id) } + looseVersionIDs
        try transferVersions(incoming, to: destination, before: nil, playingVersionID: playingVersionID,
                             preserveDestinationSelection: true)
        return destination
    }

    mutating func moveVersions(
        _ versionIDs: [UUID], to destination: UUID, before anchor: UUID? = nil, playingVersionID: UUID? = nil
    ) throws {
        try transferVersions(versionIDs, to: destination, before: anchor, playingVersionID: playingVersionID,
                             preserveDestinationSelection: false)
    }

    private mutating func transferVersions(
        _ versionIDs: [UUID], to destinationID: UUID, before anchor: UUID?, playingVersionID: UUID?,
        preserveDestinationSelection: Bool
    ) throws {
        try validate()
        guard var destination = items.first(where: { $0.id == destinationID }) else {
            throw PlaylistWorkspaceError.itemNotFound(destinationID)
        }
        let moving = Set(versionIDs)
        guard moving.count == versionIDs.count else { throw PlaylistWorkspaceError.invalidItemOrder }
        var translated = [UUID: PlaylistVersion]()
        var selectedIncoming = Set<UUID>()
        let destinationOffset = Self.referenceOffset(for: destination)
        var candidate = self
        candidate.items = items.compactMap { source in
            let delta = destinationOffset - Self.referenceOffset(for: source)
            var remaining = source
            remaining.versions.removeAll { version in
                guard moving.contains(version.id) else { return false }
                var copy = version
                copy.offsetSeconds += delta
                translated[version.id] = copy
                return true
            }
            if source.id == destinationID {
                destination.versions = remaining.versions
                return source
            }
            if let selected = source.selectedVersionID, moving.contains(selected),
               let index = source.versions.firstIndex(where: { $0.id == selected }) {
                selectedIncoming.insert(selected)
                remaining.selectedVersionID = source.versions[index...].first { !moving.contains($0.id) }?.id
                    ?? remaining.versions.last?.id
            }
            return remaining.versions.isEmpty ? nil : remaining
        }
        let ordered = try versionIDs.map { id in
            guard let version = translated[id] else {
                throw PlaylistWorkspaceError.versionNotFound(id)
            }
            return version
        }
        let insertion = try anchor.map { id in
            guard let index = destination.versions.firstIndex(where: { $0.id == id }) else {
                throw PlaylistWorkspaceError.versionNotInItem(versionID: id, itemID: destinationID)
            }
            return index
        } ?? destination.versions.endIndex
        destination.versions.insert(contentsOf: ordered, at: insertion)
        if let playingVersionID, destination.versions.contains(where: { $0.id == playingVersionID }) {
            destination.selectedVersionID = playingVersionID
        } else if !preserveDestinationSelection, let selected = versionIDs.last(where: selectedIncoming.contains) {
            destination.selectedVersionID = selected
        }
        destination.selectedVersionID = destination.selectedVersionID ?? destination.versions.first?.id
        guard let index = candidate.items.firstIndex(where: { $0.id == destinationID }) else {
            throw PlaylistWorkspaceError.itemNotFound(destinationID)
        }
        candidate.items[index] = destination
        if case let .comparison(activeID) = activeView, !candidate.items.contains(where: { $0.id == activeID }) {
            candidate.activeView = .comparison(itemID: destinationID)
        }
        if let state = listeningState, moving.contains(state.versionID) {
            candidate.listeningState?.itemID = destinationID
        }
        try candidate.validate()
        self = candidate
    }

    /// The insertion index is relative to the destination after removal.
    mutating func moveVersion(
        _ versionID: PlaylistVersion.ID,
        from sourceItemID: PlaylistItem.ID,
        to destinationItemID: PlaylistItem.ID,
        at destinationIndex: Int? = nil,
        playingVersionID: PlaylistVersion.ID? = nil
    ) throws {
        guard let source = items.first(where: { $0.id == sourceItemID }) else {
            throw PlaylistWorkspaceError.itemNotFound(sourceItemID)
        }
        guard source.versions.contains(where: { $0.id == versionID }) else {
            throw PlaylistWorkspaceError.versionNotInItem(versionID: versionID, itemID: sourceItemID)
        }
        guard let destination = items.first(where: { $0.id == destinationItemID }) else {
            throw PlaylistWorkspaceError.itemNotFound(destinationItemID)
        }
        let remaining = destination.versions.filter { $0.id != versionID }
        let index = destinationIndex ?? remaining.count
        guard (0...remaining.count).contains(index) else { throw PlaylistWorkspaceError.invalidDestinationIndex(index) }
        try moveVersions([versionID], to: destinationItemID, before: index < remaining.count ? remaining[index].id : nil,
                         playingVersionID: playingVersionID)
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

    mutating func reorderVersions(_ orderedIDs: [UUID], in itemID: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            throw PlaylistWorkspaceError.itemNotFound(itemID)
        }
        let versions = items[index].versions
        guard orderedIDs.count == versions.count, Set(orderedIDs) == Set(versions.map(\.id)) else {
            throw PlaylistWorkspaceError.invalidItemOrder
        }
        let byID = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, $0) })
        items[index].versions = orderedIDs.compactMap { byID[$0] }
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
