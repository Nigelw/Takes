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
    let artworkStore: PlaylistArtworkStore
    let undoManager: UndoManager?

    func makeCoordinator() -> PlaylistOutlineController {
        PlaylistOutlineController(playlist: playlist, presentation: presentation, artworkStore: artworkStore)
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
    /// The table's one column; rows lay out their own content (A2 §6).
    static let row = NSUserInterfaceItemIdentifier("row")
}

/// Row geometry (A2 spec §3, §6), in points from the table's leading edge.
/// Row highlights sit inside the 10 pt edge inset; item thumbnails and
/// version checks share one 34 pt column, and item and version titles start
/// at the same x.
enum PlaylistRowMetrics {
    static let itemHeight: CGFloat = 46
    static let versionHeight: CGFloat = 30
    /// Top and bottom inset of the list inside its scroll view.
    static let listVerticalInset: CGFloat = 6
    /// Edge inset of every row background and the selection highlight.
    static let edgeInset: CGFloat = 10
    static let highlightRadius: CGFloat = 6
    /// Content padding inside the highlight.
    static let leadingPadding: CGFloat = 4
    static let trailingPadding: CGFloat = 8
    static let gap: CGFloat = 10
    /// Always reserved, so thumbnails align whether or not a row has versions.
    static let disclosureWidth: CGFloat = 12
    /// The chevron slot overlaps the gap after it by this much (canvas).
    static let disclosureOverlap: CGFloat = 4
    static let thumbnailSide: CGFloat = 34
    static let thumbnailRadius: CGFloat = 4
    /// Up-and-right offsets of the stacked-card edges on multi-version items.
    static let stackOffsets: [CGFloat] = [3, 6]
    static let durationMinimumWidth: CGFloat = 30
    static let comparePillHeight: CGFloat = 22
    static let comparePillPadding: CGFloat = 9

    static var disclosureX: CGFloat { edgeInset + leadingPadding }
    /// The thumbnail on item rows; the playback-version check column on
    /// version rows.
    static var thumbnailX: CGFloat { disclosureX + disclosureWidth - disclosureOverlap + gap }
    static var titleX: CGFloat { thumbnailX + thumbnailSide + gap }
    static func trailingX(rowWidth: CGFloat) -> CGFloat { rowWidth - edgeInset - trailingPadding }
    /// Row highlight and background rect.
    static func highlightRect(in bounds: NSRect) -> NSRect {
        bounds.insetBy(dx: edgeInset, dy: 0)
    }
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
    /// rate, and bit rate. Shown in the version row's tooltip.
    static func format(_ metadata: PlaylistMetadata) -> String {
        format(fileFormat: metadata.fileFormatDescription, sampleRate: metadata.sampleRate, bitRate: metadata.bitRate)
    }

    /// Shared with the compare lane strip (`LaneStripText`).
    static func format(fileFormat: String, sampleRate: Double, bitRate: Double) -> String {
        var parts: [String] = []
        if !fileFormat.isEmpty { parts.append(fileFormat) }
        if sampleRate.isFinite, sampleRate > 0 {
            let kHz = sampleRate / 1000
            let text = kHz == kHz.rounded() ? String(format: "%.0f", kHz) : String(format: "%.1f", kHz)
            parts.append("\(text) kHz")
        }
        if bitRate.isFinite, bitRate > 0 {
            parts.append("\(Int((bitRate / 1000).rounded())) kbps")
        }
        return parts.joined(separator: " · ")
    }

    /// The version row's format column: the container alone (FLAC, MP3).
    static func formatName(_ metadata: PlaylistMetadata) -> String {
        metadata.fileFormatDescription
    }

    /// A version's name: its title tag, else its filename without the
    /// extension (A2 §6) — the readout's rule, without the uppercasing.
    static func versionName(_ version: PlaylistVersion) -> String {
        versionName(tag: version.metadata.title, url: version.file.storedURL)
    }

    /// Shared with the compare lane strip (`LaneStripText`).
    static func versionName(tag: String?, url: URL) -> String {
        let tag = tag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !tag.isEmpty { return tag }
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? url.lastPathComponent : stem
    }

