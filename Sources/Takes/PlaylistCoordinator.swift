import AVFoundation
import Foundation
import Observation

/// The order in which playlist items are visited by the transport.
///
/// This type deliberately has no workspace or audio-runtime dependencies. It
/// owns the listening history used by Shuffle, which means Previous remains
/// useful even after a shuffle cycle has crossed its boundary.
struct PlaylistTraversal {
    typealias ID = PlaylistItem.ID
    typealias ShuffleProvider = ([ID]) -> [ID]

    private(set) var itemIDs: [ID]
    private(set) var shuffleEnabled: Bool
    private(set) var repeatMode: PlaylistRepeatMode
    private(set) var history: [ID] = []
    private(set) var historyIndex: Int = -1
    private(set) var cycle: [ID]
    private var cycleIndex: Int = -1
    private let shuffleProvider: ShuffleProvider

    init(
        itemIDs: [ID],
        shuffleEnabled: Bool = false,
        repeatMode: PlaylistRepeatMode = .off,
        shuffleProvider: @escaping ShuffleProvider = { $0.shuffled() }
    ) {
        self.itemIDs = itemIDs
        self.shuffleEnabled = shuffleEnabled
        self.repeatMode = repeatMode
        self.shuffleProvider = shuffleProvider
        self.cycle = itemIDs
    }

    /// Keep the history that still belongs to the workspace while removing
    /// IDs deleted by an organization operation.
    mutating func updateItemIDs(_ itemIDs: [ID]) {
        self.itemIDs = itemIDs
        let valid = Set(itemIDs)
        let previousHistoryIndex = historyIndex
        let previousCurrentID = history.indices.contains(historyIndex)
            ? history[historyIndex]
            : nil
        history = history.filter(valid.contains)
        if let previousCurrentID,
           let recoveredIndex = history.firstIndex(of: previousCurrentID) {
            historyIndex = recoveredIndex
        } else {
            historyIndex = min(max(previousHistoryIndex, -1), history.count - 1)
        }
        let currentID = history.indices.contains(historyIndex)
            ? history[historyIndex]
            : nil
        cycle = cycle.filter(valid.contains)
        if !shuffleEnabled {
            cycle = itemIDs
            cycleIndex = currentID.flatMap { cycle.firstIndex(of: $0) } ?? -1
        } else if Set(cycle) != valid || cycle.count != itemIDs.count {
            cycle = makeCycle()
            anchorCycle(at: currentID)
        } else if let currentID {
            anchorCycle(at: currentID)
        } else {
            cycleIndex = -1
        }
    }

    mutating func setShuffleEnabled(_ enabled: Bool) {
        guard shuffleEnabled != enabled else { return }
        let currentID = history.indices.contains(historyIndex) ? history[historyIndex] : nil
        shuffleEnabled = enabled
        cycle = makeCycle()
        if enabled {
            anchorCycle(at: currentID)
        } else {
            cycleIndex = currentID.flatMap { cycle.firstIndex(of: $0) } ?? -1
        }
    }

    mutating func setRepeatMode(_ mode: PlaylistRepeatMode) {
        repeatMode = mode
    }

    func hasNext(from currentID: ID?) -> Bool {
        guard !itemIDs.isEmpty else { return false }
        guard let currentID else { return true }
        if history.indices.contains(historyIndex),
           history[historyIndex] == currentID,
           historyIndex + 1 < history.count {
            return true
        }
        if let index = cycle.firstIndex(of: currentID),
           index + 1 < cycle.count {
            return true
        }
        return repeatMode == .all || repeatMode == .one
    }

    func hasPrevious(from currentID: ID?) -> Bool {
        guard history.indices.contains(historyIndex),
              history[historyIndex] == currentID else {
            return false
        }
        return historyIndex > 0
    }

    mutating func reset(currentID: ID? = nil) {
        history.removeAll(keepingCapacity: true)
        historyIndex = -1
        cycle = makeCycle()
        cycleIndex = -1
        if let currentID, itemIDs.contains(currentID) {
            record(currentID)
            if shuffleEnabled {
                anchorCycle(at: currentID)
            } else {
                cycleIndex = cycle.firstIndex(of: currentID) ?? -1
            }
        }
    }

    /// Return the next item after `currentID`, respecting repeat and shuffle.
    /// A nil current ID starts a new traversal at the beginning of the cycle.
    mutating func next(from currentID: ID?, atNaturalEnd: Bool = false) -> ID? {
        guard !itemIDs.isEmpty else { return nil }

        if let currentID,
           atNaturalEnd,
           repeatMode == .one,
           itemIDs.contains(currentID) {
            record(currentID)
            return currentID
        }

        // If Previous moved the history cursor backwards, Next first walks
        // forward through that already-heard history instead of inventing a
        // second path through the same cycle.
        if let currentID,
           history.indices.contains(historyIndex),
           history[historyIndex] == currentID,
           historyIndex + 1 < history.count {
            historyIndex += 1
            cycleIndex = cycle.firstIndex(of: history[historyIndex]) ?? cycleIndex
            return history[historyIndex]
        }

        if let currentID,
           let index = cycle.firstIndex(of: currentID) {
            cycleIndex = index
        } else if cycleIndex < 0 {
            cycleIndex = -1
        }

        let nextIndex = cycleIndex + 1
        if cycle.indices.contains(nextIndex) {
            cycleIndex = nextIndex
            let result = cycle[nextIndex]
            record(result)
            return result
        }

        guard repeatMode == .all || (!atNaturalEnd && repeatMode == .one) else { return nil }
        cycle = makeCycle()
        cycleIndex = cycle.firstIndex(of: currentID ?? UUID()) ?? -1
        // A fresh shuffle cycle is allowed to begin with the previous item;
        // every item is still visited exactly once before another wrap.
        guard let first = cycle.first else { return nil }
        cycleIndex = 0
        record(first)
        return first
    }

    /// Previous follows listening history. At the beginning of history it
    /// returns nil instead of guessing an item the user has not heard.
    mutating func previous(from currentID: ID?) -> ID? {
        guard !itemIDs.isEmpty else { return nil }
        guard history.indices.contains(historyIndex),
              history[historyIndex] == currentID,
              historyIndex > 0 else {
            return nil
        }
        historyIndex -= 1
        let result = history[historyIndex]
        cycleIndex = cycle.firstIndex(of: result) ?? cycleIndex
        return result
    }

    private mutating func record(_ id: ID) {
        guard itemIDs.contains(id) else { return }
        if history.indices.contains(historyIndex), history[historyIndex] == id {
            return
        }
        if historyIndex >= 0, historyIndex + 1 < history.count {
            history.removeSubrange((historyIndex + 1)..<history.count)
        }
        if history.last != id {
            history.append(id)
        }
        historyIndex = history.count - 1
    }

    /// Rotate a fresh cycle so an explicitly selected/current item is the
    /// anchor. This keeps every other item available exactly once before the
    /// next cycle boundary, even when the shuffle provider placed the anchor
    /// in the middle of its result.
    private mutating func anchorCycle(at currentID: ID?) {
        guard let currentID,
              let index = cycle.firstIndex(of: currentID) else {
            cycleIndex = -1
            return
        }
        if index > 0 {
            cycle = Array(cycle[index...]) + Array(cycle[..<index])
        }
        cycleIndex = 0
    }

    private func makeCycle() -> [ID] {
        guard shuffleEnabled else { return itemIDs }
        let proposed = shuffleProvider(itemIDs)
        let valid = Set(itemIDs)
        guard proposed.count == itemIDs.count,
              Set(proposed) == valid else {
            return itemIDs
        }
        return proposed
    }
}

/// Coordinates the persisted playlist value with the one comparison audio
/// runtime. The coordinator is intentionally the only application-level entry
/// point for playlist transport and organization.
@MainActor
@Observable
final class PlaylistCoordinator {
    enum Mode: Equatable {
        case playlist
        case comparison(itemID: PlaylistItem.ID)

