import AppKit
import SwiftUI

// MARK: - Layout

/// The A2 bottom bar's geometry (§7): 30 pt including its 1 pt top hairline,
/// the shared 10 pt edge insets, 6 pt between controls.
enum BottomBarMetrics {
    /// The whole bar, its top hairline included.
    static let height: CGFloat = 30
    static let hairlineHeight: CGFloat = 1
    static let edgeInset: CGFloat = ControlBarMetrics.edgeInset
    static let spacing: CGFloat = 6
    /// The compare zoom slider, between its two magnifiers.
    static let zoomSliderWidth: CGFloat = 96
    static let minimumZoomSliderWidth: CGFloat = 64
}

/// One bottom bar for both modes (A2 §7), as `ControlBarLayout` is for the
/// control bar: leading controls, then trailing ones at the far edge. It
/// stretches to any width; there are no width-dependent layouts. Every
/// control in it is a standard small control.
struct BottomBarLayout<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: BottomBarMetrics.spacing) {
            leading
            Spacer(minLength: BottomBarMetrics.spacing)
            trailing
        }
        .padding(.horizontal, BottomBarMetrics.edgeInset)
        .frame(maxWidth: .infinity)
        .frame(height: BottomBarMetrics.height - BottomBarMetrics.hairlineHeight)
        .padding(.top, BottomBarMetrics.hairlineHeight)
        .background(alignment: .top) {
            Rectangle()
                .fill(Theme.bottomBarHairline)
                .frame(height: BottomBarMetrics.hairlineHeight)
                .allowsHitTesting(false)
        }
        // Decorative, so it must not take clicks from the drag area behind it.
        .background(Theme.bottomBarSurface.allowsHitTesting(false))
        // Like the control bar, empty bar space drags the window.
        .background(WindowDragArea())
        .controlSize(.small)
    }
}

/// The bar's + / − pair (A2 §7): a momentary segmented control, AppKit's
/// standard add/remove control. Each segment runs an existing command; the
/// bar adds no behaviour of its own.
struct BottomBarAddRemoveControl: NSViewRepresentable {
    var addLabel: String
    var removeLabel: String
    var canRemove: Bool
    var add: () -> Void
    var remove: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = 2
        control.trackingMode = .momentary
        control.segmentStyle = .rounded
        control.controlSize = .small
        control.target = context.coordinator
        control.action = #selector(Coordinator.segmentClicked(_:))
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.add = add
        context.coordinator.remove = remove
        context.coordinator.setSegment(0, of: control, symbol: "plus", label: addLabel)
        context.coordinator.setSegment(1, of: control, symbol: "minus", label: removeLabel)
        control.isEnabled = context.environment.isEnabled
        control.setEnabled(canRemove, forSegment: 1)
    }

    @MainActor
    final class Coordinator: NSObject {
        var add: () -> Void = {}
        var remove: () -> Void = {}
        private var labels: [Int: String] = [:]

        /// Sets a segment's glyph, tooltip and VoiceOver label, only when the
        /// label changes (compare and playlist name the same segments
        /// differently).
        func setSegment(_ segment: Int, of control: NSSegmentedControl, symbol: String, label: String) {
            guard labels[segment] != label else { return }
            labels[segment] = label
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
            control.setImage(image, forSegment: segment)
            control.setToolTip(label, forSegment: segment)
        }

        @objc func segmentClicked(_ sender: NSSegmentedControl) {
            switch sender.selectedSegment {
            case 0: add()
            case 1: remove()
            default: break
            }
        }
    }
}

/// Reject / Clear Rejection (culling §4.1) as a bar button: the broken
/// heart, running the same command as the menus and ⌘R. Its tooltip and
/// VoiceOver label carry the command's current title.
struct BottomBarRejectButton: View {
    static let glyphSize: CGFloat = 12
    var clears: Bool
    var isEnabled: Bool
    var action: () -> Void

    var body: some View {
        let title = PlaylistRejectionCommand.title(clears: clears)
        Button(action: action) {
            Image(nsImage: RejectedMark.templateImage(size: Self.glyphSize))
                .frame(width: 16, height: 14)
        }
        .disabled(!isEnabled)
        .help(title)
        .accessibilityLabel(title)
    }
}

// MARK: - Playlist

/// The playlist bar's summary (A2 §7): `6 tracks · 19:35`, one track per
/// playlist item. The total adds up each item's key version, the duration
/// its row shows. Rejected tracks are left out of both the count and the
/// total (culling spec §8, question 2). Selecting multiple track rows shows
/// their count out of all tracks and their combined duration.
enum PlaylistSummaryText {
    static func text(for items: [PlaylistItem], selection: Set<PlaylistRowID> = []) -> String {
        guard let summary = summary(for: items, selection: selection) else { return "" }
        return "\(summary.count) · \(summary.duration)"
    }

