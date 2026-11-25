import AppKit
import SwiftUI

enum PlaylistRowID: Hashable {
    case item(UUID)
    case version(UUID)
}

enum RowMoveDirection: Int { case up = -1, down = 1 }

@MainActor
final class PlaylistPresentationState: ObservableObject {
    @Published var selection: Set<PlaylistRowID> = []
    @Published var expanded: Set<UUID> = []
    @Published var locateVersionID: UUID?
    @Published var listHasFocus = false

    /// Rows in display order: each item, then its versions while a
    /// multi-version item is expanded.
    func visibleRows(in workspace: PlaylistWorkspace) -> [PlaylistRowID] {
        workspace.items.flatMap { item in
            [.item(item.id)] + (item.versions.count > 1 && expanded.contains(item.id)
                ? item.versions.map { .version($0.id) } : [])
        }
    }

    func prune(in workspace: PlaylistWorkspace) {
        let remainingExpansion = expanded.intersection(workspace.items.map(\.id))
        if expanded != remainingExpansion { expanded = remainingExpansion }
        let visible = Set(visibleRows(in: workspace))
        let remainingSelection = selection.intersection(visible)
        if selection != remainingSelection { selection = remainingSelection }
    }
}

@MainActor
struct PlaylistCommandContext {
    let coordinator: PlaylistCoordinator
    let presentation: PlaylistPresentationState
    let undoManager: UndoManager?
    /// Rows the commands act on. Nil means the current selection; a context
    /// menu opened on an unselected row passes that row instead.
    var rows: Set<PlaylistRowID>?

    private var isPlaylist: Bool { coordinator.mode == .playlist }
    private var targetRows: Set<PlaylistRowID> { isPlaylist ? rows ?? presentation.selection : [] }

    var itemIDs: [UUID] {
        let rows = targetRows
        return coordinator.workspace.items.filter { rows.contains(.item($0.id)) }.map(\.id)
    }

    /// Selected versions whose item is not itself selected.
    var versionIDs: [UUID] {
        let rows = targetRows
        return coordinator.workspace.items.filter { !rows.contains(.item($0.id)) }
            .flatMap(\.versions).filter { rows.contains(.version($0.id)) }.map(\.id)
    }

    private var groupSources: (items: [UUID], versions: [UUID])? {
        let items = itemIDs
        guard !items.isEmpty else { return nil }
        let versions = versionIDs
        guard items.count + versions.count > 1 else { return nil }
        return (items, versions)
    }

    var canGroup: Bool { groupSources != nil }
    var canRemove: Bool { !itemIDs.isEmpty || !versionIDs.isEmpty }
    var canSeparate: Bool { !versionsToSeparate.isEmpty }

    func selectAll() {
        guard isPlaylist else { return }
        presentation.selection = Set(presentation.visibleRows(in: coordinator.workspace))
    }

    func deselectAll() {
        guard isPlaylist else { return }
        presentation.selection = []
    }

    func selectCurrentSong() {
        guard isPlaylist, let itemID = coordinator.currentItemID else { return }
        presentation.selection = [.item(itemID)]
    }

    func group() {
        guard let sources = groupSources,
              let destination = coordinator.groupItems(
                sources.items, looseVersionIDs: sources.versions, undoManager: undoManager
              ) else { return }
        presentation.selection = [.item(destination)]
        presentation.expanded.insert(destination)
    }

    func remove() {
        let items = itemIDs
        let versions = versionIDs
        let removed = targetRows
        let firstRemovedIndex = presentation.visibleRows(in: coordinator.workspace).firstIndex(where: removed.contains)
        guard coordinator.removeVersions(versions, alongWithItems: items, undoManager: undoManager) else { return }
        presentation.prune(in: coordinator.workspace)
        // Select the row that took the removed rows' place, so Delete can be
        // pressed repeatedly.
        let remaining = presentation.visibleRows(in: coordinator.workspace)
        if presentation.selection.isEmpty, let firstRemovedIndex, !remaining.isEmpty {
            presentation.selection = [remaining[min(firstRemovedIndex, remaining.count - 1)]]
        }
    }

