import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Private pasteboard flavor for in-app playlist row drags. Declared as an
/// exported type in Takes-Info.plist so no external drag can carry it.
enum PlaylistItemDrag {
    static let type = UTType(exportedAs: "com.nigelwarren.takes.playlist-item")
    static let pasteboardType = NSPasteboard.PasteboardType(type.identifier)
}

/// The playlist table: an `NSOutlineView` of playlist items with their
/// versions as children. AppKit owns selection drawing, disclosure, keyboard
/// navigation, type-select, and drag and drop; `PlaylistPresentationState`
/// stays the source of truth for selection and expansion so menu commands and
/// the workspace keep working against plain values.
struct PlaylistOutline: NSViewRepresentable {
    let playlist: PlaylistCoordinator
    @ObservedObject var presentation: PlaylistPresentationState
    let items: [PlaylistItem]
    let currentItemID: UUID?
    let isPlaying: Bool
    let isActive: Bool
    let undoManager: UndoManager?

    func makeCoordinator() -> PlaylistOutlineController {
        PlaylistOutlineController(playlist: playlist, presentation: presentation)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.undoManager = undoManager
        context.coordinator.update(items: items, currentItemID: currentItemID, isPlaying: isPlaying, isActive: isActive)
    }
}

// MARK: - Nodes

/// Reference-typed outline item. `NSOutlineView` identifies rows by object
/// identity, so one node is kept per stable playlist ID across reloads.
final class PlaylistNode: NSObject {
    let rowID: PlaylistRowID

    init(_ rowID: PlaylistRowID) { self.rowID = rowID }

    var itemID: UUID? { if case let .item(id) = rowID { return id }; return nil }
    var versionID: UUID? { if case let .version(id) = rowID { return id }; return nil }
}

private enum PlaylistColumn {
    static let title = NSUserInterfaceItemIdentifier("title")
    static let artist = NSUserInterfaceItemIdentifier("artist")
    static let album = NSUserInterfaceItemIdentifier("album")
    static let format = NSUserInterfaceItemIdentifier("format")
    static let time = NSUserInterfaceItemIdentifier("time")
    static let actions = NSUserInterfaceItemIdentifier("actions")
}

enum PlaylistRowText {
    /// `2:41`, or `1:02:41` past an hour — no leading zero on the first field.
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "" }
        let total = Int(max(0, seconds.rounded()))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    /// The details that distinguish versions of one song: container, sample
    /// rate, and bit rate.
    static func format(_ metadata: PlaylistMetadata) -> String {
        var parts: [String] = []
        if !metadata.fileFormatDescription.isEmpty { parts.append(metadata.fileFormatDescription) }
        if metadata.sampleRate.isFinite, metadata.sampleRate > 0 {
            let kHz = metadata.sampleRate / 1000
            let text = kHz == kHz.rounded() ? String(format: "%.0f", kHz) : String(format: "%.1f", kHz)
            parts.append("\(text) kHz")
        }
        if metadata.bitRate.isFinite, metadata.bitRate > 0 {
            parts.append("\(Int((metadata.bitRate / 1000).rounded())) kbps")
        }
        return parts.joined(separator: " · ")
    }

    static func versionName(_ version: PlaylistVersion) -> String {
        version.metadata.displayName.isEmpty ? version.file.storedURL.lastPathComponent : version.metadata.displayName
    }
}

// MARK: - Controller

@MainActor
final class PlaylistOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSTextFieldDelegate, NSMenuDelegate {
    private let playlist: PlaylistCoordinator
    private let presentation: PlaylistPresentationState
    var undoManager: UndoManager?

    private var outlineView: PlaylistNSOutlineView!
    private var items: [PlaylistItem] = []
    private var itemsByID: [UUID: PlaylistItem] = [:]
    private var ownerByVersionID: [UUID: UUID] = [:]
    private var nodes: [PlaylistRowID: PlaylistNode] = [:]
    private var currentItemID: UUID?
    private var isPlaying = false
    private var isActive = false
    private var hasLoaded = false
    /// True while this controller pushes model state into the outline view, so
    /// the resulting delegate callbacks are not echoed back into the model.
    private var isApplying = false
    private var availability: [UUID: (reference: PlaylistFileReference, url: URL?)] = [:]
    private var draggedNodes: [PlaylistNode] = []
    private var editingItemID: UUID?
    private var needsContentReload = false

    init(playlist: PlaylistCoordinator, presentation: PlaylistPresentationState) {
        self.playlist = playlist
        self.presentation = presentation
    }

    // MARK: Setup

