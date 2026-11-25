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
    let metadataFields: Set<TrackMetadataField>
    let fileIssues: [PlaylistVersion.ID: PlaylistCoordinator.FileIssue]
    let currentItemID: UUID?
    /// The playing (or current) version: an expanded track shows the
    /// speaker on that version's row instead of its artwork (culling §9.1).
    let currentVersionID: UUID?
    let isPlaying: Bool
    let isActive: Bool
    let moveRevision: Int
    let artworkStore: PlaylistArtworkStore
    let undoManager: UndoManager?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Help ▸ Show Component Names: badges the item and version rows.
    var showsDebugLabels = false

    func makeCoordinator() -> PlaylistOutlineController {
        PlaylistOutlineController(playlist: playlist, presentation: presentation, artworkStore: artworkStore)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.undoManager = undoManager
        context.coordinator.showsDebugLabels = showsDebugLabels
        context.coordinator.update(
            items: items, fileIssues: fileIssues, currentItemID: currentItemID, currentVersionID: currentVersionID,
            isPlaying: isPlaying, isActive: isActive,
            moveRevision: moveRevision, reduceMotion: reduceMotion, metadataFields: metadataFields
        )
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
    /// Added to a rejected row's accessibility value (culling §4.3).
    static let rejectedAccessibilityValue = "Rejected"

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
        formatParts(
            fileFormat: metadata.fileFormatDescription, sampleRate: metadata.sampleRate,
            bitRate: metadata.bitRate, fields: AppSettings.compareMetadataFieldsDefault
        ).joined(separator: " · ")
    }

    /// Shared with the compare lane strip (`LaneStripText`).
    static func formatParts(
        fileFormat: String, sampleRate: Double, bitRate: Double, fields: Set<TrackMetadataField>
    ) -> [String] {
        [
            fields.contains(.format) && !fileFormat.isEmpty ? fileFormat : nil,
            fields.contains(.sampleRate) ? sampleRateText(sampleRate) : nil,
            fields.contains(.bitrate) ? bitrateText(bitRate) : nil
        ].compactMap { $0 }
    }

    private static func sampleRateText(_ sampleRate: Double) -> String? {
        guard sampleRate.isFinite, sampleRate > 0 else { return nil }
        let kHz = sampleRate / 1000
        return String(format: kHz == kHz.rounded() ? "%.0f kHz" : "%.1f kHz", kHz)
    }

    private static func bitrateText(_ bitrate: Double) -> String? {
        guard bitrate.isFinite, bitrate > 0 else { return nil }
        return String(format: "%.0f kbps", (bitrate / 1000).rounded())
    }

    static func itemTitle(_ item: PlaylistItem) -> String {
        item.keyVersion.map(versionName) ?? item.title
    }

    /// A version's name: its title tag, else its filename without the
    /// extension (A2 §6). The playlist readout uses the same name.
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

    /// The item row's second line, using the key version's available metadata.
    static func metadataLine(_ metadata: PlaylistMetadata?, fields: Set<TrackMetadataField>) -> String {
        guard let metadata else { return "" }
        return TrackMetadataField.allCases.compactMap { field -> String? in
            guard fields.contains(field) else { return nil }
            let value: String?
            switch field {
            case .artist: value = metadata.artist
            case .album: value = metadata.album
            case .format: value = metadata.fileFormatDescription
            case .sampleRate: value = sampleRateText(metadata.sampleRate)
            case .bitrate: value = bitrateText(metadata.bitRate)
            }
            guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }.joined(separator: " • ")
    }
}

// MARK: - Controller

@MainActor
final class PlaylistOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSMenuDelegate {
    private let playlist: PlaylistCoordinator
    private let presentation: PlaylistPresentationState
    private let artworkStore: PlaylistArtworkStore
    var undoManager: UndoManager?

