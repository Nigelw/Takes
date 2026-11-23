import AppKit
import SwiftUI

enum PlaylistRowID: Hashable {
    case item(UUID)
    case version(UUID)
}

@MainActor
final class PlaylistPresentationState: ObservableObject {
    @Published var selection: Set<PlaylistRowID> = []
    @Published var expanded: Set<UUID> = []
    @Published var renamingItemID: UUID?
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
        let valid = Set(workspace.items.map { PlaylistRowID.item($0.id) }
            + workspace.allVersions.map { PlaylistRowID.version($0.id) })
        selection.formIntersection(valid)
        expanded.formIntersection(Set(workspace.items.map(\.id)))
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

    /// Grouping needs a destination item; loose versions selected alongside
    /// it are moved into the group.
    var canGroup: Bool { !itemIDs.isEmpty && itemIDs.count + versionIDs.count > 1 }
    var canRemove: Bool { !itemIDs.isEmpty || !versionIDs.isEmpty }
    var canSeparate: Bool {
        coordinator.workspace.items.contains { item in
            item.versions.count > 1 && (itemIDs.contains(item.id)
                || item.versions.contains { versionIDs.contains($0.id) })
        }
    }

    func group(compare: Bool) {
        let ids = itemIDs
        let looseVersions = versionIDs
        Task {
            let destination: UUID?
            if ids.count > 1 {
                destination = await coordinator.groupItems(
                    ids, compare: compare && looseVersions.isEmpty, undoManager: undoManager
                )
            } else {
                destination = ids.first
            }
            guard let destination else { return }
            if !looseVersions.isEmpty {
                for id in looseVersions { coordinator.moveVersion(id, to: destination, undoManager: undoManager) }
                if compare { await coordinator.enterComparison(itemID: destination) }
            }
            presentation.selection = [.item(destination)]
            presentation.expanded.insert(destination)
        }
    }

    func remove() {
        let items = itemIDs
        let versions = versionIDs
        let removed = targetRows
        let firstRemovedIndex = presentation.visibleRows(in: coordinator.workspace).firstIndex(where: removed.contains)
        undoManager?.beginUndoGrouping()
        if !items.isEmpty { coordinator.removeItems(items, undoManager: undoManager) }
        if !versions.isEmpty { coordinator.removeVersions(versions, undoManager: undoManager) }
        undoManager?.endUndoGrouping()
        presentation.prune(in: coordinator.workspace)
        // Select the row that took the removed rows' place, so Delete can be
        // pressed repeatedly.
        let remaining = presentation.visibleRows(in: coordinator.workspace)
        if presentation.selection.isEmpty, let firstRemovedIndex, !remaining.isEmpty {
            presentation.selection = [remaining[min(firstRemovedIndex, remaining.count - 1)]]
        }
    }

    func separate() {
        let selectedItems = Set(itemIDs)
        let selectedVersions = Set(versionIDs)
        let ids = coordinator.workspace.items.flatMap { item -> [UUID] in
            guard item.versions.count > 1 else { return [] }
            return item.versions.filter { selectedItems.contains(item.id) || selectedVersions.contains($0.id) }.map(\.id)
        }
        undoManager?.beginUndoGrouping()
        for id in ids.reversed() {
            guard let source = coordinator.workspace.items.first(where: { $0.versions.contains { $0.id == id } }),
                  source.versions.count > 1 else { continue }
            _ = coordinator.separateVersion(id, undoManager: undoManager)
        }
        undoManager?.endUndoGrouping()
        presentation.prune(in: coordinator.workspace)
    }

    func moveSelection(direction: Int) {
        var order = coordinator.workspace.items.map(\.id)
        let selected = Set(itemIDs)
        guard !selected.isEmpty else { return }
        let indices = direction < 0 ? Array(order.indices) : Array(order.indices.reversed())
        for index in indices where selected.contains(order[index]) {
            let next = index + direction
            guard order.indices.contains(next), !selected.contains(order[next]) else { continue }
            order.swapAt(index, next)
        }
        coordinator.reorderItems(order, undoManager: undoManager)
    }
}

private struct PlaylistCommandContextKey: FocusedValueKey {
    typealias Value = PlaylistCommandContext
}

extension FocusedValues {
    var playlistCommandContext: PlaylistCommandContext? {
        get { self[PlaylistCommandContextKey.self] }
        set { self[PlaylistCommandContextKey.self] = newValue }
    }
}

struct PlaylistCommands: Commands {
    @FocusedValue(\.playlistCommandContext) private var context

    var body: some Commands {
        CommandMenu("Playlist") {
            PlaylistOrganizationMenuItems(context: context)
        }
    }
}

/// The organisation commands, acting on the selection. The Playlist menu and
/// the bottom bar's `…` pull-down (A2 §7) both show this one list.
struct PlaylistOrganizationMenuItems: View {
    let context: PlaylistCommandContext?

    var body: some View {
        Button("Group as Versions") { context?.group(compare: false) }
            .disabled(context?.canGroup != true)
        Button("Group and Compare") { context?.group(compare: true) }
            .disabled(context?.canGroup != true)
        Button("Rename…") { context?.presentation.renamingItemID = context?.itemIDs.first }
            .disabled(context?.itemIDs.count != 1)
        Button("Separate Versions") { context?.separate() }
            .disabled(context?.canSeparate != true)
        Divider()
        Button("Move Up") { context?.moveSelection(direction: -1) }
            .disabled(context?.itemIDs.isEmpty != false)
        Button("Move Down") { context?.moveSelection(direction: 1) }
            .disabled(context?.itemIDs.isEmpty != false)
        Divider()
        Button("Clear Playlist") { _ = context?.coordinator.clearPlaylist(undoManager: context?.undoManager) }
            .disabled(context?.coordinator.workspace.items.isEmpty != false)
    }
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
                    currentItemID: coordinator.currentItemID,
                    isPlaying: coordinator.isPlaying,
                    isActive: coordinator.mode == .playlist,
                    artworkStore: artworkStore,
                    undoManager: undoManager
                )
            }
        }
        .background(Theme.timelineWellShade)
        .onChange(of: items.map { ($0.id.uuidString + $0.versions.map { $0.id.uuidString }.joined()) }) { _, _ in
            presentation.prune(in: coordinator.workspace)
        }
    }
}
