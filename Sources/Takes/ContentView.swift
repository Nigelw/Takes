import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NumericControlConfiguration {
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
    static let contentType = UTType.plainText
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
        if hasFileURLs {
            return .file
        }
        if hasReorderItems {
            return .reorder
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

struct TrackReorderInsertionTarget: Equatable {
    let trackID: SessionTrack.ID
    let placement: TrackReorderInsertionPlacement
}

enum ImportActionMenuItem: CaseIterable {
    case open
    case finderSelection
    case musicSelection

    static let dropdownItems: [ImportActionMenuItem] = [
        .finderSelection,
        .musicSelection
    ]

    var title: String {
        switch self {
        case .open:
            "Open..."
        case .finderSelection:
            "Open Finder Selection"
        case .musicSelection:
            "Open Apple Music Selection"
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

    private let loadAppleMusicSelection: @MainActor () -> Void
    private let loadFinderSelection: @MainActor () -> Void
    private let showActiveTrackInFinderAction: @MainActor () -> Void
    private let removeActiveTrackAction: @MainActor () -> Void
    private let clearAllTracksAction: @MainActor () -> Void

    init(
        loadAppleMusicSelection: @escaping @MainActor () -> Void = {},
        loadFinderSelection: @escaping @MainActor () -> Void = {},
        showActiveTrackInFinder: @escaping @MainActor () -> Void = {},
        removeActiveTrack: @escaping @MainActor () -> Void = {},
        clearAllTracks: @escaping @MainActor () -> Void = {}
    ) {
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
    let resetWindowSize: @MainActor () -> Void
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
    @ObservedObject var controller: PlaybackController
    @EnvironmentObject private var settings: AppSettings

    @StateObject private var openFileCommandState = OpenFileCommandState()
    @StateObject private var waveformStore = WaveformStore()
    @State private var keyMonitor: KeyMonitor?
    @State private var mouseMonitor: MouseMonitor?
    @State private var reorderInsertionTarget: TrackReorderInsertionTarget?
    @State private var windowIsDropTargeted = false
    @State private var emptyStateIsHovered = false
    @State private var hoveredTrackID: SessionTrack.ID?
    @State private var focusedOffsetTrackID: SessionTrack.ID?
    @State private var didConfigureMainWindow = false
    @State private var mainWindow: NSWindow?
    @State private var loopDraft: LoopDraft?
    @State private var transportReadoutWidth: CGFloat = TransportReadoutWidthKey.defaultValue
    @State private var showsAlignmentAttentionPopover = false
    @State private var alignmentOutcomePulse = false

    /// An in-progress loop drag, in absolute seconds. `start` is where the drag
    /// began; `current` tracks the pointer. Committed to a `LoopRegion` on mouse-up.
    private struct LoopDraft {
        var start: TimeInterval
        var current: TimeInterval
    }

    /// Coordinate space for the waveform column, so loop gestures report x in
    /// `0...waveformWidth` regardless of the column's offset.
    private static let loopColumnSpace = "loopColumn"
    /// Coordinate space for the timeline ruler, so ruler gestures report x in
    /// `0...waveformWidth` just like the waveform column.
    private static let rulerSpace = "timelineRuler"
    /// Coordinate space for the section-level playhead overlay (grabber + line),
    /// so a grabber drag reports x across the whole section.
    private static let playheadSpace = "timelinePlayhead"
    /// Horizontal travel (points) that turns a click into a loop drag.
    private static let loopDragThreshold: CGFloat = 4

    init(controller: PlaybackController) {
        self.controller = controller
        _openFileCommandState = StateObject(
            wrappedValue: OpenFileCommandState(
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

    var body: some View {
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
                guard !didConfigureMainWindow else { return }
                didConfigureMainWindow = true
                TakesWindowPolicy.configureMainWindow(window)
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
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $windowIsDropTargeted) { providers in
            loadDroppedURLs(from: providers)
        }
        .fileImporter(
            isPresented: $openFileCommandState.isImportingTracks,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .focusedSceneValue(\.openFileCommandState, openFileCommandState)
        .focusedSceneValue(
            \.mainWindowCommandState,
            MainWindowCommandState {
                guard let mainWindow else { return }
                TakesWindowPolicy.resetMainWindowSize(mainWindow)
            }
        )
        .focusedSceneValue(\.canShowActiveTrackInFinder, controller.session.activeTrack != nil)
        .focusedSceneValue(\.canRemoveActiveTrack, controller.session.activeTrackID != nil)
        .focusedSceneValue(\.canUseGlobalMenuShortcuts, focusedOffsetTrackID == nil)
        .focusedSceneValue(\.canClearTracks, !controller.session.tracks.isEmpty)
        .onAppear {
            setupKeyMonitor()
            waveformStore.sync(tracks: controller.session.tracks)
            NSApp.appearance = settings.appearanceTheme.nsAppearance
        }
        .onChange(of: settings.appearanceTheme) { _, theme in
            NSApp.appearance = theme.nsAppearance
        }
        .onChange(of: controller.session.tracks) { _, tracks in
            waveformStore.sync(tracks: tracks)
        }
        .onChange(of: controller.session.tracks.count) { previousTrackCount, trackCount in
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
        .onDisappear {
            keyMonitor?.stop()
            mouseMonitor?.stop()
        }
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
                DigitalTimeReadout(
                    style: settings.readoutStyle,
                    elapsed: controller.session.transportPosition.formattedSignedTimestamp
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
                            visibleSpan: max(controller.session.visibleSpan, 0.001),
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
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
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
            Image(systemName: isOn ? "eye.slash" : "eye")
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

    private var visibleStart: TimeInterval {
        controller.session.visibleStart
    }

    private var visibleSpan: TimeInterval {
        max(controller.session.visibleSpan, 0.001)
    }

    private var trackRowHeight: CGFloat {
        TakesWindowPolicy.trackRowHeight
    }

    private var trackInfoWidth: CGFloat {
        240
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
        TakesWindowPolicy.trackTimelineHeight(displayingTrackRows: controller.session.tracks.count)
    }

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
                timelineEnd: controller.session.visibleEnd
            )
        ) * width
    }

    private var trackTimelineSection: some View {
        GeometryReader { proxy in
            let waveformWidth = max(proxy.size.width - trackInfoWidth, 1)
            VStack(alignment: .leading, spacing: 0) {
                if controller.session.tracks.isEmpty {
                    // The empty state owns the whole section — no header, no
                    // column split — one centered drop/click target.
                    trackAreaEmptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    trackTimelineHeader(waveformWidth: waveformWidth)
                        .frame(width: proxy.size.width, height: trackHeaderHeight)
                    Divider()

                    ScrollView(.vertical) {
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 0) {
                                ForEach(Array(controller.session.tracks.enumerated()), id: \.element.id) { index, sessionTrack in
                                    trackRow(index: index, sessionTrack: sessionTrack, infoWidth: trackInfoWidth)
                                    if index < controller.session.tracks.count - 1 {
                                        Divider()
                                            .frame(height: trackTimelineDividerHeight)
                                    }
                                }
                            }

                            if controller.session.isPlayable {
                                loopSelectionOverlay(waveformWidth: waveformWidth)
                            }
                        }
                        .frame(width: proxy.size.width)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .overlay(alignment: .topLeading) {
                if !controller.session.tracks.isEmpty {
                    TimelineScrollOverlay(
                        visibleStart: controller.session.visibleStart,
                        visibleSpan: visibleSpan,
                        contentStart: controller.session.timelineStart,
                        contentEnd: controller.session.timelineEnd,
                        onScroll: { controller.scrollTimeline(toVisibleStart: $0) },
                        onMagnify: { controller.magnifyTimeline(by: $0, atFraction: $1) }
                    )
                    .frame(width: waveformWidth, height: proxy.size.height)
                    .offset(x: trackInfoWidth)
                }
            }
            .overlay(alignment: .topLeading) {
                // Frozen-column edge: one continuous hairline at the info/waveform
                // boundary, running the full height so the header's control|ruler
                // border and the rows' info|waveform border are the same line.
                // With no tracks the whole section is the empty state, so there
                // is no column boundary to draw.
                if !controller.session.tracks.isEmpty {
                    Rectangle()
                        .fill(Theme.frozenColumnEdge)
                        .frame(width: 1, height: proxy.size.height)
                        .offset(x: trackInfoWidth)
                        .allowsHitTesting(false)
                }
            }
            // Playhead drawn last so the grabber and line sit ON TOP of the
            // frozen-column and header/row dividers rather than under them.
            .overlay(alignment: .topLeading) {
                timelinePlayheadOverlay(sectionHeight: proxy.size.height, waveformWidth: waveformWidth)
            }
            .coordinateSpace(name: Self.playheadSpace)
        }
    }

    private func trackTimelineHeader(waveformWidth: CGFloat) -> some View {
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
            .frame(width: trackInfoWidth, height: trackHeaderHeight, alignment: .leading)
            .overlay(alignment: .trailing) {
                Button("Remove All") {
                    controller.clearTracks()
                }
                .controlSize(.regular)
                .disabled(controller.session.tracks.isEmpty)
                .help("Remove all tracks")
                .padding(.trailing, 8)
            }

            timelineHeaderRuler(width: waveformWidth)
                .frame(maxWidth: .infinity)
                // Same click-to-seek / drag-to-loop behaviour as the waveform column.
                .contentShape(Rectangle())
                .gesture(loopSelectionGesture(waveformWidth: waveformWidth, in: Self.rulerSpace))
                .coordinateSpace(name: Self.rulerSpace)
                .componentDebugLabel("Timeline Ruler", enabled: settings.showsComponentDebugLabels, color: .orange)
        }
        .componentDebugLabel("Timeline Header", enabled: settings.showsComponentDebugLabels)
    }

    /// GarageBand-style grabber art: a downward pentagon (flat top, straight sides,
    /// converging to a small flat tip) with beveled dimension and grip lines.
    /// Positioning, hit area, and gesture are applied by the caller.
    private var playheadGrabberArt: some View {
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
            .accessibilityHidden(true)
    }

    /// The full playhead — the grabber seated on the ruler notches plus the line
    /// running down over the lanes — drawn as one overlay on top of the whole
    /// section so it sits ABOVE the frozen-column and header/row dividers. The
    /// grabber is draggable to scrub; the line is inert. Mirrors the same
    /// `isPlayable` + in-range guard used elsewhere.
    @ViewBuilder
    private func timelinePlayheadOverlay(sectionHeight: CGFloat, waveformWidth: CGFloat) -> some View {
        let playheadX = xPosition(for: controller.session.transportPosition, width: waveformWidth)
        if controller.session.isPlayable, playheadX >= -1, playheadX <= waveformWidth + 1 {
            let handleWidth: CGFloat = 14
            let handleHeight: CGFloat = 16
            // Comfortable grab target a bit wider than the visible grabber.
            let hitWidth: CGFloat = 22
            // Whole-pixel center so the 2pt tip and 2pt line overlap exactly.
            let centerX = trackInfoWidth + playheadX.rounded()
            // The grabber's flat tip seats just below the header/rows divider, where the line begins.
            let seatBottom = trackHeaderHeight + trackTimelineDividerHeight
            let lineHeight = max(min(trackTimelineHeight, sectionHeight - seatBottom), 0)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Theme.secondary)
                    // Center (not leading edge) of the 2pt line on centerX.
                    .frame(width: 2, height: lineHeight)
                    .offset(x: centerX - 1, y: seatBottom)
                    .allowsHitTesting(false)

                playheadGrabberArt
                    .frame(width: handleWidth, height: handleHeight)
                    // Wider transparent hit area centered on the same x as the art.
                    .frame(width: hitWidth, height: handleHeight)
                    .contentShape(Rectangle())
                    // Seat the grabber so its flat tip lands at seatBottom (on the line's top).
                    .offset(x: centerX - hitWidth / 2, y: seatBottom - handleHeight)
                    .onHover { inside in
                        if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                    }
                    // Drag the grabber to scrub. Reports x across the section space.
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.playheadSpace))
                            .onChanged { value in
                                controller.seek(to: globalTime(atX: value.location.x - trackInfoWidth, width: waveformWidth))
                            }
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func timelineHeaderRuler(width: CGFloat) -> some View {
        let rulerStart = max(visibleStart, controller.session.timelineStart)
        let rulerEnd = min(controller.session.visibleEnd, controller.session.timelineEnd)
        let ruler = TimelineHeaderMarker.ruler(
            timelineStart: rulerStart,
            timelineEnd: rulerEnd,
            targetMarkerCount: timelineHeaderTargetMarkerCount,
            // Keep the just-off-screen major tick so its label clips at the left edge while scrolling
            // rather than blinking out (mirrors the right-edge clipping in TimelineHeaderLabelLayout).
            leadingMajorTicks: 1
        )

        // Drop minor ticks once they would pack closer than this; keeps the ruler from turning into
        // a gray blur at narrow widths or high subdivision counts.
        let visibleSpan = controller.session.visibleEnd - visibleStart
        let minorSpacing = visibleSpan > 0 ? ruler.minorInterval / visibleSpan * Double(width) : 0
        let showMinorTicks = minorSpacing >= timelineHeaderMinorTickMinSpacing

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
                        timelineHeaderMinorTick(at: tickTime, width: width)
                    }
                }
                ForEach(ruler.majorTicks, id: \.time) { marker in
                    timelineHeaderMarker(marker, width: width)
                }
            }
        }
        .clipped()
        .accessibilityLabel("Timeline")
    }

    // Ruler notches hang downward from below the numbers toward the rows, Fission-style:
    // major (labeled) ticks are tall — their top edge comes up to just beneath the number so the
    // label sits against the tick like a baseline — while minor ticks stay short. Both are
    // bottom-anchored so they hang toward the rows.
    private var timelineHeaderTickColor: Color { .secondary.opacity(0.45) }
    private var timelineHeaderMajorTickHeight: CGFloat { 19 }
    private var timelineHeaderMinorTickHeight: CGFloat { 8 }
    /// Vertical inset of the time label from the top of the header.
    private var timelineHeaderLabelTopInset: CGFloat { 7 }

    private func timelineHeaderMinorTick(at time: TimeInterval, width: CGFloat) -> some View {
        Rectangle()
            .fill(timelineHeaderTickColor)
            .frame(width: 1, height: timelineHeaderMinorTickHeight)
            .offset(x: xPosition(for: time, width: width))
            // Anchor to the bottom so the notch hangs down toward the waveforms.
            .frame(width: width, height: trackHeaderHeight, alignment: .bottomLeading)
            .accessibilityHidden(true)
    }

    private func timelineHeaderMarker(_ marker: TimelineHeaderMarker, width: CGFloat) -> some View {
        let tickX = xPosition(for: marker.time, width: width)
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
                    .offset(x: CGFloat(labelLayout.x), y: timelineHeaderLabelTopInset)
            }

            // Taller notch hanging below the number, anchored to the header bottom.
            Rectangle()
                .fill(timelineHeaderTickColor)
                .frame(width: 1, height: timelineHeaderMajorTickHeight)
                .offset(x: tickX)
                .frame(width: width, height: trackHeaderHeight, alignment: .bottomLeading)
        }
        .frame(width: width, height: trackHeaderHeight, alignment: .topLeading)
        .accessibilityLabel(marker.label)
    }

    private func trackRow(
        index: Int,
        sessionTrack: SessionTrack,
        infoWidth: CGFloat
    ) -> some View {
        let isActive = controller.session.activeTrackID == sessionTrack.id
        let isHovered = hoveredTrackID == sessionTrack.id
        return HStack(spacing: 0) {
            trackInfoArea(index: index, sessionTrack: sessionTrack, showsTrash: isHovered)
                .frame(width: infoWidth, height: trackRowHeight, alignment: .leading)
                .contentShape(Rectangle())
                .overlay(alignment: .top) {
                    reorderInsertionIndicator(for: sessionTrack.id, placement: .before)
                }
                .overlay(alignment: .bottom) {
                    reorderInsertionIndicator(for: sessionTrack.id, placement: .after)
                }
                .onDrag {
                    trackReorderProvider(for: sessionTrack.id)
                }
                .onDrop(
                    of: TrackRowDropTarget.acceptedContentTypeIdentifiers,
                    delegate: TrackRowDropDelegate(
                        controller: controller,
                        targetTrackID: sessionTrack.id,
                        rowHeight: trackRowHeight,
                        reorderInsertionTarget: $reorderInsertionTarget,
                        destinationAfterTargetTrackID: {
                            destinationTrackID(after: sessionTrack.id)
                        },
                        loadDroppedURLs: loadDroppedURLs
                    )
                )
                .onTapGesture {
                    controller.selectActiveTrack(sessionTrack.id)
                }

            waveformLane(index: index, sessionTrack: sessionTrack)
                .frame(maxWidth: .infinity)
                .frame(height: trackRowHeight)
        }
        .frame(height: trackRowHeight)
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
        .onHover { inside in
            hoveredTrackID = inside ? sessionTrack.id : (hoveredTrackID == sessionTrack.id ? nil : hoveredTrackID)
        }
    }

    /// Kaleidoscope-style empty state: one centered composition — a soft
    /// circular badge holding a waveform glyph, a single line of text below —
    /// owning the whole track section with no header or column split. Hovering
    /// darkens the badge and swaps the drag prompt for a click prompt; clicking
    /// anywhere opens the file dialog. Dragging files over any part of the
    /// window tints the badge, glyph, and background with the indigo brand
    /// color (drops are handled by the window-wide `onDrop`).
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
                Text("Drag Audio Files Here to Compare")
                    .opacity(emptyStateIsHovered && !isTargeted ? 0 : 1)
                Text("Click Here to Compare")
                    .opacity(emptyStateIsHovered && !isTargeted ? 1 : 0)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.primary.opacity(isTargeted ? 0.08 : 0))
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

    private func trackInfoArea(index: Int, sessionTrack: SessionTrack, showsTrash: Bool) -> some View {
        let track = sessionTrack.loadedTrack
        let isActive = controller.session.activeTrackID == sessionTrack.id
        let isBlind = controller.session.isBlindListeningModeEnabled
        let title = isBlind ? "Track \(index + 1)" : track.displayName
        // Badge on the left; filename, metadata, and the Offset row form a single
        // left-aligned column to its right so all three share the filename's left
        // edge. Vertically centered so the info column matches the waveform lane.
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            trackIndexBadge(index: index, isActive: isActive)
                // Baseline is technically aligned, but the fixed badge frame makes
                // the centered number read a touch low; nudge it up 1pt.
                .offset(y: -1)

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
                            .help(title)

                        Spacer(minLength: 0)

                        Button {
                            controller.removeTrack(sessionTrack.id)
                        } label: {
                            Image(systemName: "trash")
                                .accessibilityLabel("Remove Track \(index + 1)")
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.borderless)
                        .frame(width: 16, height: 16)
                        // Only surfaces on hover; kept mounted (opacity, not removed) so it
                        // stays reachable by accessibility/keyboard.
                        .opacity(showsTrash ? 1 : 0)
                    }

                    Text(track.metadataSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .opacity(isBlind ? 0 : 1)
                        .accessibilityHidden(isBlind)
                }

                offsetControl(sessionTrack: sessionTrack)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity, alignment: .center)
        .componentDebugLabel("Track Info", enabled: settings.showsComponentDebugLabels, color: .green)
    }

    /// The rounded index badge: filled with the primary color when the row is
    /// active (white number), a neutral fill otherwise (secondary number).
    private func trackIndexBadge(index: Int, isActive: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let badge = settings.indexBadgeAppearance
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

    private func offsetControl(sessionTrack: SessionTrack) -> some View {
        let offsetMs = Int((sessionTrack.loadedTrack.offsetSeconds * 1000).rounded())
        let binding = Binding(
            get: { offsetMs },
            set: { controller.setOffset(sessionTrack.id, seconds: Double($0) / 1000) }
        )
        // firstTextBaseline so the "Offset" caption sits on the same line as the
        // field's numeric text; both use .caption so their baselines match.
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Offset")
                .font(.caption)
                .foregroundStyle(.secondary)

            offsetField(binding: binding, trackID: sessionTrack.id)
        }
    }

    /// Composite offset control: a single rounded, bordered box holding the
    /// borderless numeric field, a static "ms" unit, and an embedded stepper — so
    /// it reads as one input `[  0  ms  ⌃⌄ ]`. Typed-entry/clamping and the
    /// Shift-large-step behavior come from `IntegerInputField`; the stepper mirrors
    /// the same step amounts.
    private func offsetField(binding: Binding<Int>, trackID: SessionTrack.ID) -> some View {
        let isFocused = focusedOffsetTrackID == trackID
        return HStack(spacing: 4) {
            IntegerInputField(
                value: binding,
                configuration: settings.offsetConfiguration,
                onFocusChange: { focused in
                    if focused {
                        focusedOffsetTrackID = trackID
                    } else if focusedOffsetTrackID == trackID {
                        focusedOffsetTrackID = nil
                    }
                }
            )
            .frame(width: 44)

            Text("ms")
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    binding.wrappedValue = 0
                }
                .accessibilityLabel("Offset units")
                .accessibilityHint("Double click to reset offset to zero milliseconds.")

            Stepper(
                "Offset",
                onIncrement: { stepOffset(binding: binding, direction: 1) },
                onDecrement: { stepOffset(binding: binding, direction: -1) }
            )
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.leading, 6)
        .padding(.trailing, 3)
        .padding(.vertical, 2)
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
                    isFocused
                        ? AnyShapeStyle(Theme.primary)
                        : AnyShapeStyle(LinearGradient(
                            colors: [.black.opacity(0.14), .white.opacity(0.45)],
                            startPoint: .top,
                            endPoint: .bottom
                        )),
                    lineWidth: isFocused ? 1.5 : 1
                )
        }
        .shadow(color: isFocused ? Theme.primary.opacity(0.55) : .clear, radius: 3)
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }

    private func stepOffset(binding: Binding<Int>, direction: Int) {
        binding.wrappedValue = settings.offsetConfiguration.steppedValue(
            from: binding.wrappedValue,
            direction: direction,
            largeStep: NumericControlConfiguration.isLargeStepModifierFlags(NSEvent.modifierFlags)
        )
    }

    /// Major-tick x-positions (points) across a lane of the given width, using the
    /// same ruler computation the header draws so the faint lane lines line up with
    /// the labeled ticks and scroll/zoom in lockstep.
    private func laneMajorTickXs(width: CGFloat) -> [CGFloat] {
        let rulerStart = max(visibleStart, controller.session.timelineStart)
        let rulerEnd = min(controller.session.visibleEnd, controller.session.timelineEnd)
        let ruler = TimelineHeaderMarker.ruler(
            timelineStart: rulerStart,
            timelineEnd: rulerEnd,
            targetMarkerCount: timelineHeaderTargetMarkerCount,
            leadingMajorTicks: 1
        )
        return ruler.majorTicks.map { xPosition(for: $0.time, width: width) }
    }

    private func waveformLane(index: Int, sessionTrack: SessionTrack) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.background.opacity(0.01))

                // Faint major-tick guides behind the waveform, aligned with the
                // ruler's labeled ticks above.
                ForEach(Array(laneMajorTickXs(width: proxy.size.width).enumerated()), id: \.offset) { _, tickX in
                    Rectangle()
                        .fill(Theme.hairline.opacity(0.5))
                        .frame(width: 1)
                        .offset(x: tickX)
                        .accessibilityHidden(true)
                }

                let isActive = controller.session.activeTrackID == sessionTrack.id
                if controller.session.isBlindListeningModeEnabled {
                    blindPlaceholderWaveform()
                        .frame(width: proxy.size.width, height: 58)
                        .foregroundStyle(isActive ? Theme.primary.opacity(0.70) : Theme.waveformInactive.opacity(0.58))
                } else {
                    let loaded = sessionTrack.loadedTrack
                    waveformShape(for: waveformStore.waveform(for: sessionTrack.id), track: loaded)
                        .frame(width: proxy.size.width, height: 58)
                        .foregroundStyle(isActive ? Theme.primary.opacity(0.85) : Theme.waveformInactive.opacity(0.7))
                }

                Rectangle()
                    .fill(.secondary.opacity(0.25))
                    .frame(width: 1)
                    .offset(x: xPosition(for: 0, width: proxy.size.width))
            }
            .clipped()
            .componentDebugLabel("Waveform Lane", enabled: settings.showsComponentDebugLabels, color: .purple)
        }
    }

    // MARK: - Loop selection

    /// The interaction layer, selection rectangle, and resize handles for the
    /// loop, spanning all lanes across the waveform column. Clipped to the column
    /// so an off-screen loop never spills into the track-info column.
    private func loopSelectionOverlay(waveformWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // Drag to select a loop; click to seek (and deselect if outside the loop).
            Color.clear
                .contentShape(Rectangle())
                .gesture(loopSelectionGesture(waveformWidth: waveformWidth, in: Self.loopColumnSpace))

            if let range = activeLoopXRange(waveformWidth: waveformWidth) {
                Rectangle()
                    .fill(Theme.secondary.opacity(0.16))
                    .overlay(alignment: .leading) { loopEdge() }
                    .overlay(alignment: .trailing) { loopEdge() }
                    .frame(width: max(1, range.upperBound - range.lowerBound), height: trackTimelineHeight)
                    .offset(x: range.lowerBound)
                    .allowsHitTesting(false)
            }

            // Resize handles for a committed loop (not while drafting a new one).
            if loopDraft == nil, let loop = controller.session.loopRegion {
                loopResizeHandle(atTime: loop.start, waveformWidth: waveformWidth) { time in
                    controller.resizeLoop(start: time)
                }
                loopResizeHandle(atTime: loop.end, waveformWidth: waveformWidth) { time in
                    controller.resizeLoop(end: time)
                }
            }
        }
        .frame(width: waveformWidth, height: trackTimelineHeight, alignment: .topLeading)
        .clipped()
        .coordinateSpace(name: Self.loopColumnSpace)
        .offset(x: trackInfoWidth)
    }

    /// Grab handle drawn at each loop edge: a slim accent rod inside a soft
    /// accent halo. Deliberately unlike the flat solid playhead line, so it
    /// reads as draggable and stays distinguishable when the playhead sits on
    /// top of it.
    private func loopEdge() -> some View {
        Capsule()
            .fill(Theme.secondary)
            .shadow(color: Theme.secondary.opacity(0.85), radius: 3)
            .frame(width: 2)
    }

    /// x-span (points, within the waveform column) of the draft loop while
    /// dragging, else the committed loop; `nil` when there is nothing to draw.
    private func activeLoopXRange(waveformWidth: CGFloat) -> ClosedRange<CGFloat>? {
        let start: TimeInterval
        let end: TimeInterval
        if let draft = loopDraft {
            start = min(draft.start, draft.current)
            end = max(draft.start, draft.current)
        } else if let loop = controller.session.loopRegion {
            start = loop.start
            end = loop.end
        } else {
            return nil
        }
        let x0 = xPosition(for: start, width: waveformWidth)
        let x1 = xPosition(for: end, width: waveformWidth)
        return min(x0, x1)...max(x0, x1)
    }

    private func loopResizeHandle(
        atTime time: TimeInterval,
        waveformWidth: CGFloat,
        onDrag: @escaping (TimeInterval) -> Void
    ) -> some View {
        let x = xPosition(for: time, width: waveformWidth)
        let hitWidth: CGFloat = 12
        return Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: hitWidth, height: trackTimelineHeight)
            .contentShape(Rectangle())
            .offset(x: x - hitWidth / 2)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.loopColumnSpace))
                    .onChanged { value in
                        onDrag(globalTime(atX: value.location.x, width: waveformWidth))
                    }
            )
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
                    start: controller.session.transportPosition,
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

    @ViewBuilder
    private func waveformShape(for waveform: Waveform?, track: LoadedTrack) -> some View {
        let windowStart = visibleStart
        let windowSpan = visibleSpan
        Canvas { context, size in
            guard let waveform, waveform.bucketCount > 0, !waveform.peaks.isEmpty else { return }
            context.fill(
                Self.waveformPath(
                    for: waveform,
                    in: size,
                    trackStart: track.offsetSeconds,
                    trackDuration: track.duration,
                    visibleStart: windowStart,
                    visibleSpan: windowSpan
                ),
                with: .foreground
            )
        }
    }

    private func blindPlaceholderWaveform() -> some View {
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

    /// Builds a filled, center-mirrored peak envelope across the visible window.
    ///
    /// The Canvas is always the viewport width, never the (potentially enormous)
    /// full track width, so the work stays O(viewport px) regardless of zoom and
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
    private static func waveformPath(
        for waveform: Waveform,
        in size: CGSize,
        trackStart: TimeInterval,
        trackDuration: TimeInterval,
        visibleStart: TimeInterval,
        visibleSpan: TimeInterval
    ) -> Path {
        let bucketCount = waveform.bucketCount
        let peaks = waveform.peaks
        guard bucketCount > 0, !peaks.isEmpty, size.width > 0, size.height > 0,
              trackDuration > 0, visibleSpan > 0 else {
            return Path()
        }

        let width = size.width
        let midline = size.height / 2
        // A visible floor so silent passages still read as a thin line.
        let minHalfHeight: CGFloat = 0.5
        let available = peaks.count

        // Portion of the visible window the track actually covers.
        let trackEnd = trackStart + trackDuration
        let overlapStart = max(visibleStart, trackStart)
        let overlapEnd = min(visibleStart + visibleSpan, trackEnd)
        guard overlapEnd > overlapStart else { return Path() }

        // x for a (fractional) bucket index, mapped through the visible window.
        func x(forBucket bucket: Double) -> CGFloat {
            CGFloat((trackStart + bucket / Double(bucketCount) * trackDuration - visibleStart) / visibleSpan) * width
        }

        // Buckets per drawn vertex ≈ buckets per on-screen pixel, ≥ 1.
        let bucketsAcrossViewport = visibleSpan / trackDuration * Double(bucketCount)
        let bucketStride = max(1, Int((bucketsAcrossViewport / Double(width)).rounded()))

        // File-anchored group range overlapping the visible region, padded one
        // group each side so the envelope crosses the clip edges smoothly.
        let firstBucket = Int((overlapStart - trackStart) / trackDuration * Double(bucketCount))
        let lastBucket = Int((overlapEnd - trackStart) / trackDuration * Double(bucketCount))
        let firstGroup = firstBucket / bucketStride - 1
        let lastGroup = lastBucket / bucketStride + 1

        // (x, half-height) vertices forming the top edge of the envelope.
        var vertices: [(x: CGFloat, half: CGFloat)] = []
        vertices.reserveCapacity(lastGroup - firstGroup + 1)
        for group in firstGroup...lastGroup {
            guard group >= 0 else { continue }
            let bucketLow = group * bucketStride
            guard bucketLow < available else { break }
            let bucketHigh = min(bucketLow + bucketStride, bucketCount)
            let upper = min(bucketHigh, available)
            guard upper > bucketLow else { break }

            var peak: Float = 0
            for index in bucketLow..<upper where peaks[index] > peak {
                peak = peaks[index]
            }
            let center = Double(bucketLow + bucketHigh) / 2
            vertices.append((x(forBucket: center), max(CGFloat(peak) * midline, minHalfHeight)))
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

    private func trackReorderProvider(for trackID: SessionTrack.ID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: TrackReorderDrag.contentType.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(Data(trackID.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    private func destinationTrackID(after trackID: SessionTrack.ID) -> SessionTrack.ID? {
        guard let index = controller.session.tracks.firstIndex(where: { $0.id == trackID }) else {
            return nil
        }

        let nextIndex = controller.session.tracks.index(after: index)
        guard controller.session.tracks.indices.contains(nextIndex) else {
            return nil
        }
        return controller.session.tracks[nextIndex].id
    }

    @ViewBuilder
    private func reorderInsertionIndicator(
        for trackID: SessionTrack.ID,
        placement: TrackReorderInsertionPlacement
    ) -> some View {
        if reorderInsertionTarget == TrackReorderInsertionTarget(trackID: trackID, placement: placement) {
            Capsule()
                .fill(Theme.primary)
                .frame(height: 3)
                .padding(.horizontal, 10)
                .shadow(color: Theme.primary.opacity(0.25), radius: 2, y: 1)
                .accessibilityHidden(true)
        }
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
            let clickedView = window.contentView?.hitTest(locationInWindow)

            if CursorResetPolicy.shouldUseArrowCursor(currentCursor: NSCursor.current, hitView: clickedView) {
                NSCursor.arrow.set()
            }

            guard event.type != .mouseMoved else { return }
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

private struct TrackRowDropDelegate: DropDelegate {
    @ObservedObject var controller: PlaybackController
    let targetTrackID: SessionTrack.ID
    let rowHeight: CGFloat
    @Binding var reorderInsertionTarget: TrackReorderInsertionTarget?
    let destinationAfterTargetTrackID: () -> SessionTrack.ID?
    let loadDroppedURLs: ([NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        dropKind(for: info) != nil
    }

    func dropEntered(info: DropInfo) {
        updateDropFeedback(info: info)
    }

    func dropExited(info: DropInfo) {
        if reorderInsertionTarget?.trackID == targetTrackID {
            reorderInsertionTarget = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        switch dropKind(for: info) {
        case .file:
            clearDropFeedback()
            return DropProposal(operation: .copy)
        case .reorder:
            updateReorderInsertionTarget(info: info)
            return DropProposal(operation: .move)
        case nil:
            return nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        switch dropKind(for: info) {
        case .file:
            let handled = loadDroppedURLs(info.itemProviders(for: TrackRowDropTarget.acceptedContentTypeIdentifiers))
            clearDropFeedback()
            return handled
        case .reorder:
            guard let provider = info.itemProviders(for: [TrackReorderDrag.contentType.identifier]).first else {
                clearDropFeedback()
                return false
            }
            let placement = TrackReorderInsertionPlacement.location(y: info.location.y, rowHeight: rowHeight)
            provider.loadDataRepresentation(forTypeIdentifier: TrackReorderDrag.contentType.identifier) { data, _ in
                guard let data,
                      let uuidString = String(data: data, encoding: .utf8),
                      let movedTrackID = UUID(uuidString: uuidString)
                else {
                    Task { @MainActor in
                        clearDropFeedback()
                    }
                    return
                }

                Task { @MainActor in
                    let destinationTrackID = placement == .after ? destinationAfterTargetTrackID() : targetTrackID
                    controller.reorderTrack(movedTrackID, before: destinationTrackID)
                    clearDropFeedback()
                }
            }
            return true
        case nil:
            clearDropFeedback()
            return false
        }
    }

    private func updateDropFeedback(info: DropInfo) {
        switch dropKind(for: info) {
        case .file:
            clearDropFeedback()
        case .reorder:
            updateReorderInsertionTarget(info: info)
        case nil:
            break
        }
    }

    private func dropKind(for info: DropInfo) -> TrackRowDropKind? {
        TrackRowDropKind.kind(
            hasFileURLs: info.hasItemsConforming(to: [UTType.fileURL.identifier]),
            hasReorderItems: info.hasItemsConforming(to: [TrackReorderDrag.contentType.identifier])
        )
    }

    private func updateReorderInsertionTarget(info: DropInfo) {
        reorderInsertionTarget = TrackReorderInsertionTarget(
            trackID: targetTrackID,
            placement: TrackReorderInsertionPlacement.location(y: info.location.y, rowHeight: rowHeight)
        )
    }

    private func clearDropFeedback() {
        if reorderInsertionTarget?.trackID == targetTrackID {
            reorderInsertionTarget = nil
        }
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