    private var outlineView: PlaylistNSOutlineView!
    private var items: [PlaylistItem] = []
    private var itemsByID: [UUID: PlaylistItem] = [:]
    private var ownerByVersionID: [UUID: UUID] = [:]
    private var metadataFields: Set<TrackMetadataField> = []
    private var nodes: [PlaylistRowID: PlaylistNode] = [:]
    private var currentItemID: UUID?
    private var currentVersionID: UUID?
    private var isPlaying = false
    private(set) var isActive = false
    private var hasLoaded = false
    private var moveRevision = 0
    private var moveAnimation: (id: UUID, foreground: Set<PlaylistRowID>)?
    /// True while this controller pushes model state into the outline view, so
    /// the resulting delegate callbacks are not echoed back into the model.
    private var isApplying = false
    private var availability: [UUID: (reference: PlaylistFileReference, url: URL?)] = [:]
    private var fileIssues: [PlaylistVersion.ID: PlaylistCoordinator.FileIssue] = [:]
    private var draggedNodes: [PlaylistNode] = []
    private var thumbnailRequestScheduled = false
    var showsDebugLabels = false {
        didSet {
            guard showsDebugLabels != oldValue, hasLoaded else { return }
            outlineView.enumerateAvailableRowViews { rowView, row in
                guard let rowView = rowView as? PlaylistRowView,
                      let node = self.outlineView.item(atRow: row) as? PlaylistNode else { return }
                self.configureRowView(rowView, node: node)
            }
        }
    }

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
        applySelection()
    }

    // MARK: Model → view

    func update(
        items newItems: [PlaylistItem], fileIssues newIssues: [PlaylistVersion.ID: PlaylistCoordinator.FileIssue],
        currentItemID: UUID?, currentVersionID: UUID?, isPlaying: Bool, isActive: Bool,
        moveRevision: Int, reduceMotion: Bool, metadataFields: Set<TrackMetadataField>
    ) {
        let structureChanged = !hasLoaded || Self.structure(newItems) != Self.structure(items)
        let contentChanged = newItems != items || newIssues != fileIssues
            || currentItemID != self.currentItemID || currentVersionID != self.currentVersionID
            || isPlaying != self.isPlaying
            || metadataFields != self.metadataFields
        let becameActive = isActive && !self.isActive
        let previousItems = items
        let animateMove = hasLoaded && isActive && self.isActive && !reduceMotion && moveRevision != self.moveRevision
        self.moveRevision = moveRevision
        items = newItems
        self.metadataFields = metadataFields
        if newIssues != fileIssues {
            availability = availability.filter { fileIssues[$0.key] == newIssues[$0.key] }
            fileIssues = newIssues
        }
        self.currentItemID = currentItemID
        self.currentVersionID = currentVersionID
        self.isPlaying = isPlaying
        self.isActive = isActive
        itemsByID = Dictionary(uniqueKeysWithValues: newItems.map { ($0.id, $0) })
        ownerByVersionID = [:]
        for item in newItems { for version in item.versions { ownerByVersionID[version.id] = item.id } }

        if structureChanged && !(animateMove && animateReorder(from: previousItems)) {
            if !hasLoaded {
                // Fit the column to the window once the scroll view has a size.
                DispatchQueue.main.async { [weak self] in self?.outlineView.sizeLastColumnToFit() }
            }
            hasLoaded = true
            let valid = Set(newItems.flatMap { item in [PlaylistRowID.item(item.id)] + item.versions.map { .version($0.id) } })
            nodes = nodes.filter { valid.contains($0.key) }
            availability = availability.filter { ownerByVersionID[$0.key] != nil }
            isApplying = true
            outlineView.reloadData()
            isApplying = false
        } else if !structureChanged && contentChanged {
            reloadContent()
        }
        applyExpansion()
        applySelection()
        if structureChanged || contentChanged {
            refreshHover()
            scheduleThumbnailRequest()
        }
        if becameActive { focusOutline() }
    }

    private static func structure(_ items: [PlaylistItem]) -> [[UUID]] {
        items.map { [$0.id] + $0.versions.map(\.id) }
    }

    private func animateReorder(from previousItems: [PlaylistItem]) -> Bool {
        guard previousItems.count == items.count, previousItems.allSatisfy({ old in
            guard let new = itemsByID[old.id] else { return false }
            return Set(old.versions.map(\.id)) == Set(new.versions.map(\.id))
        }) else { return false }

        let animationID = UUID()
        var foreground = presentation.selection
        for item in previousItems where foreground.contains(.item(item.id)) {
            foreground.formUnion(item.versions.map { .version($0.id) })
        }
        moveAnimation = (animationID, foreground)
        updateMoveLayerOrder()

        isApplying = true
        defer { isApplying = false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            outlineView.beginUpdates()
            for old in previousItems {
                let parent = node(.item(old.id))
                guard outlineView.isItemExpanded(parent), let new = itemsByID[old.id] else { continue }
                moveChildren(from: old.versions.map(\.id), to: new.versions.map(\.id), in: parent)
            }
            moveChildren(from: previousItems.map(\.id), to: items.map(\.id), in: nil)
            outlineView.endUpdates()
        } completionHandler: { [weak self] in
            // A repeated command can start another move before this one ends.
            guard let self, self.moveAnimation?.id == animationID else { return }
            self.moveAnimation = nil
            self.updateMoveLayerOrder()
        }
        outlineView.enumerateAvailableRowViews { rowView, row in
            guard let rowView = rowView as? PlaylistRowView,
                  let node = self.outlineView.item(atRow: row) as? PlaylistNode else { return }
            self.configureRowView(rowView, node: node)
            switch (node.rowID, rowView.view(atColumn: 0)) {
            case let (.item(id), cell as PlaylistItemCellView): self.configureItem(cell, itemID: id)
            case let (.version(id), cell as PlaylistVersionCellView): self.configureVersion(cell, versionID: id)
            default: break
            }
        }
        return true
    }

    private func updateMoveLayerOrder() {
        outlineView.enumerateAvailableRowViews { rowView, row in
            guard let rowView = rowView as? PlaylistRowView,
                  let node = self.outlineView.item(atRow: row) as? PlaylistNode else { return }
            rowView.setMoveForeground(self.moveAnimation?.foreground.contains(node.rowID) == true)
        }
    }

    private func moveChildren(from oldOrder: [UUID], to newOrder: [UUID], in parent: PlaylistNode?) {
        var order = oldOrder
        for (target, id) in newOrder.enumerated() where order[target] != id {
            guard let source = order.firstIndex(of: id) else { return }
            outlineView.moveItem(at: source, inParent: parent, to: target, inParent: parent)
            let moved = order.remove(at: source)
            order.insert(moved, at: target)
        }
    }

    private func reloadContent() {
        guard hasLoaded else { return }
        isApplying = true
        defer { isApplying = false }
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

    private func fileWarning(for version: PlaylistVersion) -> String? {
        if let issue = fileIssues[version.id], issue.reference == version.file {
            return issue.error.localizedDescription
        }
        return availableURL(for: version) == nil
            ? PlaybackError.failedToOpenFile(version.file.storedURL).localizedDescription : nil
    }

    /// The version a row stands for: a version row's own, or an item row's
    /// playback version.
    private func representedVersion(_ rowID: PlaylistRowID) -> (item: PlaylistItem, version: PlaylistVersion)? {
        switch rowID {
        case let .item(id):
            guard let item = itemsByID[id], let version = item.keyVersion else { return nil }
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
        let isRejected: Bool
        switch node.rowID {
        case let .item(id): isRejected = itemsByID[id]?.isRejected == true
        case let .version(id): isRejected = version(id)?.version.isRejected == true
        }
        rowView.setAccessibilityValue(isRejected ? PlaylistRowText.rejectedAccessibilityValue : nil)
        rowView.alphaValue = draggedNodes.contains(node) ? 0.3 : 1
        rowView.setMoveForeground(moveAnimation?.foreground.contains(node.rowID) == true)
        rowView.debugLabel = showsDebugLabels ? (node.versionID == nil ? "Item Row" : "Version Row") : nil
    }

    private func configureItem(_ cell: PlaylistItemCellView, itemID id: UUID) {
        guard let item = itemsByID[id] else { return }
        let version = item.keyVersion
        let versionURL = version.flatMap { availableURL(for: $0) }
        let warnings = item.versions.compactMap { fileWarning(for: $0) }
        let node = node(.item(id))
        // Rejected and missing dim alike; only the track's own flag and its
        // key version's file count. A track whose every version is rejected
        // shows nothing extra here: its version rows carry that.
        cell.configure(PlaylistItemCellView.Content(
            title: PlaylistRowText.itemTitle(item),
            metadata: PlaylistRowText.metadataLine(version?.metadata, fields: metadataFields),
            duration: version.map { PlaylistRowText.duration($0.metadata.duration) } ?? "",
            hasVersions: item.versions.count > 1,
            isExpanded: outlineView.isItemExpanded(node),
            nowPlaying: currentItemID == id ? (isPlaying ? .playing : .paused) : nil,
            warning: warnings.isEmpty ? nil : warnings.joined(separator: "\n"),
            isDimmed: item.isRejected || version.flatMap { fileWarning(for: $0) } != nil,
            isRejected: item.isRejected,
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
        let isCurrent = currentItemID == item.id && currentVersionID == id
        cell.configure(
            title: PlaylistRowText.versionName(version),
            duration: PlaylistRowText.duration(version.metadata.duration),
            marks: PlaylistVersionCellView.Marks(
                warning: fileWarning(for: version),
                isRejected: version.isRejected,
                nowPlaying: isCurrent ? (isPlaying ? .playing : .paused) : nil
            ),
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
                  let version = item.keyVersion,
                  let url = availableURL(for: version) else { continue }
            requests.append((version.id, url))
        }
        artworkStore.requestThumbnails(requests)
    }

    private func thumbnailLoaded(_ versionID: UUID) {
        guard hasLoaded, let itemID = ownerByVersionID[versionID], let item = itemsByID[itemID],
              item.keyVersion?.id == versionID,
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
        presentation.prune(in: playlist.workspace)
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        guard let node = item as? PlaylistNode else { return nil }
        switch node.rowID {
        case let .item(id): return itemsByID[id].map(PlaylistRowText.itemTitle)
        case let .version(id): return version(id).map { PlaylistRowText.versionName($0.version) }
        }
    }

    func refreshHover(at windowPoint: NSPoint? = nil) {
        guard let window = outlineView.window else { return }
        let point = outlineView.convert(windowPoint ?? window.mouseLocationOutsideOfEventStream, from: nil)
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
        let fromBeginning: Bool
        switch rowID {
        case .item: fromBeginning = false
        case .version: fromBeginning = true
        }
        Task { await playlist.playItem(id: item.id, versionID: version.id, fromBeginning: fromBeginning) }
    }

    /// Compare opens even with missing files: their lanes show an error
    /// state, and the lane strip's menu offers Locate File….
    private func compare(itemID: UUID) {
        guard itemsByID[itemID] != nil else { return }
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
            playback.append(ClosureMenuItem("Compare Versions") { [weak self] in self?.compare(itemID: id) })
        }
        sections.append(playback)

        let reject = ClosureMenuItem(
            PlaylistRejectionCommand.title(clears: context.rejectionClears), enabled: context.canToggleRejection
        ) { context.toggleRejection() }
        reject.keyEquivalent = String(PlaylistRejectionCommand.key.character)
        reject.keyEquivalentModifierMask = PlaylistRejectionCommand.appKitModifiers
        sections.append([reject])

        var organize: [NSMenuItem] = []
        if rows.count > 1, !itemIDs.isEmpty {
            organize.append(ClosureMenuItem("Group Versions", enabled: context.canGroup) { context.group() })
        }
        if context.canSeparate {
            organize.append(ClosureMenuItem("Ungroup Versions") { context.separate() })
        }
        if itemIDs.isEmpty, !versionIDs.isEmpty {
            let owners = Set(versionIDs.compactMap { ownerByVersionID[$0] })
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for destination in items where owners != [destination.id] {
                let incoming = versionIDs.filter { ownerByVersionID[$0] != destination.id }.count
                let hasRoom = destination.versions.count + incoming <= PlaylistWorkspace.maximumVersionsPerItem
                submenu.addItem(ClosureMenuItem(PlaylistRowText.itemTitle(destination), enabled: hasRoom) { [weak self] in
                    self?.moveVersions(versionIDs, to: destination.id, before: nil)
                })
            }
            let moveTo = NSMenuItem(title: "Move To", action: nil, keyEquivalent: "")
            moveTo.submenu = submenu
            moveTo.isEnabled = submenu.numberOfItems > 0
            organize.append(moveTo)
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
            if let missing = candidates.first(where: { fileWarning(for: $0) != nil }) {
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

    /// File URLs for an item row's other versions, so dragging an item to
    /// Finder copies all of its versions. Missing files are left out, and a
    /// file already in the drag (the row's own, or a dragged version row's)
    /// isn't added twice. Each extra carries only a file URL: in-app drops
    /// read `draggedNodes`, never these.
    func extraDraggingItems(for draggingItems: [NSDraggingItem]) -> [NSDraggingItem] {
        let pasteboardItems = draggingItems.compactMap { $0.item as? NSPasteboardItem }
        var seen = Set(pasteboardItems.compactMap { $0.string(forType: .fileURL) })
        var extras: [NSDraggingItem] = []
        for draggingItem in draggingItems {
            guard let pasteboardItem = draggingItem.item as? NSPasteboardItem,
                  let id = pasteboardItem.string(forType: PlaylistItemDrag.pasteboardType).flatMap(UUID.init(uuidString:)),
                  let item = itemsByID[id] else { continue }
            for version in item.versions {
                guard let url = availableURL(for: version), seen.insert(url.absoluteString).inserted else { continue }
                let extra = NSPasteboardItem()
                extra.setString(url.absoluteString, forType: .fileURL)
                let extraItem = NSDraggingItem(pasteboardWriter: extra)
                extraItem.setDraggingFrame(draggingItem.draggingFrame, contents: nil)
                extras.append(extraItem)
            }
        }
        return extras
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
            guard playlist.groupItems(itemIDs, into: destination, undoManager: undoManager) != nil else { return false }
            presentation.selection = [.item(destination)]
            presentation.expanded.insert(destination)
        case let .separate(versionIDs, beforeItem: anchor):
            guard let created = playlist.separateVersions(
                versionIDs, placement: .beforeItem(anchor), undoManager: undoManager
            ) else { return false }
            if !created.isEmpty { presentation.selection = Set(created.map(PlaylistRowID.item)) }
        case let .moveVersions(versionIDs, to: destination, before: anchor):
            return moveVersions(versionIDs, to: destination, before: anchor)
        }
        return true
    }

    /// Move versions into `destination` ahead of `anchor` (nil appends),
    /// preserving their relative order. Versions already in the destination
    /// are reordered in place.
    @discardableResult
    private func moveVersions(_ versionIDs: [UUID], to destination: UUID, before anchor: UUID?) -> Bool {
        guard playlist.moveVersions(versionIDs, to: destination, before: anchor, undoManager: undoManager) else {
            return false
        }
        presentation.expanded.insert(destination)
        presentation.selection = Set(versionIDs.map(PlaylistRowID.version))
        return true
    }
}

// MARK: - Outline view

final class PlaylistNSOutlineView: NSOutlineView {
    weak var controller: PlaylistOutlineController?

    /// Rows draw their own chevron in a reserved slot (A2 §6), so AppKit's
    /// disclosure triangle and its indentation are suppressed: every cell
    /// spans the full row.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    /// Compare keeps the playlist in the hierarchy at zero opacity, so the
    /// table leaves the Tab loop while it is inactive; otherwise Tab would
    /// stop on it before reaching the lanes' offset fields.
    override var canBecomeKeyView: Bool {
        (controller?.isActive ?? true) && super.canBecomeKeyView
    }

    /// Dragging an item out carries every version whose file is there, not
    /// only its playback version: the extra files ride along as image-less
    /// dragging items (`PlaylistOutlineController.extraDraggingItems`).
    override func beginDraggingSession(
        with items: [NSDraggingItem], event: NSEvent, source: NSDraggingSource
    ) -> NSDraggingSession {
        super.beginDraggingSession(with: items + (controller?.extraDraggingItems(for: items) ?? []), event: event, source: source)
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let rowRect = rect(ofRow: row)
        guard column >= 0, column < numberOfColumns else { return rowRect }
        let columnRect = rect(ofColumn: column)
        return NSRect(x: columnRect.minX, y: rowRect.minY, width: columnRect.width, height: rowRect.height)
    }

    override func mouseDown(with event: NSEvent) {
        controller?.refreshHover(at: event.locationInWindow)
        super.mouseDown(with: event)
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
/// radius (A2 §3, §6): selection, hover, and the drop-on-item ring. Now
/// playing draws no background (culling §9.1): the cells tint their text and
/// speaker instead. Tracks hover for the Compare pill.
final class PlaylistRowView: NSTableRowView {
    private var hoverArea: NSTrackingArea?

    func setMoveForeground(_ isForeground: Bool) {
        if isForeground { wantsLayer = true }
        guard let layer, layer.zPosition != (isForeground ? 1 : 0) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.zPosition = isForeground ? 1 : 0
        CATransaction.commit()
    }

    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
            (view(atColumn: 0) as? PlaylistItemCellView)?.isHovered = isHovered
        }
    }

    /// Help ▸ Show Component Names badge, drawn over the row's cells.
    var debugLabel: String? {
        didSet {
            guard debugLabel != oldValue else { return }
            if let debugLabel {
                let badge = debugBadge ?? ComponentDebugBadgeView(name: debugLabel, color: .systemTeal)
                badge.name = debugLabel
                badge.frame = PlaylistRowMetrics.highlightRect(in: bounds)
                badge.autoresizingMask = [.width, .height]
                addSubview(badge, positioned: .above, relativeTo: nil)
                debugBadge = badge
            } else {
                debugBadge?.removeFromSuperview()
                debugBadge = nil
            }
        }
    }
    private var debugBadge: ComponentDebugBadgeView?

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        // Cells arrive after the badge; keep the badge on top.
        if let debugBadge, subview !== debugBadge { addSubview(debugBadge, positioned: .above, relativeTo: nil) }
    }

    override func layout() {
        super.layout()
        debugBadge?.frame = PlaylistRowMetrics.highlightRect(in: bounds)
    }

    private var highlightPath: NSBezierPath {
        let radius = PlaylistRowMetrics.highlightRadius
        return NSBezierPath(roundedRect: PlaylistRowMetrics.highlightRect(in: bounds), xRadius: radius, yRadius: radius)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard !isSelected else { return }
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
        setMoveForeground(false)
        isHovered = false
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

    /// The text is wider than the field, so it shows truncated.
    var isTruncatingText: Bool {
        guard let cell, !stringValue.isEmpty else { return false }
        let unbounded = NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: bounds.height)
        return ceil(cell.cellSize(forBounds: unbounded).width) > bounds.width
    }

    /// Single-line height for the field's font.
    var lineHeight: CGFloat {
        let saved = stringValue
        stringValue = "Ag"
        defer { stringValue = saved }
        return ceil(intrinsicContentSize.height)
    }

    /// Width that shows the whole text. Measured from the cell, which
    /// includes the label's side padding; `intrinsicContentSize` leaves it
    /// out and clipped the last few points (a version row's "FLAC").
    var fittingTextWidth: CGFloat {
        guard let cell else { return ceil(intrinsicContentSize.width) }
        let unbounded = NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        return ceil(cell.cellSize(forBounds: unbounded).width)
    }
}

/// A row's text colours for its state (culling §9.1). Selection wins, with
/// a dimmed row's text at `selectedDimmedTextOpacity`; then now playing,
/// whose tint replaces the dimming; then rejected or missing.
struct PlaylistRowTextStyle: Equatable {
    let title: NSColor
    let detail: NSColor

    static func resolve(emphasized: Bool, nowPlaying: Bool, dimmed: Bool) -> PlaylistRowTextStyle {
        if emphasized {
            let text = NSColor.alternateSelectedControlTextColor
            let opacity = dimmed ? PlaylistRowPalette.selectedDimmedTextOpacity : 1
            return .init(title: text.withAlphaComponent(opacity), detail: text.withAlphaComponent(0.75 * opacity))
        }
        if nowPlaying { return .init(title: PlaylistRowPalette.nowPlayingTitle, detail: PlaylistRowPalette.nowPlayingDetail) }
        if dimmed { return .init(title: PlaylistRowPalette.dimmedTitle, detail: PlaylistRowPalette.dimmedDetail) }
        // System label colours stay dynamic across appearance changes.
        return .init(title: .labelColor, detail: .secondaryLabelColor)
    }
}

private enum PlaylistGlyph {
    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, label: String? = nil) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }

    static func warning(size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Audio file unavailable")?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
                    .applying(.init(paletteColors: [PlaylistRowPalette.warningMark, PlaylistRowPalette.warningFill]))
            )
    }
}