    static func accessibilityText(for items: [PlaylistItem], selection: Set<PlaylistRowID> = []) -> String {
        guard let summary = summary(for: items, selection: selection) else { return "" }
        let selectionLabel = summary.isSelection ? " selected" : ""
        return "\(summary.count)\(selectionLabel), \(summary.duration) in total"
    }

    private static func summary(
        for items: [PlaylistItem], selection: Set<PlaylistRowID>
    ) -> (count: String, duration: String, isSelection: Bool)? {
        guard !items.isEmpty else { return nil }
        let selected = items.filter { selection.contains(.item($0.id)) }
        if selected.count > 1 {
            return ("\(selected.count.formatted()) of \(count(items.count))",
                    PlaylistRowText.duration(totalDuration(of: selected)), true)
        }
        let counted = items.filter { !$0.isRejected }
        return (count(counted.count), PlaylistRowText.duration(totalDuration(of: counted)), false)
    }

    static func count(_ count: Int) -> String {
        count == 1 ? "1 track" : "\(count.formatted()) tracks"
    }

    static func totalDuration(of items: [PlaylistItem]) -> TimeInterval {
        items.reduce(0) { total, item in
            let duration = item.keyVersion?.metadata.duration ?? 0
            return total + (duration.isFinite && duration > 0 ? duration : 0)
        }
    }
}

/// Which playlist bar controls are enabled (A2 §7). Each follows the
/// validation of the commands it shares an action with.
struct PlaylistBottomBarState: Equatable {
    /// Remove Selected: Delete's rule, any selected item or version.
    var canRemove: Bool
    /// The `…` pull-down: every command in it needs at least one item.
    var canShowActions: Bool

    init(itemCount: Int, canRemoveSelection: Bool) {
        canRemove = canRemoveSelection
        canShowActions = itemCount > 0
    }

    @MainActor
    init(context: PlaylistCommandContext) {
        self.init(itemCount: context.coordinator.workspace.items.count, canRemoveSelection: context.canRemove)
    }
}

/// The playlist's bottom bar (A2 §7): Add Files… / Remove Selected, Reject,
/// the `…` pull-down with the Playlist menu's organisation commands, and the summary.
struct PlaylistBottomBar: View {
    let coordinator: PlaylistCoordinator
    @ObservedObject var presentation: PlaylistPresentationState
    @ObservedObject var openFiles: OpenFileCommandState
    let undoManager: UndoManager?

    var body: some View {
        let context = PlaylistCommandContext(coordinator: coordinator, presentation: presentation, undoManager: undoManager)
        let state = PlaylistBottomBarState(context: context)
        let availability = PlaylistOrganizationAvailability(context)
        let items = coordinator.workspace.items
        BottomBarLayout {
            BottomBarAddRemoveControl(
                addLabel: "Add Files…",
                removeLabel: "Remove Selected",
                canRemove: state.canRemove,
                // ⌘O and Delete: the shared import path, and the selection-
                // aware removal.
                add: {
                    if coordinator.mode == .playlist { openFiles.presentOpenDialog() }
                },
                remove: context.remove
            )
            .fixedSize()
            BottomBarRejectButton(
                clears: availability.rejectionClears, isEnabled: availability.canReject, action: context.toggleRejection
            )
            Menu {
                playlistOrganizationMenuItems(
                    // Reject has its own button beside the pull-down.
                    context: context, availability: availability, move: context.moveSelection, toggleRejection: nil
                )
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.visible)
            .fixedSize()
            .disabled(!state.canShowActions)
            .help("Playlist Actions")
            .accessibilityLabel("Playlist Actions")
        } trailing: {
            Text(PlaylistSummaryText.text(for: items, selection: presentation.selection))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityLabel(PlaylistSummaryText.accessibilityText(for: items, selection: presentation.selection))
        }
    }
}

// MARK: - Compare

/// Which compare bar controls are enabled (A2 §7). Each follows the
/// validation of the command it shares an action with.
struct CompareBottomBarState: Equatable {
    /// Remove Active Version: the rule of File ▸ Remove Version and the lane
    /// strip's Remove Version, any active version. Removing an item's last
    /// version removes the item and returns to the playlist, as those do.
    /// Blind Listening Mode changes nothing: the active version is the lane
    /// already marked active, and nothing here names its file.
    var canRemove: Bool
    /// Auto-Align Tracks: two or more versions, and no run in flight.
    var canAlign: Bool
    /// ⌘+ / ⌘−: content longer than the smallest visible window.
    var canZoom: Bool

