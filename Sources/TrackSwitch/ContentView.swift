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

struct ContentView: View {
    @ObservedObject var controller: PlaybackController

    @State private var importingTracks = false
    @State private var keyMonitor: KeyMonitor?
    @State private var mouseMonitor: MouseMonitor?
    @State private var dropTargetTrackID: SessionTrack.ID?
    @State private var gainPopoverTrackID: SessionTrack.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            transportBar
            if let error = controller.playbackError {
                Text(error.localizedDescription)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            trackTimelineSection
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 860, minHeight: 540)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            loadDroppedURLs(from: providers, targetTrackID: nil)
        }
        .fileImporter(
            isPresented: $importingTracks,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
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
            Button("Open") {
                importingTracks = true
            }

            Menu {
                Button("Load Selected from Music") {
                    Task { await controller.loadSelectedLibraryTracks() }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .accessibilityLabel("Import Options")
            }
            .menuStyle(.borderlessButton)

            Divider()
                .frame(height: 22)

            Button(controller.session.isPlaying ? "Pause" : "Play") {
                controller.session.isPlaying ? controller.pause() : controller.play()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!controller.session.isPlayable)

            Button("Rewind") {
                controller.seek(to: controller.session.timelineStart)
            }
            .disabled(!controller.session.isPlayable)

            Button("Switch Playback") {
                controller.toggleActiveTrack()
            }
            .keyboardShortcut("x", modifiers: [])
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
            let infoWidth: CGFloat = 240
            let waveformWidth = max(proxy.size.width - infoWidth, 1)
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        if controller.session.tracks.isEmpty {
                            emptyTrackRow(infoWidth: infoWidth)
                        } else {
                            ForEach(Array(controller.session.tracks.enumerated()), id: \.element.id) { index, sessionTrack in
                                trackRow(index: index, sessionTrack: sessionTrack, infoWidth: infoWidth)
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
                                x: infoWidth + xPosition(for: controller.session.transportPosition, width: waveformWidth),
                                y: 8
                            )
                    }
                }
                .frame(width: proxy.size.width)
            }
        }
        .frame(height: min(trackTimelineHeight, 420))
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
                .onTapGesture {
                    controller.selectActiveTrack(sessionTrack.id)
                }

            waveformLane(index: index, sessionTrack: sessionTrack)
                .frame(maxWidth: .infinity)
                .frame(height: trackRowHeight)
        }
        .frame(height: trackRowHeight)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: dropBinding(for: sessionTrack.id)) { providers in
            loadDroppedURLs(from: providers, targetTrackID: sessionTrack.id)
        }
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
            .background(.quaternary.opacity(0.4))

            waveformLane(index: 0, sessionTrack: nil)
                .frame(maxWidth: .infinity)
                .frame(height: trackRowHeight)
        }
        .frame(height: trackRowHeight)
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
        importingTracks = false

        switch result {
        case let .success(urls):
            Task {
                await controller.loadImportedFiles(urls)
            }
        case .failure:
            break
        }
    }

    private func backgroundStyle(for trackID: SessionTrack.ID) -> some ShapeStyle {
        if dropTargetTrackID == trackID {
            return AnyShapeStyle(.blue.opacity(0.16))
        }
        return AnyShapeStyle(.quaternary.opacity(0.4))
    }

    private func dropBinding(for trackID: SessionTrack.ID) -> Binding<Bool> {
        Binding(
            get: { dropTargetTrackID == trackID },
            set: { isTargeted in
                if isTargeted {
                    dropTargetTrackID = trackID
                } else if dropTargetTrackID == trackID {
                    dropTargetTrackID = nil
                }
            }
        )
    }

    private func setupKeyMonitor() {
        let monitor = KeyMonitor { event in
            if let window = NSApp.keyWindow, window.firstResponder is NSTextView {
                return false
            }

            switch event.keyCode {
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
                controller.toggleActiveTrack()
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
                if let targetTrackID, urls.count == 1 {
                    await controller.replaceTrack(targetTrackID, with: urls[0])
                } else {
                    await controller.loadImportedFiles(urls)
                }
            }
        }

        return true
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