        var itemID: PlaylistItem.ID? {
            guard case let .comparison(itemID) = self else { return nil }
            return itemID
        }
    }

    private(set) var workspace: PlaylistWorkspace
    private(set) var mode: Mode
    private(set) var controller: PlaybackController
    private(set) var currentItemID: PlaylistItem.ID?
    private(set) var currentVersionID: PlaylistVersion.ID?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var runtimeContext: PlaylistRuntimeContext?

    /// The current runtime's stable item identity. The controller owns the
    /// callback and only invokes it for a natural end, never for a seek or a
    /// user pause.
    private(set) var runtimeTrackCount = 0

    @ObservationIgnored private let loader: AudioFileLoading
    @ObservationIgnored private var navigationGeneration = 0
    @ObservationIgnored private var importGeneration = 0
    @ObservationIgnored private var loadingOperationCount = 0
    @ObservationIgnored private var traversal: PlaylistTraversal
    @ObservationIgnored private var pendingRuntimeRefreshTask: Task<Void, Never>?

    private struct PlaybackSnapshot {
        var itemID: PlaylistItem.ID?
        var versionID: PlaylistVersion.ID?
        var filePosition: TimeInterval
        var isPlaying: Bool
    }

    init(
        workspace: PlaylistWorkspace = PlaylistWorkspace(),
        controller: PlaybackController? = nil,
        loader: AudioFileLoading = AudioFileLoader()
    ) {
        self.workspace = workspace
        self.loader = loader
        self.controller = controller ?? PlaybackController(loader: loader)
        self.mode = workspace.activeView.itemID.map { .comparison(itemID: $0) } ?? .playlist
        self.currentItemID = workspace.listeningState?.itemID ?? workspace.activeItemID
        self.currentVersionID = workspace.listeningState?.versionID
            ?? workspace.items.first(where: { $0.id == workspace.activeItemID })?.selectedVersionID
        self.traversal = PlaylistTraversal(
            itemIDs: workspace.items.map(\.id),
            shuffleEnabled: workspace.isShuffleEnabled,
            repeatMode: workspace.playlistRepeatMode
        )
        self.traversal.reset(currentID: self.currentItemID)
        self.controller.onPlaybackEnded = { [weak self] context in
            self?.receivedPlaybackEnded(context)
        }
        self.runtimeTrackCount = self.controller.runtimeTrackCount
    }

    deinit {
        pendingRuntimeRefreshTask?.cancel()
    }

    var isPlaying: Bool { controller.session.isPlaying }

    var canPlay: Bool {
        controller.session.isPlayable
            || workspace.items.contains { item in
                guard let version = item.selectedVersion ?? item.versions.first else { return false }
                return version.metadata.duration > 0
            }
    }

    var canNext: Bool {
        guard !workspace.items.isEmpty else { return false }
        if mode.itemID != nil {
            return controller.session.canSwitchPlayback
        }
        let current = currentItemID ?? workspace.listeningState?.itemID
        return traversal.hasNext(from: current)
    }

    var canPrevious: Bool {
        if mode.itemID != nil { return controller.session.canSwitchPlayback }
        let current = currentItemID ?? workspace.listeningState?.itemID
        return traversal.hasPrevious(from: current)
    }

    /// Capture the destination synchronously, before a picker, metadata read,
    /// or provider task can suspend.
    func captureImportDestination() -> PlaylistImportDestination {
        if let itemID = mode.itemID,
           workspace.items.contains(where: { $0.id == itemID }) {
            return .item(itemID)
        }
        return .playlist
    }

