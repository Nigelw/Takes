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
    static func shouldClearEditingFocus(firstResponder: NSResponder?, clickedView: NSView?) -> Bool {
        guard firstResponder is NSTextView else { return false }
        guard let clickedView else { return true }

        var currentView: NSView? = clickedView
        while let view = currentView {
            if view is NSTextField {
                return false
            }
            currentView = view.superview
        }

        return true
    }
}

struct GlobalShortcutFocusPolicy {
    static func shouldHandleGlobalShortcut(firstResponder: NSResponder?) -> Bool {
        !(firstResponder is NSTextView || firstResponder is NSTextField)
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
    static let controlWidth: CGFloat = 86
    static let controlHeight: CGFloat = 34
    static let primaryButtonWidth: CGFloat = 48
    static let menuButtonWidth: CGFloat = 37
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
    private let clearAllTracksAction: @MainActor () -> Void

    init(
        loadAppleMusicSelection: @escaping @MainActor () -> Void = {},
        loadFinderSelection: @escaping @MainActor () -> Void = {},
        showActiveTrackInFinder: @escaping @MainActor () -> Void = {},
        clearAllTracks: @escaping @MainActor () -> Void = {}
    ) {
        self.loadAppleMusicSelection = loadAppleMusicSelection
        self.loadFinderSelection = loadFinderSelection
        self.showActiveTrackInFinderAction = showActiveTrackInFinder
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

    func clearAllTracks() {
        clearAllTracksAction()
    }
}

private struct OpenFileCommandStateKey: FocusedValueKey {
    typealias Value = OpenFileCommandState
}

private struct CanClearTracksKey: FocusedValueKey {
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

    var canClearTracks: Bool? {
        get { self[CanClearTracksKey.self] }
        set { self[CanClearTracksKey.self] = newValue }
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
    @State private var emptyTrackIsDropTargeted = false
    @State private var gainPopoverTrackID: SessionTrack.ID?
    @State private var didConfigureMainWindow = false
    @State private var mainWindow: NSWindow?
    @State private var loopDraft: LoopDraft?

    /// An in-progress loop drag, in absolute seconds. `start` is where the drag
    /// began; `current` tracks the pointer. Committed to a `LoopRegion` on mouse-up.
    private struct LoopDraft {
        var start: TimeInterval
        var current: TimeInterval
    }

    /// Coordinate space for the waveform column, so loop gestures report x in
    /// `0...waveformWidth` regardless of the column's offset.
    private static let loopColumnSpace = "loopColumn"
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
                clearAllTracks: {
                    controller.clearTracks()
                }
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            transportBar
                .fixedSize(horizontal: false, vertical: true)
            trackTimelineSection
                .frame(maxHeight: .infinity)
        }
        .padding(20)
        .frame(
            minWidth: TakesWindowPolicy.minimumContentWidth,
            minHeight: TakesWindowPolicy.minimumContentHeight
        )
        .background {
            MainWindowConfigurationView { window in
                mainWindow = window
                guard !didConfigureMainWindow else { return }
                didConfigureMainWindow = true
                TakesWindowPolicy.configureMainWindow(window)
                TakesWindowPolicy.resizeMainWindow(
                    window,
                    displayingTrackRows: controller.session.tracks.count
                )
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
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
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
        .focusedSceneValue(\.canShowActiveTrackInFinder, controller.session.activeTrack != nil)
        .focusedSceneValue(\.canClearTracks, !controller.session.tracks.isEmpty)
        .onAppear {
            setupKeyMonitor()
            waveformStore.sync(tracks: controller.session.tracks)
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
        HStack(spacing: 10) {
            Button(controller.session.isPlaying ? "Pause" : "Play") {
                controller.session.isPlaying ? controller.pause() : controller.play()
            }
            .disabled(!controller.session.isPlayable)

//            Button("Rewind") {
//                controller.seek(to: controller.session.timelineStart)
//            }
            .disabled(!controller.session.isPlayable)

            Button("Switch Track") {
                controller.selectNextTrack()
            }
            .disabled(!controller.session.canSwitchPlayback)

            Spacer()

            Text("\(controller.session.transportPosition.formattedSignedTimestamp) / \(controller.session.timelineEnd.formattedSignedTimestamp)")
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer()

            repeatButton

            zoomControls
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            .frame(width: 150)
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
    }

    private var repeatButton: some View {
        let mode = controller.session.repeatMode
        return Button {
            controller.cycleRepeatMode()
        } label: {
            Image(systemName: Self.repeatSymbol(for: mode))
                .foregroundStyle(mode == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
        }
        .buttonStyle(.borderless)
        .disabled(!controller.session.isPlayable)
        .help(Self.repeatHelp(for: mode))
        .accessibilityLabel("Repeat")
        .accessibilityValue(Self.repeatModeName(for: mode))
    }

    private static func repeatSymbol(for mode: RepeatMode) -> String {
        switch mode {
        case .off, .switchAndRepeat: return "repeat"
        case .one: return "repeat.1"
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
            VStack(alignment: .leading, spacing: 8) {
                trackTimelineHeader(waveformWidth: waveformWidth)
                    .frame(width: proxy.size.width, height: trackHeaderHeight)

                ScrollView(.vertical) {
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            if controller.session.tracks.isEmpty {
                                emptyTrackRow(infoWidth: trackInfoWidth)
                            } else {
                                ForEach(Array(controller.session.tracks.enumerated()), id: \.element.id) { index, sessionTrack in
                                    trackRow(index: index, sessionTrack: sessionTrack, infoWidth: trackInfoWidth)
                                    if index < controller.session.tracks.count - 1 {
                                        Divider()
                                            .frame(height: trackTimelineDividerHeight)
                                    }
                                }
                            }
                        }
                        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                        if controller.session.isPlayable {
                            loopSelectionOverlay(waveformWidth: waveformWidth)
                        }

                        let playheadX = xPosition(for: controller.session.transportPosition, width: waveformWidth)
                        if controller.session.isPlayable, playheadX >= -1, playheadX <= waveformWidth + 1 {
                            Rectangle()
                                .fill(.blue)
                                .frame(width: 2, height: trackTimelineHeight - 16)
                                .offset(x: trackInfoWidth + playheadX, y: 8)
                                // Never let the thin playhead swallow drags meant
                                // for a loop handle sitting directly beneath it.
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(width: proxy.size.width)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .overlay(alignment: .topLeading) {
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
    }

    private func trackTimelineHeader(waveformWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            ImportActionSplitButton(
                dropdownItems: ImportActionMenuItem.dropdownItems,
                performAction: performImportAction(_:)
            )
            .frame(width: ImportActionControlMetrics.controlWidth, height: ImportActionControlMetrics.controlHeight)
            .padding(.leading, 8)
            .frame(width: trackInfoWidth, alignment: .leading)
            .overlay(alignment: .trailing) {
                Button("Clear All") {
                    controller.clearTracks()
                }
                .controlSize(.regular)
                .disabled(controller.session.tracks.isEmpty)
                .help("Clear all tracks")
                .padding(.trailing, 8)
            }

            timelineHeaderRuler(width: waveformWidth)
                .frame(maxWidth: .infinity)
        }
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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

    private func timelineHeaderMinorTick(at time: TimeInterval, width: CGFloat) -> some View {
        Rectangle()
            .fill(.secondary.opacity(0.45))
            .frame(width: 1, height: 5)
            .offset(x: xPosition(for: time, width: width))
            .frame(width: width, height: ImportActionControlMetrics.controlHeight, alignment: .topLeading)
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
            Rectangle()
                .fill(.secondary.opacity(0.45))
                .frame(width: 1, height: 13)
                .offset(x: tickX)

            if labelLayout.isVisible {
                Text(marker.label)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: labelWidth, alignment: .leading)
                    .offset(x: CGFloat(labelLayout.x), y: 11)
            }
        }
        .frame(width: width, height: ImportActionControlMetrics.controlHeight, alignment: .topLeading)
        .accessibilityLabel(marker.label)
    }

    private func trackRow(
        index: Int,
        sessionTrack: SessionTrack,
        infoWidth: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            trackInfoArea(index: index, sessionTrack: sessionTrack)
                .frame(width: infoWidth, height: trackRowHeight, alignment: .leading)
                .background(backgroundStyle(for: .normal))
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
    }

    private func emptyTrackRow(infoWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Track 1")
                    .font(.headline)
                Text("No file loaded")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(width: infoWidth, height: trackRowHeight, alignment: .leading)
            .background(backgroundStyle(for: TrackDropHighlight.empty(isTargeted: emptyTrackIsDropTargeted)))

            waveformLane(index: 0, sessionTrack: nil)
                .frame(maxWidth: .infinity)
                .frame(height: trackRowHeight)
        }
        .frame(height: trackRowHeight)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $emptyTrackIsDropTargeted) { providers in
            loadDroppedURLs(from: providers)
        }
    }

    private func trackInfoArea(index: Int, sessionTrack: SessionTrack) -> some View {
        let track = sessionTrack.loadedTrack
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Track \(index + 1)")
                    .font(.headline)
                if controller.session.activeTrackID == sessionTrack.id {
                    Text("Active")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.15), in: Capsule())
                }
                Spacer()
                Button {
                    if gainPopoverTrackID == sessionTrack.id {
                        gainPopoverTrackID = nil
                    }
                    controller.removeTrack(sessionTrack.id)
                } label: {
                    Image(systemName: "trash")
                        .accessibilityLabel("Remove Track \(index + 1)")
                }
                .buttonStyle(.borderless)

                gainButton(sessionTrack: sessionTrack)
            }

            Text(track.displayName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(track.metadataSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            offsetControl(sessionTrack: sessionTrack)
        }
        .padding(12)
    }

    private func gainButton(sessionTrack: SessionTrack) -> some View {
        Button {
            gainPopoverTrackID = sessionTrack.id
        } label: {
            Image(systemName: "gearshape")
                .accessibilityLabel("\(sessionTrack.loadedTrack.displayName) Settings")
        }
        .buttonStyle(.borderless)
        .popover(
            isPresented: Binding(
                get: { gainPopoverTrackID == sessionTrack.id },
                set: { isPresented in
                    gainPopoverTrackID = isPresented ? sessionTrack.id : nil
                }
            ),
            arrowEdge: .trailing
        ) {
            gainPopoverContent(sessionTrack: sessionTrack)
                .padding()
                .frame(width: 300)
        }
    }

    private func gainPopoverContent(sessionTrack: SessionTrack) -> some View {
        let gainValue = Int(sessionTrack.loadedTrack.gainDB.rounded())
        return VStack(alignment: .leading, spacing: 10) {
            Text("Track Gain")
                .font(.headline)
            Text("\(gainValue) dB")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ResettableSlider(
                    value: Binding(
                        get: { Double(gainValue) },
                        set: { controller.setGain(sessionTrack.id, db: Float(Int($0.rounded()))) }
                    ),
                    range: -24...24,
                    resetValue: 0
                )
                NumericControlRow(
                    value: Binding(
                        get: { gainValue },
                        set: { controller.setGain(sessionTrack.id, db: Float($0)) }
                    ),
                    configuration: .gain
                )
            }
        }
    }

    private func offsetControl(sessionTrack: SessionTrack) -> some View {
        let offsetMs = Int((sessionTrack.loadedTrack.offsetSeconds * 1000).rounded())
        return VStack(alignment: .leading, spacing: 4) {
            Text("Offset \(offsetMs) ms")
                .font(.caption)
                .foregroundStyle(.secondary)
            NumericControlRow(
                value: Binding(
                    get: { offsetMs },
                    set: { controller.setOffset(sessionTrack.id, seconds: Double($0) / 1000) }
                ),
                configuration: settings.offsetConfiguration
            )
        }
    }

    private func waveformLane(index: Int, sessionTrack: SessionTrack?) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.background.opacity(0.01))

                if let sessionTrack {
                    let loaded = sessionTrack.loadedTrack
                    waveformShape(for: waveformStore.waveform(for: sessionTrack.id), track: loaded)
                        .frame(width: proxy.size.width, height: 58)
                        .foregroundStyle(trackColor(index: index).opacity(0.55))
                } else {
                    Text("Drop audio file here")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 16)
                }

                Rectangle()
                    .fill(.secondary.opacity(0.25))
                    .frame(width: 1)
                    .offset(x: xPosition(for: 0, width: proxy.size.width))
            }
            .clipped()
        }
    }

    // MARK: - Loop selection

    /// The interaction layer, selection rectangle, and resize handles for the
    /// loop, spanning all lanes across the waveform column. Clipped to the column
    /// so an off-screen loop never spills into the track-info column.
    private func loopSelectionOverlay(waveformWidth: CGFloat) -> some View {
        let laneHeight = trackTimelineHeight - 16
        return ZStack(alignment: .topLeading) {
            // Drag to select a loop; click to seek (and deselect if outside the loop).
            Color.clear
                .contentShape(Rectangle())
                .gesture(loopSelectionGesture(waveformWidth: waveformWidth))

            if let range = activeLoopXRange(waveformWidth: waveformWidth) {
                Rectangle()
                    .fill(Color.blue.opacity(0.14))
                    .overlay(alignment: .leading) { loopEdge() }
                    .overlay(alignment: .trailing) { loopEdge() }
                    .frame(width: max(1, range.upperBound - range.lowerBound), height: laneHeight)
                    .offset(x: range.lowerBound, y: 8)
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

    /// Grab handle drawn at each loop edge. Deliberately unlike the thin solid
    /// playhead: a wider white capsule with a blue outline, so it reads as
    /// draggable and stays distinguishable when the playhead sits on top of it.
    private func loopEdge() -> some View {
        Capsule()
            .fill(Color.white)
            .overlay(Capsule().strokeBorder(Color.blue, lineWidth: 1.5))
            .frame(width: 6)
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
            .frame(width: hitWidth, height: trackTimelineHeight - 16)
            .contentShape(Rectangle())
            .offset(x: x - hitWidth / 2, y: 8)
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

    private func loopSelectionGesture(waveformWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.loopColumnSpace))
            .onChanged { value in
                let dx = abs(value.location.x - value.startLocation.x)
                if loopDraft != nil || dx > Self.loopDragThreshold {
                    loopDraft = LoopDraft(
                        start: globalTime(atX: value.startLocation.x, width: waveformWidth),
                        current: globalTime(atX: value.location.x, width: waveformWidth)
                    )
                }
            }
            .onEnded { value in
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

    private func trackColor(index: Int) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal]
        return colors[index % colors.count]
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
            return AnyShapeStyle(.blue.opacity(0.16))
        }
        return AnyShapeStyle(.quaternary.opacity(0.4))
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
                .fill(.blue)
                .frame(height: 3)
                .padding(.horizontal, 10)
                .shadow(color: .blue.opacity(0.25), radius: 2, y: 1)
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
            let urls = urlsByProvider.compactMap(\.self)
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
            let axis = scrollAxis(for: event)
            if scrollGestureEnded(event) {
                lockedScrollAxis = nil
            }
            return axis == .horizontal ? self : nil
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

private struct NumericControlRow: View {
    @Binding var value: Int
    let configuration: NumericControlConfiguration

    var body: some View {
        HStack(spacing: 6) {
            Button {
                value = configuration.steppedValue(
                    from: value,
                    direction: -1,
                    largeStep: NumericControlConfiguration.isLargeStepModifierFlags(NSEvent.modifierFlags)
                )
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.bordered)

            IntegerInputField(
                value: $value,
                configuration: configuration
            )
                .frame(width: 70)

            Text(configuration.suffix)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .leading)

            Button {
                value = configuration.steppedValue(
                    from: value,
                    direction: 1,
                    largeStep: NumericControlConfiguration.isLargeStepModifierFlags(NSEvent.modifierFlags)
                )
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.bordered)

            Button {
                value = 0
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .accessibilityLabel("Reset")
            .buttonStyle(.bordered)
        }
    }
}

private struct IntegerInputField: NSViewRepresentable {
    @Binding var value: Int
    let configuration: NumericControlConfiguration

    func makeCoordinator() -> Coordinator {
        Coordinator(
            value: $value,
            configuration: configuration
        )
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NumericInputTextField(frame: .zero)
        textField.alignment = .right
        textField.isBordered = true
        textField.focusRingType = .default
        textField.delegate = context.coordinator
        textField.stringValue = "\(value)"
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.configuration = configuration
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

private struct ResettableSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let resetValue: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    func makeNSView(context: Context) -> DoubleClickResetSlider {
        let slider = DoubleClickResetSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: context.coordinator, action: #selector(Coordinator.valueChanged(_:)))
        slider.doubleActionHandler = {
            context.coordinator.reset(to: resetValue)
        }
        return slider
    }

    func updateNSView(_ nsView: DoubleClickResetSlider, context: Context) {
        nsView.minValue = range.lowerBound
        nsView.maxValue = range.upperBound
        if nsView.doubleValue != value {
            nsView.doubleValue = value
        }
        nsView.doubleActionHandler = {
            context.coordinator.reset(to: resetValue)
        }
    }

    final class Coordinator: NSObject {
        @Binding private var value: Double

        init(value: Binding<Double>) {
            _value = value
        }

        @MainActor
        @objc func valueChanged(_ sender: NSSlider) {
            value = sender.doubleValue
        }

        @MainActor
        func reset(to resetValue: Double) {
            value = resetValue
        }
    }
}

private final class DoubleClickResetSlider: NSSlider {
    var doubleActionHandler: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let resetValue = min(max(0, minValue), maxValue)
            doubleValue = resetValue
            doubleActionHandler?()
            sendAction(action, to: target)
            return
        }

        super.mouseDown(with: event)
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
