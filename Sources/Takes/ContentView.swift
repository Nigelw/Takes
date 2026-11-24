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

enum WaveformTrackSelectionPolicy {
    static func trackIndex(atY y: CGFloat, rowStep: CGFloat, trackCount: Int) -> Int? {
        guard trackCount > 0, rowStep > 0, y >= 0 else { return nil }
        let index = Int((y / rowStep).rounded(.down))
        guard index < trackCount else { return nil }
        return index
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

/// Compact compare geometry (A2 §8): a 21 pt ruler with a 1 pt bottom
/// border, then full-width lanes of one fixed height, each carrying a 21 pt
/// info strip at its top and a 1 pt divider at its bottom. Lanes never
/// resize: more than fit the window scroll, fewer leave the well empty below.
enum CompareLaneLayout {
    /// The ruler, above its bottom border.
    /// 21 pt: the 19 pt major notches and a 2 pt margin above them, where
    /// the labels' tops align (was 26 until the labels moved down to the
    /// notch tops).
    static let rulerHeight: CGFloat = 21
    /// The ruler's bottom border, and each lane's bottom divider.
    static let dividerHeight: CGFloat = 1
    /// The ruler's bottom edge, below its border: where the lanes start and
    /// the playhead grabber's tip sits.
    static let seatBottom: CGFloat = rulerHeight + dividerHeight
    /// The info strip overlaid at the top of each lane.
    static let stripHeight: CGFloat = 21
    /// Clearance above and below the waveform in the space under the strip.
    static let waveformVerticalInset: CGFloat = 5
    /// One lane plus its divider. Fixed (milestone 4 review): the height five
    /// versions shared in a 986 pt window with the artwork shown.
    static let laneStep: CGFloat = 96
    /// The drawn lane, without its divider.
    static let laneHeight: CGFloat = laneStep - dividerHeight

    /// Every lane stacked, dividers included.
    static func contentHeight(laneCount: Int) -> CGFloat {
        laneStep * CGFloat(max(laneCount, 0))
    }

    /// The waveform's band in a lane of `laneHeight`: the space under the
    /// strip, inset top and bottom, so the waveform is centred beneath it.
    static func waveformBand(laneHeight: CGFloat = laneHeight) -> (minY: CGFloat, height: CGFloat) {
        let below = max(laneHeight - stripHeight, 0)
        let inset = min(waveformVerticalInset, below / 2)
        return (stripHeight + inset, below - inset * 2)
    }

    /// The lane strip's frame height: everything from the lane's top (the
    /// divider above it) down to the waveform band, so the strip's contents
    /// sit centred between the two (milestone 4 review).
    static var stripFrameHeight: CGFloat { waveformBand().minY }
}

// MARK: - Compare info bar

/// The compare info bar (A2 compare info-bar variant §2): 32 pt between
/// the control bar's divider and the ruler, on the well with no line to the
/// ruler. The take count on the left, the elapsed time centred in the
/// window, Done on the right.
///
/// The bar's own body reads nothing from the controller. The count and the
/// time are leaves: the count re-renders when the session changes, the time
/// (`ControlBarElapsedDigits`) once per displayed second.
struct CompareInfoBar: View {
    let controller: PlaybackController
    let done: () -> Void

    var body: some View {
        CompareInfoBarRow {
            CompareTakeCount(controller: controller)
            CompareInfoBarTime(controller: controller)
            Button("Done", action: done)
                .buttonStyle(CompareDoneButtonStyle())
                .help("Back to Playlist")
                .accessibilityLabel("Back to Playlist")
        }
        .padding(.horizontal, CompareInfoBarMetrics.edgeInset)
        .frame(height: CompareInfoBarMetrics.height)
        .frame(maxWidth: .infinity)
    }
}

enum CompareInfoBarMetrics {
    static let height: CGFloat = 32
    static let edgeInset: CGFloat = 10
}

enum CompareInfoBarText {
    /// `3 takes`; `1 take` (removal can leave compare with one version).
    /// Unchanged in Blind Listening Mode: the count reveals nothing.
    static func takeCount(_ count: Int) -> String {
        count == 1 ? "1 take" : "\(count) takes"
    }
}

/// The take count: one style, 12 pt medium secondary, tail-truncated if it
/// ever meets the time.
private struct CompareTakeCount: View {
    let controller: PlaybackController

    var body: some View {
        Text(CompareInfoBarText.takeCount(controller.displayedTrackRowCount))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// The info bar's three columns: the centre at its natural width, centred
/// in the bar whatever the sides hold; the sides each get the equal width
/// left beside it, the first leading-aligned and the last trailing-aligned.
/// Expects three subviews.
struct CompareInfoBarRow: Layout {
    static let columnSpacing: CGFloat = 8

    /// The width each side column may take beside a centre of `centerWidth`.
    static func sideWidth(barWidth: CGFloat, centerWidth: CGFloat) -> CGFloat {
        max((barWidth - centerWidth) / 2 - columnSpacing, 0)
    }

    static func centerWidth(barWidth: CGFloat, sideWidth: CGFloat) -> CGFloat {
        max(barWidth - 2 * (sideWidth + columnSpacing), 0)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(
            width: proposal.width ?? sizes[1].width + 2 * (max(sizes[0].width, sizes[2].width) + Self.columnSpacing),
            height: proposal.height ?? sizes.map(\.height).max() ?? 0
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let sideWidth = max(subviews[0].sizeThatFits(.unspecified).width, subviews[2].sizeThatFits(.unspecified).width)
        let centerProposal = ProposedViewSize(
            width: Self.centerWidth(barWidth: bounds.width, sideWidth: sideWidth), height: bounds.height
        )
        let center = subviews[1].sizeThatFits(centerProposal)
        let side = ProposedViewSize(
            width: Self.sideWidth(barWidth: bounds.width, centerWidth: center.width),
            height: bounds.height
        )
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: side)
        subviews[1].place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: centerProposal)
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: side)
    }
}

/// Done (§2.3): a rectangular button, not a pill. 22 pt tall, 5 pt radius,
/// 12 pt horizontal padding, 12 pt semibold white on the primary fill (the
/// light primary in light appearance), with a faint top highlight and a
/// small drop shadow, the canvas's values. Built by hand because
/// `.borderedProminent` follows the system accent and sizes differently.
///
/// Pressed, it sinks into the bar as Play does (`CircleTransportButtonStyle`):
/// a dark inner shadow falls across the top of the face, the rim inverts
/// (dark top edge), the drop shadow goes, the label drops half a point, and
/// the face darkens.
struct CompareDoneButtonStyle: ButtonStyle {
    static let height: CGFloat = 22
    static let cornerRadius: CGFloat = 5
    static let horizontalPadding: CGFloat = 12
    /// Play's pressed inner shadow, scaled from its 56 pt face to 22 pt.
    static let pressedInnerShadowRadius: CGFloat = 1.5
    static let pressedInnerShadowY: CGFloat = 1
    static let pressedLabelOffset: CGFloat = 0.5

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        return configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .offset(y: pressed ? Self.pressedLabelOffset : 0)
            .padding(.horizontal, Self.horizontalPadding)
            .frame(height: Self.height)
            .background {
                shape
                    .fill(face(pressed: pressed))
                    // Canvas: inset 0 0.5px 0 rgba(255,255,255,0.3). Pressed,
                    // the lit top edge becomes a shadowed one.
                    .overlay {
                        shape.strokeBorder(
                            LinearGradient(
                                stops: [
                                    .init(color: pressed ? .black.opacity(0.3) : .white.opacity(0.3), location: 0),
                                    .init(color: .clear, location: 0.12)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                    }
                    // Canvas: 0 0.5px 1.5px rgba(0,0,0,0.5); lighter on the
                    // pale light-appearance well. Gone while pressed: the
                    // button sits in the bar instead of on it.
                    .shadow(color: .black.opacity(pressed ? 0 : (colorScheme == .dark ? 0.5 : 0.25)),
                            radius: 0.75, y: 0.5)
            }
            .brightness(pressed ? -0.10 : 0)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.5)
    }

    /// The primary fill, with Play's dark inner shadow from the top while
    /// pressed (its opacities: 0.80 light, 0.55 dark).
    private func face(pressed: Bool) -> AnyShapeStyle {
        guard pressed else { return AnyShapeStyle(Theme.primary) }
        return AnyShapeStyle(Theme.primary.shadow(.inner(
            color: .black.opacity(colorScheme == .dark ? 0.55 : 0.80),
            radius: Self.pressedInnerShadowRadius,
            y: Self.pressedInnerShadowY
        )))
    }
}

/// The ruler's notches and labels (A2 §8, v2.9.0's arrangement at 21 pt):
/// notches hang from the bottom edge, and each label sits 4 pt right of its
/// major notch (`TimelineHeaderLabelLayout.leading`) with its digits' tops
/// level with the notch's top. The playhead grabber overlaps the labels; that
/// is accepted (it replaced the info-bar variant's §3 rule, which kept them
/// clear of it on a 26 pt ruler).
enum TimelineRulerMetrics {
    /// v2.9.0's notch heights.
    static let majorTickHeight: CGFloat = 19
    static let minorTickHeight: CGFloat = 8
    static let labelFontSize: CGFloat = 10
    /// The label's line: its frame height, tighter than the type's natural
    /// line height, as on the canvas (10 pt type on a 10 pt line).
    static let labelHeight: CGFloat = 10
    static var labelFont: Font { .system(size: labelFontSize).monospacedDigit() }

    /// Where a major notch's top, and so its label's digits' tops, sit.
    static var majorTickTop: CGFloat { CompareLaneLayout.rulerHeight - majorTickHeight }

    /// The label line's top inset, chosen so the digits' tops (the font's
    /// cap height) land on `majorTickTop` (about 0.5 pt).
    static let labelTopInset: CGFloat = majorTickTop - labelGlyphBand(topInset: 0).lowerBound

    /// The glyph band of a label, in ruler coordinates: the font's natural
    /// line centred on the `labelHeight` line, from the cap height down to
    /// the baseline (the labels are digits and colons: no descenders).
    static func labelGlyphBand(
        topInset: CGFloat = labelTopInset,
        font: NSFont = .systemFont(ofSize: labelFontSize)
    ) -> ClosedRange<CGFloat> {
        let naturalLine = font.ascender - font.descender + font.leading
        let baseline = topInset + (labelHeight - naturalLine) / 2 + font.ascender
        return (baseline - font.capHeight)...baseline
    }

    /// A 1 pt notch at `x`, hanging from the ruler's bottom edge.
    static func tickFrame(x: CGFloat, height: CGFloat, rulerHeight: CGFloat = CompareLaneLayout.rulerHeight) -> CGRect {
        CGRect(x: x, y: rulerHeight - height, width: 1, height: height)
    }

    /// Where a major notch's label starts.
    static func labelOrigin(tickX: CGFloat, rulerWidth: CGFloat) -> CGPoint? {
        let layout = TimelineHeaderLabelLayout.leading(tickX: Double(tickX), rulerWidth: Double(rulerWidth))
        return layout.isVisible ? CGPoint(x: layout.x, y: labelTopInset) : nil
    }
}

/// v2.9.0's playhead: a 2 pt line from the ruler's bottom edge down through
/// the lanes, and a 14 × 16 pt grabber whose tip sits on that edge. Frames are
/// relative to the carrier layer, whose x is the playhead position.
enum PlayheadGeometry {
    static let handleWidth: CGFloat = 14
    static let handleHeight: CGFloat = 16
    static let lineWidth: CGFloat = 2

    /// The line, in the lanes' scroll content: from its top (the ruler's
    /// bottom edge) down through every lane.
    static func lineFrame(lineHeight: CGFloat) -> CGRect {
        CGRect(x: -lineWidth / 2, y: 0, width: lineWidth, height: max(lineHeight, 0))
    }

    /// The grabber art's frame, padded by `padding` on every side for its
    /// shadow; the unpadded art ends exactly at `seatBottom`.
    static func grabberFrame(seatBottom: CGFloat, padding: CGFloat) -> CGRect {
        CGRect(
            x: -handleWidth / 2 - padding,
            y: seatBottom - handleHeight - padding,
            width: handleWidth + padding * 2,
            height: handleHeight + padding * 2
        )
    }
}

enum TimelineLaneDragMode: Equatable {
    case playhead
    case loopSelection
}

struct TimelineLaneGesturePolicy {
    static func dragMode(startX: CGFloat, playheadX: CGFloat, playheadHitWidth: CGFloat) -> TimelineLaneDragMode {
        abs(startX - playheadX) <= playheadHitWidth / 2 ? .playhead : .loopSelection
    }
}

enum TrackDropHighlight: Equatable {
    case normal
    case dropTarget

    static func empty(isTargeted: Bool) -> TrackDropHighlight {
        isTargeted ? .dropTarget : .normal
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
    let reorderVersion: (UUID, UUID?) -> Void

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
            reorderVersion(draggingID, nil)
        case .before(let destinationIndex):
            let destinationID = tracks.indices.contains(destinationIndex) ? tracks[destinationIndex].id : nil
            reorderVersion(draggingID, destinationID)
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

/// The lane strip's context menu (A2 milestone 4), acting on the clicked lane
/// rather than the active one.
struct LaneStripMenuActions {
    var isBlind: Bool
    var hasOffset: Bool
    /// The version's file can't be found: Locate File… replaces nothing, it
    /// is added, and Reveal in Finder turns off.
    var isMissing = false
    var remove: () -> Void
    var revealInFinder: () -> Void
    var resetOffset: () -> Void
    var locate: () -> Void = {}

    /// Reveal in Finder would show the file's name, so blind listening turns
    /// it off; a missing file has nothing to reveal.
    var canRevealInFinder: Bool { !isBlind && !isMissing }
}

/// AppKit-backed drag source for a lane. SwiftUI's `onDrag` can't express a
/// move-inside / copy-outside operation, so the lane's drag is run here as an
/// `NSDraggingSession`: **move** (reorder) within the app, **copy** the audio file
/// out to Finder / other apps / another Takes window, and **cancel** on the menu
/// bar or any non-target. A plain click (no drag) selects the lane; a right-click
/// opens the lane's context menu.
///
/// Placed behind the lane strip's badge, title and format, which forward their
/// clicks here. The rest of the strip passes clicks through to the lane's seek
/// and loop gestures.
struct TrackRowDragSource: NSViewRepresentable {
    let fileURL: URL
    let trackID: SessionTrack.ID
    let toolTip: String?
    let menuActions: LaneStripMenuActions
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
        nsView.toolTip = toolTip
        nsView.menuActions = menuActions
        nsView.onSelect = onSelect
        nsView.onDragBegan = onDragBegan
        nsView.onDragEnded = onDragEnded
        nsView.makeDragImage = makeDragImage
    }
}

final class DragSourceNSView: NSView, NSDraggingSource {
    var fileURL: URL?
    var trackID: SessionTrack.ID?
    var menuActions: LaneStripMenuActions?
    var onSelect: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var makeDragImage: (() -> NSImage?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let actions = menuActions else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(title: "Remove Version", action: actions.remove))
        menu.addItem(.separator())
        if actions.isMissing {
            menu.addItem(ClosureMenuItem(title: "Locate File…", action: actions.locate))
        }
        menu.addItem(ClosureMenuItem(
            title: "Reveal in Finder",
            isEnabled: actions.canRevealInFinder,
            action: actions.revealInFinder
        ))
        menu.addItem(ClosureMenuItem(title: "Reset Offset", isEnabled: actions.hasOffset, action: actions.resetOffset))
        return menu
    }

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

/// A menu item that runs a closure, for menus built on the fly.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, isEnabled: Bool = true, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(runHandler), keyEquivalent: "")
        target = self
        self.isEnabled = isEnabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func runHandler() {
        handler()
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

@MainActor
final class OpenFileCommandState: ObservableObject {
    @Published var isImportingTracks = false
    @Published var isPromptingForStreamingURL = false
    @Published var streamingURLText = ""
    @Published var streamingURLStatus: StreamingURLPromptStatus = .idle

    private var streamingURLTask: Task<Void, Never>?
    private var streamingURLTaskID: UUID?

    var captureDestination: () -> PlaylistImportDestination = { .playlist }
    private(set) var importDestination: PlaylistImportDestination = .playlist
    private(set) var streamingDestination: PlaylistImportDestination = .playlist

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
        importDestination = captureDestination()
        isImportingTracks = true
    }

    func dismissOpenDialog() {
        isImportingTracks = false
    }

    func presentStreamingURLPrompt() {
        streamingDestination = captureDestination()
        cancelStreamingURLTask()
        streamingURLText = ""
        streamingURLStatus = .idle
        isPromptingForStreamingURL = true
    }

    func openStreamingURL(_ urlString: String) {
        streamingDestination = captureDestination()
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

    func isCurrentStreamingURLTask(_ id: UUID) -> Bool {
        streamingURLTaskID == id
    }

    func updateStreamingURLStatus(_ status: StreamingURLPromptStatus, id: UUID) {
        guard streamingURLTaskID == id else { return }
        streamingURLStatus = status
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
    let visibility: WorkspaceVisibility
    let toggleVisibility: @MainActor (WorkspaceVisibility.Region) -> Void
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
    let coordinator: PlaylistCoordinator
    private let importProviders: ([NSItemProvider]) -> Bool
    /// Opens the Locate dialog for a missing version (the playlist's, so
    /// both modes share one dialog).
    private let locateVersion: (PlaylistVersion.ID) -> Void
    var controller: PlaybackController { coordinator.controller }
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var settings: AppSettings

    @ObservedObject private var openFileCommandState: OpenFileCommandState
    @StateObject private var waveformStore = WaveformStore()
    @State private var mouseMonitor: MouseMonitor?
    /// While a playhead drag is in flight: the preview's x across the lanes.
    /// `nil` when not dragging.
    @State private var playheadDragX: CGFloat?
    /// The lane-wide gesture chooses playhead or loop behavior once at
    /// mouse-down, then keeps that mode for the full drag.
    @State private var laneDragMode: TimelineLaneDragMode?
    /// Timeline frame and lane step, captured for the mouse-monitor cursor
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
    @State private var focusedOffsetTrackID: SessionTrack.ID?
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
    @State private var controlBarHeight: CGFloat = TakesWindowPolicy.controlBarReservedHeight - ControlBarDivider.height

    /// An in-progress loop drag, in absolute seconds. `start` is where the drag
    /// began; `current` tracks the pointer. Committed to a `LoopRegion` on mouse-up.
    private struct LoopDraft {
        var start: TimeInterval
        var current: TimeInterval
    }

    /// Coordinate space for the lanes, so loop gestures report x in
    /// `0...waveformWidth`. (`fileprivate` so the loop overlay leaf's handle
    /// gestures can name the same space.)
    fileprivate static let loopColumnSpace = "loopColumn"
    /// Coordinate space for the timeline ruler, so ruler gestures report x in
    /// `0...waveformWidth` just like the lanes.
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
    /// Horizontal travel (points) that turns a click into a loop drag.
    private static let loopDragThreshold: CGFloat = 4

    init(
        coordinator: PlaylistCoordinator,
        openFileCommandState: OpenFileCommandState,
        importProviders: @escaping ([NSItemProvider]) -> Bool,
        locateVersion: @escaping (PlaylistVersion.ID) -> Void = { _ in }
    ) {
        self.coordinator = coordinator
        self.openFileCommandState = openFileCommandState
        self.importProviders = importProviders
        self.locateVersion = locateVersion
    }

    var body: some View {
        inactiveAwareContent
            .frame(minWidth: TakesWindowPolicy.minimumWidth)
            .environment(\.transportAppearance, settings.transportAppearance)
            .background(WindowBackground().ignoresSafeArea())
            .background {
                MainWindowConfigurationView { window in
                    mainWindow = window
                    mainWindowIsKey = window.isKeyWindow
                }
            }
            .overlay {
                if !mainWindowIsKey {
                    InactiveWindowInteractionShield(window: mainWindow)
                        .ignoresSafeArea()
                }
            }
            .onAppear {
                setupMouseMonitor()
                waveformStore.sync(tracks: controller.session.tracks, context: controller.runtimeContext)
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
                waveformStore.sync(tracks: tracks, context: controller.runtimeContext)
            }
            .onChange(of: controller.runtimeContext) { _, _ in
                waveformStore.sync(tracks: controller.session.tracks, context: controller.runtimeContext)
            }
            .onDisappear {
                waveformStore.sync(tracks: [], context: nil)
                mouseMonitor?.stop()
            }
    }

    private var inactiveAwareContent: some View {
        contentStack
            .windowActivityAppearance(isActive: mainWindowIsKey)
            // Draw the import highlight after the inactive-window treatment so drag
            // hover stays vivid even while the window is in the background.
            .overlay {
                if settings.windowVisibility.showsPlaylist { trackDropHighlightOverlay }
            }
    }

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            if settings.windowVisibility.showsPlayer {
                controlBar
            }
            if settings.windowVisibility.showsPlaylist {
                ControlBarDivider()
                VStack(spacing: 0) {
                    CompareInfoBar(controller: controller) {
                        Task { await coordinator.backToPlaylist() }
                    }
                    .componentDebugLabel("Info Bar", enabled: settings.showsComponentDebugLabels)
                    trackTimelineSection
                        .frame(maxHeight: .infinity)
                }
                .background(Theme.timelineWellShade)
                CompareBottomBar(coordinator: coordinator, openFiles: openFileCommandState)
                    .componentDebugLabel("Bottom Bar", enabled: settings.showsComponentDebugLabels)
            }
        }
    }

    private var trackDropHighlightOverlay: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(
                    height: (settings.windowVisibility.showsPlayer ? controlBarHeight : 0)
                        + ControlBarDivider.height + CompareInfoBarMetrics.height
                        + (controller.displayedTrackRowCount == 0 ? 0 : CompareLaneLayout.seatBottom)
                )
            trackAreaImportHighlight(isTargeted: windowIsDropTargeted)
            // The highlight stops at the bottom bar.
            Color.clear
                .frame(height: BottomBarMetrics.height)
        }
        .allowsHitTesting(false)
    }

    /// Compare control bar (spec §5.1): Blind · Play · Switch Track · Repeat,
    /// with no readout. The elapsed time and Done are in the info bar below
    /// the divider (A2 compare info-bar variant).
    private var controlBar: some View {
        let buttons = CompareTransportButtons(coordinator: coordinator, showsDebugLabels: settings.showsComponentDebugLabels)
        return ControlBarLayout {
            buttons.blindListening
        } center: {
            buttons.center()
        } trailing: {
            buttons.repeatMode
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if abs(height - controlBarHeight) > 0.5 { controlBarHeight = height }
        }
        .componentDebugLabel("Control Bar", enabled: settings.showsComponentDebugLabels)
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

    private var timelineHeaderTargetMarkerCount: Int {
        7
    }

    /// Minimum on-screen spacing (points) between minor ticks before they are hidden.
    private var timelineHeaderMinorTickMinSpacing: Double {
        7
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

    /// The compact compare area (A2 §8): the 26 pt ruler, then full-width
    /// lanes of a fixed height (`CompareLaneLayout.laneStep`) that scroll when
    /// they don't fit.
    ///
    /// The lanes' scroll content has four layers, back to front: the lane
    /// visuals (`TrackRowView`), the seek / loop gesture surface with the loop
    /// selection, the playhead line, and the lane strips (`LaneStripView`).
    /// The strips sit on top so they draw over the playhead line, and so their
    /// badge, title and format (drag source and context menu) and their offset
    /// field take clicks; the rest of a strip passes clicks through to the
    /// lane gestures beneath it. Both per-lane layers are equatable values
    /// with no per-scroll or per-zoom inputs. The playhead's grabber stays on
    /// the ruler, in an overlay above the section.
    private var trackTimelineSection: some View {
        GeometryReader { proxy in
            let waveformWidth = max(proxy.size.width, 1)
            let displayedTrackRowCount = controller.displayedTrackRowCount
            let laneStep = CompareLaneLayout.laneStep
            let contentHeight = CompareLaneLayout.contentHeight(laneCount: displayedTrackRowCount)
            VStack(alignment: .leading, spacing: 0) {
                if displayedTrackRowCount == 0 {
                    // The empty state owns the whole section — no ruler —
                    // one centered drop/click target.
                    trackAreaEmptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    timelineRuler(waveformWidth: waveformWidth)
                        .frame(width: proxy.size.width, height: CompareLaneLayout.rulerHeight)
                    laneDivider

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
                                    trackRowView(
                                        index: index,
                                        sessionTrack: sessionTrack,
                                        laneHeight: CompareLaneLayout.laneHeight,
                                        wideWidth: wideWidth
                                    )
                                        .equatable()
                                        .modifier(reorderPlacement(index: index, trackID: sessionTrack.id, rowStep: laneStep))
                                    laneDivider
                                        .modifier(reorderPlacement(index: index, trackID: nil, rowStep: laneStep))
                                }
                            }
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: coordinator.rowMoveRevision)
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
                                loopSelectionOverlay(waveformWidth: waveformWidth, contentHeight: contentHeight)
                                // Behind the strips, so their badges, titles
                                // and offset fields draw over it.
                                timelinePlayhead(.line, waveformWidth: waveformWidth, height: contentHeight)
                            }

                            VStack(spacing: 0) {
                                ForEach(Array(controller.session.tracks.enumerated()), id: \.element.id) { index, sessionTrack in
                                    laneStripView(index: index, sessionTrack: sessionTrack)
                                        .equatable()
                                        .frame(height: laneStep, alignment: .top)
                                        .modifier(reorderPlacement(index: index, trackID: sessionTrack.id, rowStep: laneStep))
                                }
                            }
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: coordinator.rowMoveRevision)
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
                                    viewportHeight: max(proxy.size.height - CompareLaneLayout.seatBottom, 0),
                                    rowStep: laneStep
                                )
                                Color.clear
                                    .onChange(of: range, initial: true) { _, newRange in
                                        if renderableRows != newRange {
                                            renderableRows = newRange
                                        }
                                    }
                            }
                        )
                        // One drop target spanning the lanes, taking reorders and
                        // external file drops. For reorders it opens the gap as the
                        // pointer moves and commits on drop. A single target (rather
                        // than per-lane) keeps the target slot stable while the lanes
                        // shift, and lets the enclosing NSScrollView auto-scroll.
                        .onDrop(
                            of: TrackRowDropTarget.acceptedContentTypeIdentifiers,
                            delegate: TrackListDropDelegate(
                                controller: controller,
                                rowStep: laneStep,
                                draggingID: $reorderDraggingID,
                                targetIndex: $reorderTargetIndex,
                                gapGeneration: $reorderGapGeneration,
                                revealingID: $reorderRevealingID,
                                isImportTargeted: $windowIsDropTargeted,
                                loadDroppedURLs: importProviders,
                                reorderVersion: { coordinator.reorderVersion($0, before: $1, undoManager: undoManager) }
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
                    TimelineScrollOverlayLeaf(
                        controller: controller,
                        onScroll: handleTimelineScroll,
                        onScrollGestureEnded: {},
                        onMagnify: handleTimelineMagnify
                    )
                        .frame(width: waveformWidth, height: proxy.size.height)
                }
            }
            // The grabber sits on the ruler's bottom edge, above everything.
            .overlay(alignment: .topLeading) {
                if controller.session.isPlayable {
                    timelinePlayhead(.grabber, waveformWidth: waveformWidth, height: proxy.size.height)
                }
            }
            // Keep the mouse-monitor cursor manager's picture of the timeline
            // geometry current (window resize, lane count, scrolling).
            .onChange(
                of: TimelineCursorGeometry(
                    sectionFrame: proxy.frame(in: .global),
                    waveformWidth: waveformWidth
                ),
                initial: true
            ) { _, geometry in
                timelineCursorGeometry = geometry
            }
        }
    }

    /// The ruler's bottom border and each lane's bottom divider (A2 §8).
    private var laneDivider: some View {
        Rectangle()
            .fill(Theme.laneDivider)
            .frame(height: CompareLaneLayout.dividerHeight)
            .allowsHitTesting(false)
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
    private func reorderRowOffset(index: Int, rowStep: CGFloat) -> CGFloat {
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
            rowStep: rowStep
        )
    }

    /// A lane's reorder placement, shared by its visual layer and its strip so
    /// both move together. `trackID` is nil for the divider, which shifts with
    /// its lane but is never hidden.
    private func reorderPlacement(index: Int, trackID: SessionTrack.ID?, rowStep: CGFloat) -> ReorderPlacement {
        ReorderPlacement(
            isLifted: trackID != nil && (reorderDraggingID == trackID || reorderRevealingID == trackID),
            offsetY: reorderRowOffset(index: index, rowStep: rowStep),
            gapGeneration: reorderGapGeneration
        )
    }

    /// The 26 pt ruler (A2 §8), full width. Dragging anywhere on it moves the
    /// playhead: the visual follows the pointer and the transport seeks once
    /// on mouse-up (no live scrubbing mid-drag). The same drag logic also
    /// powers the narrow playhead band over the lanes; loop selection stays
    /// lane-only.
    private func timelineRuler(waveformWidth: CGFloat) -> some View {
        TimelineHeaderRulerView(
            controller: controller,
            width: waveformWidth,
            targetMarkerCount: timelineHeaderTargetMarkerCount,
            minorTickMinSpacing: timelineHeaderMinorTickMinSpacing,
            headerHeight: CompareLaneLayout.rulerHeight
        )
            .contentShape(Rectangle())
            .gesture(playheadDragGesture(waveformWidth: waveformWidth, in: Self.rulerSpace))
            .coordinateSpace(name: Self.rulerSpace)
            .componentDebugLabel("Timeline Ruler", enabled: settings.showsComponentDebugLabels, color: .orange)
            // Hide a notch on the window's edge, as the lanes hide their
            // guides there; the label beside it stays.
            .mask(TimelineLeadingEdgeMask())
    }

    /// One part of the playhead. The grabber sits on the ruler's bottom edge
    /// in an overlay above the whole section; the line runs down through the
    /// lanes inside their scroll content, beneath the lane strips, so the
    /// strips draw over it. Both parts take the same inputs from the same
    /// update, so they seat their tweens together.
    ///
    /// Visuals only: each part's layers are moved by a single Core Animation
    /// linear tween per transport anchor event (play, pause, seek, loop wrap,
    /// zoom, scroll, resize) — see `TimelinePlayheadVisual` — so steady
    /// playback does no per-frame main-thread work at all. Interaction lives
    /// on the ruler and the lane drag strip (`playheadDragGesture`); cursor
    /// feedback lives in the central mouse-monitor cursor manager.
    ///
    /// While a playhead drag is in flight (`playheadDragX != nil`) the
    /// playhead parks at the pointer as a preview; the transport itself
    /// doesn't move (and audio keeps playing from the old position) until
    /// mouse-up.
    private func timelinePlayhead(_ part: PlayheadPart, waveformWidth: CGFloat, height: CGFloat) -> some View {
        // The x-positioning lives in a leaf that alone reads the per-event
        // transport/window state, so a scroll or anchor event re-runs only
        // the leaf (one representable update), not this section body.
        TimelinePlayheadOverlayView(
            controller: controller,
            part: part,
            playheadDragX: playheadDragX,
            waveformWidth: waveformWidth,
            height: height
        )
        // Clipped by the layer view's masksToBounds, so a position off
        // either edge never draws.
        .frame(width: waveformWidth, height: height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// Comfortable ruler grab target a bit wider than the visible grabber.
    private static let rulerPlayheadHitWidth: CGFloat = 22
    /// Match the loop edge resize handles in the waveform lanes.
    private static let lanePlayheadHitWidth: CGFloat = 12

    /// Drag the playhead from a gesture surface in waveform coordinates. The
    /// visual follows the pointer as a preview; the seek happens once on
    /// mouse-up, so nothing scrubs live mid-drag. A plain click behaves like
    /// the lane click: deselect the loop when it lands outside it, then seek.
    private func playheadDragGesture(waveformWidth: CGFloat, in space: String) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { value in
                handlePlayheadDragChanged(value: value, waveformWidth: waveformWidth)
            }
            .onEnded { value in
                handlePlayheadDragEnded(value: value, waveformWidth: waveformWidth)
            }
    }

    private func handlePlayheadDragChanged(value: DragGesture.Value, waveformWidth: CGFloat) {
        if playheadDragX == nil {
            NSCursor.closedHand.set()
        }
        playheadDragX = clampedPlayheadDragX(value.location.x, waveformWidth: waveformWidth)
    }

    private func handlePlayheadDragEnded(value: DragGesture.Value, waveformWidth: CGFloat) {
        playheadDragX = nil
        commitPlayheadDrag(atX: value.location.x, waveformWidth: waveformWidth)
        // The playhead now sits under the pointer, so the grab cursor is the
        // right resting state. Record it centrally so the next pointer move
        // can reset it if the pointer is no longer on the grabber.
        timelineCursorShape = .playheadGrab
        NSCursor.openHand.set()
    }

    private func clampedPlayheadDragX(_ x: CGFloat, waveformWidth: CGFloat) -> CGFloat {
        min(max(x, 0), waveformWidth)
    }

    private func commitPlayheadDrag(atX x: CGFloat, waveformWidth: CGFloat) {
        let clampedX = clampedPlayheadDragX(x, waveformWidth: waveformWidth)
        let time = globalTime(atX: clampedX, width: waveformWidth)
        if let loop = controller.session.loopRegion, time < loop.start || time > loop.end {
            controller.deselectLoop()
        }
        controller.seek(to: time)
    }

    /// Build the value for one equatable lane. All observable reads
    /// (`controller.session`, `waveformStore`, `settings`) happen here in the
    /// container so the lane itself stays a pure value: a zoom step or a
    /// reorder gap move re-runs this cheap builder + an `==` check per lane, but
    /// never re-runs a lane's body unless one of its compared inputs changed.
    private func trackRowView(
        index: Int,
        sessionTrack: SessionTrack,
        laneHeight: CGFloat,
        wideWidth: CGFloat
    ) -> TrackRowView {
        let isBlind = controller.session.isBlindListeningModeEnabled
        return TrackRowView(
            trackStart: sessionTrack.loadedTrack.offsetSeconds,
            trackDuration: sessionTrack.loadedTrack.duration,
            // Blind listening feeds the lane a nil waveform so progress can't
            // leak identity through redraw timing (an invariant).
            waveform: isBlind ? nil : waveformStore.waveform(for: sessionTrack.id),
            isActive: controller.session.activeTrackID == sessionTrack.id,
            isBlind: isBlind,
            isMissing: sessionTrack.loadedTrack.isMissing,
            isRenderable: renderableRows.contains(index),
            laneHeight: laneHeight,
            wideWidth: wideWidth,
            showsDebugLabel: settings.showsComponentDebugLabels,
            controller: controller,
            viewportStore: laneViewportStore
        )
    }

    /// Build the value for one equatable lane strip, the same way as
    /// `trackRowView`: observable reads here, a pure value out.
    private func laneStripView(index: Int, sessionTrack: SessionTrack) -> LaneStripView {
        let track = sessionTrack.loadedTrack
        let trackID = sessionTrack.id
        let isBlind = controller.session.isBlindListeningModeEnabled
        let offsetMs = Int((track.offsetSeconds * 1000).rounded())
        let format = LaneStripText.format(for: track, isBlind: isBlind, fields: settings.compareMetadataFields)
        return LaneStripView(
            index: index,
            trackID: trackID,
            fileURL: track.url,
            name: LaneStripText.name(for: track, index: index, isBlind: isBlind),
            format: format,
            toolTip: LaneStripText.toolTip(for: track, isBlind: isBlind, format: format),
            offsetMs: offsetMs,
            isActive: controller.session.activeTrackID == trackID,
            isBlind: isBlind,
            isMissing: track.isMissing,
            isOffsetFocused: focusedOffsetTrackID == trackID,
            offsetConfiguration: settings.offsetConfiguration,
            indexBadgeAppearance: settings.indexBadgeAppearance,
            showsDebugLabel: settings.showsComponentDebugLabels,
            menuActions: LaneStripMenuActions(
                isBlind: isBlind,
                hasOffset: offsetMs != 0,
                isMissing: track.isMissing,
                remove: { _ = coordinator.removeVersion(trackID, undoManager: undoManager) },
                revealInFinder: { NSWorkspace.shared.activateFileViewerSelecting([track.url]) },
                resetOffset: { coordinator.setOffset(trackID, seconds: 0) },
                locate: { locateVersion(trackID) }
            ),
            onSelect: { controller.selectActiveTrack(trackID) },
            onSetOffsetMs: { coordinator.setOffset(trackID, seconds: Double($0) / 1000) },
            onOffsetFocusChange: { focused in
                if focused {
                    focusedOffsetTrackID = trackID
                } else if focusedOffsetTrackID == trackID {
                    focusedOffsetTrackID = nil
                }
            },
            onDragBegan: {
                reorderDraggingID = trackID
            },
            onDragEnded: {
                // A committed reorder has already moved the lane into the reveal
                // phase via the drop delegate; a cancelled or copied-out drag
                // reveals in place the same way.
                if let draggingID = reorderDraggingID {
                    reorderRevealingID = draggingID
                    reorderDraggingID = nil
                }
                reorderTargetIndex = nil
                // Next tick: the (possibly reordered) layout has landed
                // unanimated, so only the opacity animates — a fade-in at the
                // lane's final position, timed to the system's fade-out of the
                // drag image.
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.24)) {
                        reorderRevealingID = nil
                    }
                }
            },
            makeDragImage: {
                reorderCardDragImage(index: index, sessionTrack: sessionTrack, width: Self.reorderCardWidth)
            }
        )
    }

    /// The lifted card's width: fixed, so it fits inside the 10 pt edge insets
    /// (A2 §3) of the 360 pt default window and doesn't grow in a wider one.
    private static let reorderCardWidth: CGFloat = 320

    /// The floating card shown under the pointer while a lane is dragged to
    /// reorder — a lifted rendition of the lane strip's identity (index badge,
    /// title, format).
    private func reorderPreviewCard(index: Int, sessionTrack: SessionTrack, width: CGFloat) -> some View {
        let track = sessionTrack.loadedTrack
        let isBlind = controller.session.isBlindListeningModeEnabled
        let format = LaneStripText.format(for: track, isBlind: isBlind, fields: settings.compareMetadataFields)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            TrackIndexBadgeView(
                index: index,
                isActive: controller.session.activeTrackID == sessionTrack.id,
                appearance: settings.indexBadgeAppearance
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(LaneStripText.name(for: track, index: index, isBlind: isBlind))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !format.isEmpty {
                    Text(format)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // Height hugs the badge/title/format so the card stays a compact pill
        // rather than an empty lane-height slab.
        .frame(width: max(width, 1), alignment: .leading)
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
    /// owning the whole track section with no ruler. Hovering
    /// darkens the badge and swaps the drag prompt for a click prompt; clicking
    /// anywhere opens the file dialog. Dragging files over any part of the
    /// window tints the badge and glyph with the indigo brand color, with the
    /// area wash and edge glow supplied by the shared track-area import
    /// highlight (drops are handled by the window-wide `onDrop`).
    private var trackAreaEmptyState: some View {
        let isTargeted = windowIsDropTargeted
        return VStack(spacing: 10) {
            Button {
                performImportAction(.open)
            } label: {
                VStack(spacing: 10) {
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
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                emptyStateIsHovered = inside
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The area wash and edge glow come from the shared track-area import
        // highlight (drawn at the root); here only the badge and glyph tint.
        .animation(.easeInOut(duration: 0.15), value: emptyStateIsHovered)
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
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
    /// loop, spanning all lanes edge to edge. Clipped so an off-screen loop
    /// never spills past the lanes. The lane strips sit above it, so only
    /// their badge/title/format and offset field shadow it.
    private func loopSelectionOverlay(waveformWidth: CGFloat, contentHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // One lane-wide gesture classifies its mouse-down against the live
            // playhead position, then locks into playhead-drag or loop-selection
            // mode. The closures' transport/window reads aren't observation-tracked.
            Color.clear
                .contentShape(Rectangle())
                .gesture(laneInteractionGesture(
                    waveformWidth: waveformWidth,
                    rowStep: CompareLaneLayout.laneStep,
                    in: Self.loopColumnSpace
                ))

            // Selection rectangle + resize handles. Their x-positioning depends
            // on the per-scroll-event visible window, so it lives in a leaf that
            // alone reads it; the gesture LOGIC stays here in closures.
            LoopOverlayContentView(
                controller: controller,
                waveformWidth: waveformWidth,
                height: contentHeight,
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
                        handleLoopSelectionEnded(value: value, waveformWidth: waveformWidth, rowStep: CompareLaneLayout.laneStep)
                    } else {
                        let time = globalTime(atX: value.location.x, width: waveformWidth)
                        isStart ? commitLoopResize(start: time) : commitLoopResize(end: time)
                    }
                }
            )
        }
        .frame(width: waveformWidth, height: contentHeight, alignment: .topLeading)
        .clipped()
        .coordinateSpace(name: Self.loopColumnSpace)
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

    /// The lanes use one gesture surface so the live playhead can win at
    /// mouse-down without requiring a SwiftUI hit target to animate every
    /// frame. Once chosen, the mode stays fixed until mouse-up.
    private func laneInteractionGesture(
        waveformWidth: CGFloat,
        rowStep: CGFloat,
        in space: String
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { value in
                let mode = laneDragMode ?? resolvedLaneDragMode(
                    startX: value.startLocation.x,
                    waveformWidth: waveformWidth
                )
                if laneDragMode == nil {
                    laneDragMode = mode
                }

                switch mode {
                case .playhead:
                    handlePlayheadDragChanged(value: value, waveformWidth: waveformWidth)
                case .loopSelection:
                    handleLoopSelectionChanged(value: value, waveformWidth: waveformWidth)
                }
            }
            .onEnded { value in
                let mode = laneDragMode ?? resolvedLaneDragMode(
                    startX: value.startLocation.x,
                    waveformWidth: waveformWidth
                )
                laneDragMode = nil

                switch mode {
                case .playhead:
                    handlePlayheadDragEnded(value: value, waveformWidth: waveformWidth)
                case .loopSelection:
                    handleLoopSelectionEnded(value: value, waveformWidth: waveformWidth, rowStep: rowStep)
                }
            }
    }

    private func resolvedLaneDragMode(startX: CGFloat, waveformWidth: CGFloat) -> TimelineLaneDragMode {
        TimelineLaneGesturePolicy.dragMode(
            startX: startX,
            playheadX: xPosition(for: controller.displayTransportPosition(), width: waveformWidth),
            playheadHitWidth: Self.lanePlayheadHitWidth
        )
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

    private func handleLoopSelectionEnded(value: DragGesture.Value, waveformWidth: CGFloat, rowStep: CGFloat) {
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
                if let trackID = waveformTrackID(atY: value.location.y, rowStep: rowStep) {
                    controller.selectActiveTrack(trackID)
                }
                if let loop = controller.session.loopRegion, t < loop.start || t > loop.end {
                    controller.deselectLoop()
                }
                controller.seek(to: t)
            }
        }
    }

    private func waveformTrackID(atY y: CGFloat, rowStep: CGFloat) -> SessionTrack.ID? {
        guard let index = WaveformTrackSelectionPolicy.trackIndex(
            atY: y,
            rowStep: rowStep,
            trackCount: controller.session.tracks.count
        ) else {
            return nil
        }
        return controller.session.tracks[index].id
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

    private func setupMouseMonitor() {
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
        // An active playhead drag owns the cursor (closed hand) for its duration.
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

        let columnX = point.x - geometry.sectionFrame.minX
        let y = point.y - geometry.sectionFrame.minY

        guard
            geometry.sectionFrame.contains(point),
            columnX >= 0, columnX <= geometry.waveformWidth,
            controller.session.isPlayable
        else {
            setTimelineCursor(.standard)
            return
        }

        let seatBottom = CompareLaneLayout.seatBottom
        let playheadX = xPosition(for: controller.displayTransportPosition(), width: geometry.waveformWidth)

        // The grabber band along the bottom of the ruler.
        if y >= seatBottom - PlayheadGeometry.handleHeight, y <= seatBottom {
            if abs(columnX - playheadX) <= Self.rulerPlayheadHitWidth / 2 {
                setTimelineCursor(.playheadGrab)
                return
            }
        }

        // A lane strip's badge/title/format and offset field sit above the
        // lane gestures and take the click, so they keep their own cursor.
        if y > seatBottom, isOverLaneStripControl(event) {
            setTimelineCursor(.standard)
            return
        }

        // The lanes: loop resize handles at the loop edges, otherwise the
        // draggable playhead band.
        if y > seatBottom, let loop = displayedLoopRegion {
            let startX = xPosition(for: loop.start, width: geometry.waveformWidth)
            let endX = xPosition(for: loop.end, width: geometry.waveformWidth)
            if abs(columnX - startX) <= Self.loopResizeCursorRange
                || abs(columnX - endX) <= Self.loopResizeCursorRange {
                setTimelineCursor(.loopResize)
                return
            }
        }

        if y > seatBottom, abs(columnX - playheadX) <= Self.lanePlayheadHitWidth / 2 {
            setTimelineCursor(.playheadGrab)
            return
        }

        setTimelineCursor(.standard)
    }

    /// Whether the pointer is over a lane strip control: the drag source
    /// behind the badge, title and format, or the offset field.
    private func isOverLaneStripControl(_ event: NSEvent) -> Bool {
        guard let hitView = event.window?.contentView?.hitTest(event.locationInWindow) else { return false }
        return hitView is DragSourceNSView || NumericControlFocusPolicy.isTextInputView(hitView)
    }

    private func setTimelineCursor(_ shape: TimelineCursorShape) {
        switch shape {
        case .standard:
            // Push arrow only on the transition out of a timeline cursor so
            // the manager never fights other controls' cursors (the offset
            // fields' iBeam) while the pointer is elsewhere.
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

    private func handleTimelineScroll(_ visibleStart: TimeInterval) {
        controller.scrollTimeline(toVisibleStart: visibleStart)
    }

    private func handleTimelineMagnify(_ magnification: Double, atFraction fraction: Double) {
        controller.magnifyTimeline(by: magnification, atFraction: fraction)
    }

}

/// Where a lane sits during a reorder drag: hidden while it is lifted (the
/// floating card stands in for it) and shifted to open the gap. Applied around
/// the equatable lane and strip, never inside them, so a gap move only
/// changes these modifiers and never re-runs a lane or strip body.
private struct ReorderPlacement: ViewModifier {
    var isLifted: Bool
    var offsetY: CGFloat
    var gapGeneration: Int

    func body(content: Content) -> some View {
        content
            // The dragged lane stays hidden one tick past the commit
            // (`reorderRevealingID`), then fades in at its landed position; the
            // fade is applied by `withAnimation` in the drag-ended handler.
            .opacity(isLifted ? 0 : 1)
            .offset(y: offsetY)
            .animation(.snappy(duration: 0.26), value: gapGeneration)
    }
}

/// The lane strip's text (A2 §8). The title is the version's title tag, else
/// its filename without the extension — milestone 3's version-row rule. The
/// format shows the enabled container, sample rate and bit rate. Blind Listening Mode
/// shows `Track n` and no format, as the pre-A2 info column did.
enum LaneStripText {
    /// Shown in place of the format when the version's file can't be found.
    static let missingFile = "File Not Found"

    static func name(for track: LoadedTrack, index: Int, isBlind: Bool) -> String {
        isBlind ? "Track \(index + 1)" : PlaylistRowText.versionName(tag: track.title, url: track.url)
    }

    static func format(for track: LoadedTrack, isBlind: Bool, fields: Set<TrackMetadataField>) -> String {
        guard !isBlind else { return "" }
        return PlaylistRowText.formatParts(
            fileFormat: track.fileFormatDescription,
            sampleRate: track.sampleRate,
            bitRate: track.bitRate,
            fields: fields
        ).joined(separator: " • ")
    }

    /// The strip's tooltip: what the pre-A2 info column showed and the strip
    /// has no room for — the duration and the filename. None while blind.
    static func toolTip(for track: LoadedTrack, isBlind: Bool, format: String) -> String? {
        guard !isBlind else { return nil }
        if track.isMissing {
            return PlaybackError.failedToOpenFile(track.url).localizedDescription
        }
        let details = [
            format,
            PlaylistRowText.duration(track.duration)
        ].filter { !$0.isEmpty }.joined(separator: " · ")
        return [
            name(for: track, index: 0, isBlind: false),
            details,
            track.url.lastPathComponent
        ].filter { !$0.isEmpty }.joined(separator: "\n")
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
    let onScrollGestureEnded: () -> Void
    /// Whether the native timeline scroll view is still moving.
    let onScrollActivityChanged: (Bool) -> Void
    /// Pinch: magnification delta, plus the cursor's `0...1` position.
    let onMagnify: (Double, Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll, onScrollGestureEnded: onScrollGestureEnded)
    }

    func makeNSView(context: Context) -> TimelineScrollNSView {
        let view = TimelineScrollNSView()
        view.onMagnify = onMagnify
        view.onScrollActivityChanged = onScrollActivityChanged
        view.onScrollGestureEnded = onScrollGestureEnded
        context.coordinator.attach(to: view)
        configure(view)
        return view
    }

    func updateNSView(_ nsView: TimelineScrollNSView, context: Context) {
        nsView.onMagnify = onMagnify
        nsView.onScrollActivityChanged = onScrollActivityChanged
        nsView.onScrollGestureEnded = onScrollGestureEnded
        context.coordinator.onScroll = onScroll
        context.coordinator.onScrollGestureEnded = onScrollGestureEnded
        configure(nsView)
    }

    private func configure(_ scrollView: TimelineScrollNSView) {
        scrollView.configureTimeline(
            visibleStart: visibleStart,
            visibleSpan: visibleSpan,
            contentStart: contentStart,
            contentEnd: contentEnd
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        var onScroll: (TimeInterval) -> Void
        var onScrollGestureEnded: () -> Void
        private weak var scrollView: TimelineScrollNSView?

        init(onScroll: @escaping (TimeInterval) -> Void, onScrollGestureEnded: @escaping () -> Void) {
            self.onScroll = onScroll
            self.onScrollGestureEnded = onScrollGestureEnded
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
            scrollView.noteNativeHorizontalScrollDidMove()
            scrollView.isReportingNativeScroll = true
            onScroll(visibleStart)
            DispatchQueue.main.async { [weak scrollView] in
                scrollView?.isReportingNativeScroll = false
            }
        }
    }
}

final class TimelineScrollNSView: NSScrollView {
    var onMagnify: ((Double, Double) -> Void)?
    var onScrollGestureEnded: (() -> Void)?
    var timelineVisibleStart: TimeInterval = 0
    var onScrollActivityChanged: ((Bool) -> Void)?
    var timelineContentStart: TimeInterval = 0
    var timelineContentEnd: TimeInterval = 0
    var timelineVisibleSpan: TimeInterval = 0
    var timelinePointsPerSecond: Double = 0
    var isReportingNativeScroll = false
    var isApplyingProgrammaticSync = false
    private var lockedScrollAxis: ScrollAxis?
    private var nativeScrollSettleWorkItem: DispatchWorkItem?
    private var isNativeHorizontalScrollActive = false

    private enum ScrollAxis {
        case horizontal
        case vertical
    }

    /// Short debounce after the last native movement so inertial scrolling can
    /// settle before playback auto-follow resumes.
    private static let nativeScrollSettleDelay: TimeInterval = 0.12

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

    override func layout() {
        super.layout()
        synchronizeTimelineGeometry()
    }

    func configureTimeline(
        visibleStart: TimeInterval,
        visibleSpan: TimeInterval,
        contentStart: TimeInterval,
        contentEnd: TimeInterval
    ) {
        timelineVisibleStart = visibleStart
        timelineVisibleSpan = visibleSpan
        timelineContentStart = contentStart
        timelineContentEnd = contentEnd
        synchronizeTimelineGeometry()
    }

    private func synchronizeTimelineGeometry() {
        let viewportWidth = max(bounds.width, 0)
        let viewportHeight = max(bounds.height, 0)
        let contentSpan = max(timelineContentEnd - timelineContentStart, 0)
        let pointsPerSecond = TimelineScrollGeometry.pointsPerSecond(
            viewportWidth: Double(viewportWidth),
            visibleSpan: timelineVisibleSpan
        )
        let documentWidth = TimelineScrollGeometry.documentWidth(
            contentSpan: contentSpan,
            visibleSpan: timelineVisibleSpan,
            viewportWidth: Double(viewportWidth)
        )
        timelinePointsPerSecond = pointsPerSecond

        let documentFrame = NSRect(
            x: 0,
            y: 0,
            width: CGFloat(max(documentWidth, Double(viewportWidth))),
            height: viewportHeight
        )
        if isReportingNativeScroll {
            if documentView?.frame != documentFrame {
                documentView?.frame = documentFrame
            }
            return
        }

        let x = TimelineScrollGeometry.scrollOffset(
            visibleStart: timelineVisibleStart,
            contentStart: timelineContentStart,
            pointsPerSecond: pointsPerSecond
        )
        let needsDocumentFrameUpdate = documentView?.frame != documentFrame
        let needsScrollUpdate = abs(contentView.bounds.origin.x - CGFloat(x)) > 0.5
        guard needsDocumentFrameUpdate || needsScrollUpdate else { return }

        performProgrammaticSync {
            if needsDocumentFrameUpdate {
                documentView?.frame = documentFrame
            }

            guard needsScrollUpdate else { return }
            contentView.scroll(to: NSPoint(x: CGFloat(x), y: 0))
            reflectScrolledClipView(contentView)
        }
    }

    func performProgrammaticSync(_ update: () -> Void) {
        isApplyingProgrammaticSync = true
        update()
        DispatchQueue.main.async { [weak self] in
            self?.isApplyingProgrammaticSync = false
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            nativeScrollSettleWorkItem?.cancel()
            nativeScrollSettleWorkItem = nil
            setNativeHorizontalScrollActive(false)
        }
        super.viewWillMove(toWindow: newWindow)
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
            onScrollGestureEnded?()
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

    func noteNativeHorizontalScrollDidMove() {
        nativeScrollSettleWorkItem?.cancel()
        setNativeHorizontalScrollActive(true)

        let workItem = DispatchWorkItem { [weak self] in
            self?.setNativeHorizontalScrollActive(false)
        }
        nativeScrollSettleWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.nativeScrollSettleDelay,
            execute: workItem
        )
    }

    private func setNativeHorizontalScrollActive(_ isActive: Bool) {
        guard isNativeHorizontalScrollActive != isActive else { return }
        isNativeHorizontalScrollActive = isActive
        onScrollActivityChanged?(isActive)
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

struct MainWindowConfigurationView: NSViewRepresentable {
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

struct InactiveWindowInteractionShield: NSViewRepresentable {
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

/// Dims a mode's content (control bar, list or lanes, bottom bar) while the
/// main window is in the background, like an inactive AppKit window. Both
/// modes use it; the cover above them stays at full colour.
struct WindowActivityAppearanceModifier: ViewModifier {
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

extension View {
    func windowActivityAppearance(isActive: Bool) -> some View {
        modifier(WindowActivityAppearanceModifier(isActive: isActive))
    }
}


private struct IntegerInputField: NSViewRepresentable {
    @Binding var value: Int
    let configuration: NumericControlConfiguration
    var font: NSFont = .systemFont(ofSize: NSFont.smallSystemFontSize)
    var onFocusChange: (Bool) -> Void = { _ in }
    /// The text while it is being edited (typed or stepped), and `nil` when
    /// editing ends, so a host can size itself to what is being typed.
    var onEditingTextChange: (String?) -> Void = { _ in }

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
        textField.font = font
        textField.delegate = context.coordinator
        textField.stringValue = "\(value)"
        textField.onFocusChange = onFocusChange
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.configuration = configuration
        context.coordinator.onEditingTextChange = onEditingTextChange
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
        var onEditingTextChange: (String?) -> Void = { _ in }

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
            defer { onEditingTextChange(nil) }
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
            let text = (textField.currentEditor() as? NSTextView)?.string ?? textField.stringValue
            editState.updatePendingText(text)
            onEditingTextChange(text)
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
            onEditingTextChange(text)
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

/// One lane's visuals — the active tint and the waveform lane — as a
/// standalone, `Equatable` value view (`.equatable()` at the call site).
///
/// The whole point is isolation: a zoom step re-runs the container body and a
/// reorder gap move bumps parent `@State`, but the container only reconstructs
/// these cheap values and runs `==` per lane. Unless a *compared* input
/// changed, SwiftUI skips this body. Three things are deliberately kept OUT of
/// the compared surface so they can update without re-running the body:
///   - the per-scroll-event lane slide AND the zoom-varying lane window
///     (window bounds + tick guides), both handled inside the `LaneView` leaf
///     (which reads `controller.visibleStart` and `viewportStore` itself), so
///     scroll and zoom re-run only that fixed-frame leaf, not the row;
///   - the reorder gap `offset(y:)`/`opacity`/animation, applied by the
///     container around this view (`ReorderPlacement`).
/// `laneHeight` changes only on window resize or when versions are added or
/// removed. `controller` and `viewportStore` are stored but excluded from `==`.
///
/// The lane's info strip is a separate layer (`LaneStripView`) above the
/// lanes' gesture surface, so its controls take clicks; this view never
/// hit-tests.
private struct TrackRowView: View, Equatable {
    var trackStart: TimeInterval
    var trackDuration: TimeInterval
    /// Nil while blind listening (so progress can't leak identity) or before
    /// generation starts. Array `==` short-circuits on shared storage, so the
    /// common case is O(1).
    var waveform: Waveform?
    var isActive: Bool
    var isBlind: Bool
    var isMissing: Bool
    /// Whether this lane may rasterize (it intersects the vertical viewport
    /// ± overscan). Culled lanes draw nothing.
    var isRenderable: Bool
    /// The drawn lane, without its divider.
    var laneHeight: CGFloat
    /// Drawn width of the 2× lane window. Geometry-driven (2× the lane
    /// width), so it changes on window resize but NOT on zoom — safe as an
    /// equatable input.
    var wideWidth: CGFloat
    var showsDebugLabel: Bool

    /// References forwarded to the lane leaf; never read in this body. The
    /// zoom-varying window/ticks live in `viewportStore` (observed only by the
    /// leaf), so they can't be equatable inputs here — see `LaneViewport`.
    var controller: PlaybackController
    var viewportStore: LaneViewportStore

    nonisolated static func == (lhs: TrackRowView, rhs: TrackRowView) -> Bool {
        lhs.trackStart == rhs.trackStart
            && lhs.trackDuration == rhs.trackDuration
            && lhs.waveform == rhs.waveform
            && lhs.isActive == rhs.isActive
            && lhs.isBlind == rhs.isBlind
            && lhs.isMissing == rhs.isMissing
            && lhs.isRenderable == rhs.isRenderable
            && lhs.laneHeight == rhs.laneHeight
            && lhs.wideWidth == rhs.wideWidth
            && lhs.showsDebugLabel == rhs.showsDebugLabel
    }

    var body: some View {
        // The lane is a self-observing leaf: it reads the shared viewport
        // (zoom) and the live scroll position (`shiftX`) itself, so zoom and
        // scroll re-run only this fixed-frame leaf, never the row body. Its
        // frame is `wideWidth × laneHeight` (both fixed on zoom), so its
        // re-runs never propagate layout up into the VStack.
        LaneView(
            controller: controller,
            viewportStore: viewportStore,
            waveform: waveform,
            isActive: isActive,
            isBlind: isBlind,
            isMissing: isMissing,
            isRenderable: isRenderable,
            trackStart: trackStart,
            trackDuration: trackDuration,
            wideWidth: wideWidth,
            laneHeight: laneHeight,
            showsDebugLabel: showsDebugLabel
        )
        // The 0:00 marker and a tick guide land on the lane's first point
        // whenever the timeline starts at 0:00; the active tint shows there.
        .mask(TimelineLeadingEdgeMask())
        .frame(height: laneHeight)
        // Active lane (A2 §8): a primary tint, with no leading accent bar.
        .background(isActive ? Theme.activeLaneFill : Color.clear)
        .allowsHitTesting(false)
    }
}

/// A lane's info strip (A2 §8): a 21 pt band across the top of the lane, in
/// the space above the waveform (so it needs no fade), holding the index
/// badge, the version's title and format, and its offset field. Every input is per-track static data — nothing varies with
/// scroll or zoom — so, like `TrackRowView`, it is an equatable value
/// (`.equatable()` at the call site) and its closures are excluded from `==`.
///
/// It sits above the lanes' gesture surface and the playhead line. Only the
/// badge, title and format (the drag source and context menu behind them) and
/// the offset field take clicks; the strip's empty middle passes clicks
/// through to seeking, loop selection and the playhead band.
private struct LaneStripView: View, Equatable {
    var index: Int
    var trackID: SessionTrack.ID
    var fileURL: URL
    var name: String
    var format: String
    var toolTip: String?
    var offsetMs: Int
    var isActive: Bool
    var isBlind: Bool
    var isMissing: Bool
    var isOffsetFocused: Bool
    var offsetConfiguration: NumericControlConfiguration
    var indexBadgeAppearance: IndexBadgeAppearance
    var showsDebugLabel: Bool

    var menuActions: LaneStripMenuActions
    var onSelect: () -> Void
    var onSetOffsetMs: (Int) -> Void
    var onOffsetFocusChange: (Bool) -> Void
    var onDragBegan: () -> Void
    var onDragEnded: () -> Void
    var makeDragImage: () -> NSImage?

    /// Gap between the badge, title and format, and before the offset field.
    static let spacing: CGFloat = 6
    static let leadingInset: CGFloat = 9
    static let trailingInset: CGFloat = 8
    static let titleFontSize: CGFloat = 11.5
    static let formatFontSize: CGFloat = 10

    nonisolated static func == (lhs: LaneStripView, rhs: LaneStripView) -> Bool {
        lhs.index == rhs.index
            && lhs.trackID == rhs.trackID
            && lhs.fileURL == rhs.fileURL
            && lhs.name == rhs.name
            && lhs.format == rhs.format
            && lhs.toolTip == rhs.toolTip
            && lhs.offsetMs == rhs.offsetMs
            && lhs.isActive == rhs.isActive
            && lhs.isBlind == rhs.isBlind
            && lhs.isMissing == rhs.isMissing
            && lhs.isOffsetFocused == rhs.isOffsetFocused
            && lhs.offsetConfiguration == rhs.offsetConfiguration
            && lhs.indexBadgeAppearance == rhs.indexBadgeAppearance
            && lhs.showsDebugLabel == rhs.showsDebugLabel
    }

    var body: some View {
        HStack(spacing: Self.spacing) {
            identity
                // Drag the badge, title or format to reorder in place (a move),
                // or out of the window to copy the version's audio file onto
                // Finder / another app / another Takes window. A plain click
                // makes the lane active; a right-click opens its menu.
                .background(
                    TrackRowDragSource(
                        fileURL: fileURL,
                        trackID: trackID,
                        toolTip: toolTip,
                        menuActions: menuActions,
                        onSelect: onSelect,
                        onDragBegan: onDragBegan,
                        onDragEnded: onDragEnded,
                        makeDragImage: makeDragImage
                    )
                )

            Spacer(minLength: 0)

            LaneOffsetField(
                offsetMs: offsetMs,
                isFocused: isOffsetFocused,
                configuration: offsetConfiguration,
                onSetOffsetMs: onSetOffsetMs,
                onFocusChange: onOffsetFocusChange
            )
        }
        .padding(.leading, Self.leadingInset)
        .padding(.trailing, Self.trailingInset)
        // Centred between the divider above the lane and the waveform.
        .frame(height: CompareLaneLayout.stripFrameHeight)
        .componentDebugLabel("Lane Strip", enabled: showsDebugLabel, color: .green)
    }

    /// Badge, title and format. Their own hit testing is off so their clicks
    /// reach the drag source behind them. The title outranks the format, so
    /// the format truncates first; titles truncate in the middle (§13).
    private var identity: some View {
        HStack(spacing: Self.spacing) {
            TrackIndexBadgeView(index: index, isActive: isActive, appearance: indexBadgeAppearance)

            Text(name)
                .font(.system(size: Self.titleFontSize, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            if isMissing {
                // In place of the format, blind or not: the lane is silent.
                Label(LaneStripText.missingFile, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: Self.formatFontSize))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Color(nsColor: PlaylistRowPalette.warningFill))
                    .lineLimit(1)
            } else if !format.isEmpty {
                Text(format)
                    .font(.system(size: Self.formatFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The lane strip's offset field (A2 §8): `0 ms` in a 17 pt box that grows
/// and shrinks with the number, as it is typed too. Typed entry, clamping and
/// ↑/↓ stepping (⇧ for large steps) come from `IntegerInputField`;
/// double-clicking "ms" resets the offset to zero. While
/// it edits, its field editor is the first responder, so
/// `GlobalShortcutFocusPolicy` keeps the global shortcuts off, and a click
/// anywhere else ends the edit (`NumericControlFocusPolicy`).
struct LaneOffsetField: View {
    var offsetMs: Int
    var isFocused: Bool
    var configuration: NumericControlConfiguration
    var onSetOffsetMs: (Int) -> Void
    var onFocusChange: (Bool) -> Void

    /// The text while the field is being edited, so the box grows and shrinks
    /// with what is typed; nil otherwise, when it fits the committed value.
    @State private var editingText: String?
    /// The pointer is over the box: the "Offset" label shows to its left.
    @State private var isHovered = false

    static let height: CGFloat = 17
    static let cornerRadius: CGFloat = 4
    static let horizontalPadding: CGFloat = 5
    static let labelSpacing: CGFloat = 4
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    /// The field's width for `text`: what a borderless text-field cell in the
    /// field's font needs to show it whole (its insets included), plus a point
    /// for the caret. Empty text keeps one digit's room.
    @MainActor
    static func fieldWidth(for text: String) -> CGFloat {
        measuringCell.stringValue = text.isEmpty ? "0" : text
        return ceil(measuringCell.cellSize.width) + 1
    }

    @MainActor
    private static let measuringCell: NSTextFieldCell = {
        let cell = NSTextFieldCell(textCell: "")
        cell.isBordered = false
        cell.drawsBackground = false
        cell.font = font
        return cell
    }()

    var body: some View {
        HStack(spacing: Self.labelSpacing) {
            // Hovering the box names it. The label takes room in the strip's
            // row rather than drawing over it, so a long title or format
            // truncates to make space instead of running under the label.
            if isHovered {
                Text("Offset")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            box
                .overlay(HoverSensor { isHovered = $0 })
        }
        .fixedSize()
    }

    private var box: some View {
        let binding = Binding(
            get: { offsetMs },
            set: { onSetOffsetMs($0) }
        )
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        return HStack(spacing: 3) {
            IntegerInputField(
                value: binding,
                configuration: configuration,
                font: Self.font,
                onFocusChange: onFocusChange,
                onEditingTextChange: { editingText = $0 }
            )
            .frame(width: Self.fieldWidth(for: editingText ?? "\(offsetMs)"))
            .accessibilityLabel("Offset in milliseconds")

            Text("ms")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    binding.wrappedValue = 0
                }
                .accessibilityLabel("Offset units")
                .accessibilityHint("Double click to reset offset to zero milliseconds.")
        }
        .padding(.horizontal, Self.horizontalPadding)
        .frame(height: Self.height)
        .background { shape.fill(Theme.laneOffsetFieldFill) }
        // Focused: the hairline gives way to a solid ring in the app's
        // indigo, plus a soft matching glow so the live field is unmissable.
        .overlay {
            shape.strokeBorder(
                isFocused ? Theme.primary : Theme.laneOffsetFieldBorder,
                lineWidth: isFocused ? 1.5 : 1
            )
        }
        .shadow(color: isFocused ? Theme.primary.opacity(0.55) : .clear, radius: 3)
        .animation(.easeOut(duration: 0.12), value: isFocused)
        .fixedSize()
    }
}

/// Reports the pointer entering and leaving its frame through an AppKit
/// tracking area, and never takes a click, so it can sit over controls —
/// an AppKit text field among them, where SwiftUI hover is unreliable —
/// without stealing their events.
struct HoverSensor: NSViewRepresentable {
    var trackingActivity: NSTrackingArea.Options = .activeInKeyWindow
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> HoverSensorView {
        HoverSensorView(trackingActivity: trackingActivity)
    }

    func updateNSView(_ view: HoverSensorView, context: Context) {
        view.onHover = onHover
    }

    final class HoverSensorView: NSView {
        var onHover: ((Bool) -> Void)?
        private var isInside = false
        private let trackingActivity: NSTrackingArea.Options

        init(trackingActivity: NSTrackingArea.Options) {
            self.trackingActivity = trackingActivity
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, trackingActivity, .inVisibleRect],
                owner: self
            ))
        }

        override func mouseEntered(with event: NSEvent) { setInside(true) }
        override func mouseExited(with event: NSEvent) { setInside(false) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { setInside(false) }
        }

        private func setInside(_ inside: Bool) {
            guard inside != isInside else { return }
            isInside = inside
            onHover?(inside)
        }
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

/// Masks the first point of the ruler and the lanes, so a notch, tick guide
/// or 0:00 marker that lands exactly on the window's left edge isn't drawn
/// as a stray line there (it does whenever the timeline starts at 0:00 and
/// is zoomed to fit). Lines one point in from the edge draw as usual, and the
/// transparent strip reveals the surface below, active-lane tint included.
private struct TimelineLeadingEdgeMask: View {
    /// The masked strip at the leading edge.
    static let width: CGFloat = 1

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: Self.width)
            Color.white
        }
    }
}

/// One lane: the pre-rendered waveform window, positioned for the live scroll
/// (`shiftX`) and drawn from the shared zoom-varying window (`viewportStore`).
///
/// A self-observing leaf. It reads `viewportStore.viewport` (zoom / grid
/// boundary) and `controller.visibleStart`/`visibleSpan` (per scroll event),
/// so both zoom and scroll re-run only this body — never the equatable row
/// around it. Its outer frame is `wideWidth × laneHeight`, both fixed on zoom
/// AND scroll, so a re-run never propagates layout up into the VStack; the
/// waveform moves purely by transforms inside that fixed frame.
/// `WaveformLaneView` stays `.equatable()`, so its Canvas redraws only when the
/// window actually changes (boundary or zoom), not on an intra-window scroll.
private struct LaneView: View {
    var controller: PlaybackController
    var viewportStore: LaneViewportStore
    // Per-row, zoom-invariant inputs (captured when the row body last ran).
    var waveform: Waveform?
    var isActive: Bool
    var isBlind: Bool
    var isMissing: Bool
    var isRenderable: Bool
    var trackStart: TimeInterval
    var trackDuration: TimeInterval
    var wideWidth: CGFloat
    var laneHeight: CGFloat
    var showsDebugLabel: Bool

    var body: some View {
        let viewport = viewportStore.viewport
        // Matches `makeLaneViewport`: `shiftX` maps the live scroll position
        // into the visible (half-window) width.
        let span = max(controller.visibleSpan, 0.001)
        let waveformWidth = wideWidth / 2
        let shiftX = CGFloat((controller.visibleStart - viewport.windowStart) / span) * waveformWidth
        Color.clear
            .frame(height: laneHeight)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                WaveformLaneView(
                    width: wideWidth,
                    height: laneHeight,
                    waveform: waveform,
                    isBlindListening: isBlind,
                    isMissing: isMissing,
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
                .frame(width: wideWidth, height: laneHeight)
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

    // Ruler notches hang from the bottom edge toward the lanes (A2 §8): major
    // (labeled) notches 19 pt, minor 8 pt (v2.9.0's heights). Labels sit
    // 4 pt right of their notch with their digits' tops level with its top;
    // the playhead grabber may overlap them. Geometry lives in
    // `TimelineRulerMetrics`.
    private var tickColor: Color { Theme.timelineRulerTick }

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
                    .font(TimelineRulerMetrics.labelFont)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .frame(height: TimelineRulerMetrics.labelHeight)
                    .padding(.leading, 8)
                    .padding(.top, TimelineRulerMetrics.labelTopInset)
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
        notch(at: xPosition(for: time, visibleStart: visibleStart, visibleEnd: visibleEnd),
              height: TimelineRulerMetrics.minorTickHeight)
            .accessibilityHidden(true)
    }

    private func majorMarker(_ marker: TimelineHeaderMarker, visibleStart: TimeInterval, visibleEnd: TimeInterval) -> some View {
        let tickX = xPosition(for: marker.time, visibleStart: visibleStart, visibleEnd: visibleEnd)
        let labelWidth: CGFloat = 60

        return ZStack(alignment: .topLeading) {
            if let labelOrigin = TimelineRulerMetrics.labelOrigin(tickX: tickX, rulerWidth: width) {
                Text(marker.label)
                    .font(TimelineRulerMetrics.labelFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    // Natural height, so the short line below doesn't shrink
                    // the type through the scale factor.
                    .fixedSize(horizontal: false, vertical: true)
                    // A 10 pt line, as the canvas draws it: the 10 pt type's
                    // natural line (about 12 pt) is centred on it, and the
                    // inset puts the digits' tops level with the notch's.
                    .frame(width: labelWidth, height: TimelineRulerMetrics.labelHeight, alignment: .leading)
                    .offset(x: labelOrigin.x, y: labelOrigin.y)
            }

            notch(at: tickX, height: TimelineRulerMetrics.majorTickHeight)
        }
        .frame(width: width, height: headerHeight, alignment: .topLeading)
        .accessibilityLabel(marker.label)
    }

    /// A notch hanging from the ruler's bottom edge.
    private func notch(at x: CGFloat, height: CGFloat) -> some View {
        let frame = TimelineRulerMetrics.tickFrame(x: x, height: height, rulerHeight: headerHeight)
        return Rectangle()
            .fill(tickColor)
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .frame(width: width, height: headerHeight, alignment: .topLeading)
    }
}

/// Leaf wrapper for the scroll/magnify event overlay: it must be fed the live
/// scroll position (its event math depends on it), so it alone re-runs per
/// scroll event — one cheap representable update — instead of the section that
/// mounts it.
private struct TimelineScrollOverlayLeaf: View {
    var controller: PlaybackController
    var onScroll: (TimeInterval) -> Void
    var onScrollGestureEnded: () -> Void
    var onMagnify: (Double, Double) -> Void

    var body: some View {
        TimelineScrollOverlay(
            visibleStart: controller.visibleStart,
            visibleSpan: max(controller.visibleSpan, 0.001),
            contentStart: controller.session.timelineStart,
            contentEnd: controller.session.timelineEnd,
            onScroll: onScroll,
            onScrollGestureEnded: onScrollGestureEnded,
            onScrollActivityChanged: { controller.setTimelineScrollActive($0) },
            onMagnify: onMagnify
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
    var part: PlayheadPart
    /// While a playhead drag is in flight: the preview x across the lanes.
    var playheadDragX: CGFloat?
    var waveformWidth: CGFloat
    /// The grabber's overlay spans the section; the line's spans the lanes.
    var height: CGFloat

    var body: some View {
        let position = controller.displayTransportPosition()
        TimelinePlayheadVisual(
            part: part,
            currentX: playheadDragX ?? xPosition(for: position),
            endX: xPosition(for: controller.session.playbackEnd),
            remaining: max(0, controller.session.playbackEnd - position),
            isPlaying: controller.session.isPlaying && playheadDragX == nil,
            height: height
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

/// The lane strip's 15 pt index badge (A2 §8): filled with the primary color
/// when the lane is active (white number), a neutral fill otherwise
/// (secondary number). The bevel and shadow come from `IndexBadgeAppearance`.
private struct TrackIndexBadgeView: View {
    var index: Int
    var isActive: Bool
    var appearance: IndexBadgeAppearance

    static let side: CGFloat = 15
    static let cornerRadius: CGFloat = 4

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        let badge = appearance
        return Text("\(index + 1)")
            .font(.system(size: 10, weight: .bold).monospacedDigit())
            .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .frame(width: Self.side, height: Self.side)
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
    /// The drawn lane's height; the waveform sits in the band below the
    /// lane strip (`CompareLaneLayout.waveformBand`).
    var height: CGFloat
    /// The waveform to draw, or `nil` while blind listening (so waveform
    /// progress can't leak identity through redraw timing) or before
    /// generation starts.
    var waveform: Waveform?
    var isBlindListening: Bool
    /// The file can't be found: the track's extent shows the error state
    /// in place of a waveform, blind or not (the lane is silent either way).
    var isMissing: Bool
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
        let band = CompareLaneLayout.waveformBand(laneHeight: height)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.background.opacity(0.01))

            // Faint major-tick guides behind the waveform, aligned with the
            // ruler's labeled ticks above. They run the full lane height,
            // behind the strip.
            ForEach(Array(majorTickXs.enumerated()), id: \.offset) { _, tickX in
                Rectangle()
                    .fill(Theme.hairline.opacity(0.5))
                    .frame(width: 1, height: height)
                    .offset(x: tickX)
                    .accessibilityHidden(true)
            }

            if isMissing {
                missingExtent
                    .frame(width: width, height: band.height)
                    .offset(y: band.minY)
            } else if isBlindListening {
                blindHatch
                    .frame(width: width, height: band.height)
                    .offset(y: band.minY)
            } else {
                // The peak envelope is drawn SYNCHRONOUSLY every frame straight
                // from the 5a pyramid (WP-7): the `Canvas` draw closure runs
                // during the frame's render pass, so the correct waveform for the
                // CURRENT window is drawn in the same frame the window changes —
                // no async image pipeline to fall behind, no blank/stale-stretch
                // gap during zoom or scroll.
                waveformContent
                    .frame(width: width, height: band.height)
                    .offset(y: band.minY)
            }

            Rectangle()
                .fill(.secondary.opacity(0.25))
                .frame(width: 1, height: height)
                .offset(x: zeroTickX)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
        // Lane visuals must NEVER hit-test: `.clipped()` clips drawing but NOT
        // hit testing, and this subtree is 2× the viewport wide and slid left
        // by up to a viewport width, so it extends invisibly past the lane's
        // edges. All lane interaction lives on the loop overlay, the lane
        // strips and the scroll overlay.
        .allowsHitTesting(false)
        .componentDebugLabel("Waveform Lane", enabled: showsDebugLabel, color: .purple)
    }

    /// Envelope tint (A2 §8): primary for the active lane,
    /// `Theme.waveformInactive` otherwise, at v2.9.0's strengths (85% and 70%).
    /// `isActive` is a color-only distinction, so an A/B switch only re-tints —
    /// the pyramid path build is identical either way.
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

    /// The missing-file error state: the track's extent as a faint warning
    /// band with a dashed outline, so the lane keeps its place on the
    /// timeline. Static Canvas drawing, like the waveform.
    private var missingExtent: some View {
        Canvas { context, size in
            guard isRenderable, let extent = LaneWaveformRenderer.trackExtent(
                width: size.width, trackStart: trackStart, trackDuration: trackDuration,
                visibleStart: visibleStart, visibleSpan: visibleSpan
            ) else { return }
            // The stroke sits inside the extent, and the start clears the
            // lane's masked first point (`TimelineLeadingEdgeMask`), so a
            // track starting at 0:00 keeps its left edge.
            let startX = extent.lowerBound + TimelineLeadingEdgeMask.width + 0.5
            let rect = CGRect(x: startX, y: 0.5, width: max(extent.upperBound - 0.5 - startX, 0), height: size.height - 1)
            let band = Path(roundedRect: rect, cornerRadius: 4)
            let color = Color(nsColor: PlaylistRowPalette.warningFill)
            context.fill(band, with: .color(color.opacity(isActive ? 0.16 : 0.10)))
            context.stroke(band, with: .color(color.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .accessibilityLabel("File not found")
    }

    /// Base tint for the masked-lane treatments: the same active/inactive
    /// distinction as the real envelope, muted further so the lane reads as a
    /// placeholder rather than data.
    private var blindTint: Color {
        isActive ? Theme.primary : Theme.waveformInactive
    }

    /// The blind branch: a redaction-bar diagonal hatch, static Canvas
    /// drawing (no animation, no async/cached image — same rule as the
    /// real-waveform branch).
    private var blindHatch: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            let rect = CGRect(origin: .zero, size: size)
            let band = Path(roundedRect: rect, cornerRadius: 4)
            context.fill(band, with: .color(blindTint.opacity(0.08)))

            context.clip(to: band)
            context.fill(Self.hatchPath(in: size), with: .color(blindTint.opacity(0.30)))
        }
        .accessibilityLabel("Masked waveform")
    }

    private static func hatchPath(in size: CGSize) -> Path {
        let period: CGFloat = 12
        let stripeWidth: CGFloat = 4
        let h = size.height
        var path = Path()
        // Each stripe runs bottom-left to top-right, offset by `h` so it
        // covers the band edge to edge.
        var x = -h
        while x < size.width + period {
            path.move(to: CGPoint(x: x, y: h))
            path.addLine(to: CGPoint(x: x + h, y: 0))
            path.addLine(to: CGPoint(x: x + h + stripeWidth, y: 0))
            path.addLine(to: CGPoint(x: x + stripeWidth, y: h))
            path.closeSubpath()
            x += period
        }
        return path
    }

}

/// Synchronous peak-envelope drawing for a lane. `waveformPath` builds the
/// O(viewport px) filled path from the 5a pyramid; `fillEnvelope` fills it into
/// a `Canvas`'s `GraphicsContext` during the frame's render pass (WP-7 — no
/// async pipeline, no cached `NSImage`).
enum LaneWaveformRenderer {
    /// The x range a track covers in a lane `width` wide showing
    /// `visibleStart ..< visibleStart + visibleSpan`, clamped a point past
    /// each edge; `nil` when it is off screen.
    static func trackExtent(
        width: CGFloat, trackStart: TimeInterval, trackDuration: TimeInterval,
        visibleStart: TimeInterval, visibleSpan: TimeInterval
    ) -> ClosedRange<CGFloat>? {
        guard width > 0, visibleSpan > 0, trackDuration > 0 else { return nil }
        let scale = Double(width) / visibleSpan
        let start = CGFloat((trackStart - visibleStart) * scale)
        let end = CGFloat((trackStart + trackDuration - visibleStart) * scale)
        guard end > 0, start < width else { return nil }
        return max(start, -1)...min(end, width + 1)
    }

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

/// One half of the playhead's visual layer (`PlayheadPart`): the grabber or
/// the line, hosted in an AppKit layer tree and moved by ONE
/// `CABasicAnimation` per transport anchor event.
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
    var part: PlayheadPart
    var currentX: CGFloat
    var endX: CGFloat
    var remaining: TimeInterval
    var isPlaying: Bool
    /// The line's length; the grabber ignores it.
    var height: CGFloat

    func makeNSView(context: Context) -> PlayheadLayerView {
        PlayheadLayerView(part: part)
    }

    func updateNSView(_ view: PlayheadLayerView, context: Context) {
        view.apply(
            currentX: currentX,
            endX: endX,
            remaining: remaining,
            isPlaying: isPlaying,
            lineHeight: height
        )
    }
}

/// The two halves of the playhead, hosted in separate layer views so the
/// lane strips can sit between them: the grabber over the ruler, the line
/// beneath the strips.
enum PlayheadPart {
    case grabber
    case line
}

/// Layer-backed host for the playhead visuals. The grabber art is the SwiftUI
/// `PlayheadGrabberArt` rasterized once per appearance into the grabber
/// layer's contents, so the art stays identical to the rest of the design
/// system without any per-frame SwiftUI involvement.
final class PlayheadLayerView: NSView {
    let part: PlayheadPart
    /// Zero-size anchor layer that carries the line or the grabber; the slide
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
    private var lastLineHeight: CGFloat = 0
    /// Host time the current tween was seated at, so re-seats (appearance or
    /// layout changes mid-playback) can re-derive where the playhead is now.
    private var seatedAt: CFTimeInterval = 0

    init(part: PlayheadPart) {
        self.part = part
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        carrier.anchorPoint = .zero
        carrier.bounds = .zero
        line.anchorPoint = .zero
        grabber.anchorPoint = .zero
        carrier.addSublayer(part == .line ? line : grabber)
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
        lineHeight: CGFloat
    ) {
        lastCurrentX = currentX
        lastEndX = endX
        lastRemaining = remaining
        lastIsPlaying = isPlaying
        lastLineHeight = lineHeight
        seatedAt = CACurrentMediaTime()
        seat()
    }

    private func seat() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        switch part {
        case .line:
            // Inside the lanes' scroll content, which starts at the ruler's
            // bottom edge.
            line.frame = PlayheadGeometry.lineFrame(lineHeight: lastLineHeight)
        case .grabber:
            grabber.frame = PlayheadGeometry.grabberFrame(
                seatBottom: CompareLaneLayout.seatBottom,
                padding: Self.grabberPadding
            )
        }

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
        guard part == .grabber else {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                line.backgroundColor = NSColor(Theme.secondary).cgColor
            }
            return
        }

        let renderer = ImageRenderer(
            content: PlayheadGrabberArt()
                .frame(
                    width: PlayheadGeometry.handleWidth,
                    height: PlayheadGeometry.handleHeight
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
    @Environment(\.colorScheme) private var colorScheme

    /// Light-mode-only lift for the playhead handle. Tweak this constant here;
    /// it does not affect the shared theme tokens used elsewhere.
    private static let lightModeHandleFill = Color(red: 0.90, green: 0.59, blue: 0.14)

    private var handleFill: Color {
        colorScheme == .light ? Self.lightModeHandleFill : Theme.secondary
    }

    var body: some View {
        PlayheadHandle(tipWidth: 2)
            .fill(handleFill)
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