    func makeScrollView() -> NSScrollView {
        let outline = PlaylistNSOutlineView()
        outline.controller = self
        outline.style = .inset
        outline.rowSizeStyle = .custom
        outline.rowHeight = 24
        outline.indentationPerLevel = 16
        outline.intercellSpacing = NSSize(width: 10, height: 0)
        outline.backgroundColor = .clear
        outline.gridStyleMask = []
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.allowsColumnReordering = false
        outline.allowsTypeSelect = true
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.setAccessibilityLabel("Playlist")

        func column(
            _ id: NSUserInterfaceItemIdentifier, _ title: String, width: CGFloat, min: CGFloat, max: CGFloat = 2000,
            resizing: NSTableColumn.ResizingOptions, alignment: NSTextAlignment = .left
        ) -> NSTableColumn {
            let column = NSTableColumn(identifier: id)
            column.title = title
            column.width = width
            column.minWidth = min
            column.maxWidth = max
            column.resizingMask = resizing
            column.headerCell.alignment = alignment
            outline.addTableColumn(column)
            return column
        }
        let flexible: NSTableColumn.ResizingOptions = [.autoresizingMask, .userResizingMask]
        let title = column(PlaylistColumn.title, "Title", width: 210, min: 160, resizing: flexible)
        _ = column(PlaylistColumn.artist, "Artist", width: 100, min: 60, resizing: flexible)
        _ = column(PlaylistColumn.album, "Album", width: 100, min: 60, resizing: flexible)
        _ = column(PlaylistColumn.format, "Format", width: 110, min: 50, resizing: flexible)
        _ = column(PlaylistColumn.time, "Time", width: 46, min: 46, max: 64, resizing: [], alignment: .right)
        _ = column(PlaylistColumn.actions, "", width: 70, min: 70, max: 70, resizing: [])
        outline.outlineTableColumn = title
        outline.autosaveName = "TakesPlaylistColumns"
        outline.autosaveTableColumns = true

        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(rowDoubleClicked)
        outline.registerForDraggedTypes([PlaylistItemDrag.pasteboardType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.draggingDestinationFeedbackStyle = .regular

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        outline.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        outlineView = outline

        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(clipViewBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        center.addObserver(
            self, selector: #selector(windowBecameKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil
        )
        return scrollView
    }

    @objc private func clipViewBoundsChanged() { refreshHover() }

    /// Files can appear or disappear while Takes is in the background.
    @objc private func windowBecameKey(_ notification: Notification) {
        guard notification.object as? NSWindow === outlineView.window else { return }
        availability.removeAll()
        reloadContent()
    }

    // MARK: Model → view

    func update(items newItems: [PlaylistItem], currentItemID: UUID?, isPlaying: Bool, isActive: Bool) {
        let structureChanged = !hasLoaded || Self.structure(newItems) != Self.structure(items)
        let contentChanged = newItems != items || currentItemID != self.currentItemID || isPlaying != self.isPlaying
        let becameActive = isActive && !self.isActive
        items = newItems
        self.currentItemID = currentItemID
        self.isPlaying = isPlaying
        self.isActive = isActive
        itemsByID = Dictionary(uniqueKeysWithValues: newItems.map { ($0.id, $0) })
        ownerByVersionID = [:]
        for item in newItems { for version in item.versions { ownerByVersionID[version.id] = item.id } }

        if structureChanged {
            if !hasLoaded {
                // Fit the columns to the window once the scroll view has a size.
                DispatchQueue.main.async { [weak self] in self?.outlineView.sizeToFit() }
            }
            hasLoaded = true
            if editingItemID != nil { finishRename(commit: false) }
            let valid = Set(newItems.flatMap { item in [PlaylistRowID.item(item.id)] + item.versions.map { .version($0.id) } })
            nodes = nodes.filter { valid.contains($0.key) }
            availability = availability.filter { ownerByVersionID[$0.key] != nil }
            isApplying = true
            outlineView.reloadData()
            isApplying = false
        } else if contentChanged {
            reloadContent()
        }
        applyExpansion()
        applySelection()
        if becameActive { focusOutline() }
        if let id = presentation.renamingItemID, editingItemID != id {
            DispatchQueue.main.async { [weak self] in self?.beginRename(id) }
        }
    }

    private static func structure(_ items: [PlaylistItem]) -> [[UUID]] {
        items.map { [$0.id] + $0.versions.map(\.id) }
    }

    private func reloadContent() {
        guard hasLoaded else { return }
        guard editingItemID == nil else { needsContentReload = true; return }
        needsContentReload = false
        outlineView.reloadData(
            forRowIndexes: IndexSet(integersIn: 0..<outlineView.numberOfRows),
            columnIndexes: IndexSet(integersIn: 0..<outlineView.numberOfColumns)
        )
    }

    private func applyExpansion() {
        isApplying = true
        defer { isApplying = false }
        for item in items {
            let node = node(.item(item.id))
            let shouldExpand = item.versions.count > 1 && presentation.expanded.contains(item.id)
            if shouldExpand != outlineView.isItemExpanded(node) {
                if shouldExpand { outlineView.expandItem(node) } else { outlineView.collapseItem(node) }
            }
        }
    }

    private func applySelection() {
        var rows = IndexSet()
        for rowID in presentation.selection {
            guard let node = nodes[rowID] else { continue }
            let row = outlineView.row(forItem: node)
            if row >= 0 { rows.insert(row) }
        }
        guard rows != outlineView.selectedRowIndexes else { return }
        isApplying = true
        outlineView.selectRowIndexes(rows, byExtendingSelection: false)
        isApplying = false
        if rows.count == 1, let row = rows.first { outlineView.scrollRowToVisible(row) }
    }

    func focusOutline() {
        DispatchQueue.main.async { [weak self] in
            guard let outline = self?.outlineView, let window = outline.window else { return }
            if window.firstResponder !== outline { window.makeFirstResponder(outline) }
        }
    }

    func focusChanged(_ focused: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentation.listHasFocus != focused else { return }
            self.presentation.listHasFocus = focused
        }
    }

    // MARK: Lookup

    private func node(_ rowID: PlaylistRowID) -> PlaylistNode {
        if let node = nodes[rowID] { return node }
        let node = PlaylistNode(rowID)
        nodes[rowID] = node
        return node
    }

    private func version(_ id: UUID) -> (item: PlaylistItem, version: PlaylistVersion)? {
        guard let itemID = ownerByVersionID[id], let item = itemsByID[itemID],
              let version = item.versions.first(where: { $0.id == id }) else { return nil }
        return (item, version)
    }

    private func availableURL(for version: PlaylistVersion) -> URL? {
        if let cached = availability[version.id], cached.reference == version.file { return cached.url }
        var url: URL?
        if case let .available(resolved) = PlaylistWorkspaceStore.resolveFileReference(version.file) { url = resolved }
        availability[version.id] = (version.file, url)
        return url
    }

    /// The version a row stands for: a version row's own, or an item row's
    /// playback version.
    private func representedVersion(_ rowID: PlaylistRowID) -> (item: PlaylistItem, version: PlaylistVersion)? {
        switch rowID {
        case let .item(id):
            guard let item = itemsByID[id], let version = item.selectedVersion ?? item.versions.first else { return nil }
            return (item, version)
        case let .version(id):
            return version(id)
        }
    }

    private func rowsInDisplayOrder(_ rows: Set<PlaylistRowID>) -> [PlaylistRowID] {
        items.flatMap { item in [PlaylistRowID.item(item.id)] + item.versions.map { .version($0.id) } }
            .filter(rows.contains)
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? PlaylistNode else { return items.count }
        guard let id = node.itemID, let item = itemsByID[id], item.versions.count > 1 else { return 0 }
        return item.versions.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? PlaylistNode, let id = node.itemID, let item = itemsByID[id] else {
            return node(.item(items[index].id))
        }
        return self.node(.version(item.versions[index].id))
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let id = (item as? PlaylistNode)?.itemID, let item = itemsByID[id] else { return false }
        return item.versions.count > 1
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("row")
        if let reused = outlineView.makeView(withIdentifier: id, owner: nil) as? PlaylistRowView { return reused }
        let rowView = PlaylistRowView()
        rowView.identifier = id
        return rowView
    }

    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        (rowView as? PlaylistRowView)?.updateActions()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let column = tableColumn?.identifier, let node = item as? PlaylistNode else { return nil }
        switch column {
        case PlaylistColumn.title:
            let cell = reuse(column) { PlaylistTitleCellView(identifier: column) }
            configureTitle(cell, node: node)
            return cell
        case PlaylistColumn.actions:
            let cell = reuse(column) { PlaylistActionCellView(identifier: column) }
            configureActions(cell, node: node)
            return cell
        default:
            let isTime = column == PlaylistColumn.time
            let cell = reuse(column) { PlaylistTextCellView(identifier: column, alignment: isTime ? .right : .left, monospacedDigits: isTime) }
            cell.label.stringValue = text(for: column, node: node)
            return cell
        }
    }

    private func reuse<Cell: NSView>(_ id: NSUserInterfaceItemIdentifier, make: () -> Cell) -> Cell {
        (outlineView.makeView(withIdentifier: id, owner: nil) as? Cell) ?? make()
    }

    private func text(for column: NSUserInterfaceItemIdentifier, node: PlaylistNode) -> String {
        guard let (_, version) = representedVersion(node.rowID) else { return "" }
        let isItem = node.itemID != nil
        switch column {
        case PlaylistColumn.artist: return isItem ? version.metadata.artist ?? "" : ""
        case PlaylistColumn.album: return isItem ? version.metadata.album ?? "" : ""
        case PlaylistColumn.format:
            return availableURL(for: version) == nil && !isItem ? "File not found" : PlaylistRowText.format(version.metadata)
        case PlaylistColumn.time: return PlaylistRowText.duration(version.metadata.duration)
        default: return ""
        }
    }

    private func configureTitle(_ cell: PlaylistTitleCellView, node: PlaylistNode) {
        cell.titleField.delegate = self
        switch node.rowID {
        case let .item(id):
            guard let item = itemsByID[id] else { return }
            let selectedMissing = (item.selectedVersion ?? item.versions.first).map { availableURL(for: $0) == nil } ?? false
            let missingCount = item.versions.filter { availableURL(for: $0) == nil }.count
            let indicator: PlaylistTitleCellView.Indicator = currentItemID == id ? .nowPlaying(isPlaying: isPlaying) : .none
            let warning: String? = missingCount == 0 ? nil
                : item.versions.count == 1 ? "The file for this item can’t be found."
                : "\(missingCount) of \(item.versions.count) files can’t be found."
            cell.configure(
                title: item.title, indicator: indicator, versionCount: item.versions.count,
                warning: warning, isDimmed: selectedMissing, toolTip: nil
            )
            cell.onIndicator = nil
        case let .version(id):
            guard let (item, version) = version(id) else { return }
            let missing = availableURL(for: version) == nil
            cell.configure(
                title: PlaylistRowText.versionName(version),
                indicator: .playbackVersion(isSelected: item.selectedVersionID == id),
                versionCount: 0, warning: missing ? "This file can’t be found." : nil, isDimmed: missing,
                toolTip: version.file.storedURL.path
            )
            cell.onIndicator = { [weak self] in
                guard let self else { return }
                Task { await self.playlist.selectPlaybackVersion(id, in: item.id) }
            }
        }
    }

    private func configureActions(_ cell: PlaylistActionCellView, node: PlaylistNode) {
        switch node.rowID {
        case let .item(id):
            cell.kind = (itemsByID[id]?.versions.count ?? 0) > 1 ? .compare : .none
            cell.onCompare = { [weak self] in self?.compare(itemID: id) }
        case .version:
            cell.kind = .more
            cell.onMore = { [weak self, weak node] button in
                guard let self, let node else { return }
                let menu = NSMenu()
                menu.autoenablesItems = false
                self.menuItems(for: self.targetRows(for: node)).forEach(menu.addItem)
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
            }
        }
        let row = outlineView.row(forItem: node)
        if row >= 0, let rowView = outlineView.rowView(atRow: row, makeIfNecessary: false) as? PlaylistRowView {
            cell.actionsVisible = rowView.showsActions
        } else {
            cell.actionsVisible = false
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplying else { return }
        let selection = Set(outlineView.selectedRowIndexes.compactMap { (outlineView.item(atRow: $0) as? PlaylistNode)?.rowID })
        if selection != presentation.selection { presentation.selection = selection }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isApplying, let id = (notification.userInfo?["NSObject"] as? PlaylistNode)?.itemID else { return }
        presentation.expanded.insert(id)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isApplying, let id = (notification.userInfo?["NSObject"] as? PlaylistNode)?.itemID else { return }
        presentation.expanded.remove(id)
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        guard let node = item as? PlaylistNode else { return nil }
        switch node.rowID {
        case let .item(id): return itemsByID[id]?.title
        case let .version(id): return version(id).map { PlaylistRowText.versionName($0.version) }
        }
    }

    private func refreshHover() {
        guard let window = outlineView.window else { return }
        let point = outlineView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let inside = outlineView.visibleRect.contains(point)
        outlineView.enumerateAvailableRowViews { rowView, _ in
            (rowView as? PlaylistRowView)?.isHovered = inside && rowView.frame.contains(point)
        }
    }

    // MARK: Actions

    @objc private func rowDoubleClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? PlaylistNode else { return }
        play([node.rowID])
    }

    func playSelection() {
        play(presentation.selection)
    }

    private func play(_ rows: Set<PlaylistRowID>) {
        guard let rowID = rowsInDisplayOrder(rows).first, let (item, version) = representedVersion(rowID) else { return }
        guard availableURL(for: version) != nil else {
            presentation.locateVersionID = version.id
            return
        }
        Task { await playlist.playItem(id: item.id, versionID: version.id) }
    }

    private func compare(itemID: UUID) {
        guard let item = itemsByID[itemID] else { return }
        if let missing = item.versions.first(where: { availableURL(for: $0) == nil }) {
            presentation.locateVersionID = missing.id
            return
        }
        Task { await playlist.enterComparison(itemID: itemID) }
    }

    /// Outline-style arrow keys: Left collapses, or moves from a version to
    /// its item; Right expands, or moves from an expanded item to its first
    /// version.
    func handleHorizontalArrow(forward: Bool) {
        let selected = outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? PlaylistNode }
        guard !selected.isEmpty else { return }
        let changing = selected.filter { outlineView.isExpandable($0) && outlineView.isItemExpanded($0) != forward }
        if !changing.isEmpty {
            for node in changing {
                if forward { outlineView.animator().expandItem(node) } else { outlineView.animator().collapseItem(node) }
            }
            return
        }
        guard selected.count == 1, let node = selected.first else { return }
        let target: Int
        if forward {
            guard outlineView.isItemExpanded(node) else { return }
            target = outlineView.row(forItem: node) + 1
        } else {
            guard let parent = outlineView.parent(forItem: node) else { return }
            target = outlineView.row(forItem: parent)
        }
        guard target >= 0, target < outlineView.numberOfRows else { return }
        outlineView.selectRowIndexes([target], byExtendingSelection: false)
        outlineView.scrollRowToVisible(target)
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? PlaylistNode else { return }
        menuItems(for: targetRows(for: node)).forEach(menu.addItem)
    }