    private var versionsToSeparate: [UUID] {
        let selectedItems = Set(itemIDs)
        let selectedVersions = Set(versionIDs)
        return coordinator.workspace.items.flatMap { item -> [UUID] in
            guard item.versions.count > 1 else { return [] }
            return item.versions.filter { selectedItems.contains(item.id) || selectedVersions.contains($0.id) }.map(\.id)
        }
    }

    func separate() {
        let versions = versionsToSeparate
        guard !versions.isEmpty else { return }
        let ids = Set(versions)
        let selectedItems = Set(itemIDs)
        guard coordinator.separateVersions(versions, placement: .adjacent, undoManager: undoManager) != nil else { return }
        presentation.selection = Set(coordinator.workspace.items.compactMap { item in
            guard item.versions.count == 1,
                  selectedItems.contains(item.id) || item.versions.contains(where: { ids.contains($0.id) })
            else { return nil }
            return .item(item.id)
        })
        presentation.prune(in: coordinator.workspace)
    }

    /// Reject / Clear Rejection targets (culling spec §4.1, §5.2). In the
    /// playlist a selected item row targets the track only, not its
    /// versions; selected version rows target those versions.
    var rejectionTargets: (items: [UUID], versions: [UUID]) {
        let rows = targetRows
        return (itemIDs, coordinator.workspace.allVersions.filter { rows.contains(.version($0.id)) }.map(\.id))
    }

    var canToggleRejection: Bool {
        let targets = rejectionTargets
        return !targets.items.isEmpty || !targets.versions.isEmpty
    }

    /// Every target is already rejected, so the command reads Clear Rejection.
    var rejectionClears: Bool {
        let targets = rejectionTargets
        return coordinator.rejectionClears(itemIDs: targets.items, versionIDs: targets.versions)
    }

    func toggleRejection() {
        let targets = rejectionTargets
        coordinator.toggleRejection(itemIDs: targets.items, versionIDs: targets.versions, undoManager: undoManager)
    }

    /// View ▸ Compare Versions (⌘]): the one multi-version item the selection points
    /// at, as the row's Compare pill and context menu allow.
    var compareItemID: UUID? {
        let rows = targetRows
        let owners = Set(coordinator.workspace.items.filter { item in
            rows.contains(.item(item.id)) || item.versions.contains { rows.contains(.version($0.id)) }
        }.map(\.id))
        guard owners.count == 1, let id = owners.first,
              (coordinator.workspace.items.first { $0.id == id }?.versions.count ?? 0) > 1 else { return nil }
        return id
    }

    func compare() {
        guard let id = compareItemID else { return }
        Task {
            guard isPlaylist else { return }
            await coordinator.enterComparison(itemID: id)
        }
    }

    /// File ▸ Locate File…: the first missing file among the selected rows
    /// (an item row stands for all its versions).
    var locateVersionID: UUID? {
        let rows = targetRows
        for item in coordinator.workspace.items {
            for version in item.versions where rows.contains(.item(item.id)) || rows.contains(.version(version.id)) {
                if coordinator.fileIssues[version.id]?.reference == version.file { return version.id }
                if case .available = PlaylistWorkspaceStore.resolveFileReference(version.file) { continue }
                return version.id
            }
        }
        return nil
    }

    func locate() {
        guard isPlaylist else { return }
        presentation.locateVersionID = locateVersionID
    }

    private struct Move {
        var items: [UUID]?
        var versions: [UUID: [UUID]] = [:]
        var isPossible: Bool { items != nil || !versions.isEmpty }
    }

    private func movePlan(_ direction: RowMoveDirection) -> Move {
        let items = coordinator.workspace.items
        let rows = targetRows
        let selectedItems = Set(itemIDs)
        var plan = Move(items: Self.shift(items.map(\.id), selected: selectedItems, by: direction.rawValue))
        for item in items where !selectedItems.contains(item.id) && item.versions.count > 1 {
            let order = item.versions.map(\.id)
            let selected = Set(order.filter { rows.contains(.version($0)) })
            plan.versions[item.id] = Self.shift(order, selected: selected, by: direction.rawValue)
        }
        return plan
    }

    private static func shift(_ original: [UUID], selected: Set<UUID>, by direction: Int) -> [UUID]? {
        guard !selected.isEmpty else { return nil }
        var order = original
        let indices = direction < 0 ? Array(order.indices) : Array(order.indices.reversed())
        for index in indices where selected.contains(order[index]) {
            let next = index + direction
            guard order.indices.contains(next), !selected.contains(order[next]) else { continue }
            order.swapAt(index, next)
        }
        return order == original ? nil : order
    }