/// Item row, 46 pt (A2 §6): chevron slot, thumbnail, title over metadata, the
/// hover Compare pill, and the duration.
final class PlaylistItemCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("item")

    enum NowPlaying: Equatable { case playing, paused }

    struct Content {
        var title: String
        var metadata: String
        var duration: String
        var hasVersions: Bool
        var isExpanded: Bool
        var nowPlaying: NowPlaying?
        /// Playback errors for versions of this item.
        var warning: String?
        /// Rejected, or the key version's file is unavailable: the two dim
        /// alike (culling §4.3).
        var isDimmed: Bool
        /// The track is rejected: the × badge on its artwork.
        var isRejected: Bool = false
        var thumbnail: NSImage?

        /// The speaker sits on the artwork unless the track is expanded,
        /// when it moves to the playing version's row (culling §9.1).
        var showsSpeakerOnArtwork: Bool { !(hasVersions && isExpanded) }
    }

    private let titleField = NSTextField.playlistLabel(font: .systemFont(ofSize: 13, weight: .semibold), truncation: .byTruncatingMiddle)
    private let metadataField = NSTextField.playlistLabel(font: .systemFont(ofSize: 11), truncation: .byTruncatingTail)
    private let durationField = NSTextField.playlistLabel(
        font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular), truncation: .byClipping, alignment: .right
    )
    private let disclosure = PlaylistDisclosureButton()
    private let thumbnail = PlaylistThumbnailView()
    private let comparePill = PlaylistComparePill()
    private let titleHeight: CGFloat
    private let metadataHeight: CGFloat
    private var content = Content(
        title: "", metadata: "", duration: "", hasVersions: false, isExpanded: false,
        nowPlaying: nil, warning: nil, isDimmed: false, isRejected: false, thumbnail: nil
    )

    var onDisclosure: (() -> Void)?
    var onCompare: (() -> Void)?

    var isHovered = false {
        didSet { if isHovered != oldValue { updatePill() } }
    }

    override var isFlipped: Bool { true }

    init() {
        titleHeight = titleField.lineHeight
        metadataHeight = metadataField.lineHeight
        super.init(frame: .zero)
        // The title has its own truncation tooltip (`layout`), and the
        // duration never needs one: AppKit's expansion tooltip showed on it
        // whenever its tight frame clipped a fraction of a point.
        titleField.allowsExpansionToolTips = false
        durationField.allowsExpansionToolTips = false
        identifier = Self.reuseIdentifier
        titleField.cell?.sendsActionOnEndEditing = true
        textField = titleField
        disclosure.action = { [weak self] in self?.onDisclosure?() }
        comparePill.target = self
        comparePill.action = #selector(comparePressed)
        for view in [disclosure, thumbnail, titleField, metadataField, comparePill, durationField] as [NSView] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ content: Content) {
        self.content = content
        titleField.stringValue = content.title
        metadataField.stringValue = content.metadata
        metadataField.isHidden = content.metadata.isEmpty
        durationField.stringValue = content.duration
        disclosure.isHidden = !content.hasVersions
        disclosure.setExpanded(content.isExpanded, animated: false)
        configureThumbnail()
        setAccessibilityValue(content.isRejected ? PlaylistRowText.rejectedAccessibilityValue : nil)
        updatePill()
        applyStyle()
        needsLayout = true
    }

    private func configureThumbnail() {
        let speaker: PlaylistThumbnailView.Status? = content.showsSpeakerOnArtwork
            ? content.nowPlaying.map { $0 == .playing ? .playing : .paused } : nil
        thumbnail.configure(
            image: content.thumbnail, isStacked: content.hasVersions,
            status: content.warning.map { .warning($0) } ?? speaker ?? .none,
            // A playing rejected track looks like any playing track, plus the
            // badge: the tint replaces the dimming.
            isDimmed: content.isDimmed && content.nowPlaying == nil,
            isRejected: content.isRejected
        )
    }

    func setThumbnail(_ image: NSImage?) {
        content.thumbnail = image
        thumbnail.image = image
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        let changed = content.isExpanded != expanded
        content.isExpanded = expanded
        disclosure.setExpanded(expanded, animated: animated)
        // Expanding moves the speaker to the playing version's row;
        // collapsing brings it back to the artwork.
        if changed { configureThumbnail() }
    }

    private func updatePill() {
        comparePill.isHidden = !(isHovered && content.hasVersions)
        needsLayout = true
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyStyle() }
    }

    private func applyStyle() {
        let emphasized = backgroundStyle == .emphasized
        // An expanded playing track keeps its tinted text; only the speaker
        // moves to the version row.
        let style = PlaylistRowTextStyle.resolve(
            emphasized: emphasized, nowPlaying: content.nowPlaying != nil, dimmed: content.isDimmed
        )
        titleField.textColor = style.title
        metadataField.textColor = style.detail
        durationField.textColor = style.detail
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
        if metadataField.isHidden {
            titleField.frame = NSRect(x: M.titleX, y: (height - titleHeight) / 2, width: textWidth, height: titleHeight)
            metadataField.frame = .zero
        } else {
            let top = ((height - titleHeight - 1 - metadataHeight) / 2).rounded()
            titleField.frame = NSRect(x: M.titleX, y: top, width: textWidth, height: titleHeight)
            metadataField.frame = NSRect(x: M.titleX, y: top + titleHeight + 1, width: textWidth, height: metadataHeight)
        }
        // The full title, only while it is cut short: by a narrow window or
        // by the hover Compare pill, which takes room from it.
        titleField.toolTip = titleField.isTruncatingText ? content.title : nil
    }

    @objc private func comparePressed() { onCompare?() }
}

