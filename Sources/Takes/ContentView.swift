import AppKit
import Combine
import os
import SwiftUI
import UniformTypeIdentifiers

struct NumericControlConfiguration: Equatable {
    let range: ClosedRange<Int>
    let step: Int
    let largeStep: Int
    let suffix: String

    static let gain = NumericControlConfiguration(range: -24...24, step: 1, largeStep: 10, suffix: "dB")
    static let offset = NumericControlConfiguration(range: -300_000...300_000, step: 100, largeStep: 500, suffix: "ms")

    func clamped(_ value: Int) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    func steppedValue(from value: Int, direction: Int, largeStep: Bool) -> Int {
        clamped(value + (largeStep ? self.largeStep : step) * direction)
    }

    func steppedValue(fromText text: String, fallbackValue: Int, direction: Int, largeStep: Bool) -> Int {
        let parsed = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? fallbackValue
        return steppedValue(from: parsed, direction: direction, largeStep: largeStep)
    }

    static func isLargeStepCommand(_ selector: Selector) -> Bool {
        selector == #selector(NSResponder.moveUpAndModifySelection(_:))
            || selector == #selector(NSResponder.moveDownAndModifySelection(_:))
    }

    static func isLargeStepModifierFlags(_ modifierFlags: NSEvent.ModifierFlags) -> Bool {
        modifierFlags.contains(.shift)
    }

    static func isCancelEditingCommand(_ selector: Selector) -> Bool {
        selector == #selector(NSResponder.cancelOperation(_:))
    }
}

struct SwitchTrackModifierPolicy {
    static func selectsPreviousTrack(
        currentEventFlags: NSEvent.ModifierFlags?,
        fallbackFlags: NSEvent.ModifierFlags = NSEvent.modifierFlags
    ) -> Bool {
        currentEventFlags?.contains(.shift) == true || fallbackFlags.contains(.shift)
    }
}

struct NumericControlEditState {
    private(set) var committedValue: Int
    private(set) var pendingText: String?

    init(committedValue: Int) {
        self.committedValue = committedValue
    }

    mutating func beginEditing(currentValue: Int) {
        committedValue = currentValue
        pendingText = nil
    }

    mutating func beginEditing(
        displayedText: String,
        fallbackValue: Int,
        configuration: NumericControlConfiguration
    ) {
        let trimmed = displayedText.trimmingCharacters(in: .whitespacesAndNewlines)
        beginEditing(currentValue: configuration.clamped(Int(trimmed) ?? fallbackValue))
    }

    mutating func refreshCommittedValue(_ value: Int) {
        guard pendingText == nil else { return }
        committedValue = value
    }

    mutating func updatePendingText(_ text: String) {
        pendingText = text
    }

    mutating func cancelledValue() -> Int {
        pendingText = nil
        return committedValue
    }

    mutating func commit(_ value: Int) {
        committedValue = value
        pendingText = nil
    }

    mutating func commitPendingText(
        fallbackValue: Int,
        configuration: NumericControlConfiguration
    ) -> Int {
        guard let pendingText else { return committedValue }
        let trimmed = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = Int(trimmed) ?? fallbackValue
        let clamped = configuration.clamped(parsed)
        commit(clamped)
        return clamped
    }

    mutating func commitSteppedPendingText(
        fallbackValue: Int,
        configuration: NumericControlConfiguration,
        direction: Int,
        largeStep: Bool
    ) -> Int {
        let stepped = configuration.steppedValue(
            fromText: pendingText ?? "\(fallbackValue)",
            fallbackValue: fallbackValue,
            direction: direction,
            largeStep: largeStep
        )
        commit(stepped)
        return stepped
    }

    mutating func commitSteppedEditingText(
        currentText: String,
        fallbackValue: Int,
        configuration: NumericControlConfiguration,
        direction: Int,
        largeStep: Bool
    ) -> Int {
        let textForStep: String
        if let pendingText,
           currentText.trimmingCharacters(in: .whitespacesAndNewlines) == "\(committedValue)" {
            textForStep = pendingText
        } else {
            textForStep = currentText
        }

        updatePendingText(textForStep)
        return commitSteppedPendingText(
            fallbackValue: fallbackValue,
            configuration: configuration,
            direction: direction,
            largeStep: largeStep
        )
    }
}

enum NumericControlEditingText {
    static func current(controlText: String, fieldEditorText: String?) -> String {
        fieldEditorText ?? controlText
    }
}

enum NumericInputKeyEquivalentPolicy {
    static func routesToFieldEditor(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        keyCode == 123 || keyCode == 124 || keyCode == 125 || keyCode == 126
    }

    static func routesToFieldEditor(event: NSEvent) -> Bool {
        routesToFieldEditor(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags
        )
    }
}

struct NumericControlFocusPolicy {
    @MainActor
    static func isTextInputView(_ view: NSView) -> Bool {
        var currentView: NSView? = view
        while let view = currentView {
            if view is NSTextField || view is NSTextView {
                return true
            }
            currentView = view.superview
        }

        return false
    }

    @MainActor
    static func shouldClearEditingFocus(firstResponder: NSResponder?, clickedView: NSView?) -> Bool {
        guard firstResponder is NSTextView else { return false }
        guard let clickedView else { return true }

        return !isTextInputView(clickedView)
    }
}

struct GlobalShortcutFocusPolicy {
    static func shouldHandleGlobalShortcut(firstResponder: NSResponder?) -> Bool {
        !(firstResponder is NSTextView || firstResponder is NSTextField)
    }
}

struct CursorResetPolicy {
    @MainActor
    static func shouldUseArrowCursor(currentCursor: NSCursor, hitView: NSView?) -> Bool {
        guard currentCursor === NSCursor.iBeam else { return false }
        guard let hitView else { return true }
        return !NumericControlFocusPolicy.isTextInputView(hitView)
    }
}

enum TrackDropHighlight: Equatable {
    case normal
    case dropTarget

    static func empty(isTargeted: Bool) -> TrackDropHighlight {
        isTargeted ? .dropTarget : .normal
    }
}

enum DroppedFileImportAction: Equatable {
    case append

    static func action(targetTrackID _: SessionTrack.ID?) -> DroppedFileImportAction {
        .append
    }
}

enum DroppedFileURLResolver {
    static func audioFileURLs(from urls: [URL], fileManager: FileManager = .default) -> [URL] {
        AppOpenedURLResolver.audioFileURLs(from: urls, fileManager: fileManager)
    }
}

enum TrackReorderDrag {
    /// Private marker type identifying an in-app track reorder drag. Must be a
    /// type no external drag can carry: Finder file drags include a plain-text
    /// flavor (the path), so a system text type here would make the reorder-only
    /// drop target claim — and swallow — genuine file drops over the track list.
    /// Declared as an exported type in Takes-Info.plist.
    static let contentType = UTType(exportedAs: "com.nigelwarren.takes.track-reorder")
}

enum TrackRowDropTarget {
    static let acceptedContentTypeIdentifiers = [
        TrackReorderDrag.contentType.identifier,
        UTType.fileURL.identifier
    ]
}

enum TrackRowDropKind: Equatable {
    case file
    case reorder

    static func kind(hasFileURLs: Bool, hasReorderItems: Bool) -> TrackRowDropKind? {
        // Reorder wins when both are present: an in-app reorder drag also
        // carries the track's file URL so it can be dragged out of the window.
        if hasReorderItems {
            return .reorder
        }
        if hasFileURLs {
            return .file
        }
        return nil
    }
}

enum TrackReorderInsertionPlacement: Equatable {
    case before
    case after

    static func location(y: CGFloat, rowHeight: CGFloat) -> TrackReorderInsertionPlacement {
        y <= rowHeight / 2 ? .before : .after
    }
}

/// Pure geometry for the custom reorder drag: mapping the pointer to a target
/// slot, deciding how far each row shifts to open the gap, and resolving the
/// final `reorderTrack(before:)` destination once the drag lands.
enum TrackReorderGeometry {
    /// The slot (0..<count) the pointer hovers, given its Y within the list
    /// content and a fixed per-row step.
    static func slot(forContentY y: CGFloat, rowStep: CGFloat, count: Int) -> Int {
        guard count > 0, rowStep > 0 else { return 0 }
        let raw = Int((y / rowStep).rounded(.down))
        return min(max(raw, 0), count - 1)
    }

    /// Vertical offset (points) for the row at `index` so a gap opens at
    /// `targetIndex` while the row at `sourceIndex` is lifted out of the flow.
    static func rowOffset(index: Int, sourceIndex: Int, targetIndex: Int, rowStep: CGFloat) -> CGFloat {
        guard index != sourceIndex else { return 0 }
        if sourceIndex < targetIndex, index > sourceIndex, index <= targetIndex {
            return -rowStep
        }
        if sourceIndex > targetIndex, index < sourceIndex, index >= targetIndex {
            return rowStep
        }
        return 0
    }

    /// Where a landed drag should place the moved row.
    enum Destination: Equatable {
        /// No change: the row is dropped on its own slot.
        case noChange
        /// Insert before the original row at this index.
        case before(Int)
        /// Append to the end of the list.
        case append
    }

    /// Resolves the final placement for `reorderTrack(before:)` from the source
    /// and target slots.
    static func destination(sourceIndex: Int, targetIndex: Int, count: Int) -> Destination {
        guard targetIndex != sourceIndex else { return .noChange }
        if targetIndex > sourceIndex {
            let after = targetIndex + 1
            return after < count ? .before(after) : .append
        }
        return .before(targetIndex)
    }
}

/// The single drop target spanning the row list, handling both drag kinds that
/// can land there. A track reorder opens the gap as the dragged row moves and
/// commits the move on drop — committing nothing until then. An external file
/// drag appends the files, same as the window-wide import target — it must be
/// handled here too because SwiftUI routes a drop to the innermost target under
/// the pointer without falling through, so the list would otherwise be a dead
/// zone for file drops. Cleanup is reliable: `dropExited` restores the row when
/// the drag leaves the list (e.g. on its way out of the window to an external
/// target), and `performDrop` restores it on a landing drop.
private struct TrackListDropDelegate: DropDelegate {
    var controller: PlaybackController
    let rowStep: CGFloat
    @Binding var draggingID: SessionTrack.ID?
    @Binding var targetIndex: Int?
    @Binding var gapGeneration: Int
    @Binding var revealingID: SessionTrack.ID?
    @Binding var isImportTargeted: Bool
    let loadDroppedURLs: ([NSItemProvider]) -> Bool

    /// A reorder carries the file URL too (for dragging out of the window), so
    /// the marker type decides the kind, not the presence of a file URL.
    private func dropKind(_ info: DropInfo) -> TrackRowDropKind? {
        TrackRowDropKind.kind(
            hasFileURLs: info.hasItemsConforming(to: [UTType.fileURL.identifier]),
            hasReorderItems: info.hasItemsConforming(to: [TrackReorderDrag.contentType.identifier])
        )
    }

    func validateDrop(info: DropInfo) -> Bool {
        dropKind(info) != nil
    }

    func dropEntered(info: DropInfo) {
        switch dropKind(info) {
        case .reorder:
            updateGap(info: info)
        case .file:
            isImportTargeted = true
        case nil:
            break
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        switch dropKind(info) {
        case .reorder:
            updateGap(info: info)
            return DropProposal(operation: .move)
        case .file:
            return DropProposal(operation: .copy)
        case nil:
            return DropProposal(operation: .cancel)
        }
    }

    func dropExited(info: DropInfo) {
        isImportTargeted = false
        // The drag left the list (e.g. headed out of the window): close the gap so
        // the rows return to rest, but keep the row hidden so re-entering resumes
        // the reorder. The drag source's `endedAt` restores it if the drop lands
        // elsewhere.
        guard targetIndex != nil else { return }
        gapGeneration += 1
        targetIndex = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        isImportTargeted = false
        guard dropKind(info) == .reorder else {
            guard dropKind(info) == .file else { return false }
            return loadDroppedURLs(info.itemProviders(for: [UTType.fileURL.identifier]))
        }
        defer { clear() }
        guard let draggingID, let targetIndex,
              let sourceIndex = controller.session.tracks.firstIndex(where: { $0.id == draggingID })
        else {
            return false
        }

        let tracks = controller.session.tracks
        // No animation: the gap is already open at the target, so committing the
        // reorder while the offsets snap back to zero leaves every row exactly
        // where it already sits — a seamless swap rather than a re-animated slide.
        switch TrackReorderGeometry.destination(sourceIndex: sourceIndex, targetIndex: targetIndex, count: tracks.count) {
        case .noChange:
            break
        case .append:
            controller.reorderTrack(draggingID, before: nil)
        case .before(let destinationIndex):
            let destinationID = tracks.indices.contains(destinationIndex) ? tracks[destinationIndex].id : nil
            controller.reorderTrack(draggingID, before: destinationID)
        }
        return true
    }

    private func updateGap(info: DropInfo) {
        guard draggingID != nil else { return }
        let slot = TrackReorderGeometry.slot(
            forContentY: info.location.y,
            rowStep: rowStep,
            count: controller.session.tracks.count
        )
        if targetIndex != slot {
            gapGeneration += 1
            targetIndex = slot
        }
    }

    private func clear() {
        // Hand the row to the reveal phase rather than unhiding it here: the
        // reorder must land unanimated first, then the drag source's ended
        // callback fades the row in at its new position.
        revealingID = draggingID
        draggingID = nil
        targetIndex = nil
    }
}

/// The window-wide audio-file import target. Accepts genuine external file drags
/// (append). A track being reordered also carries a file URL, so it lands here
/// too when it strays over the window's chrome (transport bar, header); it's
/// claimed but proposed as `.cancel`, so it reads as a cancel matching the menu
/// bar — leaving it target-less instead would make AppKit fall back to the drag
/// source's copy mask and flash a stray copy badge.
private struct WindowFileImportDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let loadDroppedURLs: ([NSItemProvider]) -> Bool

    private func isReorderDrag(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [TrackReorderDrag.contentType.identifier])
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL.identifier])
    }

    func dropEntered(info: DropInfo) {
        isTargeted = !isReorderDrag(info)
    }

    func dropExited(info: DropInfo) { isTargeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: isReorderDrag(info) ? .cancel : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard !isReorderDrag(info) else { return false }
        return loadDroppedURLs(info.itemProviders(for: [UTType.fileURL.identifier]))
    }
}

/// AppKit-backed drag source for a track row. SwiftUI's `onDrag` can't express a
/// move-inside / copy-outside operation, so the row's drag is run here as an
/// `NSDraggingSession`: **move** (reorder) within the app, **copy** the audio file
/// out to Finder / other apps / another Takes window, and **cancel** on the menu
/// bar or any non-target. A plain click (no drag) selects the row.
///
/// Placed as the info column's background so the badge/name/metadata forward their
/// clicks here while the column's own controls (trash, offset field) still work.
struct TrackRowDragSource: NSViewRepresentable {
    let fileURL: URL
    let trackID: SessionTrack.ID
    let onSelect: () -> Void
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void
    let makeDragImage: () -> NSImage?

    func makeNSView(context: Context) -> DragSourceNSView {
        DragSourceNSView()
    }

    func updateNSView(_ nsView: DragSourceNSView, context: Context) {
        nsView.fileURL = fileURL
        nsView.trackID = trackID
        nsView.onSelect = onSelect
        nsView.onDragBegan = onDragBegan
        nsView.onDragEnded = onDragEnded
        nsView.makeDragImage = makeDragImage
    }
}

final class DragSourceNSView: NSView, NSDraggingSource {
    var fileURL: URL?
    var trackID: SessionTrack.ID?
    var onSelect: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var makeDragImage: (() -> NSImage?)?