    func canMove(_ direction: RowMoveDirection) -> Bool {
        movePlan(direction).isPossible
    }

    func moveSelection(_ direction: RowMoveDirection) {
        let plan = movePlan(direction)
        guard plan.isPossible else { return }
        coordinator.reorderPlaylistRows(items: plan.items, versions: plan.versions, undoManager: undoManager)
    }
}

/// Culling's Reject / Clear Rejection command, shared by the Playlist menu,
/// the bottom bar's pull-down, the row and lane-strip context menus, and the
/// key monitor.
enum PlaylistRejectionCommand {
    static let key: KeyEquivalent = "r"
    static let modifiers: EventModifiers = .command
    static let appKitModifiers: NSEvent.ModifierFlags = .command
    /// The R key's virtual key code, for the workspace key monitor.
    static let keyCode: UInt16 = 15

    static func title(clears: Bool) -> String { clears ? "Clear Rejection" : "Reject" }
}

/// Publish validation by value so the scene menu updates as selection and order change.
struct PlaylistOrganizationAvailability: Equatable {
    let canGroup: Bool
    let canSeparate: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let canReject: Bool
    let rejectionClears: Bool

    @MainActor
    init(_ context: PlaylistCommandContext) {
        let isPlaylist = context.coordinator.mode == .playlist
        canGroup = isPlaylist && context.canGroup
        canSeparate = isPlaylist && context.canSeparate
        canMoveUp = isPlaylist ? context.canMove(.up) : context.coordinator.canMoveActiveComparisonVersion(.up)
        canMoveDown = isPlaylist ? context.canMove(.down) : context.coordinator.canMoveActiveComparisonVersion(.down)
        if let active = context.coordinator.activeComparisonVersionID {
            canReject = true
            rejectionClears = context.coordinator.rejectionClears(itemIDs: [], versionIDs: [active])
        } else {
            canReject = context.canToggleRejection
            rejectionClears = context.rejectionClears
        }
    }

    /// The Reject command's title: Clear Rejection when every target is
    /// already rejected.
    var rejectionTitle: String { PlaylistRejectionCommand.title(clears: rejectionClears) }
}

private struct PlaylistCommandContextKey: FocusedValueKey {
    typealias Value = PlaylistCommandContext
}

private struct PlaylistOrganizationAvailabilityKey: FocusedValueKey {
    typealias Value = PlaylistOrganizationAvailability
}

private struct CanDeselectKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var canDeselect: Bool? {
        get { self[CanDeselectKey.self] }
        set { self[CanDeselectKey.self] = newValue }
    }

    var playlistCommandContext: PlaylistCommandContext? {
        get { self[PlaylistCommandContextKey.self] }
        set { self[PlaylistCommandContextKey.self] = newValue }
    }

    var playlistOrganizationAvailability: PlaylistOrganizationAvailability? {
        get { self[PlaylistOrganizationAvailabilityKey.self] }
        set { self[PlaylistOrganizationAvailabilityKey.self] = newValue }
    }
}

struct PlaylistCommands: Commands {
    let coordinator: PlaylistCoordinator
    @FocusedValue(\.playlistCommandContext) private var context
    @FocusedValue(\.playlistOrganizationAvailability) private var availability
    @FocusedValue(\.openFileCommandState) private var openFileCommandState
    @FocusedValue(\.canRemoveActiveTrack) private var canRemoveActiveTrack
    @FocusedValue(\.canClearTracks) private var canClearTracks
    @FocusedValue(\.canUseGlobalMenuShortcuts) private var canUseGlobalMenuShortcuts

    private var isComparison: Bool { coordinator.mode.itemID != nil }