    /// The item row's second line: the artist tag, or nothing.
    static func artist(_ version: PlaylistVersion?) -> String {
        version?.metadata.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Tooltip on an item row's warning overlay.
    static func missingWarning(missing: Int, of total: Int) -> String? {
        guard missing > 0 else { return nil }
        return total == 1 ? "The file for this item can’t be found." : "\(missing) of \(total) files can’t be found."
    }
}

// MARK: - Controller

@MainActor
final class PlaylistOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSTextFieldDelegate, NSMenuDelegate {
    private let playlist: PlaylistCoordinator
    private let presentation: PlaylistPresentationState
    private let artworkStore: PlaylistArtworkStore
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
    private var thumbnailRequestScheduled = false

    init(playlist: PlaylistCoordinator, presentation: PlaylistPresentationState, artworkStore: PlaylistArtworkStore) {
        self.playlist = playlist
        self.presentation = presentation
        self.artworkStore = artworkStore
        super.init()
        artworkStore.onThumbnailLoaded = { [weak self] id in self?.thumbnailLoaded(id) }
    }

    // MARK: Setup

    func makeScrollView() -> NSScrollView {
        let outline = PlaylistNSOutlineView()
        outline.controller = self
        outline.style = .plain
        outline.headerView = nil
        outline.rowSizeStyle = .custom
        outline.rowHeight = PlaylistRowMetrics.itemHeight
        outline.indentationPerLevel = 0
        outline.intercellSpacing = .zero
        outline.backgroundColor = .clear
        outline.gridStyleMask = []
        outline.selectionHighlightStyle = .regular
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.allowsColumnReordering = false
        outline.allowsColumnResizing = false
        outline.allowsTypeSelect = true
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.setAccessibilityLabel("Playlist")

        let column = NSTableColumn(identifier: PlaylistColumn.row)
        column.resizingMask = .autoresizingMask
        column.minWidth = 100
        column.maxWidth = .greatestFiniteMagnitude
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
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
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: PlaylistRowMetrics.listVerticalInset, left: 0, bottom: PlaylistRowMetrics.listVerticalInset, right: 0
        )
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        outlineView = outline

        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(clipViewBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        center.addObserver(
            self, selector: #selector(clipViewBoundsChanged),
            name: NSView.frameDidChangeNotification, object: scrollView.contentView
        )
        center.addObserver(
            self, selector: #selector(windowBecameKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil
        )
        return scrollView
    }