    private var mouseDownPoint: NSPoint?
    private var isDragging = false
    /// The lifted-card image for the drag in flight, kept so the session can
    /// restore it when a drop destination replaces or scales the drag image.
    private var activeDragImage: NSImage?
    private static let dragThreshold: CGFloat = 6

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDragging, let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard abs(point.x - start.x) > Self.dragThreshold || abs(point.y - start.y) > Self.dragThreshold else {
            return
        }
        isDragging = true
        beginDrag(with: event, at: start)
    }

    override func mouseUp(with event: NSEvent) {
        if !isDragging { onSelect?() }
        mouseDownPoint = nil
    }

    private func beginDrag(with event: NSEvent, at origin: NSPoint) {
        guard let fileURL, let trackID else { return }

        let pasteboardItem = NSPasteboardItem()
        // File URL so external targets (Finder, other apps) receive the audio file.
        pasteboardItem.setData(fileURL.dataRepresentation, forType: .fileURL)
        // Own reorder marker type so the in-window drop target recognizes it.
        pasteboardItem.setString(
            trackID.uuidString,
            forType: NSPasteboard.PasteboardType(TrackReorderDrag.contentType.identifier)
        )

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let image = makeDragImage?() ?? NSImage(size: NSSize(width: 1, height: 1))
        let size = image.size
        // Center the card on the grabbed point.
        let frame = NSRect(
            x: origin.x - size.width / 2,
            y: origin.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        draggingItem.setDraggingFrame(frame, contents: image)

        onDragBegan?()
        activeDragImage = image
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.draggingFormation = .none
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        // Drop destinations (including our own SwiftUI drop targets) update the
        // dragging items as the drag passes over them, replacing the lifted card
        // with a scaled-down generic preview. Detect the size change and restore
        // the card, keeping it full-size for the whole drag.
        guard let image = activeDragImage else { return }
        let size = image.size
        session.enumerateDraggingItems(
            options: [],
            for: nil,
            classes: [NSPasteboardItem.self],
            searchOptions: [:]
        ) { item, _, _ in
            let frame = item.draggingFrame
            guard abs(frame.width - size.width) > 0.5 || abs(frame.height - size.height) > 0.5 else {
                return
            }
            item.setDraggingFrame(
                NSRect(
                    x: screenPoint.x - size.width / 2,
                    y: screenPoint.y - size.height / 2,
                    width: size.width,
                    height: size.height
                ),
                contents: image
            )
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        switch context {
        case .withinApplication:
            return .move
        case .outsideApplication:
            return .copy
        @unknown default:
            return .copy
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        // Reliable end-of-drag signal regardless of where the drop landed (a row,
        // an external app, or nowhere): restore the row. An in-window reorder has
        // already committed via the drop delegate's `performDrop`.
        activeDragImage = nil
        onDragEnded?()
    }
}

/// AppKit tooltip sensor that tracks a single-line title label's rendered width.
/// It registers the standard tooltip only when the untruncated string is wider
/// than the label's current bounds, and it never steals clicks/drags from the
/// row because hit-testing passes through to the drag source behind it.
private struct TruncationAwareTooltip: NSViewRepresentable {
    let text: String
    let font: NSFont

    func makeNSView(context: Context) -> TruncationAwareTooltipNSView {
        TruncationAwareTooltipNSView()
    }

    func updateNSView(_ nsView: TruncationAwareTooltipNSView, context: Context) {
        nsView.text = text
        nsView.font = font
        nsView.updateTooltipIfNeeded()
    }
}

private final class TruncationAwareTooltipNSView: NSView {
    var text = ""
    var font = NSFont.preferredFont(forTextStyle: .headline)

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        updateTooltipIfNeeded()
    }

    func updateTooltipIfNeeded() {
        guard bounds.width > 0, !text.isEmpty else {
            toolTip = nil
            return
        }

        toolTip = measuredTextWidth > bounds.width + 0.5 ? text : nil
    }

    private var measuredTextWidth: CGFloat {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        return ceil(attributed.size().width)
    }
}

enum ImportActionMenuItem: CaseIterable {
    case open
    case streamingURL
    case finderSelection
    case musicSelection

    static let dropdownItems: [ImportActionMenuItem] = [
        .streamingURL,
        .finderSelection,
        .musicSelection
    ]

    var title: String {
        switch self {
        case .open:
            "Open..."
        case .streamingURL:
            "Open Streaming URL..."
        case .finderSelection:
            "Quick Open from Finder"
        case .musicSelection:
            "Quick Open from Apple Music"
        }
    }
}

enum ImportActionControlMetrics {
    static let controlWidth: CGFloat = 62
    static let controlHeight: CGFloat = 34
    static let primaryButtonWidth: CGFloat = 34
    static let menuButtonWidth: CGFloat = 27
}

enum ImportActionSplitButtonHitTesting {
    static func segment(
        atX x: CGFloat,
        controlWidth: CGFloat,
        primaryWidth: CGFloat,
        menuWidth: CGFloat,
        layoutDirection: NSUserInterfaceLayoutDirection
    ) -> Int? {
        guard x >= 0, x <= controlWidth else { return nil }

        switch layoutDirection {
        case .rightToLeft:
            return x <= controlWidth - primaryWidth ? 1 : 0
        default:
            return x <= primaryWidth ? 0 : 1
        }
    }
}

enum ImportActionSplitButtonMenuPlacement {
    static func origin(
        bounds: NSRect,
        menuWidth: CGFloat,
        layoutDirection: NSUserInterfaceLayoutDirection,
        isFlipped: Bool
    ) -> NSPoint {
        let menuX = layoutDirection == .rightToLeft ? bounds.minX : bounds.maxX - menuWidth
        let menuY = isFlipped ? bounds.maxY : bounds.minY
        return NSPoint(x: menuX, y: menuY)
    }
}

@MainActor
final class OpenFileCommandState: ObservableObject {
    @Published var isImportingTracks = false
    @Published var isPromptingForStreamingURL = false
    @Published var streamingURLText = ""
    @Published var streamingURLStatus: StreamingURLPromptStatus = .idle

    private var streamingURLTask: Task<Void, Never>?
    private var streamingURLTaskID: UUID?

    private let loadStreamingURLAction: @MainActor (String, OpenFileCommandState) -> Void
    private let loadAppleMusicSelection: @MainActor () -> Void
    private let loadFinderSelection: @MainActor () -> Void
    private let showActiveTrackInFinderAction: @MainActor () -> Void
    private let removeActiveTrackAction: @MainActor () -> Void
    private let clearAllTracksAction: @MainActor () -> Void

    init(
        loadStreamingURL: @escaping @MainActor (String, OpenFileCommandState) -> Void = { _, _ in },
        loadAppleMusicSelection: @escaping @MainActor () -> Void = {},
        loadFinderSelection: @escaping @MainActor () -> Void = {},
        showActiveTrackInFinder: @escaping @MainActor () -> Void = {},
        removeActiveTrack: @escaping @MainActor () -> Void = {},
        clearAllTracks: @escaping @MainActor () -> Void = {}
    ) {
        self.loadStreamingURLAction = loadStreamingURL
        self.loadAppleMusicSelection = loadAppleMusicSelection
        self.loadFinderSelection = loadFinderSelection
        self.showActiveTrackInFinderAction = showActiveTrackInFinder
        self.removeActiveTrackAction = removeActiveTrack
        self.clearAllTracksAction = clearAllTracks
    }

    func presentOpenDialog() {
        isImportingTracks = true
    }

    func dismissOpenDialog() {
        isImportingTracks = false
    }

    func presentStreamingURLPrompt() {
        cancelStreamingURLTask()
        streamingURLText = ""
        streamingURLStatus = .idle
        isPromptingForStreamingURL = true
    }

    func openStreamingURL(_ urlString: String) {
        guard !streamingURLStatus.isWorking else { return }
        streamingURLText = urlString
        streamingURLStatus = .idle
        isPromptingForStreamingURL = true
        submitStreamingURL()
    }

    func dismissStreamingURLPrompt() {
        cancelStreamingURLTask()
        isPromptingForStreamingURL = false
        streamingURLText = ""
        streamingURLStatus = .idle
    }

    func registerStreamingURLTask(_ task: Task<Void, Never>, id: UUID) {
        streamingURLTask = task
        streamingURLTaskID = id
    }

    func finishStreamingURLTask(id: UUID) {
        guard streamingURLTaskID == id else { return }
        streamingURLTask = nil
        streamingURLTaskID = nil
    }

    private func cancelStreamingURLTask() {
        streamingURLTask?.cancel()
        streamingURLTask = nil
        streamingURLTaskID = nil
    }

    func submitStreamingURL() {
        guard !streamingURLStatus.isWorking else { return }
        let urlString = streamingURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty else { return }
        streamingURLStatus = .readingMetadata("streaming")
        loadStreamingURLAction(urlString, self)
    }

    func openAppleMusicSelection() {
        loadAppleMusicSelection()
    }

    func openFinderSelection() {
        loadFinderSelection()
    }

    func showActiveTrackInFinder() {
        showActiveTrackInFinderAction()
    }

    func removeActiveTrack() {
        removeActiveTrackAction()
    }

    func clearAllTracks() {
        clearAllTracksAction()
    }
}

struct MainWindowCommandState {
    let resetWindowSizing: @MainActor () -> Void
}

private struct OpenFileCommandStateKey: FocusedValueKey {
    typealias Value = OpenFileCommandState
}

private struct MainWindowCommandStateKey: FocusedValueKey {
    typealias Value = MainWindowCommandState
}

private struct CanClearTracksKey: FocusedValueKey {
    typealias Value = Bool
}

private struct CanRemoveActiveTrackKey: FocusedValueKey {
    typealias Value = Bool
}

private struct CanUseGlobalMenuShortcutsKey: FocusedValueKey {
    typealias Value = Bool
}

private struct CanShowActiveTrackInFinderKey: FocusedValueKey {
    typealias Value = Bool
}

private struct TransportReadoutWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 180

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TrackInfoColumnResizeHandleView: NSViewRepresentable {
    let sectionWidth: CGFloat
    @Binding var columnWidth: Double

    func makeNSView(context: Context) -> ResizeHandleNSView {
        let view = ResizeHandleNSView()
        view.sectionWidth = sectionWidth
        view.columnWidth = CGFloat(columnWidth)
        view.onColumnWidthChanged = { columnWidth = Double($0) }
        return view
    }

    func updateNSView(_ nsView: ResizeHandleNSView, context: Context) {
        nsView.sectionWidth = sectionWidth
        nsView.columnWidth = CGFloat(columnWidth)
        nsView.onColumnWidthChanged = { columnWidth = Double($0) }
    }

    final class ResizeHandleNSView: NSView {
        var sectionWidth: CGFloat = 0
        var columnWidth: CGFloat = TakesWindowPolicy.defaultTrackInfoColumnWidth
        var onColumnWidthChanged: ((CGFloat) -> Void)?
        private var dragStartWidth: CGFloat?
        private var dragStartX: CGFloat?

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }

        override func mouseMoved(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }

        override func mouseDown(with event: NSEvent) {
            dragStartWidth = columnWidth
            dragStartX = event.locationInWindow.x
            NSCursor.resizeLeftRight.set()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragStartWidth, let dragStartX else { return }
            let nextWidth = TakesWindowPolicy.clampedTrackInfoColumnWidth(
                dragStartWidth + event.locationInWindow.x - dragStartX,
                sectionWidth: sectionWidth
            )
            onColumnWidthChanged?(nextWidth)
            NSCursor.resizeLeftRight.set()
        }

        override func mouseUp(with event: NSEvent) {
            dragStartWidth = nil
            dragStartX = nil
        }
    }
}

extension FocusedValues {
    var openFileCommandState: OpenFileCommandState? {
        get { self[OpenFileCommandStateKey.self] }
        set { self[OpenFileCommandStateKey.self] = newValue }
    }

    var mainWindowCommandState: MainWindowCommandState? {
        get { self[MainWindowCommandStateKey.self] }
        set { self[MainWindowCommandStateKey.self] = newValue }
    }

    var canClearTracks: Bool? {
        get { self[CanClearTracksKey.self] }
        set { self[CanClearTracksKey.self] = newValue }
    }

    var canRemoveActiveTrack: Bool? {
        get { self[CanRemoveActiveTrackKey.self] }
        set { self[CanRemoveActiveTrackKey.self] = newValue }
    }

    var canUseGlobalMenuShortcuts: Bool? {
        get { self[CanUseGlobalMenuShortcutsKey.self] }
        set { self[CanUseGlobalMenuShortcutsKey.self] = newValue }
    }

    var canShowActiveTrackInFinder: Bool? {
        get { self[CanShowActiveTrackInFinderKey.self] }
        set { self[CanShowActiveTrackInFinderKey.self] = newValue }
    }

}

struct ContentView: View {
    var controller: PlaybackController
    @EnvironmentObject private var settings: AppSettings
    private let appFileOpenRouter: AppFileOpenRouter?
    private let usesTemporaryDefaultWindowLayout: Bool

    @StateObject private var openFileCommandState = OpenFileCommandState()
    @StateObject private var waveformStore = WaveformStore()
    @State private var keyMonitor: KeyMonitor?
    @State private var mouseMonitor: MouseMonitor?
    /// While a ruler scrub is in flight: the playhead preview's x within the
    /// waveform column. `nil` when not scrubbing.
    @State private var playheadDragX: CGFloat?
    /// Timeline frame + column split, captured for the mouse-monitor cursor
    /// manager (which works in window coordinates, outside SwiftUI hover).
    @State private var timelineCursorGeometry: TimelineCursorGeometry?
    /// The cursor shape the cursor manager last applied, so it only calls
    /// `NSCursor.set()` on transitions and never fights other controls'
    /// cursors while the pointer is elsewhere.
    @State private var timelineCursorShape = TimelineCursorShape.standard
    /// Which row is being dragged for reorder (hidden in place; its floating
    /// preview is the OS drag image). Set at drag start, cleared when the drag
    /// commits or is abandoned.
    @State private var reorderDraggingID: SessionTrack.ID?
    /// The slot the dragged row will land in, driving the gap the other rows open.
    @State private var reorderTargetIndex: Int?
    /// Bumped only when the gap moves during a drag, so the offset animation fires
    /// on gap changes but not on the instant teardown at commit.
    @State private var reorderGapGeneration = 0
    /// The just-dropped row, held invisible for one more tick after the reorder
    /// commits so it can fade in at its landed position (in sync with the system
    /// fading out the drag image) instead of sliding there from its old slot.
    @State private var reorderRevealingID: SessionTrack.ID?
    @State private var windowIsDropTargeted = false
    @State private var emptyStateIsHovered = false
    @State private var hoverStore = TrackHoverStore()
    @State private var focusedOffsetTrackID: SessionTrack.ID?
    @FocusState private var streamingURLFieldIsFocused: Bool
    @State private var didConfigureMainWindow = false
    @State private var mainWindow: NSWindow?
    @State private var mainWindowIsKey = true
    @State private var loopDraft: LoopDraft?
    @State private var loopResizeDraft: LoopRegion?
    /// Row indices whose lanes may rasterize: the rows intersecting the
    /// vertical scroll viewport plus overscan. Row-quantized and written with
    /// an equality guard, so vertical scrolling within the band never re-runs
    /// the container. Starts fully open so nothing is culled before the first
    /// geometry pass lands.
    @State private var renderableRows: ClosedRange<Int> = 0...Int.max
    /// Shared source for the zoom-varying lane window (window bounds + tick
    /// guides). Only the lane leaves observe it, so a zoom step re-runs those
    /// fixed-frame leaves — never the row bodies — keeping the VStack from
    /// re-laying-out. Written from the container via an equality-guarded
    /// `.onChange`; see `LaneViewport` for why it can't be a row input.
    @State private var laneViewportStore = LaneViewportStore()
    @State private var transportReadoutWidth: CGFloat = TransportReadoutWidthKey.defaultValue
    @State private var trackInfoColumnWidth: Double
    @State private var showsAlignmentAttentionPopover = false
    @State private var alignmentOutcomePulse = false

    /// An in-progress loop drag, in absolute seconds. `start` is where the drag
    /// began; `current` tracks the pointer. Committed to a `LoopRegion` on mouse-up.
    private struct LoopDraft {
        var start: TimeInterval
        var current: TimeInterval
    }

    /// Height of one row plus its divider — the step between reorder target slots.
    private var reorderRowStep: CGFloat { trackRowHeight + trackTimelineDividerHeight }

    /// Coordinate space for the waveform column, so loop gestures report x in
    /// `0...waveformWidth` regardless of the column's offset. (`fileprivate` so
    /// the loop overlay leaf's handle gestures can name the same space.)
    fileprivate static let loopColumnSpace = "loopColumn"
    /// Coordinate space for the timeline ruler, so ruler gestures report x in
    /// `0...waveformWidth` just like the waveform column.
    private static let rulerSpace = "timelineRuler"
    /// Coordinate space of the vertical track ScrollView, for reading the rows'
    /// content offset when computing the renderable row range.
    private static let trackScrollSpace = "trackScroll"
    /// Rows beyond the visible viewport on each side that still rasterize, so
    /// small scrolls reveal already-rendered lanes.
    private static let renderableRowOverscan = 2

    /// Row indices intersecting the vertical viewport ± overscan. Rows are
    /// fixed-height, so this is pure math on the content offset.
    static func renderableRowRange(
        contentMinY: CGFloat,
        viewportHeight: CGFloat,
        rowStep: CGFloat
    ) -> ClosedRange<Int> {
        guard rowStep > 0, viewportHeight > 0 else { return 0...Int.max }
        let topVisible = -contentMinY
        let first = Int((topVisible / rowStep).rounded(.down)) - renderableRowOverscan
        let last = Int(((topVisible + viewportHeight) / rowStep).rounded(.down)) + renderableRowOverscan
        return max(first, 0)...max(last, 0)
    }
    /// Coordinate space for the section-level playhead overlay (grabber + line),
    /// so a grabber drag reports x across the whole section.
    private static let playheadSpace = "timelinePlayhead"
    /// Horizontal travel (points) that turns a click into a loop drag.
    private static let loopDragThreshold: CGFloat = 4

    init(
        controller: PlaybackController,
        appFileOpenRouter: AppFileOpenRouter? = nil,
        usesTemporaryDefaultWindowLayout: Bool = false
    ) {
        self.controller = controller
        self.appFileOpenRouter = appFileOpenRouter
        self.usesTemporaryDefaultWindowLayout = usesTemporaryDefaultWindowLayout
        _trackInfoColumnWidth = State(
            initialValue: Self.initialTrackInfoColumnWidth(
                usesTemporaryDefaultWindowLayout: usesTemporaryDefaultWindowLayout
            )
        )
        _openFileCommandState = StateObject(
            wrappedValue: OpenFileCommandState(
                loadStreamingURL: { urlString, commandState in
                    let taskID = UUID()
                    let task = Task {
                        let didLoad = await controller.loadStreamingTrack(
                            from: urlString,
                            statusHandler: { status in
                                await MainActor.run {
                                    commandState.streamingURLStatus = status
                                }
                            }
                        )
                        await MainActor.run {
                            commandState.finishStreamingURLTask(id: taskID)
                        }
                        if didLoad {
                            await MainActor.run {
                                commandState.dismissStreamingURLPrompt()
                            }
                        }
                    }
                    commandState.registerStreamingURLTask(task, id: taskID)
                },
                loadAppleMusicSelection: {
                    Task { await controller.loadSelectedLibraryTracks() }
                },
                loadFinderSelection: {
                    Task {
                        do {
                            let urls = try FinderSelectionLoader().selectedAudioFileURLs()
                            await controller.loadImportedFiles(urls)
                        } catch let error as PlaybackError {
                            controller.setPlaybackError(error)
                        } catch {
                            controller.setPlaybackError(.librarySelectionFailed("Could not read the Finder selection."))
                        }
                    }
                },
                showActiveTrackInFinder: {
                    guard let url = controller.session.activeTrack?.loadedTrack.url else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                },
                removeActiveTrack: {
                    guard let trackID = controller.session.activeTrackID else { return }
                    controller.removeTrack(trackID)
                },
                clearAllTracks: {
                    controller.clearTracks()
                }
            )
        )
    }

    private static func initialTrackInfoColumnWidth(
        usesTemporaryDefaultWindowLayout: Bool,
        defaults: UserDefaults = .standard
    ) -> Double {
        guard !usesTemporaryDefaultWindowLayout,
              let storedWidth = defaults.object(forKey: TakesWindowPolicy.trackInfoColumnWidthKey) as? NSNumber
        else {
            return TakesWindowPolicy.defaultTrackInfoColumnWidth
        }

        return storedWidth.doubleValue
    }

    private var trackInfoColumnWidthBinding: Binding<Double> {
        Binding(
            get: { trackInfoColumnWidth },
            set: { width in
                trackInfoColumnWidth = width
                guard !usesTemporaryDefaultWindowLayout else { return }
                UserDefaults.standard.set(width, forKey: TakesWindowPolicy.trackInfoColumnWidthKey)
            }
        )
    }

    var body: some View {
        inactiveAwareContent
            .frame(
                minWidth: TakesWindowPolicy.minimumContentWidth,
                minHeight: TakesWindowPolicy.rootViewMinimumHeight
            )
            // The transport bar doubles as the titlebar: lay the root view out
            // under the hidden titlebar so the bar starts at the window's top edge.
            .ignoresSafeArea(.container, edges: .top)
            .environment(\.transportAppearance, settings.transportAppearance)
            .background(WindowBackground().ignoresSafeArea())
            .background {
                MainWindowConfigurationView { window in
                    mainWindow = window
                    mainWindowIsKey = window.isKeyWindow
                    guard !didConfigureMainWindow else { return }
                    didConfigureMainWindow = true
                    TakesWindowPolicy.configureMainWindow(
                        window,
                        resetsLayoutForLaunch: usesTemporaryDefaultWindowLayout
                    )
                }
            }
            .overlay {
                if !mainWindowIsKey {
                    InactiveWindowInteractionShield(window: mainWindow)
                        .ignoresSafeArea()
                }
            }
            .alert(
                "Takes Error",
                isPresented: Binding(
                    get: { controller.playbackError != nil },
                    set: { isPresented in
                        if !isPresented {
                            controller.clearPlaybackError()
                        }
                    }
                )
            ) {
                Button("OK") {
                    controller.clearPlaybackError()
                }
            } message: {
                Text(controller.playbackError?.localizedDescription ?? "")
            }
            .onDrop(
                of: [UTType.fileURL.identifier],
                delegate: WindowFileImportDropDelegate(
                    isTargeted: $windowIsDropTargeted,
                    loadDroppedURLs: { loadDroppedURLs(from: $0) }
                )
            )
            .fileImporter(
                isPresented: $openFileCommandState.isImportingTracks,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
            }
            .sheet(isPresented: $openFileCommandState.isPromptingForStreamingURL) {
                streamingURLPrompt
            }
            .focusedSceneValue(\.openFileCommandState, openFileCommandState)
            .focusedSceneValue(
                \.mainWindowCommandState,
                MainWindowCommandState {
                    trackInfoColumnWidthBinding.wrappedValue = TakesWindowPolicy.defaultTrackInfoColumnWidth
                    guard let mainWindow else { return }
                    TakesWindowPolicy.resetMainWindowSize(mainWindow)
                }
            )
            .focusedSceneValue(\.canShowActiveTrackInFinder, controller.session.activeTrack != nil)
            .focusedSceneValue(\.canRemoveActiveTrack, controller.session.activeTrackID != nil)
            .focusedSceneValue(
                \.canUseGlobalMenuShortcuts,
                focusedOffsetTrackID == nil && !streamingURLFieldIsFocused
            )
            .focusedSceneValue(\.canClearTracks, controller.displayedTrackRowCount > 0)
            .onAppear {
                setupKeyMonitor()
                configureAppOpenRouter()
                waveformStore.sync(tracks: controller.session.tracks)
                NSApp.appearance = settings.appearanceTheme.nsAppearance
            }
            .onChange(of: settings.appearanceTheme) { _, theme in
                NSApp.appearance = theme.nsAppearance
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                guard notification.object as? NSWindow === mainWindow else { return }
                mainWindowIsKey = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
                guard notification.object as? NSWindow === mainWindow else { return }
                mainWindowIsKey = false
            }
            .onChange(of: controller.session.tracks) { _, tracks in
                waveformStore.sync(tracks: tracks)
            }
            .onChange(of: controller.displayedTrackRowCount) { previousTrackCount, trackCount in
                guard let mainWindow else { return }
                let shouldResize = TakesWindowPolicy.shouldAutoGrowWindow(
                    previousTrackRowCount: previousTrackCount,
                    newTrackRowCount: trackCount,
                    currentWindowHeight: mainWindow.frame.height
                ) || TakesWindowPolicy.shouldAutoShrinkWindow(
                    previousTrackRowCount: previousTrackCount,
                    newTrackRowCount: trackCount,
                    currentWindowHeight: mainWindow.frame.height
                )
                guard shouldResize else { return }
                TakesWindowPolicy.resizeMainWindow(mainWindow, displayingTrackRows: trackCount)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                controller.cleanupStreamingDownloads()
            }
            .onDisappear {
                keyMonitor?.stop()
                mouseMonitor?.stop()
            }
    }