    var body: some Commands {
        CommandMenu("Playlist") {
            if !isComparison {
                Button("Go to Current Song") { context?.selectCurrentSong() }
                    .keyboardShortcut("l", modifiers: [.command])
                    .disabled(context == nil || coordinator.currentItemID == nil || canUseGlobalMenuShortcuts != true)
                Divider()
            }

            playlistOrganizationMenuItems(context: context, availability: availability, move: { direction in
                if coordinator.mode == .playlist {
                    context?.moveSelection(direction)
                } else {
                    coordinator.moveActiveComparisonVersion(direction, undoManager: NSApp.mainWindow?.undoManager)
                }
            }, toggleRejection: {
                if let active = coordinator.activeComparisonVersionID {
                    coordinator.toggleRejection(versionIDs: [active], undoManager: NSApp.mainWindow?.undoManager)
                } else {
                    context?.toggleRejection()
                }
            })

            Divider()

            Button(isComparison ? "Remove Current Version" : "Remove Selected Items") {
                openFileCommandState?.removeActiveTrack()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(openFileCommandState == nil || canRemoveActiveTrack != true || canUseGlobalMenuShortcuts != true)

            Button(isComparison ? "Remove All Versions" : "Remove All Tracks") {
                openFileCommandState?.clearAllTracks()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(openFileCommandState == nil || canClearTracks != true || canUseGlobalMenuShortcuts != true)
        }
    }
}

/// The organisation commands, acting on the selection. The Playlist menu and
/// the bottom bar's `…` pull-down (A2 §7) both show this one list; the
/// pull-down leaves out Reject, which has its own button beside it.
@MainActor @ViewBuilder
func playlistOrganizationMenuItems(
    context: PlaylistCommandContext?, availability: PlaylistOrganizationAvailability?,
    move: @escaping (RowMoveDirection) -> Void, toggleRejection: (() -> Void)?
) -> some View {
    Button("Move Up") { move(.up) }
        .keyboardShortcut(.upArrow, modifiers: [.command, .option])
        .disabled(availability?.canMoveUp != true)
    Button("Move Down") { move(.down) }
        .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        .disabled(availability?.canMoveDown != true)
    Divider()
    Button("Group Versions") { context?.group() }
        .keyboardShortcut("g", modifiers: [.command])
        .disabled(availability?.canGroup != true)
    Button("Ungroup Versions") { context?.separate() }
        .keyboardShortcut("g", modifiers: [.command, .shift])
        .disabled(availability?.canSeparate != true)
    if let toggleRejection {
        Divider()
        Button(availability?.rejectionTitle ?? PlaylistRejectionCommand.title(clears: false)) { toggleRejection() }
            .keyboardShortcut(PlaylistRejectionCommand.key, modifiers: PlaylistRejectionCommand.modifiers)
            .disabled(availability?.canReject != true)
    }
}

/// The playlist list (A2 §6). There is no header bar: the bottom bar below
/// it (`PlaylistBottomBar`, A2 §7) carries Add Files…, Remove Selected and
/// organisation commands shared with the Playlist menu.
struct PlaylistView: View {
    let coordinator: PlaylistCoordinator
    @ObservedObject var presentation: PlaylistPresentationState
    @ObservedObject var openFiles: OpenFileCommandState
    let artworkStore: PlaylistArtworkStore
    let isDropTargeted: Bool
    @Environment(\.undoManager) private var undoManager
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let items = coordinator.workspace.items
        Group {
            if items.isEmpty {
                FileImportEmptyState(
                    icon: "music.note.list", dragPrompt: "Drag Files Here to Play", clickPrompt: "Click Here to Play",
                    accessibilityLabel: "Add audio files to the playlist", isDropTargeted: isDropTargeted
                ) {
                    if coordinator.mode == .playlist { openFiles.presentOpenDialog() }
                }
            } else {
                PlaylistOutline(
                    playlist: coordinator,
                    presentation: presentation,
                    items: items,
                    metadataFields: settings.playlistMetadataFields,
                    fileIssues: coordinator.fileIssues,
                    currentItemID: coordinator.currentItemID,
                    currentVersionID: coordinator.currentVersionID,
                    isPlaying: coordinator.isPlaying,
                    isActive: coordinator.mode == .playlist,
                    moveRevision: coordinator.rowMoveRevision,
                    artworkStore: artworkStore,
                    undoManager: undoManager,
                    showsDebugLabels: settings.showsComponentDebugLabels
                )
            }
        }
        .background(Theme.timelineWellShade)
        .componentDebugLabel("Playlist", enabled: settings.showsComponentDebugLabels, color: .orange)
    }
}
