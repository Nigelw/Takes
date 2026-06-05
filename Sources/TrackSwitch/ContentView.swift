import SwiftUI
import UniformTypeIdentifiers

struct NumericControlConfiguration {
    let range: ClosedRange<Int>
    let step: Int
    let largeStep: Int
    let suffix: String

    static let gain = NumericControlConfiguration(range: -24...24, step: 1, largeStep: 10, suffix: "dB")
    static let offset = NumericControlConfiguration(range: -300_000...300_000, step: 10, largeStep: 100, suffix: "ms")

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

    init(committedValue: Int) {
        self.committedValue = committedValue
    }

    mutating func beginEditing(currentValue: Int) {
        committedValue = currentValue
    }

    func cancelledValue() -> Int {
        committedValue
    }

    mutating func commit(_ value: Int) {
        committedValue = value
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
        !(firstResponder is NSTextView)
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
    static let contentType = UTType.plainText
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
    case musicSelection

    var title: String {
        switch self {
        case .open:
            "Open..."
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

@MainActor
final class OpenFileCommandState: ObservableObject {
    @Published var isImportingTracks = false

    private let loadAppleMusicSelection: @MainActor () -> Void

    init(loadAppleMusicSelection: @escaping @MainActor () -> Void = {}) {
        self.loadAppleMusicSelection = loadAppleMusicSelection
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
}

private struct OpenFileCommandStateKey: FocusedValueKey {
    typealias Value = OpenFileCommandState
}

extension FocusedValues {
    var openFileCommandState: OpenFileCommandState? {
        get { self[OpenFileCommandStateKey.self] }
        set { self[OpenFileCommandStateKey.self] = newValue }
    }
}

struct ContentView: View {
    @ObservedObject var controller: PlaybackController

    @StateObject private var openFileCommandState = OpenFileCommandState()
    @State private var keyMonitor: KeyMonitor?
    @State private var mouseMonitor: MouseMonitor?
    @State private var dropTargetTrackID: SessionTrack.ID?
    @State private var reorderInsertionTarget: TrackReorderInsertionTarget?
    @State private var emptyTrackIsDropTargeted = false
    @State private var gainPopoverTrackID: SessionTrack.ID?

    init(controller: PlaybackController) {
        self.controller = controller
        _openFileCommandState = StateObject(
            wrappedValue: OpenFileCommandState {
                Task { await controller.loadSelectedLibraryTracks() }
            }
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
        .frame(minWidth: 860, minHeight: 540)
        .alert(
            "TrackSwitch Error",
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
            loadDroppedURLs(from: providers, targetTrackID: nil)
        }
        .fileImporter(
            isPresented: $openFileCommandState.isImportingTracks,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .focusedSceneValue(\.openFileCommandState, openFileCommandState)
        .onAppear {
            setupKeyMonitor()
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
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var timelineSpan: TimeInterval {
        max(controller.session.timelineEnd - controller.session.timelineStart, 0.001)
    }

    private var trackRowHeight: CGFloat {
        124
    }

    private var trackInfoWidth: CGFloat {
        240
    }

    private var trackHeaderHeight: CGFloat {
        34
    }

    private var timelineHeaderTargetMarkerCount: Int {
        7
    }

    private var trackTimelineDividerHeight: CGFloat {
        1
    }

    private var trackTimelineHeight: CGFloat {
        let rowCount = max(controller.session.tracks.count, 1)
        let dividerCount = max(rowCount - 1, 0)
        return trackRowHeight * CGFloat(rowCount) + trackTimelineDividerHeight * CGFloat(dividerCount)
    }

    private func globalTime(atX x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0 else { return controller.session.timelineStart }
        let normalized = min(max(Double(x / width), 0), 1)
        return controller.session.timelineStart + normalized * timelineSpan
    }

    private func xPosition(for globalTime: TimeInterval, width: CGFloat) -> CGFloat {
        CGFloat(
            TransportMapping.normalizedPosition(
                globalTime: globalTime,
                timelineStart: controller.session.timelineStart,
                timelineEnd: controller.session.timelineEnd
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
                            Rectangle()
                                .fill(.blue)
                                .frame(width: 2, height: trackTimelineHeight - 16)
                                .offset(
                                    x: trackInfoWidth + xPosition(for: controller.session.transportPosition, width: waveformWidth),
                                    y: 8
                                )
                        }
                    }
                    .frame(width: proxy.size.width)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }

    private func trackTimelineHeader(waveformWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    performImportAction(.open)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(
                            width: ImportActionControlMetrics.primaryButtonWidth,
                            height: ImportActionControlMetrics.controlHeight
                        )
                        .contentShape(Rectangle())
                        .accessibilityLabel(ImportActionMenuItem.open.title)
                }
                .buttonStyle(.plain)
                .help(ImportActionMenuItem.open.title)

                Divider()
                    .frame(height: ImportActionControlMetrics.controlHeight)

                Menu {
                    ForEach(ImportActionMenuItem.allCases, id: \.self) { item in
                        Button(item.title) {
                            performImportAction(item)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(
                            width: ImportActionControlMetrics.menuButtonWidth,
                            height: ImportActionControlMetrics.controlHeight
                        )
                        .contentShape(Rectangle())
                        .accessibilityLabel("Open Track Menu")
                }
                .menuStyle(.borderlessButton)
                .help("Open Track Menu")
            }
            .frame(width: ImportActionControlMetrics.controlWidth, height: ImportActionControlMetrics.controlHeight)
            .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(.separator, lineWidth: 1)
            )
            .padding(.leading, 8)
            .frame(width: trackInfoWidth, alignment: .leading)

            timelineHeaderRuler(width: waveformWidth)
                .frame(maxWidth: .infinity)
        }
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func timelineHeaderRuler(width: CGFloat) -> some View {
        let markers = TimelineHeaderMarker.markers(
            timelineStart: controller.session.timelineStart,
            timelineEnd: controller.session.timelineEnd,
            targetMarkerCount: timelineHeaderTargetMarkerCount
        )

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.background.opacity(0.01))

            if markers.isEmpty {
                Text("00:00")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .frame(maxHeight: .infinity, alignment: .center)
            } else {
                ForEach(markers, id: \.time) { marker in
                    timelineHeaderMarker(marker, width: width)
                }
            }
        }
        .clipped()
        .accessibilityLabel("Timeline")
    }

    private func timelineHeaderMarker(_ marker: TimelineHeaderMarker, width: CGFloat) -> some View {
        let tickX = xPosition(for: marker.time, width: width)
        let labelWidth: CGFloat = 52
        let labelLayout = TimelineHeaderLabelLayout.leading(
            tickX: Double(tickX),
            labelWidth: Double(labelWidth),
            rulerWidth: Double(width)
        )

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.secondary.opacity(0.45))
                .frame(width: 1, height: 9)
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
                .background(backgroundStyle(for: sessionTrack.id))
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
                    of: [TrackReorderDrag.contentType.identifier, UTType.fileURL.identifier],
                    delegate: TrackInfoDropDelegate(
                        controller: controller,
                        targetTrackID: sessionTrack.id,
                        rowHeight: trackRowHeight,
                        dropTargetTrackID: $dropTargetTrackID,
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
            loadDroppedURLs(from: providers, targetTrackID: nil)
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
                configuration: .offset
            )
        }
    }

    private func waveformLane(index: Int, sessionTrack: SessionTrack?) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.background.opacity(0.01))

                if let track = sessionTrack?.loadedTrack {
                    placeholderWaveform(index: index)
                        .frame(
                            width: max(CGFloat(track.duration / timelineSpan) * proxy.size.width, 1),
                            height: 58
                        )
                        .offset(
                            x: xPosition(for: track.offsetSeconds, width: proxy.size.width)
                        )
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
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        controller.seek(to: globalTime(atX: value.location.x, width: proxy.size.width))
                    }
            )
        }
    }