    @objc private func clipViewBoundsChanged() {
        refreshHover()
        scheduleThumbnailRequest()
    }

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
                // Fit the column to the window once the scroll view has a size.
                DispatchQueue.main.async { [weak self] in self?.outlineView.sizeLastColumnToFit() }
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
        if structureChanged || contentChanged { scheduleThumbnailRequest() }
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

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? PlaylistNode)?.versionID == nil ? PlaylistRowMetrics.itemHeight : PlaylistRowMetrics.versionHeight
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("rowView")
        if let reused = outlineView.makeView(withIdentifier: id, owner: nil) as? PlaylistRowView { return reused }
        let rowView = PlaylistRowView()
        rowView.identifier = id
        return rowView
    }

    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard let rowView = rowView as? PlaylistRowView, let node = outlineView.item(atRow: row) as? PlaylistNode else { return }
        configureRowView(rowView, node: node)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? PlaylistNode else { return nil }
        let view: NSView
        switch node.rowID {
        case let .item(id):
            let cell = reuse(PlaylistItemCellView.reuseIdentifier) { PlaylistItemCellView() }
            configureItem(cell, itemID: id)
            view = cell
        case let .version(id):
            let cell = reuse(PlaylistVersionCellView.reuseIdentifier) { PlaylistVersionCellView() }
            configureVersion(cell, versionID: id)
            view = cell
        }
        let row = outlineView.row(forItem: node)
        if row >= 0, let rowView = outlineView.rowView(atRow: row, makeIfNecessary: false) as? PlaylistRowView {
            configureRowView(rowView, node: node)
        }
        return view
    }

    private func reuse<Cell: NSView>(_ id: NSUserInterfaceItemIdentifier, make: () -> Cell) -> Cell {
        (outlineView.makeView(withIdentifier: id, owner: nil) as? Cell) ?? make()
    }

    private func configureRowView(_ rowView: PlaylistRowView, node: PlaylistNode) {
        rowView.isNowPlaying = node.itemID != nil && node.itemID == currentItemID
        rowView.alphaValue = draggedNodes.contains(node) ? 0.3 : 1
    }

    private func configureItem(_ cell: PlaylistItemCellView, itemID id: UUID) {
        guard let item = itemsByID[id] else { return }
        let version = item.selectedVersion ?? item.versions.first
        let versionURL = version.flatMap { availableURL(for: $0) }
        let missingCount = item.versions.filter { availableURL(for: $0) == nil }.count
        let node = node(.item(id))
        cell.titleField.delegate = self
        cell.configure(PlaylistItemCellView.Content(
            title: item.title,
            artist: PlaylistRowText.artist(version),
            duration: version.map { PlaylistRowText.duration($0.metadata.duration) } ?? "",
            hasVersions: item.versions.count > 1,
            isExpanded: outlineView.isItemExpanded(node),
            nowPlaying: currentItemID == id ? (isPlaying ? .playing : .paused) : nil,
            warning: PlaylistRowText.missingWarning(missing: missingCount, of: item.versions.count),
            isDimmed: version != nil && versionURL == nil,
            thumbnail: thumbnailImage(version: version, url: versionURL)
        ))
        cell.onDisclosure = { [weak self, weak node] in
            guard let self, let node else { return }
            self.toggleExpansion(node)
        }
        cell.onCompare = { [weak self] in self?.compare(itemID: id) }
        let row = outlineView.row(forItem: node)
        cell.isHovered = row >= 0
            && (outlineView.rowView(atRow: row, makeIfNecessary: false) as? PlaylistRowView)?.isHovered == true
    }

    private func configureVersion(_ cell: PlaylistVersionCellView, versionID id: UUID) {
        guard let (item, version) = version(id) else { return }
        let missing = availableURL(for: version) == nil
        let state: PlaylistVersionCellView.Mark = missing ? .missing : item.selectedVersionID == id ? .playback : .none
        cell.configure(
            title: PlaylistRowText.versionName(version),
            format: PlaylistRowText.formatName(version.metadata),
            duration: PlaylistRowText.duration(version.metadata.duration),
            mark: state,
            toolTip: [version.file.storedURL.lastPathComponent, PlaylistRowText.format(version.metadata)]
                .filter { !$0.isEmpty }.joined(separator: "\n")
        )
    }

    private func toggleExpansion(_ node: PlaylistNode) {
        guard outlineView.isExpandable(node) else { return }
        if outlineView.isItemExpanded(node) {
            outlineView.animator().collapseItem(node)
        } else {
            outlineView.animator().expandItem(node)
        }
    }

    /// Rotates an item row's chevron after its expansion changed.
    private func updateDisclosure(for node: PlaylistNode?, animated: Bool) {
        guard let node else { return }
        let row = outlineView.row(forItem: node)
        guard row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? PlaylistItemCellView else { return }
        cell.setExpanded(outlineView.isItemExpanded(node), animated: animated)
    }

    // MARK: Thumbnails

    /// The item row's thumbnail for its playback version, if decoded.
    private func thumbnailImage(version: PlaylistVersion?, url: URL?) -> NSImage? {
        guard let version, let url, case let .image(image) = artworkStore.thumbnail(for: version.id, url: url) else { return nil }
        return image
    }

    /// Coalesces requests to once per run-loop turn: scrolling posts many
    /// bounds changes per frame.
    private func scheduleThumbnailRequest() {
        guard !thumbnailRequestScheduled else { return }
        thumbnailRequestScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.thumbnailRequestScheduled = false
            self.requestVisibleThumbnails()
        }
    }

    /// Asks for thumbnails of the item rows inside the visible rect, and
    /// only those: rows AppKit prepares off screen are never decoded.
    private func requestVisibleThumbnails() {
        guard hasLoaded, outlineView.window != nil else { return }
        let visible = outlineView.rows(in: outlineView.visibleRect)
        guard visible.length > 0 else {
            artworkStore.requestThumbnails([])
            return
        }
        var requests: [(id: PlaylistVersion.ID, url: URL)] = []
        for row in visible.location..<NSMaxRange(visible) {
            guard let id = (outlineView.item(atRow: row) as? PlaylistNode)?.itemID, let item = itemsByID[id],
                  let version = item.selectedVersion ?? item.versions.first,
                  let url = availableURL(for: version) else { continue }
            requests.append((version.id, url))
        }
        artworkStore.requestThumbnails(requests)
    }

    private func thumbnailLoaded(_ versionID: UUID) {
        guard hasLoaded, let itemID = ownerByVersionID[versionID], let item = itemsByID[itemID],
              (item.selectedVersion ?? item.versions.first)?.id == versionID,
              let node = nodes[.item(itemID)], case let row = outlineView.row(forItem: node), row >= 0,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? PlaylistItemCellView,
              let version = item.versions.first(where: { $0.id == versionID }) else { return }
        cell.setThumbnail(thumbnailImage(version: version, url: availableURL(for: version)))
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplying else { return }
        let selection = Set(outlineView.selectedRowIndexes.compactMap { (outlineView.item(atRow: $0) as? PlaylistNode)?.rowID })
        if selection != presentation.selection { presentation.selection = selection }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        let node = notification.userInfo?["NSObject"] as? PlaylistNode
        updateDisclosure(for: node, animated: !isApplying)
        scheduleThumbnailRequest()
        guard !isApplying, let id = node?.itemID else { return }
        presentation.expanded.insert(id)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        let node = notification.userInfo?["NSObject"] as? PlaylistNode
        updateDisclosure(for: node, animated: !isApplying)
        scheduleThumbnailRequest()
        guard !isApplying, let id = node?.itemID else { return }
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

    /// A plain click on a version row makes it the item's playback version
    /// (A2 §6); a missing file asks to be located instead. Clicks that extend
    /// the selection only select.
    @objc private func rowClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let event = NSApp.currentEvent, event.clickCount == 1,
              event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty,
              let id = (outlineView.item(atRow: row) as? PlaylistNode)?.versionID,
              let (item, version) = version(id) else { return }
        guard availableURL(for: version) != nil else {
            presentation.locateVersionID = id
            return
        }
        guard item.selectedVersionID != id else { return }
        Task { await playlist.selectPlaybackVersion(id, in: item.id) }
    }

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
        guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? PlaylistItemCellView else {
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
            (field.superview as? PlaylistItemCellView)?.setEditing(false)
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
        updateDragSourceRows()
    }

    func outlineView(
        _ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        draggedNodes = []
        updateDragSourceRows()
    }

    /// Rows being dragged stay in place, dimmed, until the drop lands.
    private func updateDragSourceRows() {
        let dragged = Set(draggedNodes.map(ObjectIdentifier.init))
        outlineView.enumerateAvailableRowViews { rowView, row in
            guard let node = self.outlineView.item(atRow: row) as? PlaylistNode else { return }
            rowView.alphaValue = dragged.contains(ObjectIdentifier(node)) ? 0.3 : 1
        }
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

    /// Rows draw their own chevron in a reserved slot (A2 §6), so AppKit's
    /// disclosure triangle and its indentation are suppressed: every cell
    /// spans the full row.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let rowRect = rect(ofRow: row)
        guard column >= 0, column < numberOfColumns else { return rowRect }
        let columnRect = rect(ofColumn: column)
        return NSRect(x: columnRect.minX, y: rowRect.minY, width: columnRect.width, height: rowRect.height)
    }

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