    private var inactiveAwareContent: some View {
        contentStack
            .windowActivityAppearance(isActive: mainWindowIsKey)
            // Draw the import highlight after the inactive-window treatment so drag
            // hover stays vivid even while the window is in the background.
            .overlay {
                trackDropHighlightOverlay
            }
    }

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            transportBar
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            trackTimelineSection
                .frame(maxHeight: .infinity)
                // Recessed well: a faint dark scrim distinguishes the timeline from
                // the raised transport bar, giving the bar's drop shadow a lower
                // surface to land on.
                .background(Theme.timelineWellShade)
                // A soft shadow gradient hugging the top edge of the content makes the
                // timeline header read as recessed beneath the transport bar. Drawn as an
                // overlay (adaptive color, stronger in dark mode) rather than a hard line.
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [Theme.transportShadow, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 8)
                    .allowsHitTesting(false)
                }
        }
    }

    private var trackDropHighlightOverlay: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: TakesWindowPolicy.transportBarReservedHeight + TakesWindowPolicy.rootVerticalSpacing)
            trackAreaImportHighlight(isTargeted: windowIsDropTargeted)
        }
        .allowsHitTesting(false)
    }

    private var transportBar: some View {
        GeometryReader { proxy in
            let sideRegionWidth = max((proxy.size.width - transportReadoutWidth) / 2, 0)

            ZStack {
                HStack(spacing: 12) {
                    playButton
                    switchTrackButton
                }
                .frame(width: sideRegionWidth, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Pinned to the true window center, independent of the side clusters.
                // While playing the text comes from `playingReadoutText`,
                // which changes only when the displayed second rolls over;
                // while paused it derives from `transportPosition`, whose
                // writes are then only user seeks. (A TimelineView here kept
                // the window's display-link layout cycle running at full
                // refresh for the whole duration of playback.)
                DigitalTimeReadout(
                    style: settings.readoutStyle,
                    elapsed: controller.session.isPlaying
                        ? controller.playingReadoutText
                        : controller.session.transportPosition.formattedSignedTimestamp
                )
                .background {
                    GeometryReader { readoutProxy in
                        Color.clear.preference(
                            key: TransportReadoutWidthKey.self,
                            value: readoutProxy.size.width
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                // Purely informational, so let clicks fall through to the window
                // drag area — the readout shouldn't be a dead spot in the titlebar.
                .allowsHitTesting(false)

                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    repeatButton
                    blindListeningButton
                        .padding(.leading, 8)
                    Spacer(minLength: 8)
                    zoomControls
                }
                .padding(.trailing, 18)
                .frame(width: sideRegionWidth, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(height: DigitalTimeReadout.panelHeight)
        // Metrically 18 + 18, but shifted 2pt down: dead-center reads a touch
        // high in the bar, so the controls sit slightly low of true center.
        .padding(.top, 20)
        .padding(.bottom, 16)
        .onPreferenceChange(TransportReadoutWidthKey.self) { width in
            guard width > 0, abs(width - transportReadoutWidth) > 0.5 else { return }
            transportReadoutWidth = width
        }
        // Raised deck: a light wash lifts the bar off the shared window
        // material, pairing with `timelineWellShade` below the divider.
        // Purely decorative, so it must not intercept clicks — otherwise it
        // swallows the mouseDown before the WindowDragArea behind it can drag.
        .background(Theme.transportBarLift.allowsHitTesting(false))
        // The transport bar is the titlebar: any click on empty bar space
        // (not claimed by a control above) drags the window.
        .background(WindowDragArea())
        .componentDebugLabel("Transport Bar", enabled: settings.showsComponentDebugLabels)
    }

    private var playButton: some View {
        Button {
            controller.session.isPlaying ? controller.pause() : controller.play()
        } label: {
            Image(systemName: controller.session.isPlaying ? "pause.fill" : "play.fill")
        }
        .buttonStyle(CircleTransportButtonStyle(
            kind: .primary,
            diameter: DigitalTimeReadout.panelHeight,
            glyphSize: 22,
            pressedGlyphOffset: 1.5
        ))
        .disabled(!controller.session.isPlayable)
        .help(controller.session.isPlaying ? "Pause" : "Play")
        .accessibilityLabel(controller.session.isPlaying ? "Pause" : "Play")
        .componentDebugLabel("Play", enabled: settings.showsComponentDebugLabels)
    }

    private var switchTrackButton: some View {
        Button {
            if SwitchTrackModifierPolicy.selectsPreviousTrack(currentEventFlags: NSApp.currentEvent?.modifierFlags) {
                controller.selectPreviousTrack()
            } else {
                controller.selectNextTrack()
            }
        } label: {
            Image(systemName: "arrow.trianglehead.swap")
        }
        .buttonStyle(CircleTransportButtonStyle(kind: .secondary, diameter: 40, glyphSize: 15))
        .disabled(!controller.session.canSwitchPlayback)
        .help("Switch Track")
        .accessibilityLabel("Switch Track")
        .componentDebugLabel("Switch Track", enabled: settings.showsComponentDebugLabels)
    }

    private var zoomControls: some View {
        let contentSpan = controller.session.duration
        let enabled = controller.canZoomTimeline
        return HStack(spacing: 8) {
            Button {
                controller.stepZoom(zoomingIn: false)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .disabled(!enabled)
            .help("Zoom out")
            .accessibilityLabel("Zoom Out")

            Slider(
                value: Binding(
                    get: {
                        TimelineViewport.sliderValue(
                            visibleSpan: max(controller.visibleSpan, 0.001),
                            contentSpan: contentSpan
                        )
                    },
                    set: { value in
                        controller.zoomVisibleSpan(
                            to: TimelineViewport.visibleSpan(sliderValue: value, contentSpan: contentSpan)
                        )
                    }
                ),
                in: 0...1
            )
            .controlSize(.small)
            .frame(width: 56)
            .disabled(!enabled)
            .accessibilityLabel("Timeline Zoom")

            Button {
                controller.stepZoom(zoomingIn: true)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .disabled(!enabled)
            .help("Zoom in")
            .accessibilityLabel("Zoom In")
        }
        .componentDebugLabel("Zoom Controls", enabled: settings.showsComponentDebugLabels)
    }

    private var repeatButton: some View {
        let mode = controller.session.repeatMode
        return Button {
            controller.cycleRepeatMode()
        } label: {
            Image(systemName: Self.repeatSymbol(for: mode))
        }
        .buttonStyle(CircleTransportButtonStyle(kind: .secondary, isOn: mode != .off, diameter: 40, glyphSize: 15))
        .disabled(!controller.session.isPlayable)
        .help(Self.repeatHelp(for: mode))
        .accessibilityLabel("Repeat")
        .accessibilityValue(Self.repeatModeName(for: mode))
        .componentDebugLabel("Repeat", enabled: settings.showsComponentDebugLabels)
    }

    /// Header-sized companion to the import control: a native bordered button
    /// (matching "Remove All") whose glyph swaps for a progress indicator
    /// while an alignment run is in flight — an indeterminate spinner during
    /// the quick pass, a determinate ring during tempo analysis. The fixed
    /// label frame keeps the button from resizing during the swap.
    private var autoAlignButton: some View {
        Button {
            controller.autoAlignTracks()
        } label: {
            Group {
                if let progress = controller.alignmentProgress {
                    ZStack {
                        Circle()
                            .stroke(Theme.secondary.opacity(0.25), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: max(0.02, progress))
                            .stroke(Theme.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 13, height: 13)
                    .animation(.easeInOut(duration: 0.2), value: progress)
                } else if controller.isAligning {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .tint(Theme.secondary)
                } else if let outcome = controller.alignmentOutcome {
                    Image(systemName: outcome == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(outcome == .success ? Color.green : Color.red)
                } else {
                    Image(systemName: "arrow.right.and.line.vertical.and.arrow.left")
                }
            }
            .frame(width: 18, height: 16)
        }
        .controlSize(.regular)
        .disabled(!controller.session.canSwitchPlayback || controller.isAligning)
        .help("Auto-Align Tracks")
        .accessibilityLabel("Auto-Align Tracks")
        .accessibilityValue(controller.isAligning ? "Aligning" : "")
        .shadow(
            color: alignmentOutcomeGlowColor.opacity(alignmentOutcomePulse ? 0.9 : 0.0),
            radius: alignmentOutcomePulse ? 7 : 0
        )
        .onChange(of: controller.alignmentOutcome) { _, outcome in
            if outcome == nil {
                withAnimation(.easeOut(duration: 0.3)) { alignmentOutcomePulse = false }
            } else {
                alignmentOutcomePulse = false
                // Finite, matching the 2 s outcome flash (see `flashOutcome`):
                // a repeatForever here would keep a display link ticking
                // indefinitely even after the glow faded.
                withAnimation(.easeInOut(duration: 0.5).repeatCount(4, autoreverses: true)) {
                    alignmentOutcomePulse = true
                }
            }
        }
        .popover(isPresented: $showsAlignmentAttentionPopover, arrowEdge: .bottom) {
            alignmentOfferPopoverContent
        }
        .onChange(of: controller.tempoAnalysisOffer) { _, offer in
            // Surface the offer automatically when the quick pass leaves
            // unaligned tracks.
            if offer != nil { showsAlignmentAttentionPopover = true }
        }
        .onChange(of: showsAlignmentAttentionPopover) { _, isShowing in
            if !isShowing { controller.dismissAlignmentAttention() }
        }
        .componentDebugLabel("Auto-Align", enabled: settings.showsComponentDebugLabels)
    }

    private var alignmentOutcomeGlowColor: Color {
        switch controller.alignmentOutcome {
        case .success: return .green
        case .failure: return .red
        case nil: return .clear
        }
    }

    @ViewBuilder
    private var alignmentOfferPopoverContent: some View {
        if let offer = controller.tempoAnalysisOffer {
            VStack(alignment: .leading, spacing: 10) {
                Text("Couldn't Align Tracks")
                    .font(.headline)
                Text("No matching audio was found for:")
                    .fixedSize(horizontal: false, vertical: true)
                Text(offer.trackNames.joined(separator: "\n"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Deeper analysis can align audio across differing tempos, but it takes longer.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Analyze Further") {
                        controller.startTempoAnalysis()
                        showsAlignmentAttentionPopover = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 300)
        }
    }

    private var blindListeningButton: some View {
        let isOn = controller.session.isBlindListeningModeEnabled
        return Button {
            controller.toggleBlindListeningMode()
        } label: {
            if isOn {
                Image("BlindListening")
                    .offset(y: 2.5)
            } else {
                Image(systemName: "eye")
            }
        }
        .buttonStyle(CircleTransportButtonStyle(kind: .secondary, isOn: isOn, diameter: 40, glyphSize: 15))
        .help("Blind Listening Mode")
        .accessibilityLabel("Blind Listening Mode")
        .accessibilityValue(isOn ? "On" : "Off")
        .componentDebugLabel("Blind Listening Mode", enabled: settings.showsComponentDebugLabels)
    }

    private static func repeatSymbol(for mode: RepeatMode) -> String {
        switch mode {
        case .off, .one: return "repeat"
        case .switchAndRepeat: return "point.topright.arrow.triangle.backward.to.point.bottomleft.scurvepath.fill"
        }
    }

    private static func repeatModeName(for mode: RepeatMode) -> String {
        switch mode {
        case .off: return "Off"
        case .one: return "One"
        case .switchAndRepeat: return "Switch & Repeat"
        }
    }

    private static func repeatHelp(for mode: RepeatMode) -> String {
        "Repeat: \(repeatModeName(for: mode))"
    }

    // NOTE: `visibleStart` changes on every horizontal scroll event (and every
    // zoomed playback-follow step). Nothing evaluated as part of a view BODY in
    // this file may read it except the dedicated per-event leaves
    // (`LaneView`, `TimelineHeaderRulerView`, `TimelinePlayheadOverlayView`,
    // `LoopOverlayContentView`, `TimelineScrollOverlayLeaf`) — reading it in a
    // container body registers an Observation dependency that re-runs (and
    // re-layouts) the whole tree per event. Gesture/event closures may read it
    // freely; they aren't observation-tracked.
    private var visibleStart: TimeInterval {
        controller.visibleStart
    }

    private var visibleSpan: TimeInterval {
        max(controller.visibleSpan, 0.001)
    }

    private var trackRowHeight: CGFloat {
        TakesWindowPolicy.trackRowHeight
    }

    private func trackInfoWidth(sectionWidth: CGFloat) -> CGFloat {
        TakesWindowPolicy.clampedTrackInfoColumnWidth(CGFloat(trackInfoColumnWidth), sectionWidth: sectionWidth)
    }

    private var trackHeaderHeight: CGFloat {
        TakesWindowPolicy.trackTimelineHeaderHeight
    }

    private var timelineHeaderTargetMarkerCount: Int {
        7
    }

    /// Minimum on-screen spacing (points) between minor ticks before they are hidden.
    private var timelineHeaderMinorTickMinSpacing: Double {
        7
    }

    private var trackTimelineDividerHeight: CGFloat {
        TakesWindowPolicy.trackTimelineDividerHeight
    }

    private var trackTimelineHeight: CGFloat {
        TakesWindowPolicy.trackTimelineHeight(displayingTrackRows: controller.displayedTrackRowCount)
    }

    // Both helpers read the per-event visible window — call them from gesture
    // and event-monitor closures only, never from a view body (see the note on
    // `visibleStart`).
    private func globalTime(atX x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0 else { return visibleStart }
        let normalized = min(max(Double(x / width), 0), 1)
        return visibleStart + normalized * visibleSpan
    }

    private func xPosition(for globalTime: TimeInterval, width: CGFloat) -> CGFloat {
        CGFloat(
            TransportMapping.normalizedPosition(
                globalTime: globalTime,
                timelineStart: visibleStart,
                timelineEnd: controller.visibleEnd
            )
        ) * width
    }

    private var trackTimelineSection: some View {
        GeometryReader { proxy in
            let infoWidth = trackInfoWidth(sectionWidth: proxy.size.width)
            let waveformWidth = max(proxy.size.width - infoWidth, 1)
            let displayedTrackRowCount = controller.displayedTrackRowCount
            VStack(alignment: .leading, spacing: 0) {
                if displayedTrackRowCount == 0 {
                    // The empty state owns the whole section — no header, no
                    // column split — one centered drop/click target.
                    trackAreaEmptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    trackTimelineHeader(infoWidth: infoWidth, waveformWidth: waveformWidth)
                        .frame(width: proxy.size.width, height: trackHeaderHeight)
                    Divider()

                    ScrollView(.vertical) {
                        ZStack(alignment: .topLeading) {
                            // Shared, zoom-varying lane window (window bounds +
                            // ticks), computed once for all lanes and pushed to
                            // the store the lane leaves observe. It is
                            // deliberately NOT threaded through the rows: doing
                            // so would flip every row's `==` on each zoom step
                            // and re-lay-out the VStack (WP-6). `wideWidth` is
                            // geometry (fixed on zoom) and DOES ride the rows.
                            let laneViewport = makeLaneViewport(waveformWidth: waveformWidth)
                            let wideWidth = waveformWidth * 2
                            VStack(spacing: 0) {
                                ForEach(Array(controller.session.tracks.enumerated()), id: \.element.id) { index, sessionTrack in
                                    let isLifted = reorderDraggingID == sessionTrack.id
                                        || reorderRevealingID == sessionTrack.id
                                    trackRowView(
                                        index: index,
                                        sessionTrack: sessionTrack,
                                        infoWidth: infoWidth,
                                        wideWidth: wideWidth
                                    )
                                        .equatable()
                                        // The dragged row's floating preview stands in
                                        // for it; its slot stays reserved as the gap the
                                        // other rows slide around. It stays hidden one
                                        // tick past the commit (`reorderRevealingID`),
                                        // then fades in at its landed position — the
                                        // fade itself is applied by `withAnimation` in
                                        // the drag-ended handler.
                                        .opacity(isLifted ? 0 : 1)
                                        .offset(y: reorderRowOffset(index: index))
                                        .animation(.snappy(duration: 0.26), value: reorderGapGeneration)
                                    if index < displayedTrackRowCount - 1 {
                                        Divider()
                                            .frame(height: trackTimelineDividerHeight)
                                            .offset(y: reorderRowOffset(index: index))
                                            .animation(.snappy(duration: 0.26), value: reorderGapGeneration)
                                    }
                                }
                            }
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(Theme.hairline)
                                    .frame(height: trackTimelineDividerHeight)
                                    .allowsHitTesting(false)
                            }
                            // Publish the zoom-varying window to the store the
                            // lane leaves observe. The container body re-running
                            // per zoom step is fine (it's cheap and produces
                            // `==`-stable rows); this hands the new window to the
                            // leaves without touching row layout.
                            .onChange(of: laneViewport, initial: true) { _, newViewport in
                                if laneViewportStore.viewport != newViewport {
                                    laneViewportStore.viewport = newViewport
                                }
                            }

                            if controller.session.isPlayable {
                                loopSelectionOverlay(infoWidth: infoWidth, waveformWidth: waveformWidth)
                            }
                        }
                        .frame(width: proxy.size.width)
                        // Vertical visibility culling: track which row indices
                        // intersect the scroll viewport (± overscan) so
                        // off-screen lanes don't rasterize. The GeometryReader
                        // body is the only thing re-evaluated per vertical
                        // scroll event (a Color.clear — the 3c rule holds); the
                        // @State write is equality-guarded and the range is
                        // row-quantized, so the container re-runs only when a
                        // row actually enters or leaves the overscan band.
                        .background(
                            GeometryReader { rowsGeometry in
                                let range = Self.renderableRowRange(
                                    contentMinY: rowsGeometry.frame(in: .named(Self.trackScrollSpace)).minY,
                                    viewportHeight: max(proxy.size.height - trackHeaderHeight, 0),
                                    rowStep: reorderRowStep
                                )
                                Color.clear
                                    .onChange(of: range, initial: true) { _, newRange in
                                        if renderableRows != newRange {
                                            renderableRows = newRange
                                        }
                                    }
                            }
                        )
                        // One drop target spanning the rows, taking reorders and
                        // external file drops. For reorders it opens the gap as the
                        // pointer moves and commits on drop. A single target (rather
                        // than per-row) keeps the target slot stable while the rows
                        // shift, and lets the enclosing NSScrollView auto-scroll.
                        .onDrop(
                            of: TrackRowDropTarget.acceptedContentTypeIdentifiers,
                            delegate: TrackListDropDelegate(
                                controller: controller,
                                rowStep: reorderRowStep,
                                draggingID: $reorderDraggingID,
                                targetIndex: $reorderTargetIndex,
                                gapGeneration: $reorderGapGeneration,
                                revealingID: $reorderRevealingID,
                                isImportTargeted: $windowIsDropTargeted,
                                loadDroppedURLs: { loadDroppedURLs(from: $0) }
                            )
                        )
                    }
                    .coordinateSpace(name: Self.trackScrollSpace)
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .overlay(alignment: .topLeading) {
                if !controller.session.tracks.isEmpty {
                    TimelineScrollOverlayLeaf(controller: controller)
                        .frame(width: waveformWidth, height: proxy.size.height)
                        .offset(x: infoWidth)
                }
            }
            .overlay(alignment: .topLeading) {
                // Frozen-column edge: one continuous hairline at the info/waveform
                // boundary, running the full height so the header's control|ruler
                // border and the rows' info|waveform border are the same line.
                // With no tracks the whole section is the empty state, so there
                // is no column boundary to draw.
                if displayedTrackRowCount > 0 {
                    Rectangle()
                        .fill(Theme.frozenColumnEdge)
                        .frame(width: 1, height: proxy.size.height)
                        .offset(x: infoWidth)
                        .allowsHitTesting(false)
                }
            }
            // Playhead drawn above the visible frozen-column and header/row
            // dividers; the transparent resize handle is installed after it so
            // its cursor and drag region still win at the column boundary.
            .overlay(alignment: .topLeading) {
                timelinePlayheadOverlay(sectionHeight: proxy.size.height, infoWidth: infoWidth, waveformWidth: waveformWidth)
            }
            .overlay(alignment: .topLeading) {
                if displayedTrackRowCount > 0 {
                    trackInfoColumnResizeHandle(
                        sectionWidth: proxy.size.width,
                        sectionHeight: proxy.size.height,
                        infoWidth: infoWidth
                    )
                }
            }
            .coordinateSpace(name: Self.playheadSpace)
            // Keep the mouse-monitor cursor manager's picture of the timeline
            // geometry current (window resize, column resize, scrolling).
            .onChange(
                of: TimelineCursorGeometry(
                    sectionFrame: proxy.frame(in: .global),
                    infoWidth: infoWidth,
                    waveformWidth: waveformWidth
                ),
                initial: true
            ) { _, geometry in
                timelineCursorGeometry = geometry
            }
        }
    }

    /// The drop-landing highlight for the track section (populated list and
    /// empty state alike): a brand wash with a soft glow bleeding in from the
    /// edges — a blurred edge band rather than a solid border, so there's no
    /// crisp line whose corners could visibly deviate from the window's corner
    /// curve (the window mask itself rounds the bottom corners). Kept mounted
    /// and driven by opacity so it fades smoothly as drags enter and leave the
    /// window.
    private func trackAreaImportHighlight(isTargeted: Bool) -> some View {
        Rectangle()
            .fill(Theme.primary.opacity(0.11))
            .overlay(
                Rectangle()
                    .strokeBorder(Theme.primary.opacity(0.65), lineWidth: 4)
                    .blur(radius: 5)
            )
            .clipped()
            .opacity(isTargeted ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: isTargeted)
            .allowsHitTesting(false)
    }

    /// Vertical offset for the row at `index` so a gap opens at the drag's target
    /// slot while the dragged row's own slot collapses into it.
    private func reorderRowOffset(index: Int) -> CGFloat {
        guard let draggingID = reorderDraggingID,
              let sourceIndex = controller.session.tracks.firstIndex(where: { $0.id == draggingID }),
              let targetIndex = reorderTargetIndex
        else {
            return 0
        }
        return TrackReorderGeometry.rowOffset(
            index: index,
            sourceIndex: sourceIndex,
            targetIndex: targetIndex,
            rowStep: reorderRowStep
        )
    }

    private func trackInfoColumnResizeHandle(sectionWidth: CGFloat, sectionHeight: CGFloat, infoWidth: CGFloat) -> some View {
        let hitWidth: CGFloat = 12
        return TrackInfoColumnResizeHandleView(
            sectionWidth: sectionWidth,
            columnWidth: trackInfoColumnWidthBinding
        )
            .frame(width: hitWidth, height: sectionHeight)
            .contentShape(Rectangle())
            .offset(x: infoWidth - hitWidth / 2)
            .accessibilityLabel("Resize track info column")
    }

    private func trackTimelineHeader(infoWidth: CGFloat, waveformWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                ImportActionSplitButton(
                    dropdownItems: ImportActionMenuItem.dropdownItems,
                    performAction: performImportAction(_:)
                )
                .frame(width: ImportActionControlMetrics.controlWidth, height: ImportActionControlMetrics.controlHeight)
                autoAlignButton
            }
            .padding(.leading, 8)
            // Center the button cluster in the taller header rather than pinning it up top.
            .frame(width: infoWidth, height: trackHeaderHeight, alignment: .leading)
            .overlay(alignment: .trailing) {
                Button("Remove All") {
                    controller.clearTracks()
                }
                .controlSize(.regular)
                .disabled(controller.displayedTrackRowCount == 0)
                .help("Remove all tracks")
                .padding(.trailing, 8)
            }

            TimelineHeaderRulerView(
                controller: controller,
                width: waveformWidth,
                targetMarkerCount: timelineHeaderTargetMarkerCount,
                minorTickMinSpacing: timelineHeaderMinorTickMinSpacing,
                headerHeight: trackHeaderHeight
            )
                .frame(maxWidth: .infinity)
                // Dragging anywhere on the ruler moves the playhead: the
                // visual follows the pointer and the transport seeks once on
                // mouse-up (no live scrubbing mid-drag). Loop selection is a
                // lane-only gesture.
                .contentShape(Rectangle())
                .gesture(playheadScrubGesture(waveformWidth: waveformWidth))
                .coordinateSpace(name: Self.rulerSpace)
                .componentDebugLabel("Timeline Ruler", enabled: settings.showsComponentDebugLabels, color: .orange)
        }
        .componentDebugLabel("Timeline Header", enabled: settings.showsComponentDebugLabels)
    }

    /// The full playhead — the grabber seated on the ruler notches plus the line
    /// running down over the lanes — drawn as one overlay on top of the whole
    /// section so it sits ABOVE the frozen-column and header/row dividers.
    ///
    /// Visuals only: the layers are moved by a single Core Animation linear
    /// tween per transport anchor event (play, pause, seek, loop wrap, zoom,
    /// scroll, resize) — see `TimelinePlayheadVisual` — so steady playback
    /// does no per-frame main-thread work at all. Interaction lives on the
    /// ruler (`playheadScrubGesture`); cursor feedback lives in the central
    /// mouse-monitor cursor manager.
    ///
    /// While a ruler scrub is in flight (`playheadDragX != nil`) the playhead
    /// parks at the pointer as a preview; the transport itself doesn't move
    /// (and audio keeps playing from the old position) until mouse-up.
    @ViewBuilder
    private func timelinePlayheadOverlay(sectionHeight: CGFloat, infoWidth: CGFloat, waveformWidth: CGFloat) -> some View {
        if controller.session.isPlayable {
            // The x-positioning lives in a leaf that alone reads the per-event
            // transport/window state, so a scroll or anchor event re-runs only
            // the leaf (one representable update), not this section body.
            TimelinePlayheadOverlayView(
                controller: controller,
                playheadDragX: playheadDragX,
                infoWidth: infoWidth,
                sectionHeight: sectionHeight,
                waveformWidth: waveformWidth,
                seatBottom: trackHeaderHeight + trackTimelineDividerHeight,
                laneAreaHeight: trackTimelineHeight
            )
            // Confine (and clip, via the layer view's masksToBounds) the
            // playhead to the waveform column so an off-viewport position
            // never draws over the track-info column.
            .frame(width: waveformWidth, height: sectionHeight, alignment: .topLeading)
            .offset(x: infoWidth)
            .allowsHitTesting(false)
        }
    }

    static let playheadHandleWidth: CGFloat = 14
    static let playheadHandleHeight: CGFloat = 16
    /// Comfortable grab target a bit wider than the visible grabber.
    private static let playheadHitWidth: CGFloat = 22

    /// Drag anywhere on the ruler to move the playhead. The playhead visual
    /// follows the pointer as a preview; the seek happens once on mouse-up,
    /// so nothing scrubs live mid-drag. A plain click behaves like the lane
    /// click: deselect the loop when the click lands outside it, then seek.
    private func playheadScrubGesture(waveformWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.rulerSpace))
            .onChanged { value in
                if playheadDragX == nil {
                    NSCursor.closedHand.set()
                }
                playheadDragX = min(max(value.location.x, 0), waveformWidth)
            }
            .onEnded { value in
                playheadDragX = nil
                let x = min(max(value.location.x, 0), waveformWidth)
                let time = globalTime(atX: x, width: waveformWidth)
                if let loop = controller.session.loopRegion, time < loop.start || time > loop.end {
                    controller.deselectLoop()
                }
                controller.seek(to: time)
                // The playhead now sits under the pointer, so the grab cursor
                // is the right resting state. Record the shape in the central
                // cursor manager too, so it knows a non-standard cursor is up
                // and resets it on the next pointer move if the pointer isn't
                // actually on the grabber (e.g. mouse-up higher on the ruler).
                timelineCursorShape = .playheadGrab
                NSCursor.openHand.set()
            }
    }

    /// Build the value for one equatable track row. All observable reads
    /// (`controller.session`, `waveformStore`, `settings`) happen here in the
    /// container so the row itself stays a pure value: a horizontal scroll or a
    /// reorder gap move re-runs this cheap builder + an `==` check per row, but
    /// never re-runs a row's body unless one of its compared inputs changed.
    private func trackRowView(
        index: Int,
        sessionTrack: SessionTrack,
        infoWidth: CGFloat,
        wideWidth: CGFloat
    ) -> TrackRowView {
        let isActive = controller.session.activeTrackID == sessionTrack.id
        let isBlind = controller.session.isBlindListeningModeEnabled
        return TrackRowView(
            index: index,
            sessionTrack: sessionTrack,
            // Blind listening feeds the lane a nil waveform so progress can't
            // leak identity through redraw timing (an invariant).
            waveform: isBlind ? nil : waveformStore.waveform(for: sessionTrack.id),
            isActive: isActive,
            isBlind: isBlind,
            isRenderable: renderableRows.contains(index),
            isOffsetFocused: focusedOffsetTrackID == sessionTrack.id,
            infoWidth: infoWidth,
            rowHeight: trackRowHeight,
            wideWidth: wideWidth,
            offsetConfiguration: settings.offsetConfiguration,
            indexBadgeAppearance: settings.indexBadgeAppearance,
            showsDebugLabel: settings.showsComponentDebugLabels,
            controller: controller,
            viewportStore: laneViewportStore,
            hoverStore: hoverStore,
            onSelect: { controller.selectActiveTrack(sessionTrack.id) },
            onRemove: { controller.removeTrack(sessionTrack.id) },
            onSetOffsetMs: { controller.setOffset(sessionTrack.id, seconds: Double($0) / 1000) },
            onOffsetFocusChange: { focused in
                if focused {
                    focusedOffsetTrackID = sessionTrack.id
                } else if focusedOffsetTrackID == sessionTrack.id {
                    focusedOffsetTrackID = nil
                }
            },
            onHover: { inside in
                // Suppress the hover trash button while a reorder drag is in
                // flight: the drag drives the pointer across rows, so their
                // hover states would otherwise flash the button on each one.
                guard reorderDraggingID == nil else { return }
                hoverStore.hoveredID = inside
                    ? sessionTrack.id
                    : (hoverStore.hoveredID == sessionTrack.id ? nil : hoverStore.hoveredID)
            },
            onDragBegan: {
                reorderDraggingID = sessionTrack.id
                // Clear any hover so no row shows its trash button mid-drag.
                hoverStore.hoveredID = nil
            },
            onDragEnded: {
                // A committed reorder has already moved the row into the reveal
                // phase via the drop delegate; a cancelled or copied-out drag
                // reveals in place the same way.
                if let draggingID = reorderDraggingID {
                    reorderRevealingID = draggingID
                    reorderDraggingID = nil
                }
                reorderTargetIndex = nil
                // Next tick: the (possibly reordered) layout has landed
                // unanimated, so only the opacity animates — a fade-in at the
                // row's final position, timed to the system's fade-out of the
                // drag image.
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.24)) {
                        reorderRevealingID = nil
                    }
                }
            },
            makeDragImage: {
                reorderCardDragImage(index: index, sessionTrack: sessionTrack, width: infoWidth)
            }
        )
    }

    /// The floating card shown under the pointer while a track is dragged to
    /// reorder — a compact, lifted rendition of the track's identity (index badge,
    /// name, metadata). Sized to the info column so it reads as the row itself
    /// lifting off the surface.
    private func reorderPreviewCard(index: Int, sessionTrack: SessionTrack, width: CGFloat) -> some View {
        let track = sessionTrack.loadedTrack
        let isBlind = controller.session.isBlindListeningModeEnabled
        let title = isBlind ? "Track \(index + 1)" : track.displayName
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            TrackIndexBadgeView(
                index: index,
                isActive: controller.session.activeTrackID == sessionTrack.id,
                appearance: settings.indexBadgeAppearance
            )
                // Same 1pt optical nudge as the in-row badge: baseline-aligned to
                // the filename, but the fixed badge frame reads a touch low.
                .offset(y: -1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !isBlind {
                    Text(track.metadataSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // Width matches the info column so the card reads as the row's identity
        // lifting off the surface; height hugs the badge/name/metadata content so
        // the card stays a compact pill rather than an empty row-height slab.
        .frame(width: width - 12, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.reorderCardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 1)
                )
        )
        // A pronounced shadow sells the lift; heavier in dark mode where a soft
        // shadow would otherwise vanish against the dark surface.
        .shadow(color: Theme.reorderCardShadow, radius: 18, y: 9)
        // Rendered to an NSImage for the drag; pad transparently so the shadow
        // (radius 18, offset down 9) has room within the image bounds instead of
        // being clipped. Extra room below for the downward offset.
        .padding(EdgeInsets(top: 24, leading: 24, bottom: 34, trailing: 24))
    }

    /// Renders the reorder preview card to an `NSImage` for the AppKit drag session.
    /// `ImageRenderer` renders in light appearance by default, so the app's actual
    /// appearance is threaded in explicitly — both as the SwiftUI color scheme and
    /// as the drawing appearance for the dynamic `NSColor`-backed theme colors —
    /// or the card comes out light in dark mode.
    private func reorderCardDragImage(index: Int, sessionTrack: SessionTrack, width: CGFloat) -> NSImage? {
        let appearance = NSApp.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let renderer = ImageRenderer(
            content: reorderPreviewCard(index: index, sessionTrack: sessionTrack, width: width)
                .environmentObject(settings)
                .environment(\.colorScheme, isDark ? .dark : .light)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        var image: NSImage?
        appearance.performAsCurrentDrawingAppearance {
            image = renderer.nsImage
        }
        return image
    }

    /// Kaleidoscope-style empty state: one centered composition — a soft
    /// circular badge holding a waveform glyph, a single line of text below —
    /// owning the whole track section with no header or column split. Hovering
    /// darkens the badge and swaps the drag prompt for a click prompt; clicking
    /// anywhere opens the file dialog. Dragging files over any part of the
    /// window tints the badge and glyph with the indigo brand color, with the
    /// area wash and edge glow supplied by the shared track-area import
    /// highlight (drops are handled by the window-wide `onDrop`).
    private var trackAreaEmptyState: some View {
        let isTargeted = windowIsDropTargeted
        return VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(badgeFill(isTargeted: isTargeted))
                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isTargeted ? AnyShapeStyle(Theme.primary) : AnyShapeStyle(.secondary))
            }
            .frame(width: 52, height: 52)

            // Both prompts stay mounted and crossfade so the swap doesn't
            // reflow the layout.
            ZStack {
                Text("Drag Files Here to Compare")
                    .opacity(emptyStateIsHovered && !isTargeted ? 0 : 1)
                Text("Click Here to Compare")
                    .opacity(emptyStateIsHovered && !isTargeted ? 1 : 0)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The area wash and edge glow come from the shared track-area import
        // highlight (drawn at the root); here only the badge and glyph tint.
        .animation(.easeInOut(duration: 0.15), value: emptyStateIsHovered)
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
        .contentShape(Rectangle())
        .onHover { inside in
            emptyStateIsHovered = inside
        }
        .onTapGesture {
            performImportAction(.open)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Add audio files to compare")
        .accessibilityAddTraits(.isButton)
    }

    private func badgeFill(isTargeted: Bool) -> AnyShapeStyle {
        if isTargeted {
            return AnyShapeStyle(Theme.primary.opacity(0.16))
        }
        if emptyStateIsHovered {
            return AnyShapeStyle(.tertiary.opacity(0.55))
        }
        return AnyShapeStyle(.quaternary.opacity(0.6))
    }

    private var streamingURLPrompt: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open Streaming URL")
                .font(.headline)

            TextField("https://...", text: $openFileCommandState.streamingURLText)
                .textFieldStyle(.roundedBorder)
                .focused($streamingURLFieldIsFocused)
                .disabled(openFileCommandState.streamingURLStatus.isWorking)
                .onSubmit {
                    openFileCommandState.submitStreamingURL()
                }

            if let message = openFileCommandState.streamingURLStatus.message {
                if openFileCommandState.streamingURLStatus.isFailed {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        streamingURLPromptStatusText(message)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                            .alignmentGuide(.firstTextBaseline) { dimensions in
                                dimensions[VerticalAlignment.center] + 4
                            }
                        streamingURLPromptStatusText(message)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Supports Apple Music, Spotify, YouTube, and YouTube Music URLs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    openFileCommandState.dismissStreamingURLPrompt()
                }
                Button("Open") {
                    openFileCommandState.submitStreamingURL()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    openFileCommandState.streamingURLStatus.isWorking
                        || openFileCommandState.streamingURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            streamingURLFieldIsFocused = true
        }
    }

    private func streamingURLPromptStatusText(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(openFileCommandState.streamingURLStatus.isFailed ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Geometry for the windowed waveform lanes. Each lane draws a
    /// 2×-viewport window anchored to a half-viewport grid in *absolute*
    /// timeline time; a leaf slides it with a plain `offset` as the timeline
    /// scrolls (`shiftX`, kept out of here) and rasterizes only when the window
    /// crosses a grid boundary.
    ///
    /// Crucially, EVERY field here varies with zoom (the quantum is
    /// `visibleSpan/2`, and the ticks are mapped through the span). So these
    /// must NOT be `TrackRowView` equatable inputs — if they were, a zoom step
    /// would flip every row's `==` and force the non-lazy VStack to re-lay-out
    /// all rows (the WP-6 bug). Instead the viewport lives in a shared
    /// `LaneViewportStore` that only the lane leaf observes, so a zoom step
    /// re-runs the N fixed-frame lane leaves, never the row bodies.
    struct LaneViewport: Equatable {
        var windowStart: TimeInterval
        var windowSpan: TimeInterval
        var majorTickXs: [CGFloat]
        var zeroTickX: CGFloat

        static let empty = LaneViewport(windowStart: 0, windowSpan: 0, majorTickXs: [], zeroTickX: 0)
    }

    private func makeLaneViewport(waveformWidth: CGFloat) -> LaneViewport {
        let span = visibleSpan
        // The grid-quantized window start is STORED on the controller (updated
        // with an equality guard whenever the visible window moves) rather than
        // derived from `visibleStart` here: reading raw `visibleStart` in the
        // container body would register a per-scroll-event Observation
        // dependency and re-run the whole track list per event.
        let windowStart = controller.laneWindowStart
        let windowSpan = span * 2
        let windowEnd = windowStart + windowSpan
        // Ticks are mapped over the drawn window width (2× the visible lane
        // width) so they line up with the lane frame; `wideWidth` itself is
        // geometry (fixed on zoom) and travels to the lane as a row input.
        let wideWidth = waveformWidth * 2
        func windowX(_ time: TimeInterval) -> CGFloat {
            CGFloat((time - windowStart) / windowSpan) * wideWidth
        }

        // Same tick computation the header draws, over the window's (clamped)
        // range, with the marker budget scaled by the clamped-span ratio so
        // the chosen interval matches the header's and the faint lane guides
        // stay aligned with the labeled ticks.
        let clampedStart = max(windowStart, controller.session.timelineStart)
        let clampedEnd = min(windowEnd, controller.session.timelineEnd)
        let targetCount = max(1, Int((
            Double(timelineHeaderTargetMarkerCount) * (clampedEnd - clampedStart) / span
        ).rounded()))
        let ruler = TimelineHeaderMarker.ruler(
            timelineStart: clampedStart,
            timelineEnd: clampedEnd,
            targetMarkerCount: targetCount,
            leadingMajorTicks: 1
        )

        return LaneViewport(
            windowStart: windowStart,
            windowSpan: windowSpan,
            majorTickXs: ruler.majorTicks.map { windowX($0.time) },
            zeroTickX: windowX(0)
        )
    }

    // MARK: - Loop selection

    /// The interaction layer, selection rectangle, and resize handles for the
    /// loop, spanning all lanes across the waveform column. Clipped to the column
    /// so an off-screen loop never spills into the track-info column.
    private func loopSelectionOverlay(infoWidth: CGFloat, waveformWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // Drag to select a loop; click to seek (and deselect if outside the
            // loop). The gesture surface carries no per-event body reads — the
            // closures' visible-window reads aren't observation-tracked.
            Color.clear
                .contentShape(Rectangle())
                .gesture(loopSelectionGesture(waveformWidth: waveformWidth, in: Self.loopColumnSpace))

            // Selection rectangle + resize handles. Their x-positioning depends
            // on the per-scroll-event visible window, so it lives in a leaf that
            // alone reads it; the gesture LOGIC stays here in closures.
            LoopOverlayContentView(
                controller: controller,
                waveformWidth: waveformWidth,
                height: trackTimelineHeight,
                draftRange: loopDraft.map { min($0.start, $0.current)...max($0.start, $0.current) },
                displayedLoop: loopDraft == nil ? displayedLoopRegion : nil,
                onHandleChanged: { isStart, value in
                    // Don't start resizing on a jitter-sized movement, so a
                    // plain click stays a click (handled below).
                    let dx = abs(value.location.x - value.startLocation.x)
                    guard loopResizeDraft != nil || dx > Self.loopDragThreshold else { return }
                    let time = globalTime(atX: value.location.x, width: waveformWidth)
                    isStart ? updateLoopResizeDraft(start: time) : updateLoopResizeDraft(end: time)
                },
                onHandleEnded: { isStart, value in
                    if loopResizeDraft == nil {
                        // A plain click on the handle strip: the strip sits
                        // over the lane's own gesture and would otherwise
                        // swallow it — run the same click-to-seek (and
                        // deselect-if-outside) behaviour as the lane.
                        handleLoopSelectionEnded(value: value, waveformWidth: waveformWidth)
                    } else {
                        let time = globalTime(atX: value.location.x, width: waveformWidth)
                        isStart ? commitLoopResize(start: time) : commitLoopResize(end: time)
                    }
                }
            )
        }
        .frame(width: waveformWidth, height: trackTimelineHeight, alignment: .topLeading)
        .clipped()
        .coordinateSpace(name: Self.loopColumnSpace)
        .offset(x: infoWidth)
    }

    private var displayedLoopRegion: LoopRegion? {
        loopResizeDraft ?? controller.session.loopRegion
    }

    private func resizedLoopRegion(start: TimeInterval? = nil, end: TimeInterval? = nil) -> LoopRegion? {
        guard let current = displayedLoopRegion else { return nil }
        return LoopRegion.normalized(
            start: start ?? current.start,
            end: end ?? current.end,
            timelineStart: controller.session.timelineStart,
            timelineEnd: controller.session.timelineEnd
        )
    }

    private func updateLoopResizeDraft(start: TimeInterval? = nil, end: TimeInterval? = nil) {
        guard let region = resizedLoopRegion(start: start, end: end) else { return }
        loopResizeDraft = region
    }

    private func commitLoopResize(start: TimeInterval? = nil, end: TimeInterval? = nil) {
        guard let region = resizedLoopRegion(start: start, end: end) else {
            loopResizeDraft = nil
            return
        }
        loopResizeDraft = nil
        controller.resizeLoop(start: region.start, end: region.end)
    }

    /// Click-to-seek / drag-to-select-loop behaviour, shared by the waveform column and the
    /// timeline ruler. Both map their local x (0...`waveformWidth`) to time the same way, so the
    /// same gesture drives both. `space` is the coordinate space the caller attaches it in.
    private func loopSelectionGesture(
        waveformWidth: CGFloat,
        in space: String
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { value in
                handleLoopSelectionChanged(value: value, waveformWidth: waveformWidth)
            }
            .onEnded { value in
                handleLoopSelectionEnded(value: value, waveformWidth: waveformWidth)
            }
    }

    private func handleLoopSelectionChanged(value: DragGesture.Value, waveformWidth: CGFloat) {
        let dx = abs(value.location.x - value.startLocation.x)
        if loopDraft != nil || dx > Self.loopDragThreshold {
            loopDraft = LoopDraft(
                start: globalTime(atX: value.startLocation.x, width: waveformWidth),
                current: globalTime(atX: value.location.x, width: waveformWidth)
            )
        }
    }

    private func handleLoopSelectionEnded(value: DragGesture.Value, waveformWidth: CGFloat) {
        if loopDraft != nil {
            loopDraft = nil
            if let region = LoopRegion.normalized(
                start: globalTime(atX: value.startLocation.x, width: waveformWidth),
                end: globalTime(atX: value.location.x, width: waveformWidth),
                timelineStart: controller.session.timelineStart,
                timelineEnd: controller.session.timelineEnd
            ) {
                controller.beginLoop(region)
            }
        } else {
            let t = globalTime(atX: value.location.x, width: waveformWidth)
            let shiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                || NSEvent.modifierFlags.contains(.shift)
            if shiftHeld {
                // Shift-click: select the range between the playhead and the click.
                if let region = LoopRegion.normalized(
                    start: controller.displayTransportPosition(),
                    end: t,
                    timelineStart: controller.session.timelineStart,
                    timelineEnd: controller.session.timelineEnd
                ) {
                    controller.beginLoop(region)
                }
            } else {
                // A plain click: seek, deselecting first if it lands outside the loop.
                if let loop = controller.session.loopRegion, t < loop.start || t > loop.end {
                    controller.deselectLoop()
                }
                controller.seek(to: t)
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        openFileCommandState.dismissOpenDialog()

        switch result {
        case let .success(urls):
            Task {
                await controller.loadImportedFiles(urls)
            }
        case .failure:
            break
        }
    }

    private func performImportAction(_ item: ImportActionMenuItem) {
        switch item {
        case .open:
            openFileCommandState.presentOpenDialog()
        case .streamingURL:
            openFileCommandState.presentStreamingURLPrompt()
        case .finderSelection:
            openFileCommandState.openFinderSelection()
        case .musicSelection:
            openFileCommandState.openAppleMusicSelection()
        }
    }

    private func backgroundStyle(for highlight: TrackDropHighlight) -> some ShapeStyle {
        if highlight == .dropTarget {
            return AnyShapeStyle(Theme.primary.opacity(0.16))
        }
        return AnyShapeStyle(Color.clear)
    }

    private func setupKeyMonitor() {
        let monitor = KeyMonitor { event in
            if !GlobalShortcutFocusPolicy.shouldHandleGlobalShortcut(firstResponder: NSApp.keyWindow?.firstResponder) {
                return false
            }

            if let hotkey = TrackNumberHotkey.hotkey(forKeyCode: event.keyCode, modifierFlags: event.modifierFlags),
               controller.canSelectTrackForHotkey(hotkey) {
                controller.selectTrackForHotkey(hotkey)
                return true
            }

            if let direction = TrackSwitchArrowHotkey.direction(forKeyCode: event.keyCode, modifierFlags: event.modifierFlags),
               controller.session.canSwitchPlayback {
                switch direction {
                case .previous:
                    controller.selectPreviousTrack()
                case .next:
                    controller.selectNextTrack()
                }
                return true
            }

            switch event.keyCode {
            case 49:
                guard !event.modifierFlags.contains(.command),
                      !event.modifierFlags.contains(.control),
                      !event.modifierFlags.contains(.option),
                      controller.session.isPlayable
                else {
                    return false
                }
                controller.session.isPlaying ? controller.pause() : controller.play()
                return true
            case 123:
                if event.modifierFlags.contains(.command) {
                    controller.seek(to: controller.session.timelineStart)
                    return true
                }
                controller.skip(by: event.modifierFlags.contains(.shift) ? -10 : -1)
                return true
            case 124:
                if event.modifierFlags.contains(.command) {
                    controller.seek(to: controller.session.timelineEnd)
                    return true
                }
                controller.skip(by: event.modifierFlags.contains(.shift) ? 10 : 1)
                return true
            case 7:
                guard !event.modifierFlags.contains(.command),
                      !event.modifierFlags.contains(.control),
                      !event.modifierFlags.contains(.option)
                else {
                    return false
                }
                if event.modifierFlags.contains(.shift) {
                    controller.selectPreviousTrack()
                } else {
                    controller.selectNextTrack()
                }
                return true
            default:
                return false
            }
        }
        monitor.start()
        keyMonitor = monitor

        let clickMonitor = MouseMonitor { event in
            guard let window = event.window else { return }
            let locationInWindow = event.locationInWindow

            if event.type == .mouseMoved {
                // No timeline cursor feedback is shown while the window isn't
                // key (interaction requires activating it first), so skip all
                // per-move cursor work rather than pay it for an inactive window.
                guard window.isKeyWindow else { return }

                // Timeline cursor feedback (playhead grabber, loop resize
                // handles) is driven from here, in window coordinates —
                // SwiftUI hover tracking is unreliable underneath the
                // NSView-based timeline scroll overlay.
                updateTimelineCursor(for: event)

                // Recover from a stuck iBeam cursor; gate on the cursor state
                // before paying for the hit test.
                if NSCursor.current === NSCursor.iBeam {
                    let hoveredView = window.contentView?.hitTest(locationInWindow)
                    if CursorResetPolicy.shouldUseArrowCursor(currentCursor: NSCursor.current, hitView: hoveredView) {
                        NSCursor.arrow.set()
                    }
                }
                return
            }

            let clickedView = window.contentView?.hitTest(locationInWindow)

            if CursorResetPolicy.shouldUseArrowCursor(currentCursor: NSCursor.current, hitView: clickedView) {
                NSCursor.arrow.set()
            }

            if NumericControlFocusPolicy.shouldClearEditingFocus(
                firstResponder: window.firstResponder,
                clickedView: clickedView
            ) {
                window.makeFirstResponder(nil)
            }
        }
        clickMonitor.start()
        mouseMonitor = clickMonitor
    }

    // MARK: - Timeline cursor management

    struct TimelineCursorGeometry: Equatable {
        var sectionFrame: CGRect
        var infoWidth: CGFloat
        var waveformWidth: CGFloat
    }

    enum TimelineCursorShape {
        case standard
        case playheadGrab
        case loopResize
    }

    /// Pointer distance (points) from a loop edge within which the resize
    /// cursor shows; matches the resize handles' hit strip half-width.
    private static let loopResizeCursorRange: CGFloat = 6

    /// Decide which timeline cursor applies at the pointer and apply it on
    /// transitions only. Runs on every mouse-move; the math is a handful of
    /// float compares against the captured section geometry.
    private func updateTimelineCursor(for event: NSEvent) {
        // A ruler scrub owns the cursor (closed hand) for its duration.
        guard playheadDragX == nil else { return }
        guard
            let geometry = timelineCursorGeometry,
            let window = event.window,
            window === mainWindow,
            let contentView = window.contentView
        else {
            setTimelineCursor(.standard)
            return
        }

        var point = contentView.convert(event.locationInWindow, from: nil)
        if !contentView.isFlipped {
            point.y = contentView.bounds.height - point.y
        }

        let columnX = point.x - geometry.sectionFrame.minX - geometry.infoWidth
        let y = point.y - geometry.sectionFrame.minY
        guard
            geometry.sectionFrame.contains(point),
            columnX >= 0, columnX <= geometry.waveformWidth,
            controller.session.isPlayable
        else {
            setTimelineCursor(.standard)
            return
        }

        let seatBottom = trackHeaderHeight + trackTimelineDividerHeight

        // The grabber band along the bottom of the ruler.
        if y >= seatBottom - Self.playheadHandleHeight, y <= seatBottom {
            let playheadX = xPosition(for: controller.displayTransportPosition(), width: geometry.waveformWidth)
            if abs(columnX - playheadX) <= Self.playheadHitWidth / 2 {
                setTimelineCursor(.playheadGrab)
                return
            }
        }

        // The lanes: loop resize handles at the loop edges.
        if y > seatBottom, let loop = displayedLoopRegion {
            let startX = xPosition(for: loop.start, width: geometry.waveformWidth)
            let endX = xPosition(for: loop.end, width: geometry.waveformWidth)
            if abs(columnX - startX) <= Self.loopResizeCursorRange
                || abs(columnX - endX) <= Self.loopResizeCursorRange {
                setTimelineCursor(.loopResize)
                return
            }
        }

        setTimelineCursor(.standard)
    }

    private func setTimelineCursor(_ shape: TimelineCursorShape) {
        switch shape {
        case .standard:
            // Push arrow only on the transition out of a timeline cursor so
            // the manager never fights other controls' cursors (text fields'
            // iBeam, the column-resize handle) while the pointer is elsewhere.
            guard timelineCursorShape != .standard else { return }
            timelineCursorShape = .standard
            NSCursor.arrow.set()
        case .playheadGrab:
            reassertTimelineCursor(NSCursor.openHand, shape: shape)
        case .loopResize:
            reassertTimelineCursor(NSCursor.resizeLeftRight, shape: shape)
        }
    }

    /// AppKit's cursor-rect machinery (the timeline scroll overlay, view
    /// boundary crossings) can quietly reset the cursor to arrow after this
    /// manager sets it, so inside a timeline hot zone the cursor is
    /// re-asserted on every mouse move rather than only on shape transitions.
    private func reassertTimelineCursor(_ cursor: NSCursor, shape: TimelineCursorShape) {
        timelineCursorShape = shape
        if NSCursor.current !== cursor {
            cursor.set()
        }
    }

    private func configureAppOpenRouter() {
        appFileOpenRouter?.setHandler { urls in
            Task { await controller.loadImportedFiles(urls) }
        }
        appFileOpenRouter?.setStreamingURLHandler { urlStrings in
            for urlString in urlStrings {
                openFileCommandState.openStreamingURL(urlString)
            }
        }
    }

    private func loadDroppedURLs(from providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }

        var urlsByProvider = Array<URL?>(repeating: nil, count: fileProviders.count)
        let group = DispatchGroup()

        for (index, provider) in fileProviders.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url = extractDroppedFileURL(from: item)
                DispatchQueue.main.async {
                    urlsByProvider[index] = url
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            let urls = DroppedFileURLResolver.audioFileURLs(from: urlsByProvider.compactMap(\.self))
            guard !urls.isEmpty else { return }
            Task { @MainActor in
                switch DroppedFileImportAction.action(targetTrackID: nil) {
                case .append:
                    await controller.loadImportedFiles(urls)
                }
            }
        }

        return true
    }
}

/// GarageBand-style playhead grabber: a downward pentagon ("home plate") with a flat, softly
/// rounded top, straight vertical sides through the upper body, then a taper to a small flat tip
/// at the bottom-center. The flat tip matches the 2pt playhead line so the two read as one
/// continuous playhead.
private struct PlayheadHandle: Shape {
    /// Width of the flat bottom tip; sized to the playhead line so they overlap seamlessly.
    var tipWidth: CGFloat = 2
    /// Corner radius of the two flat top corners.
    var topCornerRadius: CGFloat = 2

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Fraction of the height that stays a straight-sided rectangle before tapering.
        let shoulderY = rect.minY + rect.height * 0.62
        let halfTip = min(tipWidth, rect.width) / 2
        let r = min(topCornerRadius, rect.width / 2)

        // Top edge with rounded top corners.
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
            radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false
        )
        // Straight right side down to the shoulder, then taper in to the flat tip.
        path.addLine(to: CGPoint(x: rect.maxX, y: shoulderY))
        path.addLine(to: CGPoint(x: rect.midX + halfTip, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX - halfTip, y: rect.maxY))
        // Back up the tapered left side and straight left side.
        path.addLine(to: CGPoint(x: rect.minX, y: shoulderY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.minY + r),
            radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

private struct ImportActionSplitButton: NSViewRepresentable {
    let dropdownItems: [ImportActionMenuItem]
    let performAction: @MainActor (ImportActionMenuItem) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(dropdownItems: dropdownItems, performAction: performAction)
    }

    func makeNSView(context: Context) -> ImmediateMenuSegmentedControl {
        let control = ImmediateMenuSegmentedControl(
            labels: ["", ""],
            trackingMode: .momentary,
            target: context.coordinator,
            action: #selector(Coordinator.segmentPressed(_:))
        )
        control.primarySegmentWidth = ImportActionControlMetrics.primaryButtonWidth
        control.menuSegmentWidth = ImportActionControlMetrics.menuButtonWidth
        control.segmentStyle = .rounded
        control.controlSize = .regular
        control.setImage(NSImage(systemSymbolName: "plus", accessibilityDescription: ImportActionMenuItem.open.title), forSegment: 0)
        control.setImage(NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Open Track Menu"), forSegment: 1)
        control.setImageScaling(.scaleProportionallyDown, forSegment: 0)
        control.setImageScaling(.scaleProportionallyDown, forSegment: 1)
        control.setWidth(ImportActionControlMetrics.primaryButtonWidth, forSegment: 0)
        control.setWidth(ImportActionControlMetrics.menuButtonWidth, forSegment: 1)
        control.setToolTip(ImportActionMenuItem.open.title, forSegment: 0)
        control.setToolTip("Open Track Menu", forSegment: 1)
        control.setShowsMenuIndicator(false, forSegment: 1)
        control.setAccessibilityLabel("Open Tracks")
        context.coordinator.configureMenu(for: control)
        return control
    }

    func updateNSView(_ control: ImmediateMenuSegmentedControl, context: Context) {
        context.coordinator.dropdownItems = dropdownItems
        context.coordinator.performAction = performAction
        context.coordinator.configureMenu(for: control)
    }

    @MainActor
    final class Coordinator: NSObject {
        var dropdownItems: [ImportActionMenuItem]
        var performAction: @MainActor (ImportActionMenuItem) -> Void

        private let menu = NSMenu()

        init(dropdownItems: [ImportActionMenuItem], performAction: @escaping @MainActor (ImportActionMenuItem) -> Void) {
            self.dropdownItems = dropdownItems
            self.performAction = performAction
        }

        func configureMenu(for control: ImmediateMenuSegmentedControl) {
            menu.removeAllItems()
            for item in dropdownItems {
                let menuItem = NSMenuItem(title: item.title, action: #selector(menuItemSelected(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = item
                menu.addItem(menuItem)
            }
            control.immediateMenu = menu
        }

        @objc func segmentPressed(_ sender: NSSegmentedControl) {
            if sender.selectedSegment == 0 {
                performAction(.open)
            }
        }

        @objc func menuItemSelected(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? ImportActionMenuItem else { return }
            performAction(item)
        }
    }
}

private final class ImmediateMenuSegmentedControl: NSSegmentedControl {
    var immediateMenu: NSMenu?
    var primarySegmentWidth: CGFloat = 0
    var menuSegmentWidth: CGFloat = 0

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let pressedSegment = ImportActionSplitButtonHitTesting.segment(
            atX: location.x,
            controlWidth: bounds.width,
            primaryWidth: primarySegmentWidth,
            menuWidth: menuSegmentWidth,
            layoutDirection: userInterfaceLayoutDirection
        )

        guard pressedSegment == 1, let immediateMenu else {
            super.mouseDown(with: event)
            return
        }

        selectedSegment = 1
        let menuOrigin = ImportActionSplitButtonMenuPlacement.origin(
            bounds: bounds,
            menuWidth: menuSegmentWidth,
            layoutDirection: userInterfaceLayoutDirection,
            isFlipped: isFlipped
        )
        immediateMenu.popUp(positioning: nil, at: menuOrigin, in: self)
        selectedSegment = -1
    }
}

/// A transparent horizontal `NSScrollView` overlay for the timeline. AppKit owns
/// the scroll physics, including native rubber-band bounce, while SwiftUI keeps
/// drawing the waveform from the reported visible time window.
private struct TimelineScrollOverlay: NSViewRepresentable {
    let visibleStart: TimeInterval
    let visibleSpan: TimeInterval
    let contentStart: TimeInterval
    let contentEnd: TimeInterval
    /// Native scroll offset mapped back to the visible timeline start.
    let onScroll: (TimeInterval) -> Void
    /// Pinch: magnification delta, plus the cursor's `0...1` position.
    let onMagnify: (Double, Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll)
    }

    func makeNSView(context: Context) -> TimelineScrollNSView {
        let view = TimelineScrollNSView()
        view.onMagnify = onMagnify
        context.coordinator.attach(to: view)
        configure(view)
        return view
    }

    func updateNSView(_ nsView: TimelineScrollNSView, context: Context) {
        nsView.onMagnify = onMagnify
        context.coordinator.onScroll = onScroll
        configure(nsView)
    }

    private func configure(_ scrollView: TimelineScrollNSView) {
        let viewportWidth = max(scrollView.bounds.width, 0)
        let viewportHeight = max(scrollView.bounds.height, 0)
        let contentSpan = max(contentEnd - contentStart, 0)
        let pointsPerSecond = TimelineScrollGeometry.pointsPerSecond(
            viewportWidth: Double(viewportWidth),
            visibleSpan: visibleSpan
        )
        let documentWidth = TimelineScrollGeometry.documentWidth(
            contentSpan: contentSpan,
            visibleSpan: visibleSpan,
            viewportWidth: Double(viewportWidth)
        )
        scrollView.timelineContentStart = contentStart
        scrollView.timelineContentEnd = contentEnd
        scrollView.timelineVisibleSpan = visibleSpan
        scrollView.timelinePointsPerSecond = pointsPerSecond
        if scrollView.isReportingNativeScroll {
            scrollView.documentView?.frame = NSRect(
                x: 0,
                y: 0,
                width: CGFloat(max(documentWidth, Double(viewportWidth))),
                height: viewportHeight
            )
            return
        }

        scrollView.performProgrammaticSync {
            scrollView.documentView?.frame = NSRect(
                x: 0,
                y: 0,
                width: CGFloat(max(documentWidth, Double(viewportWidth))),
                height: viewportHeight
            )

            let x = TimelineScrollGeometry.scrollOffset(
                visibleStart: visibleStart,
                contentStart: contentStart,
                pointsPerSecond: pointsPerSecond
            )
            guard abs(scrollView.contentView.bounds.origin.x - CGFloat(x)) > 0.5 else { return }
            scrollView.contentView.scroll(to: NSPoint(x: CGFloat(x), y: 0))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var onScroll: (TimeInterval) -> Void
        private weak var scrollView: TimelineScrollNSView?

        init(onScroll: @escaping (TimeInterval) -> Void) {
            self.onScroll = onScroll
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func attach(to scrollView: TimelineScrollNSView) {
            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        @objc private func boundsDidChange(_ notification: Notification) {
            guard let scrollView, !scrollView.isApplyingProgrammaticSync else { return }
            let visibleStart = TimelineScrollGeometry.visibleStart(
                scrollOffset: scrollView.contentView.bounds.origin.x,
                contentStart: scrollView.timelineContentStart,
                contentEnd: scrollView.timelineContentEnd,
                visibleSpan: scrollView.timelineVisibleSpan,
                pointsPerSecond: scrollView.timelinePointsPerSecond
            )
            scrollView.isReportingNativeScroll = true
            onScroll(visibleStart)
            DispatchQueue.main.async { [weak scrollView] in
                scrollView?.isReportingNativeScroll = false
            }
        }
    }
}

private final class TimelineScrollNSView: NSScrollView {
    var onMagnify: ((Double, Double) -> Void)?
    var timelineContentStart: TimeInterval = 0
    var timelineContentEnd: TimeInterval = 0
    var timelineVisibleSpan: TimeInterval = 0
    var timelinePointsPerSecond: Double = 0
    var isReportingNativeScroll = false
    var isApplyingProgrammaticSync = false
    private var lockedScrollAxis: ScrollAxis?

    private enum ScrollAxis {
        case horizontal
        case vertical
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        drawsBackground = false
        hasHorizontalScroller = true
        hasVerticalScroller = false
        horizontalScrollElasticity = .allowed
        verticalScrollElasticity = .none
        usesPredominantAxisScrolling = true
        autohidesScrollers = true
        borderType = .noBorder
        documentView = NSView(frame: .zero)
    }

    func performProgrammaticSync(_ update: () -> Void) {
        isApplyingProgrammaticSync = true
        update()
        DispatchQueue.main.async { [weak self] in
            self?.isApplyingProgrammaticSync = false
        }
    }

    // Only claim the events we handle. `NSApp.currentEvent` lets `hitTest`
    // decide per-event: scroll/magnify route to us, everything else (clicks,
    // drags, vertical scroll) falls through to the views below. Scroll gestures
    // are axis-locked until the gesture ends so horizontal movement during an
    // in-flight vertical scroll cannot steal the event stream from the track
    // list's ScrollView.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let scrollerHit = horizontalScrollerHitTest(at: point) {
            return scrollerHit
        }

        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .magnify, .beginGesture, .endGesture, .smartMagnify:
            return self
        case .scrollWheel:
            if scrollGestureBegan(event) || !scrollGestureHasPhase(event) {
                lockedScrollAxis = nil
            }
            // Do not clear the lock on gesture end here: hitTest can run more
            // than once for the same event (extra passes happen while a field
            // editor is active), and the ended event has zero deltas — a second
            // pass without the lock would return nil and the scroll view would
            // never see the gesture end, leaving the rubber band stretched.
            // `scrollWheel(with:)` clears the lock exactly once per event, and
            // the next gesture's began clears any stale lock anyway.
            return scrollAxis(for: event) == .horizontal ? self : nil
        default:
            return nil
        }
    }

    private func horizontalScrollerHitTest(at point: NSPoint) -> NSView? {
        guard let horizontalScroller else { return nil }
        let pointInSelf = superview.map { convert(point, from: $0) } ?? point
        let pointInScroller = horizontalScroller.convert(pointInSelf, from: self)
        guard horizontalScroller.bounds.contains(pointInScroller) else { return nil }
        let hitView = super.hitTest(point)
        guard hitView === horizontalScroller || hitView?.isDescendant(of: horizontalScroller) == true else {
            return nil
        }
        return hitView
    }

    override func scrollWheel(with event: NSEvent) {
        if scrollGestureBegan(event) || !scrollGestureHasPhase(event) {
            lockedScrollAxis = nil
        }
        super.scrollWheel(with: event)
        if scrollGestureEnded(event) {
            lockedScrollAxis = nil
        }
    }

    private func scrollAxis(for event: NSEvent) -> ScrollAxis? {
        if let lockedScrollAxis {
            return lockedScrollAxis
        }

        let horizontalDelta = abs(event.scrollingDeltaX)
        let verticalDelta = abs(event.scrollingDeltaY)
        guard horizontalDelta > 0 || verticalDelta > 0 else { return nil }

        let axis: ScrollAxis = horizontalDelta > verticalDelta ? .horizontal : .vertical
        if scrollGestureInProgress(event) {
            lockedScrollAxis = axis
        }
        return axis
    }

    private func scrollGestureHasPhase(_ event: NSEvent) -> Bool {
        event.phase != [] || event.momentumPhase != []
    }

    private func scrollGestureBegan(_ event: NSEvent) -> Bool {
        event.phase.contains(.began) || event.momentumPhase.contains(.began)
    }

    private func scrollGestureInProgress(_ event: NSEvent) -> Bool {
        let phase = event.momentumPhase != [] ? event.momentumPhase : event.phase
        return phase != [] && !phase.contains(.ended) && !phase.contains(.cancelled)
    }

    private func scrollGestureEnded(_ event: NSEvent) -> Bool {
        event.phase.contains(.ended)
            || event.phase.contains(.cancelled)
            || event.momentumPhase.contains(.ended)
            || event.momentumPhase.contains(.cancelled)
    }

    /// Multiplier applied to the raw trackpad pinch delta. Higher = zoom
    /// changes faster per unit of finger movement.
    private static let zoomSensitivity = 1.5

    override func magnify(with event: NSEvent) {
        let visibleBounds = contentView.bounds
        let width = visibleBounds.width
        guard width > 0 else { return }
        let windowLocation = window?.mouseLocationOutsideOfEventStream ?? event.locationInWindow
        let location = contentView.convert(windowLocation, from: nil)
        let fraction = TimelineScrollGeometry.viewportFraction(
            locationX: Double(location.x),
            visibleOriginX: Double(visibleBounds.origin.x),
            viewportWidth: Double(width)
        )
        onMagnify?(Double(event.magnification) * Self.zoomSensitivity, fraction)
    }
}

private struct MainWindowConfigurationView: NSViewRepresentable {
    let configure: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureWindow(for: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        configureWindow(for: view)
    }

    private func configureWindow(for view: NSView) {
        Task { @MainActor in
            guard let window = view.window else { return }
            configure(window)
        }
    }
}

private struct InactiveWindowInteractionShield: NSViewRepresentable {
    weak var window: NSWindow?

    func makeNSView(context: Context) -> ShieldView {
        let view = ShieldView()
        view.targetWindow = window
        return view
    }

    func updateNSView(_ view: ShieldView, context: Context) {
        view.targetWindow = window
    }

    final class ShieldView: NSView {
        weak var targetWindow: NSWindow?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard !Self.shouldPassThrough(event: NSApp.currentEvent) else { return nil }
            return super.hitTest(point)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            !Self.shouldPassThrough(event: event)
        }

        override func mouseDown(with event: NSEvent) {
            activateWindow()
        }

        override func rightMouseDown(with event: NSEvent) {
            activateWindow()
        }

        override func otherMouseDown(with event: NSEvent) {
            activateWindow()
        }

        override func scrollWheel(with event: NSEvent) {
            activateWindow()
        }

        private func activateWindow() {
            NSApp.activate(ignoringOtherApps: true)
            (targetWindow ?? window)?.makeKeyAndOrderFront(nil)
        }

        private static func shouldPassThrough(event: NSEvent?) -> Bool {
            event?.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) == true
        }
    }
}

private struct WindowActivityAppearanceModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .saturation(isActive ? 1.0 : 0.6)
            .opacity(isActive ? 1.0 : 0.58)
            .overlay {
                if !isActive {
                    Color(nsColor: .windowBackgroundColor)
                        .opacity(0.16)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isActive)
    }
}

private extension View {
    func windowActivityAppearance(isActive: Bool) -> some View {
        modifier(WindowActivityAppearanceModifier(isActive: isActive))
    }
}


private struct IntegerInputField: NSViewRepresentable {
    @Binding var value: Int
    let configuration: NumericControlConfiguration
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            value: $value,
            configuration: configuration
        )
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NumericInputTextField(frame: .zero)
        textField.alignment = .right
        // Borderless and transparent so the field blends into the composite
        // offset box that surrounds it; the box supplies the border.
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        textField.delegate = context.coordinator
        textField.stringValue = "\(value)"
        textField.onFocusChange = onFocusChange
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.configuration = configuration
        (nsView as? NumericInputTextField)?.onFocusChange = onFocusChange
        let clamped = configuration.clamped(value)
        if clamped != value {
            DispatchQueue.main.async {
                self.value = clamped
            }
        }
        if !context.coordinator.isEditing {
            context.coordinator.refreshCommittedValue(clamped)
            if nsView.stringValue != "\(clamped)" {
                nsView.stringValue = "\(clamped)"
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding private var value: Int
        var configuration: NumericControlConfiguration
        private var editState: NumericControlEditState
        private(set) var isEditing = false
        private var isCancellingEdit = false

        init(
            value: Binding<Int>,
            configuration: NumericControlConfiguration
        ) {
            _value = value
            self.configuration = configuration
            editState = NumericControlEditState(committedValue: value.wrappedValue)
        }

        @MainActor
        func controlTextDidBeginEditing(_ obj: Notification) {
            let displayedText = (obj.object as? NSTextField)?.stringValue ?? "\(value)"
            editState.beginEditing(
                displayedText: displayedText,
                fallbackValue: value,
                configuration: configuration
            )
            isEditing = true
            isCancellingEdit = false
        }

        @MainActor
        func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
            guard let textField = control as? NSTextField else { return true }
            editState.updatePendingText(fieldEditor.string)
            if isCancellingEdit {
                let restoredValue = editState.cancelledValue()
                value = restoredValue
                textField.stringValue = "\(restoredValue)"
                return true
            }
            syncValue(from: textField, overrideText: fieldEditor.string)
            return true
        }

        @MainActor
        func controlTextDidEndEditing(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            if isCancellingEdit {
                let restoredValue = editState.cancelledValue()
                value = restoredValue
                textField.stringValue = "\(restoredValue)"
                isEditing = false
                isCancellingEdit = false
                return
            }
            syncValue(from: textField)
            isEditing = false
        }

        @MainActor
        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            editState.updatePendingText((textField.currentEditor() as? NSTextView)?.string ?? textField.stringValue)
        }

        func applyStep(direction: Int, largeStep: Bool) {
            value = configuration.steppedValue(from: value, direction: direction, largeStep: largeStep)
        }

        func refreshCommittedValue(_ value: Int) {
            editState.refreshCommittedValue(value)
        }

        @MainActor
        private func syncValue(from textField: NSTextField) {
            syncValue(from: textField, overrideText: nil)
        }

        @MainActor
        private func syncValue(from textField: NSTextField, overrideText: String?) {
            editState.updatePendingText(overrideText ?? textField.stringValue)
            let committedValue = editState.commitPendingText(
                fallbackValue: value,
                configuration: configuration
            )
            value = committedValue
            textField.stringValue = "\(committedValue)"
        }

        @MainActor
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                let steppedValue = applyStep(
                    using: NumericControlEditingText.current(
                        controlText: (control as? NSTextField)?.stringValue ?? "\(value)",
                        fieldEditorText: textView.string
                    ),
                    direction: 1,
                    largeStep: false
                )
                updateEditingText(control: control, textView: textView, value: steppedValue)
                return true
            case #selector(NSResponder.moveDown(_:)):
                let steppedValue = applyStep(
                    using: NumericControlEditingText.current(
                        controlText: (control as? NSTextField)?.stringValue ?? "\(value)",
                        fieldEditorText: textView.string
                    ),
                    direction: -1,
                    largeStep: false
                )
                updateEditingText(control: control, textView: textView, value: steppedValue)
                return true
            case #selector(NSResponder.moveUpAndModifySelection(_:)):
                let steppedValue = applyStep(
                    using: NumericControlEditingText.current(
                        controlText: (control as? NSTextField)?.stringValue ?? "\(value)",
                        fieldEditorText: textView.string
                    ),
                    direction: 1,
                    largeStep: true
                )
                updateEditingText(control: control, textView: textView, value: steppedValue)
                return true
            case #selector(NSResponder.moveDownAndModifySelection(_:)):
                let steppedValue = applyStep(
                    using: NumericControlEditingText.current(
                        controlText: (control as? NSTextField)?.stringValue ?? "\(value)",
                        fieldEditorText: textView.string
                    ),
                    direction: -1,
                    largeStep: true
                )
                updateEditingText(control: control, textView: textView, value: steppedValue)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                if let textField = control as? NSTextField {
                    syncValue(from: textField, overrideText: textView.string)
                }
                control.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                isCancellingEdit = true
                if let textField = control as? NSTextField {
                    let restoredValue = editState.cancelledValue()
                    value = restoredValue
                    textField.stringValue = "\(restoredValue)"
                    textView.string = "\(restoredValue)"
                }
                isEditing = false
                control.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }

        private func applyStep(using currentText: String, direction: Int, largeStep: Bool) -> Int {
            let steppedValue = editState.commitSteppedEditingText(
                currentText: currentText,
                fallbackValue: value,
                configuration: configuration,
                direction: direction,
                largeStep: largeStep
            )
            value = steppedValue
            return steppedValue
        }

        @MainActor
        private func updateEditingText(control: NSControl, textView: NSTextView, value: Int) {
            let text = "\(value)"
            if let textField = control as? NSTextField {
                textField.stringValue = text
            }
            textView.string = text
            textView.setSelectedRange(NSRange(location: text.count, length: 0))
        }
    }

    private final class NumericInputTextField: NSTextField {
        /// Reports focus so the composite box wrapping this borderless field can
        /// draw its own highlight (the field's native focus ring is disabled).
        var onFocusChange: ((Bool) -> Void)?

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted {
                onFocusChange?(true)
            }
            return accepted
        }

        override func textDidEndEditing(_ notification: Notification) {
            super.textDidEndEditing(notification)
            onFocusChange?(false)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard NumericInputKeyEquivalentPolicy.routesToFieldEditor(event: event),
                  let fieldEditor = currentEditor() as? NSTextView
            else {
                return super.performKeyEquivalent(with: event)
            }

            fieldEditor.interpretKeyEvents([event])
            return true
        }
    }
}

private func extractDroppedFileURL(from item: NSSecureCoding?) -> URL? {
    if let data = item as? Data {
        return URL(dataRepresentation: data, relativeTo: nil)
    }

    if let url = item as? URL {
        return url
    }

    if let text = item as? String {
        return URL(string: text)
    }

    return nil
}

/// One track row (info column + waveform lane) as a standalone, `Equatable`
/// value view (`.equatable()` at the call site).
///
/// The whole point is isolation: a horizontal scroll writes `visibleStart` and
/// a reorder gap move bumps parent `@State`, both of which re-run the container
/// body — but the container only reconstructs these cheap values and runs `==`
/// per row. Unless a *compared* input changed, SwiftUI skips this body and the
/// entire info-column subtree (index badge, offset field, drag source) is left
/// untouched. Three things are deliberately kept OUT of the compared surface so
/// they can update without re-running the body:
///   - the per-scroll-event lane slide AND the zoom-varying lane window
///     (window bounds + tick guides), both handled inside the `LaneView` leaf
///     (which reads `controller.visibleStart` and `viewportStore` itself), so
///     scroll and zoom re-run only that fixed-frame leaf, not the row;
///   - the reorder gap `offset(y:)`/`opacity`/animation, applied by the
///     container around this view.
/// `controller`, `viewportStore`, and the action closures are stored but
/// excluded from `==`; the closures only capture the row's own identity /
/// actions, never per-event state, so a skipped body can't show stale visuals.
private struct TrackRowView: View, Equatable {
    var index: Int
    var sessionTrack: SessionTrack
    /// Nil while blind listening (so progress can't leak identity) or before
    /// generation starts. Array `==` short-circuits on shared storage, so the
    /// common scroll case is O(1).
    var waveform: Waveform?
    var isActive: Bool
    var isBlind: Bool
    /// Whether this row's lane may rasterize (it intersects the vertical
    /// viewport ± overscan). Culled lanes keep showing their last image.
    var isRenderable: Bool
    var isOffsetFocused: Bool
    var infoWidth: CGFloat
    var rowHeight: CGFloat
    /// Drawn width of the 2× lane window. Geometry-driven (2× the waveform
    /// column), so it changes on window/column resize but NOT on zoom — safe
    /// as an equatable input.
    var wideWidth: CGFloat
    var offsetConfiguration: NumericControlConfiguration
    var indexBadgeAppearance: IndexBadgeAppearance
    var showsDebugLabel: Bool

    /// References forwarded to the lane leaf; never read in this body. The
    /// zoom-varying window/ticks live in `viewportStore` (observed only by the
    /// leaf), so they can't be equatable inputs here — see `LaneViewport`.
    var controller: PlaybackController
    var viewportStore: LaneViewportStore
    /// Observed only by the trash-button leaf, never by this body, so a hover
    /// change re-evaluates that one leaf and not the equatable row.
    var hoverStore: TrackHoverStore
    var onSelect: () -> Void
    var onRemove: () -> Void
    var onSetOffsetMs: (Int) -> Void
    var onOffsetFocusChange: (Bool) -> Void
    var onHover: (Bool) -> Void
    var onDragBegan: () -> Void
    var onDragEnded: () -> Void
    var makeDragImage: () -> NSImage?

    nonisolated static func == (lhs: TrackRowView, rhs: TrackRowView) -> Bool {
        lhs.index == rhs.index
            && lhs.sessionTrack == rhs.sessionTrack
            && lhs.waveform == rhs.waveform
            && lhs.isActive == rhs.isActive
            && lhs.isBlind == rhs.isBlind
            && lhs.isRenderable == rhs.isRenderable
            && lhs.isOffsetFocused == rhs.isOffsetFocused
            && lhs.infoWidth == rhs.infoWidth
            && lhs.rowHeight == rhs.rowHeight
            && lhs.wideWidth == rhs.wideWidth
            && lhs.offsetConfiguration == rhs.offsetConfiguration
            && lhs.indexBadgeAppearance == rhs.indexBadgeAppearance
            && lhs.showsDebugLabel == rhs.showsDebugLabel
    }

    var body: some View {
        HStack(spacing: 0) {
            infoArea
                .frame(width: infoWidth, height: rowHeight, alignment: .leading)
                // Drag the info column to reorder in place (a move), or out of the
                // window to copy the track's audio file onto Finder / another app /
                // another Takes window. An AppKit drag source (behind the column's
                // content, so its own controls still work) runs the drag with the
                // right move-inside / copy-outside operation; a plain click selects.
                .background(
                    TrackRowDragSource(
                        fileURL: sessionTrack.loadedTrack.url,
                        trackID: sessionTrack.id,
                        onSelect: onSelect,
                        onDragBegan: onDragBegan,
                        onDragEnded: onDragEnded,
                        makeDragImage: makeDragImage
                    )
                )

            // The lane is a self-observing leaf: it reads the shared viewport
            // (zoom) and the live scroll position (`shiftX`) itself, so zoom and
            // scroll re-run only this fixed-frame leaf, never the row body. Its
            // frame is `wideWidth × rowHeight` (both fixed on zoom), so its
            // re-runs never propagate layout up into the VStack.
            LaneView(
                controller: controller,
                viewportStore: viewportStore,
                waveform: waveform,
                isActive: isActive,
                isBlind: isBlind,
                isRenderable: isRenderable,
                trackStart: sessionTrack.loadedTrack.offsetSeconds,
                trackDuration: sessionTrack.loadedTrack.duration,
                wideWidth: wideWidth,
                rowHeight: rowHeight,
                showsDebugLabel: showsDebugLabel
            )
        }
        .frame(height: rowHeight)
        // Active highlight spans the whole row (info + lane) as one continuous
        // band; a leading accent bar anchors the active track to the left edge.
        // Drawn at the HStack level so the frozen-column edge (a top-level overlay)
        // reads as crossing a single tinted band rather than two boxes.
        .background(isActive ? Theme.activeRowFill : Color.clear)
        .overlay(alignment: .leading) {
            if isActive {
                Rectangle()
                    .fill(Theme.primary)
                    .frame(width: 3)
                    .allowsHitTesting(false)
            }
        }
        .onHover { onHover($0) }
    }

    private var infoArea: some View {
        let track = sessionTrack.loadedTrack
        let title = isBlind ? "Track \(index + 1)" : track.displayName
        // Badge on the left; filename, metadata, and the Offset row form a single
        // left-aligned column to its right so all three share the filename's left
        // edge. Vertically centered so the info column matches the waveform lane.
        // The badge, filename, and metadata opt out of hit-testing so the drag
        // source behind the column receives their clicks (a drag anywhere but the
        // trash button and offset field starts a reorder). The trash button and
        // offset field keep hit-testing so they still work.
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            TrackIndexBadgeView(index: index, isActive: isActive, appearance: indexBadgeAppearance)
                // Baseline is technically aligned, but the fixed badge frame makes
                // the centered number read a touch low; nudge it up 1pt.
                .offset(y: -1)
                .allowsHitTesting(false)

            // Outer spacing (12) pushes the Offset row down; the inner group's
            // spacing (2) keeps the filename and metadata tightly associated.
            // Tweak these two numbers to taste.
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 2) {
                        Text(title)
                            .font(.headline.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .overlay {
                                TruncationAwareTooltip(
                                    text: title,
                                    font: .systemFont(
                                        ofSize: NSFont.preferredFont(forTextStyle: .headline).pointSize,
                                        weight: .medium
                                    )
                                )
                            }
                            .allowsHitTesting(false)

                        Spacer(minLength: 0)

                        TrackRowTrashButton(
                            store: hoverStore,
                            trackID: sessionTrack.id,
                            index: index,
                            onRemove: onRemove
                        )
                    }

                    Text(track.metadataSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .opacity(isBlind ? 0 : 1)
                        .accessibilityHidden(isBlind)
                        .allowsHitTesting(false)
                }

                offsetControl
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity, alignment: .center)
        .componentDebugLabel("Track Info", enabled: showsDebugLabel, color: .green)
    }

    private var offsetControl: some View {
        let offsetMs = Int((sessionTrack.loadedTrack.offsetSeconds * 1000).rounded())
        let binding = Binding(
            get: { offsetMs },
            set: { onSetOffsetMs($0) }
        )
        // firstTextBaseline so the "Offset" caption sits on the same line as the
        // field's numeric text; both use .caption so their baselines match.
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Offset")
                .font(.caption)
                .foregroundStyle(.secondary)

            offsetField(binding: binding)
        }
    }

    /// Composite offset control: a single rounded, bordered box holding the
    /// borderless numeric field, a static "ms" unit, and an embedded stepper — so
    /// it reads as one input `[  0  ms  ⌃⌄ ]`. Typed-entry/clamping and the
    /// Shift-large-step behavior come from `IntegerInputField`; the stepper mirrors
    /// the same step amounts.
    private func offsetField(binding: Binding<Int>) -> some View {
        HStack(spacing: 4) {
            IntegerInputField(
                value: binding,
                configuration: offsetConfiguration,
                onFocusChange: onOffsetFocusChange
            )
            .frame(width: 44)

            Text("ms")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    binding.wrappedValue = 0
                }
                .accessibilityLabel("Offset units")
                .accessibilityHint("Double click to reset offset to zero milliseconds.")

            Stepper(
                "Offset",
                onIncrement: { stepOffset(binding, direction: 1) },
                onDecrement: { stepOffset(binding, direction: -1) }
            )
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.leading, 6)
        .padding(.trailing, 3)
        .padding(.vertical, 2)
        .fixedSize(horizontal: true, vertical: false)
        // Recessed field: a filled surface with a soft top inner shadow, ringed by
        // an inset bevel (dark top edge fading to a light bottom edge).
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.readoutSurface.shadow(.inner(color: .black.opacity(0.15), radius: 1.5, y: 1)))
        }
        // Focused: the bevel gives way to a solid ring in the app's active
        // indigo, plus a soft matching glow so the live field is unmissable.
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isOffsetFocused
                        ? AnyShapeStyle(Theme.primary)
                        : AnyShapeStyle(LinearGradient(
                            colors: [.black.opacity(0.14), .white.opacity(0.45)],
                            startPoint: .top,
                            endPoint: .bottom
                        )),
                    lineWidth: isOffsetFocused ? 1.5 : 1
                )
        }
        .shadow(color: isOffsetFocused ? Theme.primary.opacity(0.55) : .clear, radius: 3)
        .animation(.easeOut(duration: 0.12), value: isOffsetFocused)
    }

    private func stepOffset(_ binding: Binding<Int>, direction: Int) {
        binding.wrappedValue = offsetConfiguration.steppedValue(
            from: binding.wrappedValue,
            direction: direction,
            largeStep: NumericControlConfiguration.isLargeStepModifierFlags(NSEvent.modifierFlags)
        )
    }
}