    /// A menu opened on a selected row acts on the whole selection; opened on
    /// an unselected row it acts on that row alone.
    private func targetRows(for node: PlaylistNode) -> Set<PlaylistRowID> {
        presentation.selection.contains(node.rowID) ? presentation.selection : [node.rowID]
    }

    private func menuItems(for rows: Set<PlaylistRowID>) -> [NSMenuItem] {
        let context = PlaylistCommandContext(coordinator: playlist, presentation: presentation, undoManager: undoManager, rows: rows)
        let itemIDs = context.itemIDs, versionIDs = context.versionIDs
        let single = rows.count == 1 ? rows.first : nil
        var sections: [[NSMenuItem]] = []

        var playback: [NSMenuItem] = [ClosureMenuItem("Play") { [weak self] in self?.play(rows) }]
        if case let .item(id)? = single, (itemsByID[id]?.versions.count ?? 0) > 1 {
            playback.append(ClosureMenuItem("Compare") { [weak self] in self?.compare(itemID: id) })
        }
        if case let .version(id)? = single, let (item, _) = version(id), item.selectedVersionID != id {
            playback.append(ClosureMenuItem("Use for Playback") { [weak self] in
                guard let self else { return }
                Task { await self.playlist.selectPlaybackVersion(id, in: item.id) }
            })
        }
        sections.append(playback)

        var organize: [NSMenuItem] = []
        if rows.count > 1, !itemIDs.isEmpty {
            organize.append(ClosureMenuItem("Group as Versions", enabled: context.canGroup) { context.group(compare: false) })
            organize.append(ClosureMenuItem("Group and Compare", enabled: context.canGroup) { context.group(compare: true) })
        }
        if context.canSeparate {
            let title = itemIDs.isEmpty && versionIDs.count == 1 ? "Separate into Playlist Item" : "Separate Versions"
            organize.append(ClosureMenuItem(title) { context.separate() })
        }
        if itemIDs.isEmpty, !versionIDs.isEmpty {
            let owners = Set(versionIDs.compactMap { ownerByVersionID[$0] })
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for destination in items where owners != [destination.id] {
                let incoming = versionIDs.filter { ownerByVersionID[$0] != destination.id }.count
                let hasRoom = destination.versions.count + incoming <= PlaylistWorkspace.maximumVersionsPerItem
                submenu.addItem(ClosureMenuItem(destination.title, enabled: hasRoom) { [weak self] in
                    self?.moveVersions(versionIDs, to: destination.id, before: nil)
                })
            }
            let moveTo = NSMenuItem(title: "Move To", action: nil, keyEquivalent: "")
            moveTo.submenu = submenu
            moveTo.isEnabled = submenu.numberOfItems > 0
            organize.append(moveTo)
        }
        if case let .item(id)? = single {
            organize.append(ClosureMenuItem("Rename…") { [weak self] in self?.presentation.renamingItemID = id })
        }
        if !organize.isEmpty { sections.append(organize) }

        let represented = rowsInDisplayOrder(rows).compactMap { representedVersion($0)?.version }
        let urls = represented.compactMap { availableURL(for: $0) }
        var files: [NSMenuItem] = [ClosureMenuItem("Reveal in Finder", enabled: !urls.isEmpty) {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }]
        if let single {
            let candidates: [PlaylistVersion]
            switch single {
            case let .item(id): candidates = itemsByID[id]?.versions ?? []
            case .version: candidates = represented
            }
            if let missing = candidates.first(where: { availableURL(for: $0) == nil }) {
                files.append(ClosureMenuItem("Locate File…") { [weak self] in self?.presentation.locateVersionID = missing.id })
            }
        }
        sections.append(files)
        sections.append([ClosureMenuItem("Remove", enabled: context.canRemove) { context.remove() }])

        var result: [NSMenuItem] = []
        for section in sections {
            if !result.isEmpty { result.append(.separator()) }
            result.append(contentsOf: section)
        }
        return result
    }