/// Draws every row background inside the 10 pt edge inset with a 6 pt
/// radius (A2 §3, §6): selection, the now-playing tint, hover, and the
/// drop-on-item ring. Tracks hover for the Compare pill.
final class PlaylistRowView: NSTableRowView {
    private var hoverArea: NSTrackingArea?

    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
            (view(atColumn: 0) as? PlaylistItemCellView)?.isHovered = isHovered
        }
    }

    var isNowPlaying = false {
        didSet { if isNowPlaying != oldValue { needsDisplay = true } }
    }

    private var highlightPath: NSBezierPath {
        let radius = PlaylistRowMetrics.highlightRadius
        return NSBezierPath(roundedRect: PlaylistRowMetrics.highlightRect(in: bounds), xRadius: radius, yRadius: radius)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard !isSelected else { return }
        if isNowPlaying {
            PlaylistRowPalette.nowPlayingFill.setFill()
            highlightPath.fill()
        }
        if isHovered {
            PlaylistRowPalette.hoverFill.setFill()
            highlightPath.fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let color: NSColor = isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
        color.setFill()
        highlightPath.fill()
    }

    override func drawDraggingDestinationFeedback(in dirtyRect: NSRect) {
        let radius = PlaylistRowMetrics.highlightRadius
        let rect = PlaylistRowMetrics.highlightRect(in: bounds)
        PlaylistRowPalette.dropTargetFill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: radius - 1, yRadius: radius - 1)
        ring.lineWidth = 2
        PlaylistRowPalette.dropTargetRing.setStroke()
        ring.stroke()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
        isNowPlaying = false
        alphaValue = 1
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

private extension NSTextField {
    static func playlistLabel(font: NSFont, truncation: NSLineBreakMode, alignment: NSTextAlignment = .left) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = font
        field.alignment = alignment
        field.lineBreakMode = truncation
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.cell?.truncatesLastVisibleLine = true
        field.allowsExpansionToolTips = true
        return field
    }

    /// Single-line height for the field's font.
    var lineHeight: CGFloat {
        let saved = stringValue
        stringValue = "Ag"
        defer { stringValue = saved }
        return ceil(intrinsicContentSize.height)
    }

    var fittingTextWidth: CGFloat { ceil(intrinsicContentSize.width) }
}