/// Shared, self-observing source for the zoom-varying lane window (window
/// bounds + tick guides). Only the lane leaves read it, so a zoom step (which
/// changes every field) re-runs those N fixed-frame leaves instead of every
/// row body — the WP-6 fix. The container writes it via an equality-guarded
/// `.onChange` on the computed `LaneViewport`.
@MainActor
@Observable
final class LaneViewportStore {
    var viewport: ContentView.LaneViewport = .empty
}

/// Which track row the pointer is over, isolated so a hover change updates only
/// the small trash-button leaf that reads it — not the equatable `TrackRowView`.
/// Writing `hoveredID` here (instead of a `ContentView` `@State`) is what keeps
/// a hover from re-running the track-list container and re-laying-out the rows.
@MainActor
@Observable
final class TrackHoverStore {
    var hoveredID: SessionTrack.ID?
}

/// The hover-revealed trash button, split into its own leaf so it — and nothing
/// else in the row — re-evaluates when the hovered row changes. Reads the shared
/// `TrackHoverStore`; the row body never does.
private struct TrackRowTrashButton: View {
    var store: TrackHoverStore
    var trackID: SessionTrack.ID
    var index: Int
    var onRemove: () -> Void

    var body: some View {
        Button(action: onRemove) {
            Image(systemName: "trash")
                .accessibilityLabel("Remove Track \(index + 1)")
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .frame(width: 16, height: 16)
        // Only surfaces on hover; kept mounted (opacity, not removed) so it
        // stays reachable by accessibility/keyboard.
        .opacity(store.hoveredID == trackID ? 1 : 0)
    }
}

/// One lane: the pre-rendered waveform window, positioned for the live scroll
/// (`shiftX`) and drawn from the shared zoom-varying window (`viewportStore`).
///
/// A self-observing leaf. It reads `viewportStore.viewport` (zoom / grid
/// boundary) and `controller.visibleStart`/`visibleSpan` (per scroll event),
/// so both zoom and scroll re-run only this body — never the equatable row
/// around it. Its outer frame is `wideWidth × rowHeight`, both fixed on zoom
/// AND scroll, so a re-run never propagates layout up into the VStack; the
/// image moves purely by transforms inside that fixed frame. `WaveformLaneView`
/// stays `.equatable()`, so its Canvas/image request is touched only when the
/// window actually changes (boundary or zoom), not on an intra-window scroll.
private struct LaneView: View {
    var controller: PlaybackController
    var viewportStore: LaneViewportStore
    // Per-row, zoom-invariant inputs (captured when the row body last ran).
    var waveform: Waveform?
    var isActive: Bool
    var isBlind: Bool
    var isRenderable: Bool
    var trackStart: TimeInterval
    var trackDuration: TimeInterval
    var wideWidth: CGFloat
    var rowHeight: CGFloat
    var showsDebugLabel: Bool