    // MARK: Inline rename

    private func beginRename(_ itemID: UUID) {
        guard editingItemID == nil, presentation.renamingItemID == itemID else { return }
        guard let node = nodes[.item(itemID)], case let row = outlineView.row(forItem: node), row >= 0,
              let window = outlineView.window else {
            presentation.renamingItemID = nil
            return
        }
        outlineView.scrollRowToVisible(row)
        let column = outlineView.column(withIdentifier: PlaylistColumn.title)
        guard let cell = outlineView.view(atColumn: column, row: row, makeIfNecessary: true) as? PlaylistTitleCellView else {
            presentation.renamingItemID = nil
            return
        }
        editingItemID = itemID
        cell.setEditing(true)
        window.makeFirstResponder(cell.titleField)
        cell.titleField.currentEditor()?.selectAll(nil)
    }

    private func finishRename(commit: Bool, field: NSTextField? = nil) {
        guard let itemID = editingItemID else { return }
        editingItemID = nil
        let original = itemsByID[itemID]?.title ?? ""
        if let field {
            let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            (field.superview?.superview as? PlaylistTitleCellView ?? field.superview as? PlaylistTitleCellView)?.setEditing(false)
            if commit, !title.isEmpty, title != original {
                playlist.renameItem(itemID, to: title, undoManager: undoManager)
            } else {
                field.stringValue = original
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.presentation.renamingItemID == itemID { self.presentation.renamingItemID = nil }
            if self.needsContentReload { self.reloadContent() }
            if let window = self.outlineView.window, window.firstResponder === window {
                window.makeFirstResponder(self.outlineView)
            }
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        finishRename(commit: true, field: notification.object as? NSTextField)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)), let field = control as? NSTextField else { return false }
        field.abortEditing()
        finishRename(commit: false, field: field)
        return true
    }