private enum PlaylistGlyph {
    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, label: String? = nil) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }

    static func warning(size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "File not found")?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
                    .applying(.init(paletteColors: [PlaylistRowPalette.warningMark, PlaylistRowPalette.warningFill]))
            )
    }
}

/// Item row, 46 pt (A2 §6): chevron slot, thumbnail, title over artist, the
/// hover Compare pill, and the duration.
final class PlaylistItemCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("item")

    enum NowPlaying: Equatable { case playing, paused }

    struct Content {
        var title: String
        var artist: String
        var duration: String
        var hasVersions: Bool
        var isExpanded: Bool
        var nowPlaying: NowPlaying?
        /// Tooltip of the warning overlay; nil when every file is present.
        var warning: String?
        /// The playback version's file is missing.
        var isDimmed: Bool
        var thumbnail: NSImage?
    }

    let titleField = NSTextField.playlistLabel(font: .systemFont(ofSize: 13, weight: .semibold), truncation: .byTruncatingMiddle)
    private let artistField = NSTextField.playlistLabel(font: .systemFont(ofSize: 11), truncation: .byTruncatingTail)
    private let durationField = NSTextField.playlistLabel(
        font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular), truncation: .byClipping, alignment: .right
    )
    private let disclosure = PlaylistDisclosureButton()
    private let thumbnail = PlaylistThumbnailView()
    private let comparePill = PlaylistComparePill()
    private let titleHeight: CGFloat
    private let artistHeight: CGFloat
    private var content = Content(
        title: "", artist: "", duration: "", hasVersions: false, isExpanded: false,
        nowPlaying: nil, warning: nil, isDimmed: false, thumbnail: nil
    )
    private var isEditingTitle = false

    var onDisclosure: (() -> Void)?
    var onCompare: (() -> Void)?

    var isHovered = false {
        didSet { if isHovered != oldValue { updatePill() } }
    }

    override var isFlipped: Bool { true }

    init() {
        titleHeight = titleField.lineHeight
        artistHeight = artistField.lineHeight
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        titleField.cell?.sendsActionOnEndEditing = true
        textField = titleField
        disclosure.action = { [weak self] in self?.onDisclosure?() }
        comparePill.target = self
        comparePill.action = #selector(comparePressed)
        for view in [disclosure, thumbnail, titleField, artistField, comparePill, durationField] as [NSView] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ content: Content) {
        if titleField.isEditable { setEditing(false) }
        self.content = content
        titleField.stringValue = content.title
        artistField.stringValue = content.artist
        artistField.isHidden = content.artist.isEmpty
        durationField.stringValue = content.duration
        disclosure.isHidden = !content.hasVersions
        disclosure.setExpanded(content.isExpanded, animated: false)
        thumbnail.configure(
            image: content.thumbnail, isStacked: content.hasVersions,
            status: content.warning.map { .missing($0) } ?? content.nowPlaying.map { $0 == .playing ? .playing : .paused } ?? .none
        )
        updatePill()
        applyStyle()
        needsLayout = true
    }

    func setThumbnail(_ image: NSImage?) {
        content.thumbnail = image
        thumbnail.image = image
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        content.isExpanded = expanded
        disclosure.setExpanded(expanded, animated: animated)
    }

    /// While renaming, the title field takes the space up to the duration.
    func setEditing(_ editing: Bool) {
        isEditingTitle = editing
        titleField.isEditable = editing
        titleField.isSelectable = editing
        updatePill()
        needsLayout = true
    }

    private func updatePill() {
        comparePill.isHidden = !(isHovered && content.hasVersions && !isEditingTitle)
        needsLayout = true
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyStyle() }
    }

    private func applyStyle() {
        let emphasized = backgroundStyle == .emphasized
        let selectedText = NSColor.alternateSelectedControlTextColor
        if emphasized {
            titleField.textColor = content.isDimmed ? selectedText.withAlphaComponent(0.6) : selectedText
            artistField.textColor = selectedText.withAlphaComponent(0.75)
            durationField.textColor = selectedText.withAlphaComponent(0.75)
        } else {
            titleField.textColor = content.isDimmed ? .tertiaryLabelColor
                : content.nowPlaying != nil ? PlaylistRowPalette.nowPlayingTitle : .labelColor
            artistField.textColor = .secondaryLabelColor
            durationField.textColor = .secondaryLabelColor
        }
        disclosure.isEmphasized = emphasized
    }

    override func layout() {
        super.layout()
        typealias M = PlaylistRowMetrics
        let height = bounds.height
        disclosure.frame = NSRect(x: M.disclosureX, y: (height - 20) / 2, width: M.disclosureWidth, height: 20)
        let thumbnailSize = PlaylistThumbnailView.size
        thumbnail.frame = NSRect(
            x: M.thumbnailX, y: (height - M.thumbnailSide) / 2 - PlaylistThumbnailView.stackExtent,
            width: thumbnailSize.width, height: thumbnailSize.height
        )

        let trailing = M.trailingX(rowWidth: bounds.width)
        let durationWidth = max(M.durationMinimumWidth, durationField.fittingTextWidth)
        let durationX = trailing - durationWidth
        durationField.frame = NSRect(x: durationX, y: (height - titleHeight) / 2, width: durationWidth, height: titleHeight)

        var textRight = durationX - M.gap
        if !comparePill.isHidden {
            let pillWidth = comparePill.preferredWidth
            let pillX = durationX - M.gap - pillWidth
            comparePill.frame = NSRect(x: pillX, y: (height - M.comparePillHeight) / 2, width: pillWidth, height: M.comparePillHeight)
            textRight = pillX - M.gap
        }
        let textWidth = max(0, textRight - M.titleX)
        if artistField.isHidden || isEditingTitle {
            titleField.frame = NSRect(x: M.titleX, y: (height - titleHeight) / 2, width: textWidth, height: titleHeight)
            artistField.frame = .zero
        } else {
            let top = ((height - titleHeight - 1 - artistHeight) / 2).rounded()
            titleField.frame = NSRect(x: M.titleX, y: top, width: textWidth, height: titleHeight)
            artistField.frame = NSRect(x: M.titleX, y: top + titleHeight + 1, width: textWidth, height: artistHeight)
        }
        artistField.isHidden = content.artist.isEmpty || isEditingTitle
    }

    @objc private func comparePressed() { onCompare?() }
}

