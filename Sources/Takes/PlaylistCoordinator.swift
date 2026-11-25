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
        guard self.itemIDs != itemIDs else { return }
        self.itemIDs = itemIDs
        let valid = Set(itemIDs)
        let previousHistoryIndex = historyIndex
        let retainedThroughCursor = history.prefix(max(0, previousHistoryIndex + 1))
            .filter(valid.contains).count
        history = history.filter(valid.contains)
        historyIndex = min(retainedThroughCursor - 1, history.count - 1)
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

    /// Advancing probes candidates in play order. Only successful activations
    /// should stay in the listening history.
    mutating func discardSkippedHistory(_ skipped: Set<ID>) {
        guard !skipped.isEmpty else { return }
        let retainedThroughCursor = history.prefix(historyIndex + 1).filter { !skipped.contains($0) }.count
        history.removeAll { skipped.contains($0) }
        historyIndex = retainedThroughCursor - 1
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

    enum VersionLimitAlert: Equatable {
        case comparison(limit: Int)
        case group(limit: Int)

        var message: String {
            switch self {
            case let .comparison(limit):
                "You can compare up to \(limit) versions at a time."
            case let .group(limit):
                "A track group can contain up to \(limit) versions."
            }
        }
    }

    private(set) var workspace: PlaylistWorkspace
    private(set) var mode: Mode
    private(set) var controller: PlaybackController
    private(set) var currentItemID: PlaylistItem.ID?
    private(set) var currentVersionID: PlaylistVersion.ID?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var versionLimitAlert: VersionLimitAlert?
    private(set) var fileIssues: [PlaylistVersion.ID: FileIssue] = [:]
    private(set) var runtimeContext: PlaylistRuntimeContext?
    private(set) var rowMoveRevision = 0

    /// The current runtime's stable item identity. The controller owns the
    /// callback and only invokes it for a natural end, never for a seek or a
    /// user pause.
    private(set) var runtimeTrackCount = 0

    @ObservationIgnored private let loader: AudioFileLoading
    @ObservationIgnored private var navigationGeneration = 0
    @ObservationIgnored private var importGeneration = 0
    @ObservationIgnored private var importCancellationGeneration = 0
    @ObservationIgnored private var loadingOperationCount = 0
    @ObservationIgnored private var traversal: PlaylistTraversal
    /// The items heard, in order; read by tests.
    var listeningHistory: [PlaylistItem.ID] { traversal.history }
    @ObservationIgnored private var pendingRuntimeRefreshTask: Task<Void, Never>?

    private struct PlaybackSnapshot {
        var itemID: PlaylistItem.ID?
        var versionID: PlaylistVersion.ID?
        var filePosition: TimeInterval
        var isPlaying: Bool
    }

    struct FileIssue: Equatable {
        let reference: PlaylistFileReference
        let error: PlaybackError
    }

    private enum PlaylistAdvance { case next, previous, naturalEnd }

    private struct AutomaticImportPlan: Sendable {
        let decisions: [TrackSimilarityClusterEvidence<UUID>]
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
            ?? workspace.items.first(where: { $0.id == workspace.activeItemID })?.keyVersion?.id
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

    private var canNavigateBetweenModes: Bool { controller.settings?.windowVisibility.showsPlaylist ?? true }

    /// With no current track, Play starts the first track that isn't
    /// rejected (culling spec §4.2), so a playlist of rejected tracks has
    /// nothing to start.
    var canPlay: Bool {
        if let itemID = mode.itemID {
            return runtimeContext?.itemID == itemID && controller.session.isPlayable
        }
        return controller.session.isPlayable
            || workspace.items.contains { item in
                guard currentItemID != nil || !item.isRejected, let version = item.keyVersion else { return false }
                return version.metadata.duration > 0
            }
    }

    /// Playlist Next Track is always available with items: at the end it
    /// wraps with Repeat All, or returns to the first track, paused.
    var canNext: Bool {
        guard !workspace.items.isEmpty else { return false }
        if mode.itemID != nil {
            return controller.session.canSwitchPlayback
        }
        return true
    }

    /// Playlist Previous Track is available whenever there is a track to
    /// restart or go back to.
    var canPrevious: Bool {
        if mode.itemID != nil { return controller.session.canSwitchPlayback }
        return !workspace.items.isEmpty
    }

    /// Previous Track restarts the current track once it has played this
    /// long, as standard media players do; earlier, it goes to the previous
    /// track.
    nonisolated static let previousTrackRestartThreshold: TimeInterval = 3

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
        isWorkspaceOwned: Bool = false,
        automaticGroupingMode: AutomaticGroupingMode = .automatic,
        undoManager: UndoManager? = nil
    ) async -> [PlaylistItem.ID] {
        guard !urls.isEmpty else { return [] }
        let operationGeneration = importGeneration &+ 1
        importGeneration = operationGeneration
        let cancellationGenerationAtStart = importCancellationGeneration
        let navigationGenerationAtStart = navigationGeneration
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
            guard !Task.isCancelled,
                  cancellationGenerationAtStart == importCancellationGeneration else { return [] }
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

        guard !Task.isCancelled,
              cancellationGenerationAtStart == importCancellationGeneration else { return [] }

        let automaticPlan: AutomaticImportPlan?
        if destination == .playlist, automaticGroupingMode == .automatic {
            guard let plan = await prepareAutomaticImportPlan(
                versions: versions,
                cancellationGeneration: cancellationGenerationAtStart
            ) else { return [] }
            automaticPlan = plan
        } else {
            automaticPlan = nil
        }

        // The user may have changed gain, blind-listening state, or playback
        // while metadata loading was running. Capture those
        // edits and the transport state at the commit boundary.
        captureRuntimeEdits()
        let activeComparisonItemID = mode.itemID
        let activeComparisonVersionsBefore = activeComparisonItemID.flatMap { itemID in
            workspace.items.first(where: { $0.id == itemID })?.versions.map(\.id)
        }
        let playbackBeforeCommit = activeComparisonItemID == nil ? nil : capturePlaybackSnapshot()
        do {
            let before = workspace
            var acceptedVersions: [PlaylistVersion] = []
            var seenFiles = Set(workspace.allVersions.map(canonicalFileKey))
            for version in versions {
                guard seenFiles.insert(canonicalFileKey(version)).inserted else {
                    failures.append(PlaylistWorkspaceError.duplicateFile(version.file.canonicalURL).localizedDescription)
                    continue
                }
                acceptedVersions.append(version)
            }
            guard let firstVersion = acceptedVersions.first else {
                if operationGeneration == importGeneration {
                    reportError(failures.joined(separator: "\n"))
                }
                return []
            }

            let newItemIDs: [PlaylistItem.ID]
            switch destination {
            case .playlist:
                if let automaticPlan {
                    newItemIDs = try applyAutomaticImportPlan(
                        automaticPlan,
                        versions: acceptedVersions
                    )
                } else {
                    newItemIDs = try workspace.appendSeparateItems(acceptedVersions)
                }
            case let .item(itemID):
                newItemIDs = try appendVersions(acceptedVersions, to: itemID)
            case .newComparison:
                let item = PlaylistItem(
                    title: PlaylistWorkspace.defaultTitle(for: firstVersion),
                    versions: acceptedVersions
                )
                newItemIDs = try workspace.appendItems([item])
            }

            registerUndo(before: before, undoManager: undoManager, actionName: "Import Tracks")
            rebuildTraversal()

            let activeComparisonMembershipChanged = activeComparisonItemID.flatMap { itemID in
                workspace.items.first(where: { $0.id == itemID })?.versions.map(\.id)
            } != activeComparisonVersionsBefore
            if activeComparisonMembershipChanged,
               let playbackBeforeCommit,
               let activeComparisonItemID,
               mode.itemID == activeComparisonItemID {
                scheduleRuntimeRefresh(
                    mode: .comparison(itemID: activeComparisonItemID),
                    snapshot: playbackBeforeCommit,
                    generation: navigationGeneration,
                    autoAlignAfterActivation: true
                )
            }
            if destination == .newComparison,
               let itemID = newItemIDs.first,
               navigationGeneration == navigationGenerationAtStart {
                let activation = await enterComparison(
                    itemID: itemID, from: capturePlaybackSnapshot(), autoAlignAfterActivation: true
                )
                guard activation == .activated else { return newItemIDs }
            }
            if operationGeneration == importGeneration, !failures.isEmpty {
                reportError(failures.joined(separator: "\n"))
            } else if operationGeneration == importGeneration {
                clearError()
            }

            if destination == .playlist,
               automaticGroupingMode != .off,
               workspace.items.count == 1,
               workspace.items[0].versions.count >= 2,
               mode == .playlist,
               navigationGeneration == navigationGenerationAtStart {
                await enterComparison(itemID: workspace.items[0].id, autoAlignAfterActivation: true)
            }
            return newItemIDs
        } catch {
            if operationGeneration == importGeneration,
               case let PlaylistWorkspaceError.versionLimitExceeded(_, limit) = error,
               destination != .playlist {
                versionLimitAlert = .comparison(limit: limit)
            }
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
        isWorkspaceOwned: Bool = false,
        automaticGroupingMode: AutomaticGroupingMode = .automatic,
        undoManager: UndoManager? = nil
    ) async -> [PlaylistItem.ID] {
        let destination = captureImportDestination()
        return await importFiles(
            urls,
            destination: destination,
            isWorkspaceOwned: isWorkspaceOwned,
            automaticGroupingMode: automaticGroupingMode,
            undoManager: undoManager
        )
    }

    /// Start the item from its saved file position. Playing a version row
    /// starts at zero and keeps the item's key version.
    func playItem(
        id itemID: PlaylistItem.ID, versionID: PlaylistVersion.ID? = nil, fromBeginning: Bool = false
    ) async {
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
            guard let selected = item.keyVersion?.id else {
                reportError(PlaylistWorkspaceError.emptyItem(itemID).localizedDescription)
                return
            }
            targetVersionID = selected
        }

        captureRuntimeEdits()
        let savedPosition = workspace.listeningState.flatMap { state in
            state.itemID == itemID && state.versionID == targetVersionID ? state.filePosition : nil
        } ?? 0
        let snapshot = PlaybackSnapshot(
            itemID: itemID,
            versionID: targetVersionID,
            filePosition: fromBeginning ? 0 : savedPosition,
            isPlaying: true
        )
        if await activatePlaylist(itemID: itemID, versionID: targetVersionID, snapshot: snapshot) == .activated {
            traversal.reset(currentID: itemID)
        }
    }

    /// Enter the current item's comparison view. The playing item preserves
    /// file time, version, and playing state; another item begins paused at
    /// its timeline start.
    func enterComparison(itemID: PlaylistItem.ID, autoAlignAfterActivation: Bool = false) async {
        guard canNavigateBetweenModes else { return }
        guard workspace.items.contains(where: { $0.id == itemID }) else {
            reportError(PlaylistWorkspaceError.itemNotFound(itemID).localizedDescription)
            return
        }

        let oldSnapshot = capturePlaybackSnapshot()
        captureRuntimeEdits()
        await enterComparison(itemID: itemID, from: oldSnapshot, autoAlignAfterActivation: autoAlignAfterActivation)
    }

    @discardableResult
    private func enterComparison(
        itemID: PlaylistItem.ID, from oldSnapshot: PlaybackSnapshot, autoAlignAfterActivation: Bool = false
    ) async -> ActivationResult {
        guard let item = workspace.items.first(where: { $0.id == itemID }) else {
            reportError(PlaylistWorkspaceError.itemNotFound(itemID).localizedDescription)
            return .failed
        }
        let sameItem = oldSnapshot.itemID == itemID
        let versionID = (sameItem ? oldSnapshot.versionID : nil)
            .flatMap { id in item.versions.contains(where: { $0.id == id }) ? id : nil }
            ?? item.keyVersion?.id
            ?? item.versions.first?.id
        guard let versionID else {
            reportError(PlaylistWorkspaceError.emptyItem(itemID).localizedDescription)
            return .failed
        }
        // Entering compare never starts an item (A2 spec §9): another item's
        // playback stops, and only the item already playing keeps going.
        let snapshot = PlaybackSnapshot(
            itemID: itemID,
            versionID: versionID,
            filePosition: sameItem ? oldSnapshot.filePosition : 0,
            isPlaying: sameItem && oldSnapshot.isPlaying
        )
        return await activateComparison(
            itemID: itemID,
            versionID: versionID,
            snapshot: snapshot,
            autoAlignAfterActivation: autoAlignAfterActivation,
            startAtTimelineBeginning: !sameItem
        )
    }

    /// Return to playlist playback while preserving the version being
    /// auditioned and translating comparison transport back to file time.
    func backToPlaylist() async {
        guard canNavigateBetweenModes else { return }
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
            ?? item.keyVersion?.id
            ?? item.versions.first?.id
        guard let versionID else { return }
        let nextSnapshot = PlaybackSnapshot(
            itemID: targetItemID,
            versionID: versionID,
            filePosition: snapshot.filePosition,
            isPlaying: snapshot.isPlaying
        )
        if await activatePlaylist(itemID: targetItemID, versionID: versionID, snapshot: nextSnapshot).didFail {
            showPlaylistWithoutRuntime(nextSnapshot)
        }
    }

    func play() {
        let runtimeItemID = mode.itemID ?? currentItemID
        if controller.session.isPlayable, runtimeContext?.itemID == runtimeItemID {
            controller.play()
            updateListeningStateFromRuntime()
            return
        }
        guard mode == .playlist else { return }
        // Space with a current track resumes it, rejected or not. With none,
        // Play starts the first track that is neither rejected nor
        // unavailable, as Next would.
        guard let itemID = currentItemID else {
            guard !workspace.items.isEmpty else { return }
            let generation = navigationGeneration
            Task { [weak self] in
                guard let self, self.navigationGeneration == generation, self.mode.itemID == nil else { return }
                await self.advancePlaylist(.next, from: nil, wasPlaying: true)
            }
            return
        }
        let versionID = currentVersionID
            ?? workspace.items.first(where: { $0.id == itemID })?.keyVersion?.id
        Task {
            guard mode == .playlist else { return }
            await playItem(id: itemID, versionID: versionID)
        }
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
        enqueuePlaylistAdvance(.next)
    }

    /// The playlist's position in the current track, in file seconds.
    private var playlistTrackPosition: TimeInterval {
        let current = currentItemID ?? workspace.listeningState?.itemID
        if runtimeContext?.itemID == current, current != nil { return controller.displayTransportPosition() }
        return workspace.listeningState?.itemID == current ? workspace.listeningState?.filePosition ?? 0 : 0
    }

    func previous() {
        if mode.itemID != nil {
            controller.selectPreviousTrack()
            currentVersionID = controller.session.activeTrackID
            updateListeningStateFromRuntime()
            return
        }
        // Previous Track (playlist), as standard media players do: past the
        // first few seconds it restarts the current track; otherwise it goes
        // back through listening history, then to the track above in list
        // order (wrapping to the last with Repeat All). At the start, it
        // restarts the current track.
        let current = currentItemID ?? workspace.listeningState?.itemID
        if let current, runtimeContext?.itemID == current, controller.session.isPlayable,
           playlistTrackPosition > Self.previousTrackRestartThreshold
               || (!traversal.hasPrevious(from: current) && previousPlaylistItems(from: current).isEmpty) {
            seek(to: 0)
            return
        }
        enqueuePlaylistAdvance(.previous)
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

    // MARK: - Culling

    /// The version Reject acts on in compare: the active lane (spec §5.2).
    var activeComparisonVersionID: PlaylistVersion.ID? {
        mode.itemID == nil ? nil : controller.session.activeTrackID
    }

    /// True when every target is already rejected, so the toggle reads
    /// Clear Rejection; a mixed or unrejected set reads Reject.
    func rejectionClears(itemIDs: [PlaylistItem.ID], versionIDs: [PlaylistVersion.ID]) -> Bool {
        guard !itemIDs.isEmpty || !versionIDs.isEmpty else { return false }
        let items = Set(itemIDs), versions = Set(versionIDs)
        let itemFlags = workspace.items.filter { items.contains($0.id) }.map(\.isRejected)
        let versionFlags = workspace.allVersions.filter { versions.contains($0.id) }.map(\.isRejected)
        return (itemFlags + versionFlags).allSatisfy { $0 }
    }

    /// Reject / Clear Rejection (spec §4.1): one undoable organization
    /// edit. Applying Reject to a mixed set rejects all of it. Nothing
    /// moves, the selection is untouched, and playback carries on: the
    /// current track keeps playing, and compare's active lane stays active.
    @discardableResult
    func toggleRejection(
        itemIDs: [PlaylistItem.ID] = [], versionIDs: [PlaylistVersion.ID] = [], undoManager: UndoManager?
    ) -> Bool {
        guard !itemIDs.isEmpty || !versionIDs.isEmpty else { return false }
        let clears = rejectionClears(itemIDs: itemIDs, versionIDs: versionIDs)
        return mutateWorkspace(beforeAction: clears ? "Clear Rejection" : "Reject", undoManager: undoManager) {
            try $0.setRejected(!clears, itemIDs: itemIDs, versionIDs: versionIDs)
        }
    }

    // MARK: - Organization

    @discardableResult
    func groupItems(
        _ itemIDs: [PlaylistItem.ID],
        looseVersionIDs: [PlaylistVersion.ID] = [],
        into destination: PlaylistItem.ID? = nil,
        undoManager: UndoManager? = nil
    ) -> PlaylistItem.ID? {
        var result: UUID?
        let succeeded = mutateWorkspace(beforeAction: "Group Versions", undoManager: undoManager) {
            result = try $0.groupItems(itemIDs, looseVersionIDs: looseVersionIDs, into: destination)
        }
        return succeeded ? result : nil
    }

    func moveVersions(_ ids: [UUID], to destination: UUID, before anchor: UUID?, undoManager: UndoManager?) -> Bool {
        return mutateWorkspace(beforeAction: ids.count == 1 ? "Move Version" : "Move Versions", undoManager: undoManager) {
            try $0.moveVersions(ids, to: destination, before: anchor)
        }
    }

    enum SeparationPlacement {
        case adjacent
        case beforeItem(UUID?)
    }

    func separateVersions(_ ids: [UUID], placement: SeparationPlacement, undoManager: UndoManager?) -> [UUID]? {
        var created: [UUID] = []
        let succeeded = mutateWorkspace(beforeAction: ids.count == 1 ? "Ungroup Version" : "Ungroup Versions",
                                        undoManager: undoManager) { candidate in
            let selected = Set(ids)
            guard selected.count == ids.count else { throw PlaylistWorkspaceError.invalidItemOrder }
            // Adjacent insertion puts each new row directly after the source.
            // Visit those versions backwards to retain their displayed order.
            let visitOrder: [UUID]
            let fullySelectedItems: Set<UUID>
            switch placement {
            case .adjacent:
                visitOrder = ids.reversed()
                fullySelectedItems = Set(candidate.items.filter { item in
                    item.versions.count > 1 && item.versions.allSatisfy { selected.contains($0.id) }
                }.map(\.id))
            case .beforeItem:
                visitOrder = ids
                fullySelectedItems = []
            }
            for id in visitOrder {
                guard let owner = candidate.items.first(where: { $0.versions.contains { $0.id == id } }) else {
                    throw PlaylistWorkspaceError.versionNotFound(id)
                }
                if owner.versions.count > 1 {
                    created.append(try candidate.separateVersion(id, from: owner.id))
                }
            }
            if case let .beforeItem(anchor) = placement {
                var order = candidate.items.map(\.id).filter { !created.contains($0) }
                let index = try anchor.map { id in
                    guard let index = order.firstIndex(of: id) else { throw PlaylistWorkspaceError.itemNotFound(id) }
                    return index
                } ?? order.endIndex
                order.insert(contentsOf: created, at: index)
                try candidate.reorderItems(order)
            } else {
                created.reverse()
                for index in candidate.items.indices where fullySelectedItems.contains(candidate.items[index].id) {
                    candidate.items[index].versions[0].offsetSeconds = 0
                    candidate.items[index].comparison.loopRegion = nil
                }
            }
        }
        return succeeded ? created : nil
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

    func reorderPlaylistRows(items: [UUID]?, versions: [UUID: [UUID]], undoManager: UndoManager?) {
        let moved = mutateWorkspace(beforeAction: "Reorder Playlist Rows", undoManager: undoManager) { candidate in
            if let items { try candidate.reorderItems(items) }
            for (itemID, order) in versions {
                try candidate.reorderVersions(order, in: itemID)
            }
        }
        if moved { rowMoveRevision &+= 1 }
    }

    private func comparisonMoveIndices(_ direction: RowMoveDirection) -> (from: Int, to: Int)? {
        guard let itemID = mode.itemID, runtimeContext?.itemID == itemID,
              controller.runtimeContext == runtimeContext, pendingRuntimeRefreshTask == nil,
              let from = controller.session.activeTrackIndex else { return nil }
        let to = from + direction.rawValue
        return controller.session.tracks.indices.contains(to) ? (from, to) : nil
    }

    func canMoveActiveComparisonVersion(_ direction: RowMoveDirection) -> Bool {
        comparisonMoveIndices(direction) != nil
    }

    func moveActiveComparisonVersion(_ direction: RowMoveDirection, undoManager: UndoManager?) {
        guard let itemID = mode.itemID,
              let indices = comparisonMoveIndices(direction),
              let item = workspace.items.first(where: { $0.id == itemID }) else { return }
        var displayedOrder = controller.session.tracks.map(\.id)
        let activeID = displayedOrder[indices.from]
        let neighborID = displayedOrder[indices.to]
        displayedOrder.swapAt(indices.from, indices.to)

        if controller.session.isBlindListeningModeEnabled {
            controller.reorderTracks(displayedOrder)
        } else {
            // A previously shuffled comparison can still be in a different
            // order. Save only the active lane's move relative to its neighbor.
            let originalOrder = item.versions.map(\.id)
            var savedOrder = originalOrder.filter { $0 != activeID }
            guard savedOrder.count + 1 == originalOrder.count,
                  let neighborIndex = savedOrder.firstIndex(of: neighborID) else { return }
            savedOrder.insert(activeID, at: direction == .up ? neighborIndex : neighborIndex + 1)
            if savedOrder != originalOrder {
                guard mutateWorkspace(beforeAction: "Reorder Versions", undoManager: undoManager,
                                      displayedComparisonOrder: displayedOrder, { candidate in
                    try candidate.reorderVersions(savedOrder, in: itemID)
                }) else { return }
            } else {
                controller.reorderTracks(displayedOrder)
            }
        }
        rowMoveRevision &+= 1
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
        return mutateWorkspace(beforeAction: "Move Version", undoManager: undoManager) {
            try $0.moveVersion(
                versionID,
                from: sourceItemID,
                to: destinationItemID,
                at: destinationIndex
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
                at: destinationIndex
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
        return mutateWorkspace(beforeAction: "Move Version", undoManager: undoManager) {
            try $0.moveVersion(
                versionID,
                to: destinationItemID,
                at: destinationIndex
            )
        }
    }

    @discardableResult
    func separateVersion(
        _ versionID: PlaylistVersion.ID,
        from itemID: PlaylistItem.ID? = nil,
        undoManager: UndoManager? = nil
    ) -> PlaylistItem.ID? {
        var result: PlaylistItem.ID?
        let succeeded = mutateWorkspace(beforeAction: "Ungroup Version", undoManager: undoManager) {
            result = try $0.separateVersion(versionID, from: itemID)
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
        mutateWorkspace(beforeAction: "Remove Version", undoManager: undoManager, removedVersionID: versionID) {
            _ = try $0.removeVersion(versionID, from: itemID)
        }
    }

    /// Remove several versions in one atomic workspace mutation and one Undo
    /// transaction. IDs are resolved against the candidate value so a missing
    /// ID leaves every requested change unapplied.
    @discardableResult
    func removeVersions(
        _ versionIDs: [PlaylistVersion.ID],
        alongWithItems itemIDs: [PlaylistItem.ID] = [],
        undoManager: UndoManager? = nil
    ) -> Bool {
        guard !versionIDs.isEmpty || !itemIDs.isEmpty else { return false }
        return mutateWorkspace(beforeAction: itemIDs.isEmpty ? "Remove Versions" : "Remove Items", undoManager: undoManager) {
            _ = try $0.removeItems(itemIDs)
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

    func resetAllComparisonOffsets() {
        guard let itemID = mode.itemID, runtimeContext?.itemID == itemID else { return }
        let offsets = Dictionary(uniqueKeysWithValues: controller.session.tracks.map { ($0.id, 0.0) })
        controller.setOffsets(offsets)
        captureRuntimeEdits()
    }

    func nudgeActiveTrackOffset(direction: Int, largeStep: Bool) {
        controller.nudgeActiveTrackOffset(direction: direction, largeStep: largeStep)
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
        fileIssues.removeAll()
        mode = restored.activeView.itemID.map { .comparison(itemID: $0) } ?? .playlist
        currentItemID = restored.listeningState?.itemID ?? restored.activeItemID
        currentVersionID = restored.listeningState?.versionID
            ?? restored.items.first(where: { $0.id == restored.activeItemID })?.keyVersion?.id
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
        let versionID = currentVersionID.flatMap { id in item.versions.contains { $0.id == id } ? id : nil }
            ?? item.keyVersion?.id
        guard let versionID else { return }
        let filePosition = restored.listeningState?.itemID == item.id
            && restored.listeningState?.versionID == versionID
            ? restored.listeningState?.filePosition ?? 0
            : 0
        let snapshot = PlaybackSnapshot(itemID: item.id, versionID: versionID, filePosition: filePosition, isPlaying: false)
        if restored.activeItemID == item.id {
            if await activateComparison(itemID: item.id, versionID: versionID, snapshot: snapshot) == .failed {
                showPlaylistWithoutRuntime(snapshot)
            }
        } else {
            await activatePlaylist(itemID: item.id, versionID: versionID, snapshot: snapshot)
        }
    }

    /// Return the workspace's persisted representation. It captures anchors
    /// and comparison edits at this explicit event; it never runs per frame.
    func snapshotForPersistence() -> PlaylistWorkspace {
        var snapshot = workspace
        _ = captureRuntimeEdits(into: &snapshot)
        return snapshot
    }

    /// Register save dependencies without materializing a workspace snapshot.
    func observePersistenceInputs() {
        _ = workspace
        _ = mode
        _ = currentItemID
        _ = currentVersionID
        _ = runtimeContext
        _ = controller.session
        _ = controller.settledViewportRevision
    }

    func reportError(_ message: String) {
        errorMessage = message
    }

    func clearError() {
        errorMessage = nil
    }

    func dismissVersionLimitAlert() {
        versionLimitAlert = nil
    }

    /// Cancels all playlist imports currently between metadata loading and
    /// their atomic commit. The generation check guarantees that no result
    /// commits after cancellation.
    func cancelCurrentImports() {
        importCancellationGeneration &+= 1
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
            fileIssues[versionID] = nil
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
            else if operationGeneration == navigationGeneration,
                    let itemID = mode.itemID,
                    candidate.items.first(where: { $0.id == itemID })?.versions.contains(where: { $0.id == versionID }) == true {
                // Another version of the compared item: rebuild compare so its
                // lane loads, keeping the audible version and the transport.
                let snapshot = capturePlaybackSnapshot()
                captureRuntimeEdits()
                if let activeID = snapshot.versionID {
                    await activateComparison(itemID: itemID, versionID: activeID, snapshot: snapshot)
                }
            }
        } catch {
            reportError(error.localizedDescription)
        }
    }

    // MARK: - Runtime activation

    private enum ActivationResult {
        case activated, unavailable, failed, superseded

        var didFail: Bool { self == .failed || self == .unavailable }
    }

    private func showPlaylistWithoutRuntime(_ snapshot: PlaybackSnapshot) {
        beginNavigation()
        controller.invalidateRuntimeContext()
        runtimeContext = nil
        runtimeTrackCount = 0
        mode = .playlist
        workspace.activeView = .playlist
        currentItemID = snapshot.itemID
        currentVersionID = snapshot.versionID
        if let itemID = snapshot.itemID, let versionID = snapshot.versionID {
            workspace.listeningState = PlaylistListeningState(
                itemID: itemID, versionID: versionID, filePosition: snapshot.filePosition
            )
        } else {
            workspace.listeningState = nil
        }
    }

    @discardableResult
    private func activatePlaylist(
        itemID: PlaylistItem.ID,
        versionID: PlaylistVersion.ID,
        snapshot: PlaybackSnapshot
    ) async -> ActivationResult {
        guard let item = workspace.items.first(where: { $0.id == itemID }),
              let version = item.versions.first(where: { $0.id == versionID }) else {
            reportError(PlaylistWorkspaceError.versionNotInItem(versionID: versionID, itemID: itemID).localizedDescription)
            return .failed
        }
        guard case let .available(resolvedURL) = PlaylistWorkspaceStore.resolveFileReference(version.file) else {
            recordFileIssue(.failedToOpenFile(version.file.storedURL), for: version)
            return .unavailable
        }
        let generation = beginNavigation()
        let context = PlaylistRuntimeContext(itemID: itemID)
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
                return .superseded
            }
            runtimeContext = context
            runtimeTrackCount = controller.runtimeTrackCount
            mode = .playlist
            workspace.activeView = .playlist
            currentItemID = itemID
            currentVersionID = versionID
            fileIssues[versionID] = nil
            if snapshot.isPlaying { controller.play() }
            updateListeningStateFromRuntime()
            clearError()
            return .activated
        } catch is CancellationError {
            return .superseded
        } catch {
            guard generation == navigationGeneration else { return .superseded }
            if let fileError = error as? PlaybackError, fileError.fileURL != nil {
                recordFileIssue(fileError, for: version)
                return .unavailable
            }
            reportError(error.localizedDescription)
            return .failed
        }
    }

    @discardableResult
    private func activateComparison(
        itemID: PlaylistItem.ID,
        versionID: PlaylistVersion.ID,
        snapshot: PlaybackSnapshot,
        autoAlignAfterActivation: Bool = false,
        startAtTimelineBeginning: Bool = false
    ) async -> ActivationResult {
        guard let item = workspace.items.first(where: { $0.id == itemID }) else {
            reportError(PlaylistWorkspaceError.itemNotFound(itemID).localizedDescription)
            return .failed
        }
        let generation = beginNavigation()
        let context = PlaylistRuntimeContext(itemID: itemID)
        let (runtimeItem, missingIDs) = materializedComparisonItem(item)
        // A missing incoming version would start silent; begin on the first
        // version whose file is there instead, when there is one.
        let startingVersionID = missingIDs.contains(versionID)
            ? runtimeItem.versions.first(where: { !missingIDs.contains($0.id) })?.id ?? versionID
            : versionID
        var session = PlaylistPlaybackBoundary.session(
            for: runtimeItem,
            incomingVersionID: startingVersionID,
            incomingFilePosition: startAtTimelineBeginning || startingVersionID != versionID ? nil : snapshot.filePosition,
            isPlaying: false
        )
        for index in session.tracks.indices where missingIDs.contains(session.tracks[index].id) {
            session.tracks[index].loadedTrack.isMissing = true
        }
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
                return .superseded
            }
            runtimeContext = context
            runtimeTrackCount = controller.runtimeTrackCount
            mode = .comparison(itemID: itemID)
            workspace.activeView = .comparison(itemID: itemID)
            currentItemID = itemID
            currentVersionID = session.activeTrackID
            for version in item.versions where !missingIDs.contains(version.id) && fileIssues[version.id] != nil {
                fileIssues[version.id] = nil
            }
            if let span = item.comparison.visibleSpan, span > 0 {
                controller.zoomVisibleSpan(to: span)
                if let start = item.comparison.visibleStart {
                    controller.scrollTimeline(toVisibleStart: start)
                }
            }
            if snapshot.isPlaying, session.isPlayable { controller.play() }
            updateListeningStateFromRuntime()
            if autoAlignAfterActivation, controller.settings?.alignTracksOnOpen == true {
                controller.autoAlignTracks()
            }
            clearError()
            return .activated
        } catch {
            guard generation == navigationGeneration else { return .superseded }
            if case let PlaybackError.trackLimitExceeded(limit, _) = error {
                versionLimitAlert = .comparison(limit: limit)
            }
            if let fileError = error as? PlaybackError, let url = fileError.fileURL,
               let index = runtimeItem.versions.firstIndex(where: { $0.file.storedURL == url }) {
                recordFileIssue(fileError, for: item.versions[index])
                return .failed
            }
            reportError(error.localizedDescription)
            return .failed
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

    private func enqueuePlaylistAdvance(_ advance: PlaylistAdvance) {
        let current = currentItemID ?? workspace.listeningState?.itemID
        let wasPlaying = controller.session.isPlaying
        let generation = navigationGeneration
        let expectedContext = runtimeContext
        Task { [weak self] in
            guard let self,
                  self.navigationGeneration == generation,
                  self.runtimeContext == expectedContext,
                  self.mode.itemID == nil else { return }
            await self.advancePlaylist(advance, from: current, wasPlaying: wasPlaying)
        }
    }

    private func previousPlaylistItems(from current: UUID?) -> [UUID] {
        let ids = workspace.items.map(\.id)
        guard let current else { return ids }
        guard !workspace.isShuffleEnabled, let index = ids.firstIndex(of: current) else { return [] }
        let preceding = Array(ids[..<index].reversed())
        return workspace.playlistRepeatMode == .all
            ? preceding + Array(ids[(index + 1)...].reversed()) : preceding
    }

    private func advancePlaylist(_ advance: PlaylistAdvance, from current: UUID?, wasPlaying: Bool) async {
        var path = traversal
        var attempted = Set<UUID>()
        var cursor = current
        var returningToStart = false
        var earlier = (advance == .previous ? previousPlaylistItems(from: current) : []).makeIterator()
        let repeatsCurrent = advance == .naturalEnd && path.repeatMode == .one && current != nil
        var tryRepeatCurrent = repeatsCurrent

        while attempted.count < path.itemIDs.count {
            let itemID: UUID
            if advance == .previous {
                if let heard = path.previous(from: cursor) {
                    itemID = heard
                } else if let preceding = earlier.next() {
                    itemID = preceding
                    path.reset(currentID: itemID)
                } else if let current, !attempted.contains(current) {
                    if runtimeContext?.itemID == current && controller.session.isPlayable {
                        seek(to: 0)
                        return
                    }
                    itemID = current
                    path.reset(currentID: itemID)
                } else {
                    return
                }
            } else if let next = path.next(
                from: cursor, atNaturalEnd: advance == .naturalEnd && (!repeatsCurrent || tryRepeatCurrent)
            ) {
                itemID = next
            } else {
                // Manual Next past the end returns to the first playable
                // item, paused. Natural playback simply ends here.
                guard advance == .next, !returningToStart else { return }
                returningToStart = true
                path.reset()
                cursor = nil
                continue
            }
            cursor = itemID
            let repeatingCurrent = tryRepeatCurrent
            let versionID = repeatingCurrent ? currentVersionID : keyVersion(for: itemID)?.id
            tryRepeatCurrent = false
            guard attempted.insert(itemID).inserted, let versionID else { continue }
            // Sequential navigation passes over rejected tracks the way it
            // passes over unavailable files: skipped, and kept out of the
            // listening history (`discardSkippedHistory`). Repeat One still
            // repeats a rejected current track; the user chose to play it.
            if !repeatingCurrent, workspace.items.first(where: { $0.id == itemID })?.isRejected == true { continue }
            let snapshot = PlaybackSnapshot(
                itemID: itemID, versionID: versionID, filePosition: 0,
                isPlaying: !returningToStart && (advance == .naturalEnd || wasPlaying)
            )
            switch await activatePlaylist(itemID: itemID, versionID: versionID, snapshot: snapshot) {
            case .activated:
                path.discardSkippedHistory(attempted.subtracting([itemID]))
                traversal = path
                return
            case .unavailable:
                continue
            case .failed, .superseded:
                return
            }
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
            ?? item.keyVersion?.id
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
        let result: ActivationResult
        switch mode {
        case .playlist:
            result = await activatePlaylist(itemID: item.id, versionID: versionID, snapshot: refreshed)
        case .comparison:
            result = await activateComparison(itemID: item.id, versionID: versionID, snapshot: refreshed)
        }
        if result.didFail {
            showPlaylistWithoutRuntime(refreshed)
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
        if currentItemID != nil { enqueuePlaylistAdvance(.naturalEnd) }
    }

    // MARK: - Workspace helpers

    private func keyVersion(for itemID: PlaylistItem.ID) -> PlaylistVersion? {
        workspace.items.first(where: { $0.id == itemID })?.keyVersion
    }

    private func currentVersion() -> PlaylistVersion? {
        guard let itemID = currentItemID,
              let item = workspace.items.first(where: { $0.id == itemID }) else { return nil }
        if let currentVersionID,
           let version = item.versions.first(where: { $0.id == currentVersionID }) {
            return version
        }
        return item.keyVersion
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
        candidate.items[index] = item
        try candidate.validate()
        workspace = candidate
        return [itemID]
    }

    private func prepareAutomaticImportPlan(
        versions: [PlaylistVersion],
        cancellationGeneration: Int
    ) async -> AutomaticImportPlan? {
        var existingVersions = workspace.allVersions
        while !Task.isCancelled, cancellationGeneration == importCancellationGeneration {
            let plan = await Self.makeAutomaticImportPlan(versions: versions, existingVersions: existingVersions)
            guard !Task.isCancelled, cancellationGeneration == importCancellationGeneration else { return nil }
            let currentVersions = workspace.allVersions
            // Group ownership and capacity are read at commit. Pair evidence
            // is reusable as long as the IDs and matching inputs still agree.
            if currentVersions.elementsEqual(existingVersions, by: { current, previous in
                current.id == previous.id
                    && current.metadata == previous.metadata
                    && current.file.storedURL == previous.file.storedURL
            }) {
                return plan
            }
            existingVersions = currentVersions
        }
        return nil
    }

    nonisolated private static func makeAutomaticImportPlan(
        versions: [PlaylistVersion],
        existingVersions: [PlaylistVersion]
    ) async -> AutomaticImportPlan {
        let incoming = versions.map { (id: $0.id, title: TrackMetadataMatcher.normalizedTitle(for: $0)) }
        let existing = existingVersions.map { (id: $0.id, title: TrackMetadataMatcher.normalizedTitle(for: $0)) }
        var decisions: [TrackSimilarityClusterEvidence<UUID>] = []
        for index in incoming.indices {
            if Task.isCancelled { break }
            let first = incoming[index]
            for second in incoming[(index + 1)...] {
                decisions.append(.init(
                    first: first.id, second: second.id,
                    decision: TrackMetadataMatcher.decision(between: first.title, and: second.title)
                ))
            }
            for second in existing {
                decisions.append(.init(
                    first: first.id, second: second.id,
                    decision: TrackMetadataMatcher.decision(between: first.title, and: second.title)
                ))
            }
        }
        return AutomaticImportPlan(decisions: decisions)
    }

    private func applyAutomaticImportPlan(
        _ plan: AutomaticImportPlan,
        versions: [PlaylistVersion]
    ) throws -> [PlaylistItem.ID] {
        let incomingIDs = versions.map(\.id)
        let existingGroups: [TrackSimilarityExistingGroup<UUID, UUID>] = workspace.items.map { item in
            TrackSimilarityExistingGroup(
                id: item.id,
                versionIDs: item.versions.map(\.id),
                availableCapacity: PlaylistWorkspace.maximumVersionsPerItem - item.versions.count
            )
        }
        let result = TrackSimilarityClusterer<UUID, UUID>().cluster(
            incoming: incomingIDs,
            evidence: plan.decisions,
            existingGroups: existingGroups
        )
        let versionsByID = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, $0) })
        var candidate = workspace
        var itemIDByVersionID: [UUID: UUID] = [:]

        for assignment in result.existingAssignments {
            guard let index = candidate.items.firstIndex(where: { $0.id == assignment.groupID }) else { continue }
            let assignedVersions = assignment.members.compactMap { versionsByID[$0] }
            guard candidate.items[index].versions.count + assignedVersions.count <= PlaylistWorkspace.maximumVersionsPerItem else {
                continue
            }
            candidate.items[index].versions.append(contentsOf: assignedVersions)
            for version in assignedVersions { itemIDByVersionID[version.id] = assignment.groupID }
        }

        for group in result.newGroups {
            let groupedVersions = group.compactMap { versionsByID[$0] }
            for chunkStart in stride(from: 0, to: groupedVersions.count, by: PlaylistWorkspace.maximumVersionsPerItem) {
                let chunkEnd = min(chunkStart + PlaylistWorkspace.maximumVersionsPerItem, groupedVersions.count)
                let chunk = Array(groupedVersions[chunkStart..<chunkEnd])
                guard let first = chunk.first else { continue }
                let item = PlaylistItem(title: automaticGroupTitle(for: first), versions: chunk)
                candidate.items.append(item)
                for version in chunk { itemIDByVersionID[version.id] = item.id }
            }
        }

        // A defensive fallback keeps every accepted version if a malformed
        // proposal omitted it.
        for version in versions where itemIDByVersionID[version.id] == nil {
            let item = PlaylistItem(title: automaticGroupTitle(for: version), versions: [version])
            candidate.items.append(item)
            itemIDByVersionID[version.id] = item.id
        }

        try candidate.validate()
        workspace = candidate
        var seen = Set<UUID>()
        return incomingIDs.compactMap { itemIDByVersionID[$0] }.filter { seen.insert($0).inserted }
    }

    private func automaticGroupTitle(for version: PlaylistVersion) -> String {
        let title = version.metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty
            ? version.file.storedURL.deletingPathExtension().lastPathComponent
            : title
    }

    private func mutateWorkspace(
        beforeAction actionName: String,
        undoManager: UndoManager?,
        displayedComparisonOrder: [UUID]? = nil,
        removedVersionID: PlaylistVersion.ID? = nil,
        _ mutation: (inout PlaylistWorkspace) throws -> Void
    ) -> Bool {
        let playback = capturePlaybackSnapshot()
        var before = workspace
        _ = captureRuntimeEdits(into: &before)
        do {
            var candidate = before
            try mutation(&candidate)
            workspace = candidate
            let modeBeforeMutation = mode
            synchronizeModeWithWorkspaceView()
            syncRuntimeRejection()
            let removedFromRuntime = removedVersionID.map { removeComparisonVersionFromRuntime($0) } ?? false
            registerUndo(before: before, undoManager: undoManager, actionName: actionName)
            rebuildTraversal()
            if removedFromRuntime {
                clearError()
                return true
            }
            let listeningVersionMoved = playback.versionID != nil
                && candidate.listeningState?.versionID == playback.versionID
                && candidate.listeningState?.itemID != before.listeningState?.itemID
            if let displayedComparisonOrder {
                controller.reorderTracks(displayedComparisonOrder)
            } else if listeningVersionMoved || runtimeRequiresRefresh(before: before, after: workspace, mode: modeBeforeMutation) {
                // Metadata-only edits must not cancel a runtime refresh queued
                // by an earlier organization action in this same event.
                if let activeID = controller.session.activeTrackID,
                   !candidate.allVersions.contains(where: { $0.id == activeID }) {
                    controller.invalidateRuntimeContext()
                    runtimeContext = nil
                    runtimeTrackCount = 0
                    currentItemID = candidate.listeningState?.itemID
                    currentVersionID = candidate.listeningState?.versionID
                }
                let organizationGeneration = beginNavigation()
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
            if case let PlaylistWorkspaceError.versionLimitExceeded(_, limit) = error {
                versionLimitAlert = .group(limit: limit)
            }
            reportError(error.localizedDescription)
            return false
        }
    }

    private func removeComparisonVersionFromRuntime(_ versionID: PlaylistVersion.ID) -> Bool {
        guard let itemID = mode.itemID,
              let context = runtimeContext, context.itemID == itemID,
              controller.runtimeContext == context, pendingRuntimeRefreshTask == nil,
              let item = workspace.items.first(where: { $0.id == itemID }),
              let key = item.keyVersion else { return false }
        let tracks = controller.session.tracks
        let remaining = tracks.filter { $0.id != versionID }
        guard remaining.count + 1 == tracks.count,
              Set(remaining.map(\.id)) == Set(item.versions.map(\.id)) else { return false }

        // Preserve surviving nodes and waveform tasks. When deleting the
        // active version, pick the same fallback as a comparison activation.
        var replacement: (id: PlaylistVersion.ID, position: TimeInterval?)?
        if controller.session.activeTrackID == versionID {
            let available = Set(remaining.filter { !$0.loadedTrack.isMissing }.map(\.id))
            let next = available.contains(key.id)
                ? key
                : item.versions.first { available.contains($0.id) } ?? key
            replacement = (next.id, next.id == key.id ? key.offsetSeconds : nil)
        }
        beginNavigation()
        controller.removeTrack(versionID, replacingActiveWith: replacement)
        runtimeTrackCount = controller.runtimeTrackCount
        currentVersionID = controller.session.activeTrackID
        captureRuntimeEdits()
        return true
    }

    private func registerUndo(before: PlaylistWorkspace, undoManager: UndoManager?, actionName: String) {
        guard let undoManager else { return }
        let after = workspace
        undoManager.registerUndo(withTarget: self) { target in
            target.applyOrganizationUndo(from: after, to: before, manager: undoManager, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    /// Apply the recorded organization change to today's versions. File repairs,
    /// comparison edits and items added since the command keep their live values.
    private func applyOrganizationUndo(
        from original: PlaylistWorkspace,
        to target: PlaylistWorkspace,
        manager: UndoManager,
        actionName: String
    ) {
        var playback = capturePlaybackSnapshot()
        captureRuntimeEdits()
        let live = workspace
        var candidate = live
        let originalItems = Dictionary(uniqueKeysWithValues: original.items.map { ($0.id, $0) })
        let liveItems = Dictionary(uniqueKeysWithValues: live.items.map { ($0.id, $0) })
        let originalVersions = Dictionary(uniqueKeysWithValues: original.allVersions.map { ($0.id, $0) })
        let liveVersions = Dictionary(uniqueKeysWithValues: live.allVersions.map { ($0.id, $0) })
        let targetItemIDs = Set(target.items.map(\.id))
        let recordedIDs = Set(originalVersions.keys)
        let targetIDs = Set(target.allVersions.map(\.id))
        let targetVersions = Dictionary(uniqueKeysWithValues: target.allVersions.map { ($0.id, $0) })

        candidate.items = target.items.compactMap { recorded in
            let prior = originalItems[recorded.id]
            let current = liveItems[recorded.id]
            guard prior == nil || current != nil else { return nil }
            var item = current ?? recorded
            if current?.title == prior?.title { item.title = recorded.title }
            if prior?.versions.map(\.id) != recorded.versions.map(\.id) {
                item.versions = recorded.versions.compactMap { version in
                    guard let old = originalVersions[version.id] else { return version }
                    guard var latest = liveVersions[version.id] else { return nil }
                    latest.offsetSeconds += version.offsetSeconds - old.offsetSeconds
                    return latest
                }
                item.versions += (current?.versions ?? []).filter { !recordedIDs.contains($0.id) && !targetIDs.contains($0.id) }
            }
            // Rejection rebases like the title: the recorded flag applies
            // unless the live flag changed since the command.
            if current?.isRejected == prior?.isRejected { item.isRejected = recorded.isRejected }
            item.versions = item.versions.map { version in
                guard let old = originalVersions[version.id], let recordedVersion = targetVersions[version.id],
                      version.isRejected == old.isRejected else { return version }
                var rebased = version
                rebased.isRejected = recordedVersion.isRejected
                return rebased
            }
            return item.versions.isEmpty ? nil : item
        }
        for item in live.items where !targetItemIDs.contains(item.id) {
            var retained = item
            if originalItems[item.id] != nil {
                retained.versions.removeAll { recordedIDs.contains($0.id) || targetIDs.contains($0.id) }
            }
            if !retained.versions.isEmpty { candidate.items.append(retained) }
        }
        if original.items.map(\.id) == target.items.map(\.id) {
            let order = Dictionary(uniqueKeysWithValues: live.items.enumerated().map { ($1.id, $0) })
            candidate.items.sort { order[$0.id, default: .max] < order[$1.id, default: .max] }
        }

        let owner = candidate.items.first { item in item.versions.contains { $0.id == playback.versionID } }
        if let owner, let versionID = playback.versionID {
            playback.itemID = owner.id
            candidate.listeningState = PlaylistListeningState(
                itemID: owner.id, versionID: versionID, filePosition: playback.filePosition
            )
            candidate.activeView = mode == .playlist ? .playlist : .comparison(itemID: owner.id)
        } else {
            let fallback = target.listeningState.flatMap { state in
                candidate.items.contains { $0.id == state.itemID && $0.versions.contains { $0.id == state.versionID } }
                    ? state : nil
            }
            candidate.listeningState = fallback
            if playback.itemID == nil, let itemID = fallback?.itemID, target.activeItemID == itemID {
                candidate.activeView = .comparison(itemID: itemID)
            } else {
                candidate.activeView = .playlist
            }
            playback = PlaybackSnapshot(itemID: fallback?.itemID, versionID: fallback?.versionID,
                                        filePosition: fallback?.filePosition ?? 0, isPlaying: false)
        }
        do { try candidate.validate() } catch {
            reportError(error.localizedDescription)
            return
        }
        workspace = candidate
        syncRuntimeRejection()
        registerUndo(before: live, undoManager: manager, actionName: actionName)
        rebuildTraversal()
        let targetMode: Mode = candidate.activeItemID.map { .comparison(itemID: $0) } ?? .playlist
        let needsRefresh = pendingRuntimeRefreshTask != nil || runtimeContext?.itemID != playback.itemID
            || controller.session.activeTrackID != playback.versionID || targetMode != mode
            || runtimeRequiresRefresh(before: live, after: candidate, mode: mode)
        mode = targetMode
        currentItemID = playback.itemID
        currentVersionID = playback.versionID
        let generation = beginNavigation()
        if playback.itemID == nil {
            showPlaylistWithoutRuntime(playback)
        } else if needsRefresh {
            pendingRuntimeRefreshTask = Task { [weak self] in
                guard let self, self.navigationGeneration == generation else { return }
                self.pendingRuntimeRefreshTask = nil
                await self.refreshAfterOrganization(snapshot: playback)
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
        if runtimeMatchesMode, let track = controller.session.activeTrack?.loadedTrack {
            let position = TransportMapping.filePosition(
                forGlobalTime: controller.displayTransportPosition(), offset: track.offsetSeconds
            )
            filePosition = min(max(position, 0), track.duration)
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
        return controller.session.activeTrackID ?? candidate.items[index].keyVersion?.id
    }

    private func captureListeningState(into candidate: inout PlaylistWorkspace) {
        guard let itemID = currentItemID ?? mode.itemID,
              runtimeContext?.itemID == itemID,
              let item = candidate.items.first(where: { $0.id == itemID }),
              let versionID = controller.session.activeTrackID ?? currentVersionID ?? item.keyVersion?.id,
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
        // Rejection never touches the audio runtime: a rejected version keeps
        // playing, and compare lanes take the flag in place
        // (`syncRuntimeRejection`). Compare versions without it.
        let oldItem = before.items.first(where: { $0.id == itemID }).map(Self.ignoringRejection)
        let newItem = after.items.first(where: { $0.id == itemID }).map(Self.ignoringRejection)
        if mode == .playlist, let versionID = currentVersionID {
            return oldItem?.versions.first { $0.id == versionID } != newItem?.versions.first { $0.id == versionID }
        }
        return oldItem?.versions != newItem?.versions
            || oldItem?.comparison != newItem?.comparison
    }

    /// Push the versions' rejection flags into the loaded compare lanes in
    /// place (spec §5.1: one flag, shown in both modes). A runtime that is
    /// rebuilt picks them up from the workspace instead.
    private func syncRuntimeRejection() {
        guard let itemID = runtimeContext?.itemID,
              let item = workspace.items.first(where: { $0.id == itemID }) else { return }
        controller.setRejectedTracks(Set(item.versions.filter(\.isRejected).map(\.id)))
    }

    private static func ignoringRejection(_ item: PlaylistItem) -> PlaylistItem {
        var item = item
        item.isRejected = false
        for index in item.versions.indices { item.versions[index].isRejected = false }
        return item
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
        pendingRuntimeRefreshTask = nil
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

    private func recordFileIssue(_ error: PlaybackError, for version: PlaylistVersion) {
        let issue = FileIssue(reference: version.file, error: error)
        if fileIssues[version.id] != issue { fileIssues[version.id] = issue }
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

    /// The item with each version's file resolved, and the versions whose
    /// files are missing. Missing versions keep their stored URL and still
    /// become lanes (`LoadedTrack.isMissing`); compare opens regardless.
    private func materializedComparisonItem(_ item: PlaylistItem) -> (item: PlaylistItem, missingIDs: Set<PlaylistVersion.ID>) {
        var materialized = item
        var missingIDs = Set<PlaylistVersion.ID>()
        for index in materialized.versions.indices {
            if case let .available(url) = PlaylistWorkspaceStore.resolveFileReference(materialized.versions[index].file) {
                materialized.versions[index].file.storedURL = url
            } else {
                missingIDs.insert(materialized.versions[index].id)
            }
        }
        return (materialized, missingIDs)
    }
}