    // MARK: Drag source

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? PlaylistNode else { return nil }
        let pasteboardItem = NSPasteboardItem()
        let id = node.itemID ?? node.versionID
        pasteboardItem.setString(id?.uuidString ?? "", forType: PlaylistItemDrag.pasteboardType)
        // The file URL lets a row be dragged out to Finder or another app.
        if let version = representedVersion(node.rowID)?.version, let url = availableURL(for: version) {
            pasteboardItem.setString(url.absoluteString, forType: .fileURL)
        }
        return pasteboardItem
    }

    func outlineView(
        _ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]
    ) {
        draggedNodes = draggedItems.compactMap { $0 as? PlaylistNode }
    }

    func outlineView(
        _ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        draggedNodes = []
    }

    // MARK: Drop destination

    private enum DropPlan {
        case reorderItems([UUID])
        case group([UUID], into: UUID)
        case separate([UUID], beforeItem: UUID?)
        case moveVersions([UUID], to: UUID, before: UUID?)
    }

    private struct ResolvedDrop {
        let plan: DropPlan
        let item: PlaylistNode?
        let childIndex: Int
    }

    private func resolveDrop(proposedItem: PlaylistNode?, childIndex: Int) -> ResolvedDrop? {
        let dragged = Set(draggedNodes.map(\.rowID))
        let draggedItems = items.map(\.id).filter { dragged.contains(.item($0)) }
        let draggedVersions = items.flatMap(\.versions).map(\.id).filter { dragged.contains(.version($0)) }
        // A drag carries items or versions, never both.
        guard draggedItems.isEmpty != draggedVersions.isEmpty else { return nil }
        let limit = PlaylistWorkspace.maximumVersionsPerItem

        // Resolve the proposal to a target item (nil for the top level) and a
        // child index (-1 for "on the item").
        var targetItem: PlaylistItem?
        var index = childIndex
        if let proposedItem {
            switch proposedItem.rowID {
            case let .item(id):
                targetItem = itemsByID[id]
            case let .version(id):
                guard let (owner, _) = version(id) else { return nil }
                targetItem = owner
                index = owner.versions.firstIndex { $0.id == id } ?? NSOutlineViewDropOnItemIndex
            }
            guard targetItem != nil else { return nil }
        }

        if !draggedItems.isEmpty {
            guard let target = targetItem else {
                let insertion = index < 0 ? items.count : min(index, items.count)
                let anchor = items[insertion...].first { !draggedItems.contains($0.id) }?.id
                var order = items.map(\.id).filter { !draggedItems.contains($0) }
                order.insert(contentsOf: draggedItems, at: anchor.flatMap { order.firstIndex(of: $0) } ?? order.endIndex)
                guard order != items.map(\.id) else { return nil }
                return ResolvedDrop(plan: .reorderItems(order), item: nil, childIndex: insertion)
            }
            // Dropping items on an item groups them into it as versions.
            guard !draggedItems.contains(target.id) else { return nil }
            let incoming = draggedItems.reduce(0) { $0 + (itemsByID[$1]?.versions.count ?? 0) }
            guard target.versions.count + incoming <= limit else { return nil }
            return ResolvedDrop(
                plan: .group(draggedItems, into: target.id), item: node(.item(target.id)),
                childIndex: NSOutlineViewDropOnItemIndex
            )
        }

        guard let target = targetItem else {
            // Dropping versions between items separates them into new items.
            let insertion = index < 0 ? items.count : min(index, items.count)
            let anchor = insertion < items.count ? items[insertion].id : nil
            return ResolvedDrop(plan: .separate(draggedVersions, beforeItem: anchor), item: nil, childIndex: insertion)
        }
        let incoming = draggedVersions.filter { ownerByVersionID[$0] != target.id }.count
        guard target.versions.count + incoming <= limit else { return nil }
        if index < 0 {
            guard incoming > 0 else { return nil }
            return ResolvedDrop(
                plan: .moveVersions(draggedVersions, to: target.id, before: nil), item: node(.item(target.id)),
                childIndex: NSOutlineViewDropOnItemIndex
            )
        }
        let clamped = min(index, target.versions.count)
        let anchor = target.versions[clamped...].first { !draggedVersions.contains($0.id) }?.id
        if incoming == 0 {
            var order = target.versions.map(\.id).filter { !draggedVersions.contains($0) }
            order.insert(contentsOf: draggedVersions, at: anchor.flatMap { order.firstIndex(of: $0) } ?? order.endIndex)
            guard order != target.versions.map(\.id) else { return nil }
        }
        return ResolvedDrop(
            plan: .moveVersions(draggedVersions, to: target.id, before: anchor), item: node(.item(target.id)),
            childIndex: clamped
        )
    }

    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard info.draggingSource as? NSOutlineView === outlineView,
              let drop = resolveDrop(proposedItem: item as? PlaylistNode, childIndex: index) else { return [] }
        outlineView.setDropItem(drop.item, dropChildIndex: drop.childIndex)
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard info.draggingSource as? NSOutlineView === outlineView,
              let drop = resolveDrop(proposedItem: item as? PlaylistNode, childIndex: index) else { return false }
        switch drop.plan {
        case let .reorderItems(order):
            return playlist.reorderItems(order, undoManager: undoManager)
        case let .group(itemIDs, into: destination):
            let versionIDs = itemIDs.flatMap { itemsByID[$0]?.versions.map(\.id) ?? [] }
            grouped(actionName: "Group Items") {
                for id in versionIDs { playlist.moveVersion(id, to: destination, undoManager: undoManager) }
            }
            presentation.selection = [.item(destination)]
            presentation.expanded.insert(destination)
        case let .separate(versionIDs, beforeItem: anchor):
            var created: [UUID] = []
            grouped(actionName: versionIDs.count == 1 ? "Separate Version" : "Separate Versions") {
                for id in versionIDs {
                    // The last version of an item stays put as that item.
                    guard let owner = playlist.workspace.items.first(where: { $0.versions.contains { $0.id == id } }),
                          owner.versions.count > 1,
                          let newID = playlist.separateVersion(id, undoManager: undoManager) else { continue }
                    created.append(newID)
                }
                var order = playlist.workspace.items.map(\.id).filter { !created.contains($0) }
                order.insert(contentsOf: created, at: anchor.flatMap { order.firstIndex(of: $0) } ?? order.endIndex)
                if order != playlist.workspace.items.map(\.id) { playlist.reorderItems(order, undoManager: undoManager) }
            }
            if !created.isEmpty { presentation.selection = Set(created.map(PlaylistRowID.item)) }
        case let .moveVersions(versionIDs, to: destination, before: anchor):
            moveVersions(versionIDs, to: destination, before: anchor)
        }
        return true
    }

    /// Move versions into `destination` ahead of `anchor` (nil appends),
    /// preserving their relative order. Versions already in the destination
    /// are reordered in place.
    private func moveVersions(_ versionIDs: [UUID], to destination: UUID, before anchor: UUID?) {
        grouped(actionName: versionIDs.count == 1 ? "Move Version" : "Move Versions") {
            for id in versionIDs {
                let workspace = playlist.workspace
                guard let target = workspace.items.first(where: { $0.id == destination }) else { return }
                if target.versions.contains(where: { $0.id == id }) {
                    playlist.reorderVersion(id, before: anchor, undoManager: undoManager)
                } else {
                    let index = anchor.flatMap { anchor in target.versions.firstIndex { $0.id == anchor } }
                    playlist.moveVersion(id, to: destination, at: index, undoManager: undoManager)
                }
            }
        }
        presentation.expanded.insert(destination)
        presentation.selection = Set(versionIDs.map(PlaylistRowID.version))
    }

    private func grouped(actionName: String, _ body: () -> Void) {
        undoManager?.beginUndoGrouping()
        body()
        undoManager?.setActionName(actionName)
        undoManager?.endUndoGrouping()
    }
}