/// Version row, 30 pt (A2 §6): the playback-version check in the thumbnail
/// column (a warning triangle in its place when the file is missing, §12),
/// the version's title tag, its format, and its duration.
final class PlaylistVersionCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("version")

    enum Mark: Equatable { case none, playback, missing }

    private let titleField = NSTextField.playlistLabel(font: .systemFont(ofSize: 12), truncation: .byTruncatingMiddle)
    private let formatField = NSTextField.playlistLabel(font: .systemFont(ofSize: 11), truncation: .byClipping)
    private let durationField = NSTextField.playlistLabel(
        font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular), truncation: .byClipping, alignment: .right
    )
    private let markView = NSImageView()
    private let titleHeight: CGFloat
    private let detailHeight: CGFloat
    private var mark = Mark.none

    override var isFlipped: Bool { true }

    init() {
        titleHeight = titleField.lineHeight
        detailHeight = durationField.lineHeight
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        textField = titleField
        markView.imageScaling = .scaleNone
        for view in [markView, titleField, formatField, durationField] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, format: String, duration: String, mark: Mark, toolTip: String) {
        titleField.stringValue = title
        titleField.toolTip = toolTip
        formatField.stringValue = format
        durationField.stringValue = duration
        self.mark = mark
        switch mark {
        case .none:
            markView.image = nil
            markView.toolTip = nil
        case .playback:
            markView.image = PlaylistGlyph.symbol("checkmark.circle.fill", size: 12, label: "Playback version")
            markView.toolTip = "Playback version"
        case .missing:
            markView.image = PlaylistGlyph.warning(size: 12)
            markView.toolTip = "This file can’t be found."
        }
        markView.setAccessibilityElement(mark != .none)
        applyStyle()
        needsLayout = true
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyStyle() }
    }

    private func applyStyle() {
        let emphasized = backgroundStyle == .emphasized
        let selectedText = NSColor.alternateSelectedControlTextColor
        let dimmed = mark == .missing
        if emphasized {
            titleField.textColor = dimmed ? selectedText.withAlphaComponent(0.6) : selectedText
            formatField.textColor = selectedText.withAlphaComponent(0.75)
            durationField.textColor = selectedText.withAlphaComponent(0.75)
        } else {
            titleField.textColor = dimmed ? .tertiaryLabelColor : NSColor.labelColor.withAlphaComponent(0.85)
            formatField.textColor = .secondaryLabelColor
            durationField.textColor = .secondaryLabelColor
        }
        if mark == .playback { markView.contentTintColor = emphasized ? selectedText : .secondaryLabelColor }
    }

    override func layout() {
        super.layout()
        typealias M = PlaylistRowMetrics
        let height = bounds.height
        markView.frame = NSRect(x: M.thumbnailX, y: 0, width: M.thumbnailSide, height: height)
        let trailing = M.trailingX(rowWidth: bounds.width)
        let durationWidth = max(M.durationMinimumWidth, durationField.fittingTextWidth)
        let durationX = trailing - durationWidth
        durationField.frame = NSRect(x: durationX, y: (height - detailHeight) / 2, width: durationWidth, height: detailHeight)
        var textRight = durationX - M.gap
        if !formatField.stringValue.isEmpty {
            let formatWidth = formatField.fittingTextWidth
            formatField.frame = NSRect(x: textRight - formatWidth, y: (height - detailHeight) / 2, width: formatWidth, height: detailHeight)
            textRight -= formatWidth + M.gap
        } else {
            formatField.frame = .zero
        }
        titleField.frame = NSRect(x: M.titleX, y: (height - titleHeight) / 2, width: max(0, textRight - M.titleX), height: titleHeight)
    }
}

