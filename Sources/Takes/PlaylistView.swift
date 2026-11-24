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

    private var targetRows: Set<PlaylistRowID> { rows ?? presentation.selection }

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

    /// View ▸ Compare (⌘]): the one multi-version item the selection points
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
        Task { await coordinator.enterComparison(itemID: id) }
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

/// Publish validation by value so the scene menu updates as selection and order change.
struct PlaylistOrganizationAvailability: Equatable {
    let canGroup: Bool
    let canSeparate: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let canClear: Bool

    @MainActor
    init(_ context: PlaylistCommandContext) {
        let isPlaylist = context.coordinator.mode == .playlist
        canGroup = isPlaylist && context.canGroup
        canSeparate = isPlaylist && context.canSeparate
        canMoveUp = isPlaylist ? context.canMove(.up) : context.coordinator.canMoveActiveComparisonVersion(.up)
        canMoveDown = isPlaylist ? context.canMove(.down) : context.coordinator.canMoveActiveComparisonVersion(.down)
        canClear = isPlaylist && !context.coordinator.workspace.items.isEmpty
    }
}

private struct PlaylistCommandContextKey: FocusedValueKey {
    typealias Value = PlaylistCommandContext
}

private struct PlaylistOrganizationAvailabilityKey: FocusedValueKey {
    typealias Value = PlaylistOrganizationAvailability
}

extension FocusedValues {
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

    var body: some Commands {
        CommandMenu("Playlist") {
            playlistOrganizationMenuItems(context: context, availability: availability) { direction in
                if coordinator.mode == .playlist {
                    context?.moveSelection(direction)
                } else {
                    coordinator.moveActiveComparisonVersion(direction, undoManager: NSApp.mainWindow?.undoManager)
                }
            }
        }
    }
}

/// The organisation commands, acting on the selection. The Playlist menu and
/// the bottom bar's `…` pull-down (A2 §7) both show this one list.
@MainActor @ViewBuilder
func playlistOrganizationMenuItems(
    context: PlaylistCommandContext?, availability: PlaylistOrganizationAvailability?,
    move: @escaping (RowMoveDirection) -> Void
) -> some View {
    Button("Group as Versions") { context?.group() }
        .keyboardShortcut("g", modifiers: [.command])
        .disabled(availability?.canGroup != true)
    Button("Separate Versions") { context?.separate() }
        .keyboardShortcut("g", modifiers: [.command, .shift])
        .disabled(availability?.canSeparate != true)
    Divider()
    Button("Move Up") { move(.up) }
        .keyboardShortcut(.upArrow, modifiers: [.command, .option])
        .disabled(availability?.canMoveUp != true)
    Button("Move Down") { move(.down) }
        .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        .disabled(availability?.canMoveDown != true)
    Divider()
    Button("Clear Playlist") { _ = context?.coordinator.clearPlaylist(undoManager: context?.undoManager) }
        .disabled(availability?.canClear != true)
}

/// The playlist list (A2 §6). There is no header bar: the bottom bar below
/// it (`PlaylistBottomBar`, A2 §7) carries Add Files…, Remove Selected and
/// the organisation commands, which the File menu, the Playlist menu and
/// the context menu also offer.
struct PlaylistView: View {
    let coordinator: PlaylistCoordinator
    @ObservedObject var presentation: PlaylistPresentationState
    @ObservedObject var openFiles: OpenFileCommandState
    let artworkStore: PlaylistArtworkStore
    @Environment(\.undoManager) private var undoManager
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let items = coordinator.workspace.items
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("Your Playlist", systemImage: "music.note.list")
                } description: {
                    Text("Add audio files, then group versions of a song to compare them.")
                } actions: {
                    Button("Add Files…") { openFiles.presentOpenDialog() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PlaylistOutline(
                    playlist: coordinator,
                    presentation: presentation,
                    items: items,
                    metadataFields: settings.playlistMetadataFields,
                    fileIssues: coordinator.fileIssues,
                    currentItemID: coordinator.currentItemID,
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