    init(hasActiveVersion: Bool, hasMultipleTracks: Bool, isAligning: Bool, canZoomTimeline: Bool) {
        canRemove = hasActiveVersion
        canAlign = hasMultipleTracks && !isAligning
        canZoom = canZoomTimeline
    }

    @MainActor
    init(controller: PlaybackController) {
        self.init(
            hasActiveVersion: controller.session.activeTrackID != nil,
            hasMultipleTracks: controller.session.hasMultipleTracks,
            isAligning: controller.isAligning,
            canZoomTimeline: controller.canZoomTimeline
        )
    }
}

/// The compare bottom bar (A2 §7): Add Version… / Remove Active Version, the
/// Align button, Reject (the active lane, as ⌘R), and the zoom control.
///
/// The zoom control and the Align button are leaves of their own, so a zoom
/// step or an alignment progress update re-runs only them. Nothing here
/// reaches the lanes (`TrackRowView`, `LaneStripView`).
struct CompareBottomBar: View {
    let coordinator: PlaylistCoordinator
    @ObservedObject var openFiles: OpenFileCommandState
    @Environment(\.undoManager) private var undoManager
    private var controller: PlaybackController { coordinator.controller }

    var body: some View {
        let state = CompareBottomBarState(controller: controller)
        let active = coordinator.activeComparisonVersionID
        BottomBarLayout {
            BottomBarAddRemoveControl(
                addLabel: "Add Version…",
                removeLabel: "Remove Active Version",
                canRemove: state.canRemove,
                // ⌘O, whose import targets the item being compared, and
                // File ▸ Remove Version (Delete).
                add: {
                    if coordinator.mode.itemID != nil { openFiles.presentOpenDialog() }
                },
                remove: {
                    guard let active = coordinator.activeComparisonVersionID else { return }
                    coordinator.removeVersion(active, undoManager: undoManager)
                }
            )
            .fixedSize()
            CompareAlignButton(controller: controller, isEnabled: state.canAlign)
            BottomBarRejectButton(
                clears: active.map { coordinator.rejectionClears(itemIDs: [], versionIDs: [$0]) } ?? false,
                isEnabled: active != nil
            ) {
                guard let active = coordinator.activeComparisonVersionID else { return }
                coordinator.toggleRejection(versionIDs: [active], undoManager: undoManager)
            }
        } trailing: {
            CompareZoomControl(controller: controller, isEnabled: state.canZoom)
        }
    }
}

/// Auto-Align Tracks (A2 §7), back from the pre-A2 compare header. The glyph
/// swaps for a spinner during the quick pass and a progress ring during tempo
/// analysis, then for a green check or red cross while the controller's
/// outcome flash lasts (two seconds). When the quick pass leaves versions
/// unaligned, "Couldn't Align Tracks" opens as a popover anchored here,
/// offering the slower tempo analysis.
struct CompareAlignButton: View {
    let controller: PlaybackController
    let isEnabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsOffer = false

    var body: some View {
        Button {
            controller.autoAlignTracks()
        } label: {
            label.frame(width: 16, height: 14)
        }
        .disabled(!isEnabled)
        .help("Auto-Align Tracks")
        .accessibilityLabel("Auto-Align Tracks")
        .accessibilityValue(controller.isAligning ? "Aligning" : "")
        .popover(isPresented: $showsOffer, arrowEdge: .top) { offerContent }
        .onChange(of: controller.tempoAnalysisOffer) { _, offer in
            if offer != nil { showsOffer = true }
        }
        .onChange(of: showsOffer) { _, isShowing in
            if !isShowing { controller.dismissAlignmentAttention() }
        }
    }