    /// Import local URLs into the captured destination. Metadata work is
    /// sequential so supplied order is stable; the destination is checked
    /// again immediately before commit because navigation or Undo may have
    /// changed the workspace while the loader was suspended.
    @discardableResult
    func importFiles(
        _ urls: [URL],
        destination: PlaylistImportDestination,
        isWorkspaceOwned: Bool = false
    ) async -> [PlaylistItem.ID] {
        guard !urls.isEmpty else { return [] }
        let operationGeneration = importGeneration &+ 1
        importGeneration = operationGeneration
        beginLoading()
        defer { endLoading() }

        // Capture any comparison adjustments that the active UI made before
        // the metadata task suspends. The destination remains independent of
        // this runtime snapshot, so a later navigation cannot redirect the
        // import commit.
        captureRuntimeEdits()

        var versions: [PlaylistVersion] = []
        var failures: [String] = []
        for url in urls {
            guard !Task.isCancelled else { return [] }
            do {
                let loaded = try await loader.loadTrackMetadata(from: url)
                versions.append(
                    PlaylistVersion(
                        file: PlaylistWorkspaceStore.makeFileReference(
                            for: url,
                            isWorkspaceOwned: isWorkspaceOwned
                        ),
                        metadata: Self.playlistMetadata(from: loaded)
                    )
                )
            } catch let error as LocalizedError {
                failures.append(error.errorDescription ?? error.localizedDescription)
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        guard !versions.isEmpty else {
            if operationGeneration == importGeneration, !failures.isEmpty {
                reportError(failures.joined(separator: "\n"))
            }
            return []
        }

        // A newer operation does not redirect this operation to another
        // destination. It only makes its commit use the latest workspace value.
        // The operation token is retained for diagnostics and the cancellation
        // check above is the only condition that may discard its content; two
        // imports captured for different destinations are independent.
        _ = operationGeneration

        // The user may have changed gain, blind-listening state, or playback
        // while metadata was loading. Capture those edits and the transport
        // state at the commit boundary rather than resuming an old snapshot.
        captureRuntimeEdits()
        let destinationItemID: PlaylistItem.ID? = {
            guard case let .item(itemID) = destination else { return nil }
            return itemID
        }()
        let wasComparisonDestination = mode.itemID != nil && mode.itemID == destinationItemID
        let playbackBeforeCommit = wasComparisonDestination ? capturePlaybackSnapshot() : nil
        do {
            var acceptedVersions: [PlaylistVersion] = []
            var seenFiles = Set(workspace.allVersions.map(canonicalFileKey))
            for version in versions {
                guard seenFiles.insert(canonicalFileKey(version)).inserted else {
                    failures.append(PlaylistWorkspaceError.duplicateFile(version.file.canonicalURL).localizedDescription)
                    continue
                }
                acceptedVersions.append(version)
            }
            guard !acceptedVersions.isEmpty else {
                if operationGeneration == importGeneration {
                    reportError(failures.joined(separator: "\n"))
                }
                return []
            }

            let newItemIDs: [PlaylistItem.ID]
            switch destination {
            case .playlist:
                newItemIDs = try workspace.appendSeparateItems(acceptedVersions)
            case let .item(itemID):
                newItemIDs = try appendVersions(acceptedVersions, to: itemID)
            }

            // Import callers can wrap this operation in their own Undo
            // transaction. The coordinator has no manager at this boundary.
            rebuildTraversal()

            if wasComparisonDestination,
               let playbackBeforeCommit,
               mode.itemID == destinationItemID,
               let destinationItemID {
                scheduleRuntimeRefresh(
                    mode: .comparison(itemID: destinationItemID),
                    snapshot: playbackBeforeCommit,
                    generation: navigationGeneration,
                    autoAlignAfterActivation: true
                )
            }
            if operationGeneration == importGeneration, !failures.isEmpty {
                reportError(failures.joined(separator: "\n"))
            } else if operationGeneration == importGeneration {
                clearError()
            }
            return newItemIDs
        } catch {
            if operationGeneration == importGeneration, !failures.isEmpty {
                reportError((failures + [error.localizedDescription]).joined(separator: "\n"))
            } else if operationGeneration == importGeneration {
                reportError(error.localizedDescription)
            }
            return []
        }
    }

    /// Convenience entry point for callers that do not have a picker task.
    /// The destination is still captured before the first suspension.
    @discardableResult
    func importFiles(
        _ urls: [URL],
        isWorkspaceOwned: Bool = false
    ) async -> [PlaylistItem.ID] {
        let destination = captureImportDestination()
        return await importFiles(urls, destination: destination, isWorkspaceOwned: isWorkspaceOwned)
    }

    /// Start the selected item from its saved file position, or from the
    /// beginning when it has no saved position. Explicit item activation always
    /// starts playback.
    func playItem(id itemID: PlaylistItem.ID, versionID: PlaylistVersion.ID? = nil) async {
        let targetVersionID: UUID
        guard let item = workspace.items.first(where: { $0.id == itemID }) else {
            reportError(PlaylistWorkspaceError.itemNotFound(itemID).localizedDescription)
            return
        }
        if let versionID {
            guard item.versions.contains(where: { $0.id == versionID }) else {
                reportError(PlaylistWorkspaceError.versionNotInItem(versionID: versionID, itemID: itemID).localizedDescription)
                return
            }
            targetVersionID = versionID
        } else {
            guard let selected = item.selectedVersion?.id ?? item.versions.first?.id else {
                reportError(PlaylistWorkspaceError.emptyItem(itemID).localizedDescription)
                return
            }
            targetVersionID = selected
        }

        captureRuntimeEdits()
        traversal.reset(currentID: itemID)
        let savedPosition = workspace.listeningState.flatMap { state in
            state.itemID == itemID && state.versionID == targetVersionID ? state.filePosition : nil
        } ?? 0
        if let index = workspace.items.firstIndex(where: { $0.id == itemID }) {
            workspace.items[index].selectedVersionID = targetVersionID
        }
        let snapshot = PlaybackSnapshot(
            itemID: itemID,
            versionID: targetVersionID,
            filePosition: savedPosition,
            isPlaying: true
        )
        await activatePlaylist(itemID: itemID, versionID: targetVersionID, snapshot: snapshot)
    }

    /// Enter the current item's comparison view. The playing item preserves
    /// file time and version; another item begins at its timeline start while
    /// retaining the current playing/paused state.
    func enterComparison(itemID: PlaylistItem.ID) async {
        guard workspace.items.contains(where: { $0.id == itemID }) else {
            reportError(PlaylistWorkspaceError.itemNotFound(itemID).localizedDescription)
            return
        }

        let oldSnapshot = capturePlaybackSnapshot()
        captureRuntimeEdits()
        guard let item = workspace.items.first(where: { $0.id == itemID }) else {
            reportError(PlaylistWorkspaceError.itemNotFound(itemID).localizedDescription)
            return
        }
        let sameItem = oldSnapshot.itemID == itemID
        let versionID = (sameItem ? oldSnapshot.versionID : nil)
            .flatMap { id in item.versions.contains(where: { $0.id == id }) ? id : nil }
            ?? item.selectedVersion?.id
            ?? item.versions.first?.id
        guard let versionID else {
            reportError(PlaylistWorkspaceError.emptyItem(itemID).localizedDescription)
            return
        }
        let snapshot = PlaybackSnapshot(
            itemID: itemID,
            versionID: versionID,
            filePosition: sameItem ? oldSnapshot.filePosition : 0,
            isPlaying: oldSnapshot.isPlaying
        )
        await activateComparison(
            itemID: itemID,
            versionID: versionID,
            snapshot: snapshot,
            startAtTimelineBeginning: !sameItem
        )
    }

    /// Return to playlist playback while preserving the version being
    /// auditioned and translating comparison transport back to file time.
    func backToPlaylist() async {
        let snapshot = capturePlaybackSnapshot()
        captureRuntimeEdits()
        let targetItemID = snapshot.itemID ?? currentItemID ?? workspace.listeningState?.itemID
        guard let targetItemID,
              let item = workspace.items.first(where: { $0.id == targetItemID }) else {
            let generation = beginNavigation()
            controller.invalidateRuntimeContext()
            runtimeContext = nil
            runtimeTrackCount = controller.runtimeTrackCount
            mode = .playlist
            workspace.activeView = .playlist
            currentItemID = nil
            currentVersionID = nil
            if generation == navigationGeneration { clearError() }
            return
        }
        let versionID = snapshot.versionID
            .flatMap { id in item.versions.contains(where: { $0.id == id }) ? id : nil }
            ?? item.selectedVersion?.id
            ?? item.versions.first?.id
        guard let versionID else { return }
        let filePosition = item.versions.first(where: { $0.id == versionID }).map {
            snapshot.itemID == targetItemID
                ? PlaylistPlaybackBoundary.filePosition(transport: controller.displayTransportPosition(), version: $0)
                : workspace.listeningState?.filePosition ?? 0
        } ?? 0
        let nextSnapshot = PlaybackSnapshot(
            itemID: targetItemID,
            versionID: versionID,
            filePosition: filePosition,
            isPlaying: snapshot.isPlaying
        )
        await activatePlaylist(itemID: targetItemID, versionID: versionID, snapshot: nextSnapshot)
    }

    /// Select the version used for playlist playback or, when the item is the
    /// active comparison, replace the runtime at the same file position.
    func selectPlaybackVersion(_ versionID: PlaylistVersion.ID, in itemID: PlaylistItem.ID) async {
        guard let item = workspace.items.first(where: { $0.id == itemID }) else {
            reportError(PlaylistWorkspaceError.itemNotFound(itemID).localizedDescription)
            return
        }
        guard item.versions.contains(where: { $0.id == versionID }) else {
            reportError(PlaylistWorkspaceError.versionNotInItem(versionID: versionID, itemID: itemID).localizedDescription)
            return
        }

        let oldSnapshot = capturePlaybackSnapshot()
        captureRuntimeEdits()
        guard let index = workspace.items.firstIndex(where: { $0.id == itemID }) else { return }
        workspace.items[index].selectedVersionID = versionID

        let isActiveComparisonItem = mode.itemID == itemID
        let isActivePlaylistItem = mode == .playlist
            && currentItemID == itemID
            && runtimeContext?.itemID == itemID
        if isActiveComparisonItem || isActivePlaylistItem {
            let snapshot = PlaybackSnapshot(
                itemID: itemID,
                versionID: versionID,
                filePosition: oldSnapshot.itemID == itemID ? oldSnapshot.filePosition : 0,
                isPlaying: oldSnapshot.isPlaying
            )
            if isActiveComparisonItem {
                await activateComparison(itemID: itemID, versionID: versionID, snapshot: snapshot)
            } else {
                await activatePlaylist(itemID: itemID, versionID: versionID, snapshot: snapshot)
            }
        } else if mode == .playlist, currentItemID == itemID {
            currentVersionID = versionID
        } else if currentItemID == nil {
            currentItemID = itemID
            currentVersionID = versionID
        }
        clearError()
    }

    func play() {
        let runtimeBelongsToCurrentMode = mode.itemID != nil
            ? runtimeContext?.itemID == mode.itemID
            : runtimeContext?.itemID == currentItemID
        if controller.session.isPlayable, runtimeBelongsToCurrentMode {
            controller.play()
            updateListeningStateFromRuntime()
            return
        }
        guard let itemID = currentItemID ?? workspace.items.first?.id else { return }
        let versionID = currentVersionID
            ?? workspace.items.first(where: { $0.id == itemID })?.selectedVersion?.id
        Task { await playItem(id: itemID, versionID: versionID) }
    }

    func pause() {
        guard controller.session.isPlaying else { return }
        controller.pause()
        updateListeningStateFromRuntime()
    }

    func togglePlayback() {
        if controller.session.isPlaying { pause() } else { play() }
    }

    func jumpToBeginning() {
        seek(to: mode.itemID == nil ? 0 : controller.session.playbackStart)
    }

    func jumpToEnd() {
        seek(to: mode.itemID == nil ? currentVersion()?.metadata.duration ?? 0 : controller.session.playbackEnd)
    }

    /// Playlist seek values are file seconds. Comparison seek values are the
    /// existing signed timeline seconds.
    func seek(to seconds: TimeInterval) {
        controller.seek(to: seconds)
        updateListeningStateFromRuntime()
    }

    func skip(by delta: TimeInterval) {
        if mode.itemID == nil {
            guard let version = currentVersion() else { return }
            let position = min(
                max(controller.displayTransportPosition(), 0),
                version.metadata.duration
            )
            seek(to: position + delta)
        } else {
            controller.skip(by: delta)
            updateListeningStateFromRuntime()
        }
    }

    func next() {
        if mode.itemID != nil {
            controller.selectNextTrack()
            currentVersionID = controller.session.activeTrackID
            updateListeningStateFromRuntime()
            return
        }
        let current = currentItemID ?? workspace.listeningState?.itemID
        guard let nextID = traversal.next(from: current) else { return }
        let wasPlaying = controller.session.isPlaying
        let versionID = workspace.items.first(where: { $0.id == nextID })?.selectedVersion?.id
        guard let versionID else { return }
        let snapshot = PlaybackSnapshot(itemID: nextID, versionID: versionID, filePosition: 0, isPlaying: wasPlaying)
        enqueuePlaylistActivation(itemID: nextID, versionID: versionID, snapshot: snapshot)
    }

    func previous() {
        if mode.itemID != nil {
            controller.selectPreviousTrack()
            currentVersionID = controller.session.activeTrackID
            updateListeningStateFromRuntime()
            return
        }
        let current = currentItemID ?? workspace.listeningState?.itemID
        guard let previousID = traversal.previous(from: current) else { return }
        let wasPlaying = controller.session.isPlaying
        let versionID = workspace.items.first(where: { $0.id == previousID })?.selectedVersion?.id
        guard let versionID else { return }
        let snapshot = PlaybackSnapshot(itemID: previousID, versionID: versionID, filePosition: 0, isPlaying: wasPlaying)
        enqueuePlaylistActivation(itemID: previousID, versionID: versionID, snapshot: snapshot)
    }

    func setPlaylistRepeatMode(_ mode: PlaylistRepeatMode) {
        workspace.playlistRepeatMode = mode
        traversal.setRepeatMode(mode)
    }

    func cyclePlaylistRepeatMode() {
        setPlaylistRepeatMode(workspace.playlistRepeatMode.next)
    }

    func setShuffleEnabled(_ enabled: Bool) {
        workspace.isShuffleEnabled = enabled
        traversal.setShuffleEnabled(enabled)
    }

    func toggleShuffle() {
        setShuffleEnabled(!workspace.isShuffleEnabled)
    }

    // MARK: - Organization

    @discardableResult
    func groupItems(
        _ itemIDs: [PlaylistItem.ID],
        compare: Bool = false,
        undoManager: UndoManager? = nil
    ) async -> PlaylistItem.ID? {
        let snapshot = capturePlaybackSnapshot()
        captureRuntimeEdits()
        let before = workspace
        do {
            let playingID = snapshot.isPlaying ? snapshot.versionID : nil
            let resultID = try workspace.groupItems(itemIDs, playingVersionID: playingID)
            registerUndo(before: before, undoManager: undoManager, actionName: "Group Items")
            rebuildTraversal()
            clearError()
            beginNavigation()
            await refreshAfterOrganization(snapshot: snapshot)
            if compare { await enterComparison(itemID: resultID) }
            return resultID
        } catch {
            reportError(error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    func renameItem(
        _ itemID: PlaylistItem.ID,
        to title: String,
        undoManager: UndoManager? = nil
    ) -> Bool {
        mutateWorkspace(beforeAction: "Rename Item", undoManager: undoManager) {
            try $0.renameItem(itemID, to: title)
        }
    }

    @discardableResult
    func reorderItems(
        _ orderedItemIDs: [PlaylistItem.ID],
        undoManager: UndoManager? = nil
    ) -> Bool {
        mutateWorkspace(beforeAction: "Reorder Items", undoManager: undoManager) {
            try $0.reorderItems(orderedItemIDs)
        }
    }

    @discardableResult
    func reorderItems(
        fromOffsets offsets: IndexSet,
        toOffset destinationOffset: Int,
        undoManager: UndoManager? = nil
    ) -> Bool {
        mutateWorkspace(beforeAction: "Reorder Items", undoManager: undoManager) {
            try $0.reorderItems(fromOffsets: offsets, toOffset: destinationOffset)
        }
    }

    @discardableResult
    func moveVersion(
        _ versionID: PlaylistVersion.ID,
        from sourceItemID: PlaylistItem.ID,
        to destinationItemID: PlaylistItem.ID,
        at destinationIndex: Int? = nil,
        undoManager: UndoManager? = nil
    ) -> Bool {
        let playingID = controller.session.isPlaying ? currentVersionID : nil
        return mutateWorkspace(beforeAction: "Move Version", undoManager: undoManager) {
            try $0.moveVersion(
                versionID,
                from: sourceItemID,
                to: destinationItemID,
                at: destinationIndex,
                playingVersionID: playingID
            )
        }
    }

    /// Reorder a version within its item by stable ID. Passing nil places it at
    /// the end. The operation follows persisted version order and therefore
    /// cannot accidentally persist blind-listening runtime order.
    @discardableResult
    func reorderVersion(
        _ versionID: PlaylistVersion.ID,
        before destinationVersionID: PlaylistVersion.ID?,
        undoManager: UndoManager? = nil
    ) -> Bool {
        guard let item = workspace.items.first(where: { item in
            item.versions.contains(where: { $0.id == versionID })
        }) else {
            reportError(PlaylistWorkspaceError.versionNotFound(versionID).localizedDescription)
            return false
        }
        let destinationIndex: Int?
        if let destinationVersionID {
            guard let index = item.versions.firstIndex(where: { $0.id == destinationVersionID }) else {
                reportError(PlaylistWorkspaceError.versionNotFound(destinationVersionID).localizedDescription)
                return false
            }
            let sourceIndex = item.versions.firstIndex(where: { $0.id == versionID })!
            destinationIndex = sourceIndex < index ? index - 1 : index
        } else {
            destinationIndex = nil
        }
        return mutateWorkspace(beforeAction: "Reorder Versions", undoManager: undoManager) {
            try $0.moveVersion(
                versionID,
                from: item.id,
                to: item.id,
                at: destinationIndex,
                playingVersionID: self.controller.session.isPlaying ? self.currentVersionID : nil
            )
        }
    }

    @discardableResult
    func moveVersion(
        _ versionID: PlaylistVersion.ID,
        to destinationItemID: PlaylistItem.ID,
        at destinationIndex: Int? = nil,
        undoManager: UndoManager? = nil
    ) -> Bool {
        let playingID = controller.session.isPlaying ? currentVersionID : nil
        return mutateWorkspace(beforeAction: "Move Version", undoManager: undoManager) {
            try $0.moveVersion(
                versionID,
                to: destinationItemID,
                at: destinationIndex,
                playingVersionID: playingID
            )
        }
    }

    @discardableResult
    func separateVersion(
        _ versionID: PlaylistVersion.ID,
        from itemID: PlaylistItem.ID? = nil,
        undoManager: UndoManager? = nil
    ) -> PlaylistItem.ID? {
        let playingID = controller.session.isPlaying ? currentVersionID : nil
        var result: PlaylistItem.ID?
        let succeeded = mutateWorkspace(beforeAction: "Separate Version", undoManager: undoManager) {
            result = try $0.separateVersion(versionID, from: itemID, playingVersionID: playingID)
        }
        return succeeded ? result : nil
    }

    @discardableResult
    func removeItem(_ itemID: PlaylistItem.ID, undoManager: UndoManager? = nil) -> Bool {
        mutateWorkspace(beforeAction: "Remove Item", undoManager: undoManager) {
            _ = try $0.removeItem(itemID)
        }
    }

    @discardableResult
    func removeItems(_ itemIDs: [PlaylistItem.ID], undoManager: UndoManager? = nil) -> Bool {
        mutateWorkspace(beforeAction: "Remove Items", undoManager: undoManager) {
            _ = try $0.removeItems(itemIDs)
        }
    }

    @discardableResult
    func removeVersion(
        _ versionID: PlaylistVersion.ID,
        from itemID: PlaylistItem.ID? = nil,
        undoManager: UndoManager? = nil
    ) -> Bool {
        mutateWorkspace(beforeAction: "Remove Version", undoManager: undoManager) {
            _ = try $0.removeVersion(versionID, from: itemID)
        }
    }

    /// Remove several versions in one atomic workspace mutation and one Undo
    /// transaction. IDs are resolved against the candidate value so a missing
    /// ID leaves every requested change unapplied.
    @discardableResult
    func removeVersions(
        _ versionIDs: [PlaylistVersion.ID],
        undoManager: UndoManager? = nil
    ) -> Bool {
        guard !versionIDs.isEmpty else { return false }
        return mutateWorkspace(beforeAction: "Remove Versions", undoManager: undoManager) {
            var seen = Set<PlaylistVersion.ID>()
            for versionID in versionIDs {
                guard seen.insert(versionID).inserted else {
                    throw PlaylistWorkspaceError.invalidItemOrder
                }
                _ = try $0.removeVersion(versionID)
            }
        }
    }

    @discardableResult
    func clearPlaylist(undoManager: UndoManager? = nil) -> Bool {
        guard !workspace.items.isEmpty else { return false }
        let snapshot = capturePlaybackSnapshot()
        captureRuntimeEdits()
        let before = workspace
        workspace.items.removeAll()
        workspace.activeView = .playlist
        workspace.listeningState = nil
        registerUndo(before: before, undoManager: undoManager, actionName: "Clear Playlist")
        rebuildTraversal()
        beginNavigation()
        controller.invalidateRuntimeContext()
        runtimeContext = nil
        runtimeTrackCount = controller.runtimeTrackCount
        mode = .playlist
        currentItemID = nil
        currentVersionID = nil
        if snapshot.isPlaying { controller.pause() }
        clearError()
        return true
    }

    @discardableResult
    func clear(undoManager: UndoManager? = nil) -> Bool {
        clearPlaylist(undoManager: undoManager)
    }

    // MARK: - Comparison wrappers

    func setRepeatMode(_ mode: RepeatMode) {
        controller.setRepeatMode(mode)
        captureRuntimeEdits()
    }

    func cycleRepeatMode() {
        controller.cycleRepeatMode()
        captureRuntimeEdits()
    }

    func setBlindListeningMode(_ enabled: Bool) {
        controller.setBlindListeningMode(enabled)
        captureRuntimeEdits()
    }

    func toggleBlindListeningMode() {
        controller.toggleBlindListeningMode()
        captureRuntimeEdits()
    }

    func setGain(_ versionID: PlaylistVersion.ID, db: Float) {
        controller.setGain(versionID, db: db)
        captureRuntimeEdits()
    }

    func setOffset(_ versionID: PlaylistVersion.ID, seconds: TimeInterval) {
        controller.setOffset(versionID, seconds: seconds)
        captureRuntimeEdits()
    }

    func beginLoop(_ region: LoopRegion) {
        controller.beginLoop(region)
        captureRuntimeEdits()
    }

    func deselectLoop() {
        controller.deselectLoop()
        captureRuntimeEdits()
    }

    // MARK: - Restoration and persistence hooks

    /// Restore a validated value. Runtime preparation failures leave the full
    /// workspace intact so unavailable files can be repaired later.
    func restoreWorkspace(_ restored: PlaylistWorkspace) async throws {
        try restored.validate()
        beginNavigation()
        controller.invalidateRuntimeContext()
        runtimeContext = nil
        runtimeTrackCount = controller.runtimeTrackCount
        workspace = restored
        mode = restored.activeView.itemID.map { .comparison(itemID: $0) } ?? .playlist
        currentItemID = restored.listeningState?.itemID ?? restored.activeItemID
        currentVersionID = restored.listeningState?.versionID
            ?? restored.items.first(where: { $0.id == restored.activeItemID })?.selectedVersion?.id
        traversal = PlaylistTraversal(
            itemIDs: restored.items.map(\.id),
            shuffleEnabled: restored.isShuffleEnabled,
            repeatMode: restored.playlistRepeatMode
        )
        traversal.reset(currentID: currentItemID)
        clearError()

        let activeItemID = restored.activeItemID
        guard let currentItemID = activeItemID ?? restored.listeningState?.itemID,
              let item = workspace.items.first(where: { $0.id == currentItemID }) else {
            return
        }
        let versionID = currentVersionID ?? item.selectedVersion?.id ?? item.versions.first?.id
        guard let versionID else { return }
        let filePosition = restored.listeningState?.itemID == item.id
            && restored.listeningState?.versionID == versionID
            ? restored.listeningState?.filePosition ?? 0
            : 0
        let snapshot = PlaybackSnapshot(itemID: item.id, versionID: versionID, filePosition: filePosition, isPlaying: false)
        if restored.activeItemID == item.id {
            await activateComparison(itemID: item.id, versionID: versionID, snapshot: snapshot)
        } else {
            await activatePlaylist(itemID: item.id, versionID: versionID, snapshot: snapshot)
        }
        controller.pause()
        workspace.activeView = restored.activeView
    }

    /// Return the workspace's persisted representation. It captures anchors
    /// and comparison edits at this explicit event; it never runs per frame.
    func snapshotForPersistence() -> PlaylistWorkspace {
        var snapshot = workspace
        _ = captureRuntimeEdits(into: &snapshot)
        return snapshot
    }

    func reportError(_ message: String) {
        errorMessage = message
    }

    func clearError() {
        errorMessage = nil
    }

    /// Replace a missing version's file reference while retaining its stable
    /// version ID. The complete candidate is validated before committing, so
    /// a located file can never introduce a canonical duplicate.
    func locateFile(versionID: PlaylistVersion.ID, url: URL) async {
        guard url.isFileURL else {
            reportError(PlaylistWorkspaceError.invalidValue("file.storedURL").localizedDescription)
            return
        }
        guard workspace.items.contains(where: { item in
            item.versions.contains(where: { $0.id == versionID })
        }) else {
            reportError(PlaylistWorkspaceError.versionNotFound(versionID).localizedDescription)
            return
        }
        let operationGeneration = navigationGeneration
        do {
            let loaded = try await loader.loadTrackMetadata(from: url)
            guard let currentItemIndex = workspace.items.firstIndex(where: { item in
                item.versions.contains(where: { $0.id == versionID })
            }),
                  let currentVersionIndex = workspace.items[currentItemIndex].versions.firstIndex(where: { $0.id == versionID }) else {
                reportError(PlaylistWorkspaceError.versionNotFound(versionID).localizedDescription)
                return
            }
            var candidate = workspace
            let replacementCanonicalURL = PlaylistFileReference.canonicalURL(for: url)
            let replacementCanonical = replacementCanonicalURL.absoluteString
            guard !candidate.allVersions.contains(where: { version in
                version.id != versionID && canonicalFileKey(version) == replacementCanonical
            }) else {
                reportError(PlaylistWorkspaceError.duplicateFile(replacementCanonicalURL).localizedDescription)
                return
            }
            candidate.items[currentItemIndex].versions[currentVersionIndex].file = PlaylistWorkspaceStore.makeFileReference(
                for: url,
                // Locating is a user-selected original, even when the missing
                // reference happened to point at a retained download.
                isWorkspaceOwned: false
            )
            candidate.items[currentItemIndex].versions[currentVersionIndex].metadata = Self.playlistMetadata(from: loaded)
            if var listening = candidate.listeningState, listening.versionID == versionID {
                listening.filePosition = min(max(listening.filePosition, 0), loaded.duration)
                candidate.listeningState = listening
            }
            try candidate.validate()
            workspace = candidate
            clearError()
            if operationGeneration == navigationGeneration,
               currentVersionID == versionID,
               let itemID = candidate.items.first(where: { item in
                   item.versions.contains(where: { $0.id == versionID })
               })?.id {
                currentItemID = itemID
                let snapshot = PlaybackSnapshot(
                    itemID: itemID,
                    versionID: versionID,
                    filePosition: workspace.listeningState?.filePosition ?? 0,
                    isPlaying: controller.session.isPlaying
                )
                if mode.itemID == itemID {
                    await activateComparison(itemID: itemID, versionID: versionID, snapshot: snapshot)
                } else if mode == .playlist {
                    await activatePlaylist(itemID: itemID, versionID: versionID, snapshot: snapshot)
                }
            }
        } catch {
            reportError(error.localizedDescription)
        }
    }

    // MARK: - Runtime activation

    private func activatePlaylist(
        itemID: PlaylistItem.ID,
        versionID: PlaylistVersion.ID,
        snapshot: PlaybackSnapshot
    ) async {
        guard let item = workspace.items.first(where: { $0.id == itemID }),
              let version = item.versions.first(where: { $0.id == versionID }) else {
            reportError(PlaylistWorkspaceError.versionNotInItem(versionID: versionID, itemID: itemID).localizedDescription)
            return
        }
        let generation = beginNavigation()
        let context = PlaylistRuntimeContext(itemID: itemID)
        guard let resolvedURL = resolvedURL(for: version) else { return }
        let loaded = playlistLoadedTrack(for: version, url: resolvedURL)
        let session = ComparisonSession(
            tracks: [SessionTrack(id: version.id, loadedTrack: loaded)],
            activeTrackID: version.id,
            isPlaying: false,
            transportPosition: min(max(snapshot.filePosition, 0), version.metadata.duration),
            timelineStart: 0,
            timelineEnd: version.metadata.duration,
            repeatMode: .off,
            isBlindListeningModeEnabled: false,
            loopRegion: nil
        )
        do {
            try await controller.replaceRuntimeSession(session, context: context)
            guard generation == navigationGeneration else {
                if controller.runtimeContext == context {
                    controller.invalidateRuntimeContext()
                }
                return
            }
            runtimeContext = context
            runtimeTrackCount = controller.runtimeTrackCount
            mode = .playlist
            workspace.activeView = .playlist
            currentItemID = itemID
            currentVersionID = versionID
            if snapshot.isPlaying { controller.play() }
            updateListeningStateFromRuntime()
            clearError()
        } catch {
            if generation == navigationGeneration { reportError(error.localizedDescription) }
        }
    }

    private func activateComparison(
        itemID: PlaylistItem.ID,
        versionID: PlaylistVersion.ID,
        snapshot: PlaybackSnapshot,
        autoAlignAfterActivation: Bool = false,
        startAtTimelineBeginning: Bool = false
    ) async {
        guard let item = workspace.items.first(where: { $0.id == itemID }) else {
            reportError(PlaylistWorkspaceError.itemNotFound(itemID).localizedDescription)
            return
        }
        let generation = beginNavigation()
        let context = PlaylistRuntimeContext(itemID: itemID)
        guard let runtimeItem = materializedComparisonItem(item) else { return }
        var session = PlaylistPlaybackBoundary.session(
            for: runtimeItem,
            incomingVersionID: versionID,
            incomingFilePosition: startAtTimelineBeginning ? nil : snapshot.filePosition,
            isPlaying: false
        )
        if item.comparison.isBlindListeningModeEnabled {
            let incomingActiveID = session.activeTrackID
            session.tracks = PlaybackController.blindListeningOrder(
                currentTracks: session.tracks,
                shuffledTracks: session.tracks.shuffled()
            )
            session.activeTrackID = incomingActiveID.flatMap { activeID in
                session.tracks.contains(where: { $0.id == activeID }) ? activeID : nil
            } ?? session.tracks.first?.id
        }
        do {
            try await controller.replaceRuntimeSession(session, context: context)
            guard generation == navigationGeneration else {
                if controller.runtimeContext == context {
                    controller.invalidateRuntimeContext()
                }
                return
            }
            runtimeContext = context
            runtimeTrackCount = controller.runtimeTrackCount
            mode = .comparison(itemID: itemID)
            workspace.activeView = .comparison(itemID: itemID)
            currentItemID = itemID
            currentVersionID = session.activeTrackID
            if let span = item.comparison.visibleSpan, span > 0 {
                controller.zoomVisibleSpan(to: span)
                if let start = item.comparison.visibleStart {
                    controller.scrollTimeline(toVisibleStart: start)
                }
            }
            if snapshot.isPlaying { controller.play() }
            updateListeningStateFromRuntime()
            if autoAlignAfterActivation, controller.settings?.alignTracksOnOpen == true {
                controller.autoAlignTracks()
            }
            clearError()
        } catch {
            if generation == navigationGeneration { reportError(error.localizedDescription) }
        }
    }

    private func scheduleRuntimeRefresh(
        mode targetMode: Mode,
        snapshot: PlaybackSnapshot,
        generation: Int,
        autoAlignAfterActivation: Bool = false
    ) {
        pendingRuntimeRefreshTask?.cancel()
        pendingRuntimeRefreshTask = Task { [weak self] in
            guard let self else { return }
            guard generation == self.navigationGeneration else { return }
            self.pendingRuntimeRefreshTask = nil
            switch targetMode {
            case .playlist:
                guard let itemID = snapshot.itemID, let versionID = snapshot.versionID else { return }
                await self.activatePlaylist(itemID: itemID, versionID: versionID, snapshot: snapshot)
            case let .comparison(itemID):
                guard let versionID = snapshot.versionID else { return }
                await self.activateComparison(
                    itemID: itemID,
                    versionID: versionID,
                    snapshot: snapshot,
                    autoAlignAfterActivation: autoAlignAfterActivation
                )
            }
        }
    }

    private func enqueuePlaylistActivation(
        itemID: PlaylistItem.ID,
        versionID: PlaylistVersion.ID,
        snapshot: PlaybackSnapshot
    ) {
        let generation = navigationGeneration
        let expectedContext = runtimeContext
        Task { [weak self] in
            guard let self,
                  self.navigationGeneration == generation,
                  self.runtimeContext == expectedContext,
                  self.mode.itemID == nil else { return }
            await self.activatePlaylist(itemID: itemID, versionID: versionID, snapshot: snapshot)
        }
    }

    private func refreshAfterOrganization(snapshot: PlaybackSnapshot) async {
        synchronizeModeWithWorkspaceView()
        let owner = snapshot.versionID.flatMap { versionID in
            workspace.items.first { item in item.versions.contains { $0.id == versionID } }
        }
        let item = owner
            ?? snapshot.itemID.flatMap { itemID in workspace.items.first { $0.id == itemID } }
            ?? workspace.listeningState.flatMap { state in workspace.items.first { $0.id == state.itemID } }
        guard let item else {
            currentItemID = nil
            currentVersionID = nil
            controller.invalidateRuntimeContext()
            runtimeContext = nil
            runtimeTrackCount = controller.runtimeTrackCount
            mode = .playlist
            workspace.activeView = .playlist
            return
        }
        let versionID = snapshot.versionID.flatMap { id in item.versions.contains(where: { $0.id == id }) ? id : nil }
            ?? workspace.listeningState.flatMap { state in item.versions.contains(where: { $0.id == state.versionID }) ? state.versionID : nil }
            ?? item.selectedVersion?.id
        guard let versionID else {
            currentItemID = item.id
            currentVersionID = nil
            if snapshot.isPlaying { controller.pause() }
            return
        }
        let versionWasRemoved = snapshot.versionID != nil && snapshot.versionID != versionID
        let refreshed = PlaybackSnapshot(
            itemID: item.id,
            versionID: versionID,
            filePosition: versionWasRemoved ? 0 : snapshot.filePosition,
            isPlaying: versionWasRemoved ? false : snapshot.isPlaying
        )
        switch mode {
        case .playlist:
            await activatePlaylist(itemID: item.id, versionID: versionID, snapshot: refreshed)
        case .comparison:
            await activateComparison(itemID: item.id, versionID: versionID, snapshot: refreshed)
        }
    }

    private func receivedPlaybackEnded(_ context: PlaylistRuntimeContext?) {
        guard let context,
              context == runtimeContext else { return }
        guard mode.itemID == nil else {
            captureRuntimeEdits()
            return
        }
        updateListeningStateFromRuntime()
        let current = currentItemID
        let repeatMode = workspace.playlistRepeatMode
        guard let current else { return }
        let generation = navigationGeneration
        let expectedContext = runtimeContext
        Task { [weak self] in
            guard let self else { return }
            var expectedGeneration = generation
            var candidate: UUID?
            var skippedMessages: [String] = []
            guard self.navigationGeneration == expectedGeneration,
                  self.runtimeContext == expectedContext,
                  self.mode.itemID == nil else { return }
            switch repeatMode {
            case .one, .off, .all:
                candidate = self.traversal.next(from: current, atNaturalEnd: true)
            }
            for _ in 0..<max(1, self.workspace.items.count) {
                guard self.navigationGeneration == expectedGeneration,
                      self.runtimeContext == expectedContext,
                      self.mode.itemID == nil else { return }
                guard let nextID = candidate else {
                    if !skippedMessages.isEmpty {
                        self.reportError(skippedMessages.joined(separator: "\n"))
                    }
                    return
                }
                guard let versionID = self.workspace.items.first(where: { $0.id == nextID })?.selectedVersion?.id else {
                    skippedMessages.append("No playable version is available for playlist item \(nextID.uuidString).")
                    candidate = self.traversal.next(from: nextID, atNaturalEnd: true)
                    continue
                }
                let snapshot = PlaybackSnapshot(itemID: nextID, versionID: versionID, filePosition: 0, isPlaying: true)
                let contextBefore = self.runtimeContext
                let generationBefore = self.navigationGeneration
                let errorBefore = self.errorMessage
                await self.activatePlaylist(itemID: nextID, versionID: versionID, snapshot: snapshot)
                if self.runtimeContext != contextBefore,
                   self.runtimeContext?.itemID == nextID {
                    if !skippedMessages.isEmpty {
                        self.reportError(skippedMessages.joined(separator: "\n"))
                    }
                    return
                }
                guard self.runtimeContext == expectedContext else { return }
                if self.navigationGeneration != generationBefore,
                   let error = self.errorMessage,
                   error != errorBefore {
                    skippedMessages.append(error)
                }
                expectedGeneration = self.navigationGeneration
                candidate = self.traversal.next(from: nextID, atNaturalEnd: true)
            }
            if skippedMessages.isEmpty {
                self.reportError("No playable playlist items remain.")
            } else {
                self.reportError(skippedMessages.joined(separator: "\n"))
            }
        }
    }

    // MARK: - Workspace helpers

    private func selectedVersion(for itemID: PlaylistItem.ID) -> PlaylistVersion? {
        workspace.items.first(where: { $0.id == itemID })?.selectedVersion
    }

    private func currentVersion() -> PlaylistVersion? {
        guard let itemID = currentItemID,
              let item = workspace.items.first(where: { $0.id == itemID }) else { return nil }
        if let currentVersionID,
           let version = item.versions.first(where: { $0.id == currentVersionID }) {
            return version
        }
        return item.selectedVersion
    }

    private func appendVersions(_ versions: [PlaylistVersion], to itemID: PlaylistItem.ID) throws -> [PlaylistItem.ID] {
        guard let index = workspace.items.firstIndex(where: { $0.id == itemID }) else {
            throw PlaylistWorkspaceError.itemNotFound(itemID)
        }
        var candidate = workspace
        var item = candidate.items[index]
        guard item.versions.count + versions.count <= PlaylistWorkspace.maximumVersionsPerItem else {
            throw PlaylistWorkspaceError.versionLimitExceeded(
                itemID: itemID,
                limit: PlaylistWorkspace.maximumVersionsPerItem
            )
        }
        var existing = Set(candidate.allVersions.map(canonicalFileKey))
        for version in versions {
            guard existing.insert(canonicalFileKey(version)).inserted else {
                throw PlaylistWorkspaceError.duplicateFile(version.file.canonicalURL)
            }
        }
        item.versions.append(contentsOf: versions)
        if item.selectedVersionID == nil { item.selectedVersionID = versions.first?.id }
        candidate.items[index] = item
        try candidate.validate()
        workspace = candidate
        return [itemID]
    }

    private func mutateWorkspace(
        beforeAction actionName: String,
        undoManager: UndoManager?,
        _ mutation: (inout PlaylistWorkspace) throws -> Void
    ) -> Bool {
        let playback = capturePlaybackSnapshot()
        captureRuntimeEdits()
        let before = workspace
        do {
            var candidate = workspace
            try mutation(&candidate)
            workspace = candidate
            let modeBeforeMutation = mode
            synchronizeModeWithWorkspaceView()
            registerUndo(before: before, undoManager: undoManager, actionName: actionName)
            rebuildTraversal()
            let organizationGeneration = beginNavigation()
            if runtimeRequiresRefresh(before: before, after: workspace, mode: modeBeforeMutation) {
                pendingRuntimeRefreshTask?.cancel()
                pendingRuntimeRefreshTask = Task { [weak self] in
                    guard let self,
                          self.navigationGeneration == organizationGeneration else { return }
                    self.pendingRuntimeRefreshTask = nil
                    await self.refreshAfterOrganization(snapshot: playback)
                }
            } else if playback.itemID != nil {
                currentItemID = playback.itemID
                currentVersionID = playback.versionID
            }
            clearError()
            return true
        } catch {
            reportError(error.localizedDescription)
            return false
        }
    }

    private func registerUndo(before: PlaylistWorkspace, undoManager: UndoManager?, actionName: String) {
        guard let undoManager else { return }
        undoManager.setActionName(actionName)
        undoManager.registerUndo(withTarget: self) { target in
            target.applyWorkspaceSnapshotForUndo(before, manager: undoManager, actionName: actionName)
        }
    }

    private func applyWorkspaceSnapshotForUndo(
        _ snapshot: PlaylistWorkspace,
        manager: UndoManager,
        actionName: String
    ) {
        let playback = capturePlaybackSnapshot()
        captureRuntimeEdits()
        let current = workspace
        manager.registerUndo(withTarget: self) { target in
            target.applyWorkspaceSnapshotForUndo(current, manager: manager, actionName: actionName)
        }
        workspace = snapshot
        mode = snapshot.activeView.itemID.map { .comparison(itemID: $0) } ?? .playlist
        currentItemID = snapshot.listeningState?.itemID ?? snapshot.activeItemID
        currentVersionID = snapshot.listeningState?.versionID
            ?? workspace.items.first(where: { $0.id == currentItemID })?.selectedVersion?.id
        rebuildTraversal()
        beginNavigation()
        controller.invalidateRuntimeContext()
        runtimeContext = nil
        runtimeTrackCount = controller.runtimeTrackCount
        pendingRuntimeRefreshTask?.cancel()
        if let currentItemID,
           let item = workspace.items.first(where: { $0.id == currentItemID }),
           let versionID = currentVersionID ?? item.selectedVersion?.id {
            let position = snapshot.listeningState?.filePosition ?? playback.filePosition
            let restored = PlaybackSnapshot(
                itemID: currentItemID,
                versionID: versionID,
                filePosition: position,
                isPlaying: playback.isPlaying
            )
            let generation = navigationGeneration
            pendingRuntimeRefreshTask = Task { [weak self] in
                guard let self else { return }
                guard self.navigationGeneration == generation else { return }
                self.pendingRuntimeRefreshTask = nil
                if self.mode.itemID == item.id {
                    await self.activateComparison(itemID: item.id, versionID: versionID, snapshot: restored)
                } else {
                    await self.activatePlaylist(itemID: item.id, versionID: versionID, snapshot: restored)
                }
            }
        }
    }

    private func capturePlaybackSnapshot() -> PlaybackSnapshot {
        let runtimeMatchesMode: Bool = {
            switch mode {
            case .playlist:
                return runtimeContext?.itemID == currentItemID
            case let .comparison(itemID):
                return runtimeContext?.itemID == itemID
            }
        }()
        let itemID = runtimeMatchesMode ? (currentItemID ?? mode.itemID) : currentItemID
        let versionID = runtimeMatchesMode
            ? (controller.session.activeTrackID ?? currentVersionID)
            : currentVersionID
        let filePosition: TimeInterval
        if let version = versionID.flatMap({ id in workspace.allVersions.first(where: { $0.id == id }) }),
           runtimeMatchesMode {
            if mode.itemID == nil {
                filePosition = min(max(controller.displayTransportPosition(), 0), version.metadata.duration)
            } else {
                filePosition = PlaylistPlaybackBoundary.filePosition(
                    transport: controller.displayTransportPosition(),
                    version: version
                )
            }
        } else if let state = workspace.listeningState,
                  state.itemID == itemID,
                  state.versionID == versionID {
            filePosition = state.filePosition
        } else if let version = versionID.flatMap({ id in workspace.allVersions.first(where: { $0.id == id }) }) {
            filePosition = min(max(controller.displayTransportPosition(), 0), version.metadata.duration)
        } else {
            filePosition = max(0, controller.displayTransportPosition())
        }
        return PlaybackSnapshot(
            itemID: itemID,
            versionID: versionID,
            filePosition: filePosition,
            isPlaying: runtimeMatchesMode && controller.session.isPlaying
        )
    }

    private func captureRuntimeEdits() {
        var candidate = workspace
        let capturedVersionID = captureRuntimeEdits(into: &candidate)
        if candidate != workspace {
            workspace = candidate
        }
        if let capturedVersionID {
            currentVersionID = capturedVersionID
        }
    }

    private func captureRuntimeEdits(into candidate: inout PlaylistWorkspace) -> PlaylistVersion.ID? {
        guard let itemID = mode.itemID,
              runtimeContext?.itemID == itemID,
              let index = candidate.items.firstIndex(where: { $0.id == itemID }) else {
            captureListeningState(into: &candidate)
            return candidate.listeningState?.versionID
        }
        PlaylistPlaybackBoundary.capture(controller.session, into: &candidate.items[index])
        if controller.visibleSpan > 0 {
            candidate.items[index].comparison.visibleStart = controller.visibleStart
            candidate.items[index].comparison.visibleSpan = controller.visibleSpan
        }
        captureListeningState(into: &candidate)
        return controller.session.activeTrackID ?? candidate.items[index].selectedVersionID
    }

    private func captureListeningState(into candidate: inout PlaylistWorkspace) {
        guard let itemID = currentItemID ?? mode.itemID,
              runtimeContext?.itemID == itemID,
              let item = candidate.items.first(where: { $0.id == itemID }),
              let versionID = controller.session.activeTrackID ?? currentVersionID ?? item.selectedVersion?.id,
              let version = item.versions.first(where: { $0.id == versionID }) else {
            return
        }
        let filePosition = mode.itemID == nil
            ? min(max(controller.displayTransportPosition(), 0), version.metadata.duration)
            : PlaylistPlaybackBoundary.filePosition(
                transport: controller.displayTransportPosition(),
                version: version
            )
        candidate.listeningState = PlaylistListeningState(
            itemID: itemID,
            versionID: versionID,
            filePosition: filePosition
        )
    }

    private func updateListeningStateFromRuntime() {
        var candidate = workspace
        captureListeningState(into: &candidate)
        if candidate.listeningState != workspace.listeningState {
            workspace.listeningState = candidate.listeningState
        }
    }

    private func rebuildTraversal() {
        traversal.updateItemIDs(workspace.items.map(\.id))
        traversal.setShuffleEnabled(workspace.isShuffleEnabled)
        traversal.setRepeatMode(workspace.playlistRepeatMode)
    }

    private func runtimeRequiresRefresh(
        before: PlaylistWorkspace,
        after: PlaylistWorkspace,
        mode: Mode
    ) -> Bool {
        guard runtimeContext != nil else { return false }
        let itemID: PlaylistItem.ID?
        switch mode {
        case .playlist:
            itemID = currentItemID
        case let .comparison(itemIDValue):
            itemID = itemIDValue
        }
        guard let itemID else { return false }
        let oldItem = before.items.first(where: { $0.id == itemID })
        let newItem = after.items.first(where: { $0.id == itemID })
        return oldItem?.versions != newItem?.versions
            || oldItem?.comparison != newItem?.comparison
    }

    private func synchronizeModeWithWorkspaceView() {
        if let activeItemID = workspace.activeItemID {
            mode = .comparison(itemID: activeItemID)
        } else if mode.itemID != nil {
            mode = .playlist
        }
    }

    @discardableResult
    private func beginNavigation() -> Int {
        navigationGeneration &+= 1
        pendingRuntimeRefreshTask?.cancel()
        return navigationGeneration
    }

    private func beginLoading() {
        loadingOperationCount += 1
        isLoading = true
    }

    private func endLoading() {
        loadingOperationCount = max(0, loadingOperationCount - 1)
        isLoading = loadingOperationCount > 0
    }

    private static func playlistMetadata(from loaded: LoadedTrack) -> PlaylistMetadata {
        PlaylistMetadata(
            title: loaded.title,
            artist: loaded.artist,
            album: loaded.album,
            duration: loaded.duration,
            sampleRate: loaded.sampleRate,
            channelCount: loaded.channelCount,
            bitRate: loaded.bitRate,
            fileFormatDescription: loaded.fileFormatDescription,
            displayName: loaded.displayName
        )
    }

    private func resolvedURL(for version: PlaylistVersion) -> URL? {
        guard case let .available(url) = PlaylistWorkspaceStore.resolveFileReference(version.file) else {
            reportError(PlaybackError.failedToOpenFile(version.file.storedURL).localizedDescription)
            return nil
        }
        return url
    }

    private func canonicalFileKey(_ version: PlaylistVersion) -> String {
        let url = PlaylistWorkspaceStore.resolveFileReference(version.file).resolvedURL
            ?? version.file.storedURL
        return PlaylistFileReference.canonicalURL(for: url).absoluteString
    }

    private func playlistLoadedTrack(for version: PlaylistVersion, url: URL) -> LoadedTrack {
        let metadata = version.metadata
        return LoadedTrack(
            url: url,
            displayName: metadata.displayName,
            fileFormatDescription: metadata.fileFormatDescription,
            duration: metadata.duration,
            sampleRate: metadata.sampleRate,
            channelCount: metadata.channelCount,
            bitRate: metadata.bitRate,
            gainDB: 0,
            offsetSeconds: 0,
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album
        )
    }

    private func materializedComparisonItem(_ item: PlaylistItem) -> PlaylistItem? {
        var materialized = item
        for index in materialized.versions.indices {
            guard let url = resolvedURL(for: materialized.versions[index]) else { return nil }
            materialized.versions[index].file.storedURL = url
        }
        return materialized
    }
}