    private func placeholderWaveform(index trackIndex: Int) -> some View {
        Canvas { context, size in
            let barCount = 96
            let barWidth = max(size.width / CGFloat(barCount * 2), 1)
            for barIndex in 0..<barCount {
                let phase = Double(barIndex) * 0.37 + Double(trackIndex % 7) * 0.4
                let amplitude = 0.25 + 0.7 * abs(sin(phase) * cos(phase * 0.43))
                let height = size.height * amplitude
                let x = CGFloat(barIndex) * size.width / CGFloat(barCount)
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .foreground)
            }
        }
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
        case .musicSelection:
            openFileCommandState.openAppleMusicSelection()
        }
    }

    private func backgroundStyle(for trackID: SessionTrack.ID) -> some ShapeStyle {
        backgroundStyle(for: dropTargetTrackID == trackID ? .dropTarget : .normal)
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

    private func loadDroppedURLs(from providers: [NSItemProvider], targetTrackID: SessionTrack.ID?) -> Bool {
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
                if let targetTrackID, fileProviders.count == 1, urls.count == 1 {
                    await controller.replaceTrack(targetTrackID, with: urls[0])
                } else {
                    await controller.loadImportedFiles(urls)
                }
            }
        }

        return true
    }
}

private struct TrackInfoDropDelegate: DropDelegate {
    @ObservedObject var controller: PlaybackController
    let targetTrackID: SessionTrack.ID
    let rowHeight: CGFloat
    @Binding var dropTargetTrackID: SessionTrack.ID?
    @Binding var reorderInsertionTarget: TrackReorderInsertionTarget?
    let destinationAfterTargetTrackID: () -> SessionTrack.ID?
    let loadDroppedURLs: ([NSItemProvider], SessionTrack.ID?) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [TrackReorderDrag.contentType.identifier])
            || info.hasItemsConforming(to: [UTType.fileURL.identifier])
    }

    func dropEntered(info: DropInfo) {
        updateDropFeedback(info: info)
    }

    func dropExited(info: DropInfo) {
        if dropTargetTrackID == targetTrackID {
            dropTargetTrackID = nil
        }
        if reorderInsertionTarget?.trackID == targetTrackID {
            reorderInsertionTarget = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if info.hasItemsConforming(to: [TrackReorderDrag.contentType.identifier]) {
            updateReorderInsertionTarget(info: info)
            return DropProposal(operation: .move)
        }
        if info.hasItemsConforming(to: [UTType.fileURL.identifier]) {
            dropTargetTrackID = targetTrackID
            reorderInsertionTarget = nil
            return DropProposal(operation: .copy)
        }
        return nil
    }

    func performDrop(info: DropInfo) -> Bool {
        if let provider = info.itemProviders(for: [TrackReorderDrag.contentType.identifier]).first {
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
        }

        let handled = loadDroppedURLs(info.itemProviders(for: [UTType.fileURL.identifier]), targetTrackID)
        clearDropFeedback()
        return handled
    }

    private func updateDropFeedback(info: DropInfo) {
        if info.hasItemsConforming(to: [TrackReorderDrag.contentType.identifier]) {
            updateReorderInsertionTarget(info: info)
        } else if info.hasItemsConforming(to: [UTType.fileURL.identifier]) {
            dropTargetTrackID = targetTrackID
            reorderInsertionTarget = nil
        }
    }

    private func updateReorderInsertionTarget(info: DropInfo) {
        dropTargetTrackID = nil
        reorderInsertionTarget = TrackReorderInsertionTarget(
            trackID: targetTrackID,
            placement: TrackReorderInsertionPlacement.location(y: info.location.y, rowHeight: rowHeight)
        )
    }

    private func clearDropFeedback() {
        if dropTargetTrackID == targetTrackID {
            dropTargetTrackID = nil
        }
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

            IntegerInputField(value: $value, configuration: configuration)
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
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct IntegerInputField: NSViewRepresentable {
    @Binding var value: Int
    let configuration: NumericControlConfiguration

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, configuration: configuration)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField(frame: .zero)
        textField.alignment = .right
        textField.isBordered = true
        textField.focusRingType = .default
        textField.delegate = context.coordinator
        textField.stringValue = "\(value)"
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        let clamped = configuration.clamped(value)
        if clamped != value {
            DispatchQueue.main.async {
                self.value = clamped
            }
        }
        if nsView.stringValue != "\(clamped)" {
            nsView.stringValue = "\(clamped)"
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding private var value: Int
        private let configuration: NumericControlConfiguration
        private var editState: NumericControlEditState
        private var isCancellingEdit = false

        init(value: Binding<Int>, configuration: NumericControlConfiguration) {
            _value = value
            self.configuration = configuration
            editState = NumericControlEditState(committedValue: value.wrappedValue)
        }

        @MainActor
        func controlTextDidBeginEditing(_ obj: Notification) {
            editState.beginEditing(currentValue: value)
            isCancellingEdit = false
        }

        @MainActor
        func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
            guard let textField = control as? NSTextField else { return true }
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
                isCancellingEdit = false
                return
            }
            syncValue(from: textField)
        }

        @MainActor
        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            if let parsed = Int(textField.stringValue.trimmingCharacters(in: .whitespaces)) {
                value = configuration.clamped(parsed)
            }
        }

        func applyStep(direction: Int, largeStep: Bool) {
            value = configuration.steppedValue(from: value, direction: direction, largeStep: largeStep)
        }

        @MainActor
        private func syncValue(from textField: NSTextField) {
            syncValue(from: textField, overrideText: nil)
        }

        @MainActor
        private func syncValue(from textField: NSTextField, overrideText: String?) {
            let trimmed = (overrideText ?? textField.stringValue).trimmingCharacters(in: .whitespaces)
            let parsed = Int(trimmed) ?? value
            let clamped = configuration.clamped(parsed)
            value = clamped
            editState.commit(clamped)
            textField.stringValue = "\(clamped)"
        }

        @MainActor
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                applyStep(
                    using: (control as? NSTextField)?.stringValue ?? "\(value)",
                    direction: 1,
                    largeStep: false
                )
                if let textField = control as? NSTextField { textField.stringValue = "\(value)" }
                return true
            case #selector(NSResponder.moveDown(_:)):
                applyStep(
                    using: (control as? NSTextField)?.stringValue ?? "\(value)",
                    direction: -1,
                    largeStep: false
                )
                if let textField = control as? NSTextField { textField.stringValue = "\(value)" }
                return true
            case #selector(NSResponder.moveUpAndModifySelection(_:)):
                applyStep(
                    using: (control as? NSTextField)?.stringValue ?? "\(value)",
                    direction: 1,
                    largeStep: true
                )
                if let textField = control as? NSTextField { textField.stringValue = "\(value)" }
                return true
            case #selector(NSResponder.moveDownAndModifySelection(_:)):
                applyStep(
                    using: (control as? NSTextField)?.stringValue ?? "\(value)",
                    direction: -1,
                    largeStep: true
                )
                if let textField = control as? NSTextField { textField.stringValue = "\(value)" }
                return true
            case #selector(NSResponder.insertNewline(_:)):
                control.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if let textField = control as? NSTextField {
                    let restoredValue = editState.cancelledValue()
                    value = restoredValue
                    textField.stringValue = "\(restoredValue)"
                }
                isCancellingEdit = true
                control.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }

        private func applyStep(using currentText: String, direction: Int, largeStep: Bool) {
            value = configuration.steppedValue(
                fromText: currentText,
                fallbackValue: value,
                direction: direction,
                largeStep: largeStep
            )
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