    @ViewBuilder
    private var label: some View {
        if let progress = controller.alignmentProgress {
            ZStack {
                Circle()
                    .stroke(Theme.primary.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(Theme.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: progress)
        } else if controller.isAligning {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .scaleEffect(0.75)
        } else if let outcome = controller.alignmentOutcome {
            let color: Color = outcome == .success ? .green : .red
            Image(systemName: outcome == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(color)
                .background {
                    AlignmentResultGlow(color: NSColor(color), reduceMotion: reduceMotion)
                        .frame(width: AlignmentResultGlow.size, height: AlignmentResultGlow.size)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        } else {
            Image(systemName: "arrow.right.and.line.vertical.and.arrow.left")
        }
    }

    @ViewBuilder
    private var offerContent: some View {
        if let offer = controller.tempoAnalysisOffer {
            let session = controller.session
            let names = AlignmentOfferText.trackNames(
                offerTrackIDs: offer.trackIDs,
                offerTrackNames: offer.trackNames,
                sessionTrackIDs: session.tracks.map(\.id),
                isBlind: session.isBlindListeningModeEnabled
            )
            VStack(alignment: .leading, spacing: 10) {
                Text("Couldn't Align Tracks")
                    .font(.headline)
                Text("No matching audio was found for:")
                    .fixedSize(horizontal: false, vertical: true)
                Text(names.joined(separator: "\n"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Deeper analysis can align audio across differing tempos, but it takes longer.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Analyze Further") {
                        controller.startTempoAnalysis()
                        showsOffer = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 300)
            .controlSize(.regular)
        }
    }
}

/// The two-second outcome pulse runs on the layer without updating the button.
private struct AlignmentResultGlow: NSViewRepresentable {
    static let size: CGFloat = 12
    let color: NSColor
    let reduceMotion: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.shadowPath = CGPath(
            ellipseIn: CGRect(x: 0, y: 0, width: Self.size, height: Self.size),
            transform: nil
        )
        view.layer?.shadowOffset = .zero
        view.layer?.shadowRadius = 7
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let restingOpacity: Float = reduceMotion ? 0.8 : 0.15
        let shadowColor = color.cgColor
        guard let layer = view.layer,
              layer.shadowColor != shadowColor || layer.shadowOpacity != restingOpacity else { return }

        layer.removeAnimation(forKey: "outcomePulse")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.shadowColor = shadowColor
        layer.shadowOpacity = restingOpacity
        CATransaction.commit()

        guard !reduceMotion else { return }
        let pulse = CABasicAnimation(keyPath: #keyPath(CALayer.shadowOpacity))
        pulse.fromValue = restingOpacity
        pulse.toValue = 0.9
        pulse.duration = 0.5
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.autoreverses = true
        pulse.repeatCount = 2
        layer.add(pulse, forKey: "outcomePulse")
    }
}

/// The alignment offer's list of versions it couldn't align.
enum AlignmentOfferText {
    /// The versions' names, or `Track n` (their lane positions) in Blind
    /// Listening Mode, as the lanes show them, so the offer never names a
    /// file. The audible version is the anchor and never listed, so a list of
    /// file names would reveal it by elimination.
    static func trackNames(
        offerTrackIDs: [UUID],
        offerTrackNames: [String],
        sessionTrackIDs: [UUID],
        isBlind: Bool
    ) -> [String] {
        guard isBlind else { return offerTrackNames }
        return offerTrackIDs.compactMap { id in
            sessionTrackIDs.firstIndex(of: id).map { "Track \($0 + 1)" }
        }
    }
}

/// Zoom (A2 §7): magnifier − · small slider · magnifier +, no Fit. The
/// slider is `TimelineViewport`'s log mapping of the controller's visible
/// span, the window ⌘+/⌘−, Zoom to Selection and pinch also change, so all
/// of them stay in sync. The magnifiers step like ⌘− and ⌘+.
///
/// A leaf: it alone reads the visible span, so a zoom step re-runs only it.
/// It writes the zoom through the controller, never with `withAnimation`.
struct CompareZoomControl: View {
    let controller: PlaybackController
    let isEnabled: Bool
    @EnvironmentObject private var zoomHaptics: ZoomHapticsController

    var body: some View {
        HStack(spacing: BottomBarMetrics.spacing) {
            Button { step(zoomingIn: false) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom Out")
                .accessibilityLabel("Zoom Out")
            Slider(
                value: Binding(
                    get: { controller.zoomSliderValue },
                    set: { value in zoom { controller.setZoomSliderValue(value) } }
                ),
                in: 0...1
            )
            .frame(minWidth: BottomBarMetrics.minimumZoomSliderWidth, idealWidth: BottomBarMetrics.zoomSliderWidth,
                   maxWidth: BottomBarMetrics.zoomSliderWidth)
            .accessibilityLabel("Timeline Zoom")
            Button { step(zoomingIn: true) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom In")
                .accessibilityLabel("Zoom In")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(!isEnabled)
    }

    private func step(zoomingIn: Bool) {
        zoom { controller.stepZoom(zoomingIn: zoomingIn) }
    }

    /// A zoom change with the haptic tick the pre-A2 control gave when the
    /// zoom crosses a quarter of its range.
    private func zoom(_ change: () -> Void) {
        zoomHaptics.syncZoomProgress(controller.zoomSliderValue)
        change()
        zoomHaptics.updateZoomProgress(controller.zoomSliderValue)
    }
}
