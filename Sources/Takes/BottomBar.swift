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

// MARK: - Playlist

/// The playlist bar's summary (A2 §7): `6 tracks · 19:35`, one track per
/// playlist item. The total adds up each item's key version, the duration
/// its row shows. Rejected tracks are left out of both the count and the
/// total (culling spec §8, question 2). An empty playlist shows no summary;
/// its empty state already says so.
enum PlaylistSummaryText {
    static func text(for items: [PlaylistItem]) -> String {
        guard !items.isEmpty else { return "" }
        let counted = items.filter { !$0.isRejected }
        return "\(count(counted.count)) · \(PlaylistRowText.duration(totalDuration(of: counted)))"
    }

    static func accessibilityText(for items: [PlaylistItem]) -> String {
        guard !items.isEmpty else { return "" }
        let counted = items.filter { !$0.isRejected }
        return "\(count(counted.count)), \(PlaylistRowText.duration(totalDuration(of: counted))) in total"
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

/// The playlist's bottom bar (A2 §7): Add Files… / Remove Selected, the `…`
/// pull-down with the Playlist menu's organisation commands, and the summary.
struct PlaylistBottomBar: View {
    let coordinator: PlaylistCoordinator
    @ObservedObject var presentation: PlaylistPresentationState
    @ObservedObject var openFiles: OpenFileCommandState
    let undoManager: UndoManager?

    var body: some View {
        let context = PlaylistCommandContext(coordinator: coordinator, presentation: presentation, undoManager: undoManager)
        let state = PlaylistBottomBarState(context: context)
        let items = coordinator.workspace.items
        BottomBarLayout {
            BottomBarAddRemoveControl(
                addLabel: "Add Files…",
                removeLabel: "Remove Selected",
                canRemove: state.canRemove,
                // ⌘O and Delete: the shared import path, and the selection-
                // aware removal.
                add: { openFiles.presentOpenDialog() },
                remove: { openFiles.removeActiveTrack() }
            )
            .fixedSize()
            Menu {
                playlistOrganizationMenuItems(
                    context: context, availability: PlaylistOrganizationAvailability(context), move: context.moveSelection,
                    toggleRejection: context.toggleRejection
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
            Text(PlaylistSummaryText.text(for: items))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel(PlaylistSummaryText.accessibilityText(for: items))
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
/// Align button, and the zoom control.
///
/// The zoom control and the Align button are leaves of their own, so a zoom
/// step or an alignment progress update re-runs only them. Nothing here
/// reaches the lanes (`TrackRowView`, `LaneStripView`).
struct CompareBottomBar: View {
    let coordinator: PlaylistCoordinator
    @ObservedObject var openFiles: OpenFileCommandState
    private var controller: PlaybackController { coordinator.controller }

    var body: some View {
        let state = CompareBottomBarState(controller: controller)
        BottomBarLayout {
            BottomBarAddRemoveControl(
                addLabel: "Add Version…",
                removeLabel: "Remove Active Version",
                canRemove: state.canRemove,
                // ⌘O, whose import targets the item being compared, and
                // File ▸ Remove Version (Delete).
                add: { openFiles.presentOpenDialog() },
                remove: { openFiles.removeActiveTrack() }
            )
            .fixedSize()
            CompareAlignButton(controller: controller, isEnabled: state.canAlign)
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
    @State private var showsOffer = false

    var body: some View {
        let outcome = controller.alignmentOutcome
        Button {
            controller.autoAlignTracks()
        } label: {
            label.frame(width: 16, height: 14)
        }
        .disabled(!isEnabled)
        .help("Auto-Align Tracks")
        .accessibilityLabel("Auto-Align Tracks")
        .accessibilityValue(controller.isAligning ? "Aligning" : "")
        // The flash: a glow in the outcome's colour while it lasts. Static,
        // not pulsed; continuous motion is Core Animation's job in Takes.
        .shadow(color: Self.glowColor(outcome).opacity(0.8), radius: outcome == nil ? 0 : 4)
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
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .controlSize(.mini)
        } else if controller.isAligning {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
        } else if let outcome = controller.alignmentOutcome {
            Image(systemName: outcome == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(Self.glowColor(outcome))
        } else {
            Image(systemName: "arrow.right.and.line.vertical.and.arrow.left")
        }
    }

    private static func glowColor(_ outcome: PlaybackController.AlignmentOutcome?) -> Color {
        switch outcome {
        case .success: .green
        case .failure: .red
        case nil: .clear
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