/// Version row, 30 pt (A2 §6): the mark column under the item's thumbnail,
/// the version's title and duration. The mark column
/// holds the now-playing speaker (an expanded track's playing version), the
/// missing-file warning and the rejection ×, side by side when several
/// apply (culling §9.1). There is no key-version control: the key version
/// is derived (`PlaylistItem.keyVersion`), and rejecting happens through
/// the commands, never a control on the row.
final class PlaylistVersionCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("version")

    struct Marks: Equatable {
        /// The load error, for a version whose file is unavailable.
        var warning: String?
        var isRejected = false
        var nowPlaying: PlaylistItemCellView.NowPlaying?

        static let none = Marks()
        /// Rejected and missing dim alike.
        var isDimmed: Bool { warning != nil || isRejected }
    }

    static let markSize: CGFloat = 12
    static let markSpacing: CGFloat = 3

    private let titleField = NSTextField.playlistLabel(font: .systemFont(ofSize: 12), truncation: .byTruncatingMiddle)
    private let durationField = NSTextField.playlistLabel(
        font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular), truncation: .byClipping, alignment: .right
    )
    private let speakerView = NSImageView()
    private let warningView = NSImageView()
    private let rejectionView = NSImageView()
    private let titleHeight: CGFloat
    private let detailHeight: CGFloat
    private(set) var marks = Marks.none

    override var isFlipped: Bool { true }

    init() {
        titleHeight = titleField.lineHeight
        detailHeight = durationField.lineHeight
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        textField = titleField
        // As on item rows, the duration shows no expansion tooltip.
        durationField.allowsExpansionToolTips = false
        for view in [speakerView, warningView, rejectionView] {
            view.imageScaling = .scaleNone
        }
        warningView.image = PlaylistGlyph.warning(size: Self.markSize)
        rejectionView.image = RejectedMark.image(size: Self.markSize)
        rejectionView.toolTip = PlaylistRowText.rejectedAccessibilityValue
        for view in [speakerView, warningView, rejectionView, titleField, durationField] as [NSView] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, duration: String, marks: Marks, toolTip: String) {
        titleField.stringValue = title
        titleField.toolTip = toolTip
        durationField.stringValue = duration
        self.marks = marks
        if let nowPlaying = marks.nowPlaying {
            let playing = nowPlaying == .playing
            speakerView.image = PlaylistGlyph.symbol(
                playing ? "speaker.wave.2.fill" : "speaker.fill", size: 11, label: playing ? "Playing" : "Current"
            )
        }
        speakerView.isHidden = marks.nowPlaying == nil
        warningView.isHidden = marks.warning == nil
        warningView.toolTip = marks.warning
        warningView.setAccessibilityHelp(marks.warning)
        rejectionView.isHidden = !marks.isRejected
        for view in [speakerView, warningView, rejectionView] { view.setAccessibilityElement(!view.isHidden) }
        setAccessibilityValue(marks.isRejected ? PlaylistRowText.rejectedAccessibilityValue : nil)
        applyStyle()
        needsLayout = true
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyStyle() }
    }

    private func applyStyle() {
        let emphasized = backgroundStyle == .emphasized
        let style = PlaylistRowTextStyle.resolve(
            emphasized: emphasized, nowPlaying: marks.nowPlaying != nil, dimmed: marks.isDimmed
        )
        titleField.textColor = style.title
        durationField.textColor = style.detail
        speakerView.contentTintColor = emphasized ? .alternateSelectedControlTextColor : PlaylistRowPalette.nowPlayingTitle
    }

    /// The visible marks, centred together in the 34 pt column.
    var visibleMarkFrames: [NSRect] {
        [speakerView, warningView, rejectionView].filter { !$0.isHidden }.map(\.frame)
    }

    override func layout() {
        super.layout()
        typealias M = PlaylistRowMetrics
        let height = bounds.height
        let marks = [speakerView, warningView, rejectionView].filter { !$0.isHidden }
        let marksWidth = CGFloat(marks.count) * Self.markSize + CGFloat(max(marks.count - 1, 0)) * Self.markSpacing
        var markX = M.thumbnailX + (M.thumbnailSide - marksWidth) / 2
        for mark in marks {
            mark.frame = NSRect(x: markX, y: (height - Self.markSize) / 2, width: Self.markSize, height: Self.markSize)
            markX += Self.markSize + Self.markSpacing
        }
        let trailing = M.trailingX(rowWidth: bounds.width)
        let durationWidth = max(M.durationMinimumWidth, durationField.fittingTextWidth)
        let durationX = trailing - durationWidth
        durationField.frame = NSRect(x: durationX, y: (height - detailHeight) / 2, width: durationWidth, height: detailHeight)
        let textRight = durationX - M.gap
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

    /// The whole slot is the hit target, never the glyph's image view, so
    /// the table proposes this view for the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinates, as `frame` is.
        !isHidden && frame.contains(point) ? self : nil
    }
    /// The table hands a click in a row to a subview only when the subview
    /// accepts it here; otherwise the table takes it (as a row selection),
    /// and the chevron's `mouseDown` never runs.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        responder === self || super.validateProposedFirstResponder(responder, for: event)
    }
    override func mouseDown(with event: NSEvent) { action?() }
    override func accessibilityPerformPress() -> Bool {
        action?()
        return true
    }
}