    var body: some View {
        let viewport = viewportStore.viewport
        // Matches `makeLaneViewport`: `shiftX` maps the live scroll position
        // into the visible (half-window) width.
        let span = max(controller.visibleSpan, 0.001)
        let waveformWidth = wideWidth / 2
        let shiftX = CGFloat((controller.visibleStart - viewport.windowStart) / span) * waveformWidth
        Color.clear
            .frame(height: rowHeight)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                WaveformLaneView(
                    width: wideWidth,
                    waveform: waveform,
                    isBlindListening: isBlind,
                    isActive: isActive,
                    isRenderable: isRenderable,
                    trackStart: trackStart,
                    trackDuration: trackDuration,
                    visibleStart: viewport.windowStart,
                    visibleSpan: viewport.windowSpan,
                    majorTickXs: viewport.majorTickXs,
                    zeroTickX: viewport.zeroTickX,
                    showsDebugLabel: showsDebugLabel
                )
                .equatable()
                .frame(width: wideWidth, height: rowHeight)
                .offset(x: -shiftX)
            }
            .clipped()
    }
}

/// The timeline header ruler — moving time labels and tick notches. It
/// legitimately redraws on every scroll event (it IS the moving ruler), so it
/// is a self-observing leaf: only this view's body reads the visible window,
/// and the header/section around it stays untouched per event.
private struct TimelineHeaderRulerView: View {
    var controller: PlaybackController
    var width: CGFloat
    var targetMarkerCount: Int
    /// Minimum on-screen spacing (points) between minor ticks before they are hidden.
    var minorTickMinSpacing: Double
    var headerHeight: CGFloat