/// The item row's chevron, in its always-reserved 12 pt slot. Rotates to
/// point down while the item is expanded.
final class PlaylistDisclosureButton: NSView {
    var action: (() -> Void)?
    var isEmphasized = false { didSet { if isEmphasized != oldValue { updateTint() } } }

    private let chevron = NSImageView()
    private var isExpanded = false

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 12, height: 20))
        wantsLayer = true
        chevron.image = PlaylistGlyph.symbol("chevron.right", size: 9, weight: .bold)
        chevron.imageScaling = .scaleNone
        chevron.wantsLayer = true
        chevron.frame = NSRect(x: 0, y: 4, width: 12, height: 12)
        addSubview(chevron)
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        updateTint()
        updateLabel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard expanded != isExpanded || chevron.frameCenterRotation != (expanded ? -90 : 0) else { return }
        isExpanded = expanded
        let angle: CGFloat = expanded ? -90 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                chevron.animator().frameCenterRotation = angle
            }
        } else {
            chevron.frameCenterRotation = angle
        }
        updateLabel()
    }

    private func updateTint() {
        chevron.contentTintColor = isEmphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }

    private func updateLabel() {
        setAccessibilityLabel(isExpanded ? "Hide Versions" : "Show Versions")
        setAccessibilityValue(isExpanded ? 1 : 0)
    }

    override func mouseDown(with event: NSEvent) { action?() }
    override func accessibilityPerformPress() -> Bool {
        action?()
        return true
    }
}

/// The item row's 34 pt thumbnail: artwork (or a music-note tile), the
/// stacked-card edges of a multi-version item, and the now-playing or
/// missing-file overlay. Laid out flipped; the stack edges extend
/// `stackExtent` above and to the right of the tile.
final class PlaylistThumbnailView: NSView {
    enum Status: Equatable {
        case none, playing, paused
        case missing(String)
    }

    static let stackExtent: CGFloat = PlaylistRowMetrics.stackOffsets.last.map { $0 - 2 } ?? 0
    static var size: NSSize {
        NSSize(width: PlaylistRowMetrics.thumbnailSide + stackExtent, height: PlaylistRowMetrics.thumbnailSide + stackExtent)
    }

    var image: NSImage? {
        didSet {
            tile.contentsImage = image
            noteGlyph.isHidden = image != nil
        }
    }