/// The item row's 34 pt thumbnail: artwork (or the shared record
/// placeholder, `RecordPlaceholder.thumbnail`), the
/// stacked-card edges of a multi-version item, the now-playing or
/// missing-file overlay, and a rejected track's broken-heart badge. Laid out flipped;
/// the stack edges extend `stackExtent` above and to the right of the tile.
/// A dimmed track's tile goes greyscale at 45% (culling §9.1).
final class PlaylistThumbnailView: NSView {
    enum Status: Equatable {
        case none, playing, paused
        case warning(String)
    }

    static let stackExtent: CGFloat = PlaylistRowMetrics.stackOffsets.last.map { $0 - 2 } ?? 0
    static var size: NSSize {
        NSSize(width: PlaylistRowMetrics.thumbnailSide + stackExtent, height: PlaylistRowMetrics.thumbnailSide + stackExtent)
    }
    /// The broken-heart badge: 16 pt, overhanging the tile's corner by
    /// 4 pt right and 3 pt down, so the badge and its 2 pt ring stay inside
    /// the 46 pt row (culling §9.1).
    static let badgeSide: CGFloat = 16
    static let badgeRing: CGFloat = 2
    static var badgeFrame: NSRect {
        let side = PlaylistRowMetrics.thumbnailSide
        return NSRect(x: side + 4 - badgeSide, y: stackExtent + side + 3 - badgeSide, width: badgeSide, height: badgeSide)
    }
    /// The badge's ring, cut out of the tile and its stack (flipped coordinates).
    static let badgeCutout = RejectedMark.ringOutline(size: badgeSide, ring: badgeRing, in: badgeFrame)