    // Ruler notches hang downward from below the numbers toward the rows, Fission-style:
    // major (labeled) ticks are tall — their top edge comes up to just beneath the number so the
    // label sits against the tick like a baseline — while minor ticks stay short. Both are
    // bottom-anchored so they hang toward the rows.
    private var tickColor: Color { .secondary.opacity(0.45) }
    private var majorTickHeight: CGFloat { 19 }
    private var minorTickHeight: CGFloat { 8 }
    /// Vertical inset of the time label from the top of the header.
    private var labelTopInset: CGFloat { 7 }

    var body: some View {
        let visibleStart = controller.visibleStart
        let visibleEnd = controller.visibleEnd
        let rulerStart = max(visibleStart, controller.session.timelineStart)
        let rulerEnd = min(visibleEnd, controller.session.timelineEnd)
        let ruler = TimelineHeaderMarker.ruler(
            timelineStart: rulerStart,
            timelineEnd: rulerEnd,
            targetMarkerCount: targetMarkerCount,
            // Keep the just-off-screen major tick so its label clips at the left edge while scrolling
            // rather than blinking out (mirrors the right-edge clipping in TimelineHeaderLabelLayout).
            leadingMajorTicks: 1
        )

        // Drop minor ticks once they would pack closer than this; keeps the ruler from turning into
        // a gray blur at narrow widths or high subdivision counts.
        let visibleSpan = visibleEnd - visibleStart
        let minorSpacing = visibleSpan > 0 ? ruler.minorInterval / visibleSpan * Double(width) : 0
        let showMinorTicks = minorSpacing >= minorTickMinSpacing

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.background.opacity(0.01))

