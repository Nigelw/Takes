import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    var draggingItemIDs: [UUID] = []

    func itemIDs(in workspace: PlaylistWorkspace) -> [UUID] {
        workspace.items.filter { selection.contains(.item($0.id)) }.map(\.id)
    }

    func versionIDs(in workspace: PlaylistWorkspace) -> [UUID] {
        workspace.items.filter { !selection.contains(.item($0.id)) }
            .flatMap(\.versions).filter { selection.contains(.version($0.id)) }.map(\.id)
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

    var itemIDs: [UUID] { presentation.itemIDs(in: coordinator.workspace) }
    var versionIDs: [UUID] { presentation.versionIDs(in: coordinator.workspace) }
    var canGroup: Bool { itemIDs.count > 1 && versionIDs.isEmpty }
    var canRemove: Bool { !itemIDs.isEmpty || !versionIDs.isEmpty }
    var canSeparate: Bool {
        coordinator.workspace.items.contains { item in
            item.versions.count > 1 && (itemIDs.contains(item.id)
                || item.versions.contains { versionIDs.contains($0.id) })
        }
    }

    func group(compare: Bool) {
        let ids = itemIDs
        Task {
            if let id = await coordinator.groupItems(ids, compare: compare, undoManager: undoManager) {
                presentation.selection = [.item(id)]
                presentation.expanded.insert(id)
            }
        }
    }

    func remove() {
        let items = itemIDs
        let versions = versionIDs
        undoManager?.beginUndoGrouping()
        if !items.isEmpty { coordinator.removeItems(items, undoManager: undoManager) }
        if !versions.isEmpty { coordinator.removeVersions(versions, undoManager: undoManager) }
        undoManager?.endUndoGrouping()
        presentation.prune(in: coordinator.workspace)
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
}

private enum PlaylistItemDrag {
    static let type = UTType(exportedAs: "com.nigelwarren.takes.playlist-item")
}

struct PlaylistView: View {
    let coordinator: PlaylistCoordinator
    @ObservedObject var presentation: PlaylistPresentationState
    @ObservedObject var openFiles: OpenFileCommandState
    @Environment(\.undoManager) private var undoManager
    @State private var renameText = ""
    @FocusState private var listFocused: Bool

    private var commands: PlaylistCommandContext {
        .init(coordinator: coordinator, presentation: presentation, undoManager: undoManager)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ImportActionSplitButton(dropdownItems: ImportActionMenuItem.dropdownItems) { action in
                    switch action {
                    case .open: openFiles.presentOpenDialog()
                    case .streamingURL: openFiles.presentStreamingURLPrompt()
                    case .finderSelection: openFiles.openFinderSelection()
                    case .musicSelection: openFiles.openAppleMusicSelection()
                    }
                }
                .frame(width: ImportActionControlMetrics.controlWidth, height: ImportActionControlMetrics.controlHeight)
                Spacer()
                Text("\(coordinator.workspace.items.count) items")
                    .foregroundStyle(.secondary).font(.caption)
                Button("Group and Compare") { commands.group(compare: true) }
                    .disabled(!commands.canGroup)
                Menu {
                    organizationMenu
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Playlist Actions")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            List(selection: $presentation.selection) {
                ForEach(coordinator.workspace.items) { item in
                    itemRow(item)
                        .tag(PlaylistRowID.item(item.id))
                        .onDrag {
                            if !presentation.selection.contains(.item(item.id)) {
                                presentation.selection = [.item(item.id)]
                            }
                            presentation.draggingItemIDs = presentation.itemIDs(in: coordinator.workspace)
                            return NSItemProvider(item: item.id.uuidString as NSString, typeIdentifier: PlaylistItemDrag.type.identifier)
                        }
                        .onDrop(of: [PlaylistItemDrag.type], isTargeted: nil) { _ in reorder(before: item.id) }
                    if presentation.expanded.contains(item.id) {
                        ForEach(item.versions) { version in
                            versionRow(version, item: item).tag(PlaylistRowID.version(version.id))
                        }
                    }
                }
                if !coordinator.workspace.items.isEmpty {
                    Color.clear.frame(height: 12).listRowSeparator(.hidden)
                        .onDrop(of: [PlaylistItemDrag.type], isTargeted: nil) { _ in reorder(before: nil) }
                        .accessibilityHidden(true)
                }
            }
            .listStyle(.inset)
            .focused($listFocused)
            .onChange(of: listFocused) { _, focused in presentation.listHasFocus = focused }
            .onKeyPress(.return) { playSelection(); return .handled }
            .onKeyPress(.rightArrow) {
                presentation.expanded.formUnion(presentation.itemIDs(in: coordinator.workspace)); return .handled
            }
            .onKeyPress(.leftArrow) {
                presentation.expanded.subtract(presentation.itemIDs(in: coordinator.workspace)); return .handled
            }
            .contextMenu(forSelectionType: PlaylistRowID.self) { _ in
                organizationMenu
            } primaryAction: { ids in
                playSelection(ids)
            }
            .overlay {
                if coordinator.workspace.items.isEmpty {
                    ContentUnavailableView {
                        Label("Your Playlist", systemImage: "music.note.list")
                    } description: {
                        Text("Add audio files, then group versions of a song to compare them.")
                    } actions: {
                        Button("Add Files…") { openFiles.presentOpenDialog() }
                    }
                    .allowsHitTesting(true)
                }
            }
        }
        .background(Theme.timelineWellShade)
        .onChange(of: coordinator.workspace.items.map { ($0.id.uuidString + $0.versions.map { $0.id.uuidString }.joined()) }) { _, _ in
            presentation.prune(in: coordinator.workspace)
        }
        .onChange(of: coordinator.mode) { _, mode in
            listFocused = mode == .playlist
        }
        .sheet(isPresented: Binding(
            get: { presentation.renamingItemID != nil },
            set: { if !$0 { presentation.renamingItemID = nil } }
        )) { renameSheet }
    }

    private func itemRow(_ item: PlaylistItem) -> some View {
        let metadata = item.selectedVersion?.metadata
        return HStack(spacing: 10) {
            Button {
                if presentation.expanded.contains(item.id) { presentation.expanded.remove(item.id) }
                else { presentation.expanded.insert(item.id) }
            } label: {
                Image(systemName: presentation.expanded.contains(item.id) ? "chevron.down" : "chevron.right")
                    .font(.caption).frame(width: 12)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Versions for \(item.title)")
            .accessibilityValue(presentation.expanded.contains(item.id) ? "Expanded" : "Collapsed")
            Image(systemName: coordinator.currentItemID == item.id && coordinator.isPlaying ? "speaker.wave.2.fill" : "music.note")
                .foregroundStyle(coordinator.currentItemID == item.id ? Theme.primary : .secondary)
                .frame(width: 20)
                .accessibilityLabel(coordinator.currentItemID == item.id && coordinator.isPlaying ? "Playing" : "")
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.headline).lineLimit(1).help(item.title)
                Text(metadata?.artist ?? "—").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(metadata?.album ?? "—").font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).frame(width: 110, alignment: .leading)
            Text((metadata?.duration ?? 0).formattedSignedTimestamp).monospacedDigit().font(.caption)
                .frame(width: 48, alignment: .trailing)
            Text("\(item.versions.count)").font(.caption).foregroundStyle(.secondary)
                .frame(width: 20).accessibilityLabel("\(item.versions.count) versions")
            if item.versions.count > 1 {
                Button("Compare") { compare(item) }
                    .buttonStyle(.borderless).frame(width: 65)
            } else {
                Color.clear.frame(width: 65, height: 1).accessibilityHidden(true)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Play") { play(item) }
            if item.versions.count > 1 {
                Button("Compare") { compare(item) }
            }
            Button("Rename…") { presentation.renamingItemID = item.id }
            Button("Remove") { coordinator.removeItem(item.id, undoManager: undoManager) }
            if let version = item.selectedVersion, availableURL(for: version) == nil {
                Button("Locate File…") { presentation.locateVersionID = version.id }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func versionRow(_ version: PlaylistVersion, item: PlaylistItem) -> some View {
        let available = availableURL(for: version) != nil
        return HStack(spacing: 10) {
            Button { Task { await coordinator.selectPlaybackVersion(version.id, in: item.id) } } label: {
                Image(systemName: item.selectedVersionID == version.id ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Use \(version.metadata.displayName) for playback")
            .accessibilityValue(item.selectedVersionID == version.id ? "Selected" : "Not selected")
            VStack(alignment: .leading, spacing: 2) {
                Text(version.metadata.displayName.isEmpty ? version.file.storedURL.lastPathComponent : version.metadata.displayName)
                    .lineLimit(1).help(version.file.storedURL.path)
                Text(available ? version.metadata.fileFormatDescription : "File unavailable")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(version.metadata.duration.formattedSignedTimestamp).font(.caption).monospacedDigit()
            if !available {
                Button("Locate File…") { presentation.locateVersionID = version.id }.buttonStyle(.borderless)
            }
            Menu {
                Button("Play This Version") { play(item, version: version) }
                Menu("Move To") {
                    ForEach(coordinator.workspace.items.filter { $0.id != item.id }) { destination in
                        Button(destination.title) {
                            coordinator.moveVersion(version.id, to: destination.id, undoManager: undoManager)
                        }.disabled(destination.versions.count >= PlaylistWorkspace.maximumVersionsPerItem)
                    }
                }
                Button("Separate into Playlist Item") { _ = coordinator.separateVersion(version.id, undoManager: undoManager) }
                    .disabled(item.versions.count < 2)
                Button("Reveal in Finder") {
                    if let url = availableURL(for: version) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }.disabled(!available)
                Button("Locate File…") { presentation.locateVersionID = version.id }
                Divider()
                Button("Remove Version") { coordinator.removeVersion(version.id, undoManager: undoManager) }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Version Actions")
        }
        .padding(.leading, 32).padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var organizationMenu: some View {
        Button("Group as Versions") { commands.group(compare: false) }.disabled(!commands.canGroup)
        Button("Group and Compare") { commands.group(compare: true) }.disabled(!commands.canGroup)
        Button("Rename…") { presentation.renamingItemID = commands.itemIDs.first }.disabled(commands.itemIDs.count != 1)
        Button("Separate Versions") { commands.separate() }.disabled(!commands.canSeparate)
        Divider()
        Button("Move Up") { commands.moveSelection(direction: -1) }.disabled(commands.itemIDs.isEmpty)
        Button("Move Down") { commands.moveSelection(direction: 1) }.disabled(commands.itemIDs.isEmpty)
        Button("Remove") { commands.remove() }.disabled(!commands.canRemove)
        Button("Clear Playlist") { coordinator.clearPlaylist(undoManager: undoManager) }
            .disabled(coordinator.workspace.items.isEmpty)
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Playlist Item").font(.headline)
            TextField("Title", text: $renameText).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { presentation.renamingItemID = nil }.keyboardShortcut(.cancelAction)
                Button("Rename") {
                    if let id = presentation.renamingItemID {
                        coordinator.renameItem(id, to: renameText.trimmingCharacters(in: .whitespacesAndNewlines), undoManager: undoManager)
                    }
                    presentation.renamingItemID = nil
                }.keyboardShortcut(.defaultAction)
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 360)
            .onAppear { renameText = coordinator.workspace.items.first { $0.id == presentation.renamingItemID }?.title ?? "" }
    }

    private func availableURL(for version: PlaylistVersion) -> URL? {
        guard case let .available(url) = PlaylistWorkspaceStore.resolveFileReference(version.file) else { return nil }
        return url
    }

    private func play(_ item: PlaylistItem, version: PlaylistVersion? = nil) {
        guard let version = version ?? item.selectedVersion else { return }
        guard availableURL(for: version) != nil else {
            presentation.locateVersionID = version.id
            return
        }
        Task { await coordinator.playItem(id: item.id, versionID: version.id) }
    }

    private func compare(_ item: PlaylistItem) {
        if let missing = item.versions.first(where: { availableURL(for: $0) == nil }) {
            presentation.locateVersionID = missing.id
            return
        }
        Task { await coordinator.enterComparison(itemID: item.id) }
    }

    private func playSelection(_ selectedRows: Set<PlaylistRowID>? = nil) {
        let selectedRows = selectedRows ?? presentation.selection
        for item in coordinator.workspace.items {
            if selectedRows.contains(.item(item.id)) {
                play(item); return
            }
            if let version = item.versions.first(where: { selectedRows.contains(.version($0.id)) }) {
                play(item, version: version); return
            }
        }
    }

    private func reorder(before destination: UUID?) -> Bool {
        let ids = presentation.draggingItemIDs
        presentation.draggingItemIDs = []
        guard !ids.isEmpty, destination.map({ !ids.contains($0) }) ?? true else { return false }
        var order = coordinator.workspace.items.map(\.id).filter { !ids.contains($0) }
        let index = destination.flatMap { order.firstIndex(of: $0) } ?? order.endIndex
        order.insert(contentsOf: ids, at: index)
        return coordinator.reorderItems(order, undoManager: undoManager)
    }
}