    var image: NSImage? {
        didSet { tile.contentsImage = Self.tileImage(artwork: image, status: status) }
    }

    /// What the tile shows: the artwork, else the record placeholder,
    /// except in the warning state, which keeps the plain tile.
    static func tileImage(artwork: NSImage?, status: Status) -> NSImage? {
        if let artwork { return artwork }
        if case .warning = status { return nil }
        return RecordPlaceholder.thumbnail
    }

    /// The image the tile is showing, for tests.
    var displayedImage: NSImage? { tile.contentsImage }
    private(set) var isDimmed = false
    var showsRejectionBadge: Bool { !badge.isHidden }

    private var status: Status = .none
    /// The tile and its stack, masked to cut the badge's heart-shaped ring
    /// out of them so the row (and its selection) shows around the badge and
    /// through its crack.
    private let cards = PlaylistCardsView()
    private let farEdge = PlaylistFillView()
    private let nearEdge = PlaylistFillView()
    private let tile = PlaylistFillView()
    private let scrim = PlaylistFillView()
    private let statusGlyph = NSImageView()
    private let badge = NSImageView()

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
        // Greyscale through a Core Image filter on the tile's layer, so the
        // shared thumbnails are never re-rendered on the main thread.
        tile.layerUsesCoreImageFilters = true
        // The scrim and glyph sit over the tile, not in it, so dimming the
        // tile never greys the warning triangle.
        scrim.frame = tileRect
        scrim.cornerRadius = M.thumbnailRadius
        statusGlyph.imageScaling = .scaleNone
        statusGlyph.frame = tileRect
        cards.frame = bounds
        for view in [farEdge, nearEdge, tile, scrim, statusGlyph] { cards.addSubview(view) }
        badge.image = RejectedMark.image(size: Self.badgeSide)
        badge.imageScaling = .scaleNone
        badge.frame = Self.badgeFrame
        badge.isHidden = true
        cards.cutout = nil
        addSubview(cards)
        addSubview(badge)
        // The badge's ring reaches past the bottom edge, inside the row.
        clipsToBounds = false
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(image: NSImage?, isStacked: Bool, status: Status, isDimmed: Bool = false, isRejected: Bool = false) {
        self.status = status
        self.image = image
        nearEdge.isHidden = !isStacked
        farEdge.isHidden = !isStacked
        toolTip = nil
        switch status {
        case .none:
            scrim.isHidden = true
            statusGlyph.image = nil
        case .playing, .paused:
            scrim.isHidden = false
            scrim.fillColor = PlaylistRowPalette.playingScrim
            let playing = status == .playing
            statusGlyph.image = PlaylistGlyph.symbol(playing ? "speaker.wave.2.fill" : "speaker.fill", size: 13,
                                                     label: playing ? "Playing" : "Current")
            statusGlyph.contentTintColor = PlaylistRowPalette.nowPlayingSpeaker
        case let .warning(warning):
            // Dimming the tile already says "unavailable"; the triangle says
            // why, without a scrim (rejected and missing dim alike).
            scrim.isHidden = true
            statusGlyph.image = PlaylistGlyph.warning(size: 16)
            statusGlyph.contentTintColor = nil
            // The tile's decorative layer ignores hit testing. Register the
            // tooltip on the thumbnail so AppKit can find it under the icon.
            toolTip = warning
        }
        statusGlyph.setAccessibilityElement(statusGlyph.image != nil)
        statusGlyph.setAccessibilityHelp(toolTip)
        setDimmed(isDimmed)
        badge.isHidden = !isRejected
        badge.setAccessibilityElement(isRejected)
        cards.cutout = isRejected ? Self.badgeCutout : nil
    }