// MARK: - Outline view

final class PlaylistNSOutlineView: NSOutlineView {
    weak var controller: PlaylistOutlineController?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        switch event.keyCode {
        case 36 where flags.isEmpty, 76 where flags.isEmpty:
            controller?.playSelection()
        case 123 where flags.isEmpty:
            controller?.handleHorizontalArrow(forward: false)
        case 124 where flags.isEmpty:
            controller?.handleHorizontalArrow(forward: true)
        default:
            super.keyDown(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { controller?.focusChanged(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { controller?.focusChanged(false) }
        return result
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { controller?.focusOutline() } else { controller?.focusChanged(false) }
    }
}

/// Tracks hover so row actions appear only on the hovered or selected row.
final class PlaylistRowView: NSTableRowView {
    private var hoverArea: NSTrackingArea?

    var isHovered = false {
        didSet { if isHovered != oldValue { updateActions() } }
    }

    override var isSelected: Bool {
        didSet { if isSelected != oldValue { updateActions() } }
    }

    var showsActions: Bool { isHovered || isSelected }

    func updateActions() {
        for column in 0..<numberOfColumns {
            (view(atColumn: column) as? PlaylistActionCellView)?.actionsVisible = showsActions
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

// MARK: - Cells

final class PlaylistTextCellView: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier, alignment: NSTextAlignment, monospacedDigits: Bool) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        label.allowsExpansionToolTips = true
        label.textColor = .secondaryLabelColor
        label.font = monospacedDigits
            ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.systemFontSize)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class PlaylistTitleCellView: NSTableCellView {
    enum Indicator: Equatable {
        case none
        case nowPlaying(isPlaying: Bool)
        case playbackVersion(isSelected: Bool)
    }

    let titleField = NSTextField(labelWithString: "")
    var onIndicator: (() -> Void)?

    private let indicatorButton = NSButton()
    private let badge = PlaylistCountBadge()
    private let warningView = NSImageView()
    private let stack = NSStackView()
    private var fillConstraint: NSLayoutConstraint!
    private var indicator = Indicator.none
    private var isDimmed = false
    private var versionCount = 0

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        indicatorButton.translatesAutoresizingMaskIntoConstraints = false
        indicatorButton.isBordered = false
        indicatorButton.imagePosition = .imageOnly
        indicatorButton.imageScaling = .scaleNone
        indicatorButton.title = ""
        indicatorButton.target = self
        indicatorButton.action = #selector(indicatorPressed)
        indicatorButton.refusesFirstResponder = true
        addSubview(indicatorButton)

        titleField.lineBreakMode = .byTruncatingTail
        titleField.allowsExpansionToolTips = true
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleField.cell?.sendsActionOnEndEditing = true
        titleField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = titleField

        warningView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "File not found")
        warningView.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        warningView.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setViews([titleField, badge, warningView], in: .leading)
        addSubview(stack)

        fillConstraint = stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2)
        NSLayoutConstraint.activate([
            indicatorButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            indicatorButton.widthAnchor.constraint(equalToConstant: 20),
            indicatorButton.topAnchor.constraint(equalTo: topAnchor),
            indicatorButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: indicatorButton.trailingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(
        title: String, indicator: Indicator, versionCount: Int, warning: String?, isDimmed: Bool, toolTip: String?
    ) {
        if titleField.isEditable { setEditing(false) }
        titleField.stringValue = title
        titleField.toolTip = toolTip
        self.indicator = indicator
        self.isDimmed = isDimmed
        self.versionCount = versionCount
        badge.count = versionCount
        badge.isHidden = versionCount < 2
        badge.setAccessibilityLabel("\(versionCount) versions")
        warningView.isHidden = warning == nil
        warningView.toolTip = warning
        applyStyle()
    }

    /// While renaming, the title field fills the column so the editor is not
    /// confined to the width of the old title.
    func setEditing(_ editing: Bool) {
        titleField.isEditable = editing
        titleField.isSelectable = editing
        titleField.setContentHuggingPriority(editing ? .init(1) : .defaultHigh, for: .horizontal)
        fillConstraint.isActive = editing
        badge.isHidden = editing || versionCount < 2
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyStyle() }
    }

    private func applyStyle() {
        let emphasized = backgroundStyle == .emphasized
        titleField.textColor = isDimmed ? .tertiaryLabelColor : .labelColor
        badge.isEmphasized = emphasized
        warningView.contentTintColor = emphasized ? .alternateSelectedControlTextColor : .systemYellow

        let symbol: String?
        let label: String
        switch indicator {
        case .none:
            symbol = nil
            label = ""
        case let .nowPlaying(isPlaying):
            symbol = isPlaying ? "speaker.wave.2.fill" : "speaker.fill"
            label = isPlaying ? "Playing" : "Current"
            indicatorButton.contentTintColor = emphasized ? .alternateSelectedControlTextColor : NSColor(Theme.primary)
        case let .playbackVersion(isSelected):
            symbol = isSelected ? "checkmark.circle.fill" : "circle"
            label = isSelected ? "Used for playback" : "Use for playback"
            indicatorButton.contentTintColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        }
        indicatorButton.image = symbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        }
        indicatorButton.setAccessibilityLabel(label)
        if case .playbackVersion = indicator {
            indicatorButton.isEnabled = true
            indicatorButton.setAccessibilityElement(true)
        } else {
            // A status glyph, not a control: clicks fall through to the row.
            indicatorButton.isEnabled = false
            indicatorButton.setAccessibilityElement(symbol != nil)
        }
        (indicatorButton.cell as? NSButtonCell)?.imageDimsWhenDisabled = false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === indicatorButton, !indicatorButton.isEnabled { return self }
        return hit
    }

    @objc private func indicatorPressed() { onIndicator?() }
}

/// Capsule showing how many versions an item holds.
final class PlaylistCountBadge: NSView {
    var count = 0 {
        didSet {
            guard count != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var isEmphasized = false {
        didSet { if isEmphasized != oldValue { needsDisplay = true } }
    }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

    private var text: NSAttributedString {
        NSAttributedString(string: "\(count)", attributes: [
            .font: Self.font,
            .foregroundColor: isEmphasized ? NSColor.alternateSelectedControlTextColor : NSColor.secondaryLabelColor
        ])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(18, ceil(text.size().width) + 10), height: 15)
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill = isEmphasized ? NSColor.white.withAlphaComponent(0.25) : NSColor.labelColor.withAlphaComponent(0.1)
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let text = text
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/// Trailing per-row actions, shown only while the row is hovered or selected.
final class PlaylistActionCellView: NSTableCellView {
    enum Kind { case none, compare, more }

    var kind = Kind.none { didSet { refresh() } }
    var actionsVisible = false { didSet { refresh() } }
    var onCompare: (() -> Void)?
    var onMore: ((NSButton) -> Void)?

    private let compareButton = NSButton(title: "Compare", target: nil, action: nil)
    private let moreButton = NSButton()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        compareButton.bezelStyle = .inline
        compareButton.controlSize = .small
        compareButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        compareButton.target = self
        compareButton.action = #selector(comparePressed)

        moreButton.isBordered = false
        moreButton.imagePosition = .imageOnly
        moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Version Actions")
        moreButton.target = self
        moreButton.action = #selector(morePressed)

        for button in [compareButton, moreButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.refusesFirstResponder = true
            addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                button.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            moreButton.widthAnchor.constraint(equalToConstant: 24),
            moreButton.heightAnchor.constraint(equalToConstant: 20)
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func refresh() {
        compareButton.isHidden = !(kind == .compare && actionsVisible)
        moreButton.isHidden = !(kind == .more && actionsVisible)
    }

    @objc private func comparePressed() { onCompare?() }
    @objc private func morePressed() { onMore?(moreButton) }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}