            if ruler.majorTicks.isEmpty {
                Text("00:00")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .frame(maxHeight: .infinity, alignment: .center)
            } else {
                if showMinorTicks {
                    ForEach(ruler.minorTicks, id: \.self) { tickTime in
                        minorTick(at: tickTime, visibleStart: visibleStart, visibleEnd: visibleEnd)
                    }
                }
                ForEach(ruler.majorTicks, id: \.time) { marker in
                    majorMarker(marker, visibleStart: visibleStart, visibleEnd: visibleEnd)
                }
            }
        }
        .clipped()
        .accessibilityLabel("Timeline")
    }

    private func xPosition(for time: TimeInterval, visibleStart: TimeInterval, visibleEnd: TimeInterval) -> CGFloat {
        CGFloat(
            TransportMapping.normalizedPosition(
                globalTime: time,
                timelineStart: visibleStart,
                timelineEnd: visibleEnd
            )
        ) * width
    }

    private func minorTick(at time: TimeInterval, visibleStart: TimeInterval, visibleEnd: TimeInterval) -> some View {
        Rectangle()
            .fill(tickColor)
            .frame(width: 1, height: minorTickHeight)
            .offset(x: xPosition(for: time, visibleStart: visibleStart, visibleEnd: visibleEnd))
            // Anchor to the bottom so the notch hangs down toward the waveforms.
            .frame(width: width, height: headerHeight, alignment: .bottomLeading)
            .accessibilityHidden(true)
    }

    private func majorMarker(_ marker: TimelineHeaderMarker, visibleStart: TimeInterval, visibleEnd: TimeInterval) -> some View {
        let tickX = xPosition(for: marker.time, visibleStart: visibleStart, visibleEnd: visibleEnd)
        let labelWidth: CGFloat = 60
        let labelLayout = TimelineHeaderLabelLayout.leading(
            tickX: Double(tickX),
            rulerWidth: Double(width)
        )

        return ZStack(alignment: .topLeading) {
            // Number on top.
            if labelLayout.isVisible {
                Text(marker.label)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: labelWidth, alignment: .leading)
                    .offset(x: CGFloat(labelLayout.x), y: labelTopInset)
            }

            // Taller notch hanging below the number, anchored to the header bottom.
            Rectangle()
                .fill(tickColor)
                .frame(width: 1, height: majorTickHeight)
                .offset(x: tickX)
                .frame(width: width, height: headerHeight, alignment: .bottomLeading)
        }
        .frame(width: width, height: headerHeight, alignment: .topLeading)
        .accessibilityLabel(marker.label)
    }
}

/// Leaf wrapper for the scroll/magnify event overlay: it must be fed the live
/// scroll position (its event math depends on it), so it alone re-runs per
/// scroll event — one cheap representable update — instead of the section that
/// mounts it.
private struct TimelineScrollOverlayLeaf: View {
    var controller: PlaybackController

    var body: some View {
        TimelineScrollOverlay(
            visibleStart: controller.visibleStart,
            visibleSpan: max(controller.visibleSpan, 0.001),
            contentStart: controller.session.timelineStart,
            contentEnd: controller.session.timelineEnd,
            onScroll: { controller.scrollTimeline(toVisibleStart: $0) },
            onMagnify: { controller.magnifyTimeline(by: $0, atFraction: $1) }
        )
    }
}

/// Leaf around `TimelinePlayheadVisual` so only this body — a single
/// representable update re-seating the CALayer tween — re-runs when the
/// visible window or a transport anchor changes, not the whole section
/// overlay. The CALayer system itself is untouched: steady playback still
/// costs zero main-thread work between anchor events.
private struct TimelinePlayheadOverlayView: View {
    var controller: PlaybackController
    /// While a ruler scrub is in flight: the preview x within the column.
    var playheadDragX: CGFloat?
    var infoWidth: CGFloat
    var sectionHeight: CGFloat
    var waveformWidth: CGFloat
    var seatBottom: CGFloat
    var laneAreaHeight: CGFloat

    var body: some View {
        let position = controller.displayTransportPosition()
        TimelinePlayheadVisual(
            currentX: playheadDragX ?? xPosition(for: position),
            endX: xPosition(for: controller.session.playbackEnd),
            remaining: max(0, controller.session.playbackEnd - position),
            isPlaying: controller.session.isPlaying && playheadDragX == nil,
            infoWidth: infoWidth,
            sectionHeight: sectionHeight,
            waveformWidth: waveformWidth,
            seatBottom: seatBottom,
            laneAreaHeight: laneAreaHeight
        )
        // Purely decorative (the caller disables hit testing too, and the layer
        // view overrides `hitTest` to nil); kept here so the leaf can never
        // intercept clicks regardless of how it's mounted.
        .allowsHitTesting(false)
    }

    private func xPosition(for globalTime: TimeInterval) -> CGFloat {
        CGFloat(
            TransportMapping.normalizedPosition(
                globalTime: globalTime,
                timelineStart: controller.visibleStart,
                timelineEnd: controller.visibleEnd
            )
        ) * waveformWidth
    }
}

/// The loop selection rectangle and resize handles. A leaf because their
/// x-positions track the per-scroll-event visible window; the gesture LOGIC
/// (draft thresholds, commit, click-to-seek fallthrough) stays in
/// `ContentView` closures, so behavior is unchanged. Mounted inside the
/// container's `loopColumnSpace` so the handle drags report the same
/// coordinates as before.
private struct LoopOverlayContentView: View {
    var controller: PlaybackController
    var waveformWidth: CGFloat
    var height: CGFloat
    /// In-progress drag selection (absolute seconds); takes priority over the loop.
    var draftRange: ClosedRange<TimeInterval>?
    /// The resize preview or committed loop; `nil` while drag-selecting (the
    /// caller suppresses it so the draft owns the rectangle and no grips show).
    var displayedLoop: LoopRegion?
    var onHandleChanged: (_ isStart: Bool, _ value: DragGesture.Value) -> Void
    var onHandleEnded: (_ isStart: Bool, _ value: DragGesture.Value) -> Void

    var body: some View {
        // The only per-scroll-event reads: this leaf re-runs, the tree above
        // it doesn't.
        let visibleStart = controller.visibleStart
        let visibleEnd = controller.visibleEnd

        ZStack(alignment: .topLeading) {
            if let range = loopTimeRange {
                // Grip tabs only once the loop is committed/resizable — while
                // drag-selecting, the edges stay plain lines.
                let showsGrips = displayedLoop != nil
                let x0 = xPosition(for: range.lowerBound, visibleStart: visibleStart, visibleEnd: visibleEnd)
                let x1 = xPosition(for: range.upperBound, visibleStart: visibleStart, visibleEnd: visibleEnd)
                Rectangle()
                    .fill(Theme.secondary.opacity(0.16))
                    .overlay(alignment: .leading) { loopEdge(showsGrip: showsGrips).offset(x: -3.5) }
                    .overlay(alignment: .trailing) { loopEdge(showsGrip: showsGrips).offset(x: 3.5) }
                    .frame(width: max(1, max(x0, x1) - min(x0, x1)), height: height)
                    .offset(x: min(x0, x1))
                    .allowsHitTesting(false)
            }

            // During resize, the preview loop is passed in as `displayedLoop`
            // so playback is rebound only once on mouse-up.
            if let loop = displayedLoop {
                resizeHandle(
                    atX: xPosition(for: loop.start, visibleStart: visibleStart, visibleEnd: visibleEnd),
                    isStart: true
                )
                resizeHandle(
                    atX: xPosition(for: loop.end, visibleStart: visibleStart, visibleEnd: visibleEnd),
                    isStart: false
                )
            }
        }
    }

    /// Time span of the rectangle: the drag draft, else the displayed loop.
    private var loopTimeRange: ClosedRange<TimeInterval>? {
        if let draftRange { return draftRange }
        if let displayedLoop { return displayedLoop.start...displayedLoop.end }
        return nil
    }

    private func xPosition(for time: TimeInterval, visibleStart: TimeInterval, visibleEnd: TimeInterval) -> CGFloat {
        CGFloat(
            TransportMapping.normalizedPosition(
                globalTime: time,
                timelineStart: visibleStart,
                timelineEnd: visibleEnd
            )
        ) * waveformWidth
    }

    private func resizeHandle(atX x: CGFloat, isStart: Bool) -> some View {
        let hitWidth: CGFloat = 12
        // Cursor feedback (resizeLeftRight) is handled by the mouse-monitor
        // cursor manager — SwiftUI hover doesn't fire reliably underneath the
        // NSView-based timeline scroll overlay.
        return Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: hitWidth, height: height)
            .contentShape(Rectangle())
            .offset(x: x - hitWidth / 2)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(ContentView.loopColumnSpace))
                    .onChanged { value in
                        onHandleChanged(isStart, value)
                    }
                    .onEnded { value in
                        onHandleEnded(isStart, value)
                    }
            )
    }

    /// Grab handle drawn at each loop edge: a slim accent rod inside a soft
    /// accent halo, plus (once the loop is committed) a centered grip tab with
    /// two engraved notches. Deliberately unlike the flat solid playhead line
    /// and its ruler grabber, so the edges read as draggable resize handles
    /// and stay distinguishable when the playhead sits on top of them.
    private func loopEdge(showsGrip: Bool) -> some View {
        ZStack {
            Capsule()
                .fill(Theme.secondary)
                .shadow(color: Theme.secondary.opacity(0.85), radius: 3)
                .frame(width: 2)

            if showsGrip {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(Theme.secondary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .stroke(.white.opacity(0.35), lineWidth: 0.75)
                    )
                    .overlay(
                        HStack(spacing: 2) {
                            Capsule().frame(width: 1, height: 10)
                            Capsule().frame(width: 1, height: 10)
                        }
                        .foregroundStyle(.black.opacity(0.35))
                    )
                    .frame(width: 9, height: 24)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            }
        }
        .frame(width: 9)
    }
}

/// The rounded index badge: filled with the primary color when the row is
/// active (white number), a neutral fill otherwise (secondary number).
private struct TrackIndexBadgeView: View {
    var index: Int
    var isActive: Bool
    var appearance: IndexBadgeAppearance

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let badge = appearance
        return Text("\(index + 1)")
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .frame(width: 20, height: 20)
            .background {
                shape.fill(isActive ? AnyShapeStyle(Theme.primary) : AnyShapeStyle(Theme.indexBadgeInactiveFill))
            }
            // A crisp beveled rim all around: bright along the top edge fading to a
            // dark bottom edge, so the badge reads as a raised, chiseled button.
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(badge.bevelTopOpacity),
                            .white.opacity(badge.bevelTopOpacity * 0.24),
                            .black.opacity(badge.bevelBottomOpacity)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: badge.bevelWidth
                )
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(badge.shadowOpacity), radius: CGFloat(badge.shadowRadius), y: CGFloat(badge.shadowY))
            .accessibilityHidden(true)
    }
}