    private func setDimmed(_ dimmed: Bool) {
        guard dimmed != isDimmed else { return }
        isDimmed = dimmed
        tile.alphaValue = dimmed ? PlaylistRowPalette.dimmedThumbnailOpacity : 1
        tile.contentFilters = dimmed
            ? [CIFilter(name: "CIColorControls", parameters: [kCIInputSaturationKey: 0])].compactMap { $0 } : []
    }
}

/// The thumbnail's tile and stack, with an optional shape cut out of them
/// for the rejection badge's ring.
private final class PlaylistCardsView: NSView {
    /// In this view's (flipped) coordinates.
    var cutout: CGPath? {
        didSet { if cutout != oldValue { updateMask() } }
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        updateMask()
    }

    private func updateMask() {
        guard let layer else { return }
        guard let cutout else {
            layer.mask = nil
            return
        }
        // Convert through the layer so the cut-out lands in the same place
        // whichever way AppKit flips the backing layer.
        let origin = convertToLayer(NSPoint.zero)
        let down = convertToLayer(NSPoint(x: 0, y: 1)).y - origin.y
        let toLayer = CGAffineTransform(a: 1, b: 0, c: 0, d: down, tx: origin.x, ty: origin.y)
        let path = CGMutablePath()
        path.addRect(layer.bounds.insetBy(dx: -8, dy: -8))
        path.addPath(cutout, transform: toLayer)
        let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        mask.frame = layer.bounds
        mask.fillRule = .evenOdd
        mask.path = path
        layer.mask = mask
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
        var contents: CGImage?
        // Resolve both for this view's appearance: a catalog image with
        // light and dark variants (the record placeholder) picks its bitmap
        // here, so an appearance change swaps it in visible rows.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = fillColor.cgColor
            contents = contentsImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        layer.backgroundColor = color
        layer.cornerRadius = cornerRadius
        layer.masksToBounds = cornerRadius > 0
        layer.contentsGravity = .resizeAspectFill
        layer.contents = contents
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