    private let farEdge = PlaylistFillView()
    private let nearEdge = PlaylistFillView()
    private let tile = PlaylistFillView()
    private let noteGlyph = NSImageView()
    private let scrim = PlaylistFillView()
    private let statusGlyph = NSImageView()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        typealias M = PlaylistRowMetrics
        let side = M.thumbnailSide
        let tileRect = NSRect(x: 0, y: Self.stackExtent, width: side, height: side)
        // Each card is the tile shrunk by 1 pt per step and shifted up and
        // right, so a 2 pt strip of it shows past the card in front.
        for (index, (edge, color)) in [(nearEdge, PlaylistRowPalette.stackNearEdge), (farEdge, PlaylistRowPalette.stackFarEdge)].enumerated() {
            let inset = CGFloat(index + 1)
            let offset = M.stackOffsets[index]
            edge.frame = tileRect.insetBy(dx: inset, dy: inset).offsetBy(dx: offset, dy: -offset)
            edge.fillColor = color
            edge.cornerRadius = M.thumbnailRadius - inset
        }
        tile.frame = tileRect
        tile.fillColor = PlaylistRowPalette.thumbnailFill
        tile.cornerRadius = M.thumbnailRadius
        noteGlyph.image = PlaylistGlyph.symbol("music.note", size: 15)
        noteGlyph.contentTintColor = PlaylistRowPalette.thumbnailGlyph
        noteGlyph.imageScaling = .scaleNone
        noteGlyph.frame = tile.bounds
        tile.addSubview(noteGlyph)
        scrim.frame = tile.bounds
        tile.addSubview(scrim)
        statusGlyph.imageScaling = .scaleNone
        statusGlyph.frame = tile.bounds
        tile.addSubview(statusGlyph)
        for view in [farEdge, nearEdge, tile] { addSubview(view) }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(image: NSImage?, isStacked: Bool, status: Status) {
        self.image = image
        nearEdge.isHidden = !isStacked
        farEdge.isHidden = !isStacked
        switch status {
        case .none:
            scrim.isHidden = true
            statusGlyph.image = nil
            statusGlyph.toolTip = nil
        case .playing, .paused:
            scrim.isHidden = false
            scrim.fillColor = PlaylistRowPalette.playingScrim
            let playing = status == .playing
            statusGlyph.image = PlaylistGlyph.symbol(playing ? "speaker.wave.2.fill" : "speaker.fill", size: 13,
                                                     label: playing ? "Playing" : "Current")
            statusGlyph.contentTintColor = .white
            statusGlyph.toolTip = nil
        case let .missing(warning):
            scrim.isHidden = false
            scrim.fillColor = PlaylistRowPalette.missingScrim
            statusGlyph.image = PlaylistGlyph.warning(size: 16)
            statusGlyph.toolTip = warning
        }
        statusGlyph.setAccessibilityElement(statusGlyph.image != nil)
    }
}

/// A layer-backed rectangle whose dynamic fill color resolves for the
/// view's appearance, optionally showing an image (aspect fill).
final class PlaylistFillView: NSView {
    var fillColor: NSColor = .clear { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    var contentsImage: NSImage? { didSet { if contentsImage !== oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateLayer() {
        guard let layer else { return }
        var color: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { color = fillColor.cgColor }
        layer.backgroundColor = color
        layer.cornerRadius = cornerRadius
        layer.masksToBounds = cornerRadius > 0
        layer.contentsGravity = .resizeAspectFill
        layer.contents = contentsImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The hover Compare pill on multi-version items (A2 §6). Opens compare
/// without starting playback.
final class PlaylistComparePill: NSButton {
    private static let font = NSFont.systemFont(ofSize: 11, weight: .semibold)

    override init(frame: NSRect) {
        super.init(frame: frame)
        title = "Compare"
        isBordered = false
        refusesFirstResponder = true
        focusRingType = .none
        toolTip = "Compare Versions"
        setAccessibilityLabel("Compare Versions")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var label: NSAttributedString {
        NSAttributedString(string: "Compare", attributes: [.font: Self.font, .foregroundColor: PlaylistRowPalette.comparePillText])
    }

    var preferredWidth: CGFloat { ceil(label.size().width) + 2 * PlaylistRowMetrics.comparePillPadding }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredWidth, height: PlaylistRowMetrics.comparePillHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        PlaylistRowPalette.comparePillFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        if isHighlighted {
            PlaylistRowPalette.comparePillFill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        let text = label
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
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