/// One track's waveform lane: the peak-envelope Canvas (or the blind-listening
/// placeholder), the major-tick guides, and the 0:00 marker.
///
/// Deliberately a standalone view over plain value inputs, compared with
/// `Equatable` (`.equatable()` at the call site): transport ticks, other
/// tracks' waveform generation progress, and unrelated session changes
/// structurally cannot reach it — SwiftUI skips the body (and the Canvas
/// redraw) unless one of these inputs actually changed. Keep observable
/// objects and closures out of its stored properties.
private struct WaveformLaneView: View, Equatable {
    var width: CGFloat
    /// The waveform to draw, or `nil` while blind listening (so waveform
    /// progress can't leak identity through redraw timing) or before
    /// generation starts.
    var waveform: Waveform?
    var isBlindListening: Bool
    var isActive: Bool
    /// Whether the lane intersects the vertical viewport (± overscan) and may
    /// kick renders; culled lanes keep showing their last image.
    var isRenderable: Bool
    var trackStart: TimeInterval
    var trackDuration: TimeInterval
    var visibleStart: TimeInterval
    var visibleSpan: TimeInterval
    /// Guide x-positions for the ruler's labeled major ticks, computed once by
    /// the parent for all lanes (they share the viewport and width).
    var majorTickXs: [CGFloat]
    var zeroTickX: CGFloat
    var showsDebugLabel: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(.background.opacity(0.01))

            // Faint major-tick guides behind the waveform, aligned with the
            // ruler's labeled ticks above.
            ForEach(Array(majorTickXs.enumerated()), id: \.offset) { _, tickX in
                Rectangle()
                    .fill(Theme.hairline.opacity(0.5))
                    .frame(width: 1)
                    .offset(x: tickX)
                    .accessibilityHidden(true)
            }

            if isBlindListening {
                blindPlaceholderWaveform
                    .frame(width: width, height: 58)
                    .foregroundStyle(isActive ? Theme.primary.opacity(0.70) : Theme.waveformInactive.opacity(0.58))
            } else {
                // The peak envelope is drawn SYNCHRONOUSLY every frame straight
                // from the 5a pyramid (WP-7): the `Canvas` draw closure runs
                // during the frame's render pass, so the correct waveform for the
                // CURRENT window is drawn in the same frame the window changes —
                // no async image pipeline to fall behind, no blank/stale-stretch
                // gap during zoom or scroll.
                waveformContent
                    .frame(width: width, height: 58)
            }

            Rectangle()
                .fill(.secondary.opacity(0.25))
                .frame(width: 1)
                .offset(x: zeroTickX)
        }
        .clipped()
        // Lane visuals must NEVER hit-test: `.clipped()` clips drawing but NOT
        // hit testing, and this subtree is 2× the viewport wide and slid left
        // by up to a viewport width, so it extends invisibly over the
        // track-info column and would swallow its clicks. All lane interaction
        // lives on the loop overlay / scroll overlay.
        .allowsHitTesting(false)
        .componentDebugLabel("Waveform Lane", enabled: showsDebugLabel, color: .purple)
    }

    /// Envelope tint. `isActive` is a color-only distinction, so an A/B switch
    /// only re-tints — the pyramid path build is identical either way.
    private var tint: Color {
        isActive ? Theme.primary.opacity(0.85) : Theme.waveformInactive.opacity(0.7)
    }

    /// The real-waveform branch (never reached while blind). Drawn synchronously
    /// so the current window is always correct; `WaveformLaneView` is equatable
    /// and depends on the window (zoom / grid boundary) but not on
    /// `transportPosition`, so the Canvas redraws exactly when the window or the
    /// waveform changes — not on playback ticks or an intra-window scroll (that
    /// stays a free `.offset` translate in `LaneView`).
    @ViewBuilder
    private var waveformContent: some View {
        if let waveform {
            if !waveform.peaks.isEmpty {
                Canvas { context, size in
                    // Vertical visibility culling (5b): a non-renderable lane
                    // skips the fill entirely. With synchronous drawing, only
                    // lanes inside the vertical viewport (± overscan) do any
                    // path work, so cost scales with visible lanes, not track
                    // count.
                    guard isRenderable else { return }
                    LaneWaveformRenderer.fillEnvelope(
                        in: context,
                        size: size,
                        waveform: waveform,
                        trackStart: trackStart,
                        trackDuration: trackDuration,
                        visibleStart: visibleStart,
                        visibleSpan: visibleSpan,
                        color: tint
                    )
                }
            } else if !waveform.isComplete {
                // Registered but not yet generated (peaks empty, not complete):
                // a static dimmed midline hairline reads as "queued". No
                // animation — continuous motion is CA-only per project rule.
                Rectangle()
                    .fill(tint)
                    .opacity(0.35)
                    .frame(height: 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Completed with no peaks (unreadable file): draw nothing.
                Color.clear
            }
        } else {
            // No waveform registered yet: stay empty so the envelope appears
            // with a clean cut, never a flash.
            Color.clear
        }
    }

    private var blindPlaceholderWaveform: some View {
        Canvas { context, size in
            context.fill(Self.blindPlaceholderWaveformPath(in: size), with: .foreground)
        }
        .accessibilityLabel("Masked waveform")
    }

    private static func blindPlaceholderWaveformPath(in size: CGSize) -> Path {
        guard size.width > 0, size.height > 0 else { return Path() }

        let sampleCount = max(Int(size.width / 6), 12)
        let midline = size.height / 2
        let minHalfHeight: CGFloat = 1.2
        var top: [CGPoint] = []
        top.reserveCapacity(sampleCount + 1)

        for index in 0...sampleCount {
            let t = CGFloat(index) / CGFloat(sampleCount)
            let wave = 0.48
                + 0.24 * sin(t * .pi * 6.0)
                + 0.16 * sin(t * .pi * 17.0 + 0.8)
                + 0.08 * sin(t * .pi * 31.0 + 1.7)
            let envelope = 0.55 + 0.45 * sin(t * .pi)
            let halfHeight = max(minHalfHeight, min(0.92, wave * envelope) * midline)
            top.append(CGPoint(x: t * size.width, y: midline - halfHeight))
        }

        var path = Path()
        guard let first = top.first else { return path }
        path.move(to: first)
        for point in top.dropFirst() {
            path.addLine(to: point)
        }
        for point in top.reversed() {
            path.addLine(to: CGPoint(x: point.x, y: midline + (midline - point.y)))
        }
        path.closeSubpath()
        return path
    }

}

/// Synchronous peak-envelope drawing for a lane. `waveformPath` builds the
/// O(viewport px) filled path from the 5a pyramid; `fillEnvelope` fills it into
/// a `Canvas`'s `GraphicsContext` during the frame's render pass (WP-7 — no
/// async pipeline, no cached `NSImage`).
enum LaneWaveformRenderer {
    #if DEBUG
    private static let renderLog = Logger(subsystem: "com.nigelwarren.Takes", category: "waveform-render")
    #endif

    /// Synchronously fill one lane's peak envelope for the CURRENT window into a
    /// `Canvas` graphics context, tinted by `color`. Called inside the Canvas
    /// draw closure, so the correct waveform is drawn in the same frame the
    /// window changes; path build is O(viewport px) via the pyramid, cheap
    /// enough to run every frame across the (culled) visible lanes.
    static func fillEnvelope(
        in context: GraphicsContext,
        size: CGSize,
        waveform: Waveform,
        trackStart: TimeInterval,
        trackDuration: TimeInterval,
        visibleStart: TimeInterval,
        visibleSpan: TimeInterval,
        color: Color
    ) {
        #if DEBUG
        // Perf probe for the WP-5 pyramid + WP-7 synchronous draw: one
        // debug-level line per lane draw with the wall time of path build +
        // fill. Watch in Console with subsystem com.nigelwarren.Takes, category
        // waveform-render.
        let drawStartedAt = CACurrentMediaTime()
        defer {
            let milliseconds = (CACurrentMediaTime() - drawStartedAt) * 1000
            renderLog.debug("lane draw \(Int(size.width))pt in \(milliseconds, format: .fixed(precision: 2)) ms")
        }
        #endif

        let path = waveformPath(
            for: waveform,
            in: size,
            trackStart: trackStart,
            trackDuration: trackDuration,
            visibleStart: visibleStart,
            visibleSpan: visibleSpan
        )
        if path.isEmpty { return }
        context.fill(path, with: .color(color))
    }

    /// Builds a filled, center-mirrored peak envelope across the visible window.
    ///
    /// The output is always the window width, never the (potentially enormous)
    /// full track width, so the work stays O(window px) regardless of zoom and
    /// a partially generated waveform still fills in left-to-right.
    ///
    /// Buckets are pooled into fixed `[k·stride, (k+1)·stride)` groups anchored
    /// to the *file* (bucket index 0), never to the screen, and each group is
    /// drawn as one vertex at its true sub-pixel x. This is what keeps scrolling
    /// stable: if pooling were aligned to the on-screen pixel grid, then as
    /// playback advances `visibleStart` each frame, every fixed pixel column
    /// would gain/lose a peak bucket at a slightly different moment and the
    /// envelope would shimmer. File-anchored groups have fixed peaks, so a
    /// scroll only slides their x — the shape translates cleanly. `stride` is
    /// chosen so a group is ≈ 1 pixel wide (≥ 1 bucket), preserving transients.
    static func waveformPath(
        for waveform: Waveform,
        in size: CGSize,
        trackStart: TimeInterval,
        trackDuration: TimeInterval,
        visibleStart: TimeInterval,
        visibleSpan: TimeInterval
    ) -> Path {
        let bucketCount = waveform.bucketCount
        guard bucketCount > 0, !waveform.peaks.isEmpty, size.width > 0, size.height > 0,
              trackDuration > 0, visibleSpan > 0 else {
            return Path()
        }

        let width = size.width
        let midline = size.height / 2
        // A visible floor so silent passages still read as a thin line.
        let minHalfHeight: CGFloat = 0.5

        // Portion of the visible window the track actually covers.
        let trackEnd = trackStart + trackDuration
        let overlapStart = max(visibleStart, trackStart)
        let overlapEnd = min(visibleStart + visibleSpan, trackEnd)
        guard overlapEnd > overlapStart else { return Path() }

        // Pick the pyramid level whose buckets-per-pixel lands in [1, 2): each
        // level halves the previous, so walk down until fewer than two of its
        // buckets cover one pixel (or the pyramid runs out). This keeps the
        // build O(viewport px) at ANY zoom — a zoomed-out window pools a few
        // hundred coarse buckets instead of walking every base bucket.
        let bucketsAcrossViewport = visibleSpan / trackDuration * Double(bucketCount)
        var bucketsPerPixel = bucketsAcrossViewport / Double(width)
        var levelIndex = 0
        while bucketsPerPixel >= 2, levelIndex < waveform.reducedLevels.count {
            levelIndex += 1
            bucketsPerPixel /= 2
        }
        // Base buckets per bucket of the chosen level.
        let levelScale = 1 << levelIndex
        let peaks = levelIndex == 0 ? waveform.peaks : waveform.reducedLevels[levelIndex - 1]
        guard !peaks.isEmpty else { return Path() }
        let available = peaks.count
        // ceil(ceil(n/2)/2)… collapses to ceil(n/2^k), so the full-file bucket
        // count at this level is a single ceil-division.
        let levelBucketCount = (bucketCount + levelScale - 1) / levelScale

        // x for a (fractional) BASE bucket index, mapped through the window.
        func x(forBaseBucket bucket: Double) -> CGFloat {
            CGFloat((trackStart + bucket / Double(bucketCount) * trackDuration - visibleStart) / visibleSpan) * width
        }

        // Level buckets per drawn vertex ≈ level buckets per pixel — 1 or 2 by
        // construction while pyramid levels remain.
        let bucketStride = max(1, Int(bucketsPerPixel.rounded()))

        // File-anchored group range overlapping the visible region, padded one
        // group each side so the envelope crosses the clip edges smoothly.
        // Level buckets pool fixed base-bucket ranges, so groups of them are
        // just as file-anchored as base buckets — the anti-shimmer argument
        // above applies unchanged at any level.
        let firstBaseBucket = Int((overlapStart - trackStart) / trackDuration * Double(bucketCount))
        let lastBaseBucket = Int((overlapEnd - trackStart) / trackDuration * Double(bucketCount))
        let firstGroup = firstBaseBucket / (levelScale * bucketStride) - 1
        let lastGroup = lastBaseBucket / (levelScale * bucketStride) + 1

        // (x, half-height) vertices forming the top edge of the envelope.
        var vertices: [(x: CGFloat, half: CGFloat)] = []
        vertices.reserveCapacity(lastGroup - firstGroup + 1)
        for group in firstGroup...lastGroup {
            guard group >= 0 else { continue }
            let bucketLow = group * bucketStride
            guard bucketLow < available else { break }
            let bucketHigh = min(bucketLow + bucketStride, levelBucketCount)
            let upper = min(bucketHigh, available)
            guard upper > bucketLow else { break }

            var peak: Float = 0
            for index in bucketLow..<upper where peaks[index] > peak {
                peak = peaks[index]
            }
            // Vertex at the group's center in base-bucket units; the last
            // level bucket may cover fewer base buckets, so clamp to the file.
            let baseLow = Double(bucketLow * levelScale)
            let baseHigh = min(Double(bucketHigh * levelScale), Double(bucketCount))
            vertices.append((x(forBaseBucket: (baseLow + baseHigh) / 2), max(CGFloat(peak) * midline, minHalfHeight)))
        }

        guard !vertices.isEmpty else { return Path() }

        var path = Path()
        // Top edge, left to right.
        for (index, vertex) in vertices.enumerated() {
            let point = CGPoint(x: vertex.x, y: midline - vertex.half)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        // Bottom edge, right to left, mirroring the top.
        for index in stride(from: vertices.count - 1, through: 0, by: -1) {
            path.addLine(to: CGPoint(x: vertices[index].x, y: midline + vertices[index].half))
        }
        path.closeSubpath()
        return path
    }
}
/// The playhead's visual layer: the grabber and the line, hosted in an AppKit
/// layer tree and moved by ONE `CABasicAnimation` per transport anchor event.
///
/// SwiftUI animations on macOS interpolate on the main thread every frame, so
/// both a `TimelineView`-driven playhead and a SwiftUI-animated offset cost
/// real CPU for the whole duration of playback. A Core Animation position
/// animation runs entirely in the render server: the parent re-evaluates only
/// on observation (play, pause, seek, loop wrap, zoom, scroll, resize),
/// `updateNSView` re-seats the tween, and between those events the app's main
/// thread does zero playhead work. Hit testing is disabled by the caller;
/// interaction lives in the scrub strip.
private struct TimelinePlayheadVisual: NSViewRepresentable {
    var currentX: CGFloat
    var endX: CGFloat
    var remaining: TimeInterval
    var isPlaying: Bool
    var infoWidth: CGFloat
    var sectionHeight: CGFloat
    var waveformWidth: CGFloat
    var seatBottom: CGFloat
    var laneAreaHeight: CGFloat

    func makeNSView(context: Context) -> PlayheadLayerView {
        PlayheadLayerView()
    }

    func updateNSView(_ view: PlayheadLayerView, context: Context) {
        view.apply(
            currentX: currentX,
            endX: endX,
            remaining: remaining,
            isPlaying: isPlaying,
            seatBottom: seatBottom,
            lineHeight: max(min(laneAreaHeight, sectionHeight - seatBottom), 0)
        )
    }
}

/// Layer-backed host for the playhead visuals. The grabber art is the SwiftUI
/// `PlayheadGrabberArt` rasterized once per appearance into the grabber
/// layer's contents, so the art stays identical to the rest of the design
/// system without any per-frame SwiftUI involvement.
final class PlayheadLayerView: NSView {
    /// Zero-size anchor layer that carries the line and grabber; the slide
    /// animation moves only this layer's x position.
    private let carrier = CALayer()
    private let line = CALayer()
    private let grabber = CALayer()

    /// Padding around the rasterized grabber art so its drop shadow isn't
    /// clipped by the image bounds.
    private static let grabberPadding: CGFloat = 4

    /// Inputs of the last `apply`, kept to re-seat after appearance or
    /// geometry changes.
    private var lastCurrentX: CGFloat = 0
    private var lastEndX: CGFloat = 0
    private var lastRemaining: TimeInterval = 0
    private var lastIsPlaying = false
    private var lastSeatBottom: CGFloat = 0
    private var lastLineHeight: CGFloat = 0
    /// Host time the current tween was seated at, so re-seats (appearance or
    /// layout changes mid-playback) can re-derive where the playhead is now.
    private var seatedAt: CFTimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        carrier.anchorPoint = .zero
        carrier.bounds = .zero
        line.anchorPoint = .zero
        grabber.anchorPoint = .zero
        carrier.addSublayer(line)
        carrier.addSublayer(grabber)
        layer?.addSublayer(carrier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// Purely decorative — never intercept clicks meant for the lanes or the
    /// scrub strip. (SwiftUI's `allowsHitTesting(false)` alone does not stop
    /// an AppKit-hosted view from hit-testing.)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(
        currentX: CGFloat,
        endX: CGFloat,
        remaining: TimeInterval,
        isPlaying: Bool,
        seatBottom: CGFloat,
        lineHeight: CGFloat
    ) {
        lastCurrentX = currentX
        lastEndX = endX
        lastRemaining = remaining
        lastIsPlaying = isPlaying
        lastSeatBottom = seatBottom
        lastLineHeight = lineHeight
        seatedAt = CACurrentMediaTime()
        seat()
    }

    private func seat() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        line.frame = CGRect(x: -1, y: lastSeatBottom, width: 2, height: lastLineHeight)
        grabber.frame = CGRect(
            x: -ContentView.playheadHandleWidth / 2 - Self.grabberPadding,
            y: lastSeatBottom - ContentView.playheadHandleHeight - Self.grabberPadding,
            width: ContentView.playheadHandleWidth + Self.grabberPadding * 2,
            height: ContentView.playheadHandleHeight + Self.grabberPadding * 2
        )

        carrier.removeAnimation(forKey: "slide")
        if lastIsPlaying, lastRemaining > 0, lastEndX != lastCurrentX {
            // If this seat is a re-derivation (appearance/layout change mid
            // playback), the playhead has moved since `apply`; start from
            // where it is now.
            let elapsed = CACurrentMediaTime() - seatedAt
            let fraction = min(max(elapsed / lastRemaining, 0), 1)
            let fromX = lastCurrentX + (lastEndX - lastCurrentX) * fraction
            carrier.position = CGPoint(x: lastEndX, y: 0)
            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = fromX
            slide.toValue = lastEndX
            slide.duration = max(lastRemaining - elapsed, 0)
            slide.timingFunction = CAMediaTimingFunction(name: .linear)
            carrier.add(slide, forKey: "slide")
        } else {
            // Whole-pixel position while parked so the 2pt line stays crisp.
            carrier.position = CGPoint(x: lastCurrentX.rounded(), y: 0)
        }

        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearanceDependentContent()
        seat()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshAppearanceDependentContent()
        seat()
    }

    private func refreshAppearanceDependentContent() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            line.backgroundColor = NSColor(Theme.secondary).cgColor
        }

        let renderer = ImageRenderer(
            content: PlayheadGrabberArt()
                .frame(
                    width: ContentView.playheadHandleWidth,
                    height: ContentView.playheadHandleHeight
                )
                .padding(Self.grabberPadding)
                .environment(\.colorScheme, effectiveAppearance.isDark ? .dark : .light)
        )
        renderer.scale = window?.backingScaleFactor ?? 2
        grabber.contents = renderer.cgImage
    }
}

/// GarageBand-style grabber art: a downward pentagon (flat top, straight sides,
/// converging to a small flat tip) with beveled dimension and grip lines.
/// Positioning is applied by the caller; `PlayheadLayerView` rasterizes it
/// into a layer so it never re-renders during playback.
private struct PlayheadGrabberArt: View {
    var body: some View {
        PlayheadHandle(tipWidth: 2)
            .fill(Theme.secondary)
            // Gloss cap over the upper body plus a shadowed taper, the same
            // top-lit treatment as the transport buttons' faces.
            .overlay {
                PlayheadHandle(tipWidth: 2)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.20), location: 0),
                                .init(color: .white.opacity(0.14), location: 0.38),
                                .init(color: .clear, location: 0.55),
                                .init(color: .black.opacity(0.18), location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            // Beveled rim: a bright lit top edge falling into shadow at the
            // tip, mirroring the transport buttons' bevel rings.
            .overlay {
                PlayheadHandle(tipWidth: 2)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.80), .white.opacity(0.12), .black.opacity(0.35)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
            }
            .overlay {
                // Two engraved grip lines: dark grooves with a light catch on
                // their lower lip, cut into the glossy cap.
                HStack(spacing: 3) {
                    Capsule().frame(width: 1, height: 6)
                    Capsule().frame(width: 1, height: 6)
                }
                .foregroundStyle(.black.opacity(0.32))
                .shadow(color: .white.opacity(0.45), radius: 0.2, y: 0.6)
                // Sit the grips in the rectangular upper body, above the tapered tip.
                .offset(y: -1)
            }
            // Slight lift off the ruler, like the raised transport controls.
            .shadow(color: .black.opacity(0.30), radius: 1, y: 0.5)
    }
}
