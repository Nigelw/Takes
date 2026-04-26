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
    @State private var dropTargetSide: TrackSide?
    @State private var gainPopoverSide: TrackSide?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            transportBar
            if let warning = controller.overlapWarning {
                Text(warning)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
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
            .disabled(!controller.session.canToggleComparison)

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
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    trackRow(side: .a, track: controller.session.trackA, infoWidth: infoWidth, waveformWidth: waveformWidth)
                    Divider()
                    trackRow(side: .b, track: controller.session.trackB, infoWidth: infoWidth, waveformWidth: waveformWidth)
                }
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                if controller.session.isPlayable {
                    Rectangle()
                        .fill(.blue)
                        .frame(width: 2)
                        .offset(x: infoWidth + xPosition(for: controller.session.transportPosition, width: waveformWidth))
                        .padding(.vertical, 8)
                }
            }
        }
        .frame(minHeight: 260)
    }

    private func trackRow(
        side: TrackSide,
        track: LoadedTrack?,
        infoWidth: CGFloat,
        waveformWidth: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            trackInfoArea(side: side, track: track)
                .frame(width: infoWidth, alignment: .leading)
                .frame(minHeight: 124, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    controller.selectActiveTrack(side)
                }
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: dropBinding(for: side)) { providers in
                    handleDrop(providers: providers, side: side)
                }

            waveformLane(side: side, track: track, width: waveformWidth)
                .frame(maxWidth: .infinity, minHeight: 124)
        }
    }

    private func trackInfoArea(side: TrackSide, track: LoadedTrack?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(side.title)
                    .font(.headline)
                if controller.session.activeTrack == side {
                    Text("Active")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.15), in: Capsule())
                }
                Spacer()
                gainButton(side: side, track: track)
            }

            if let track {
                Text(track.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(track.metadataSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("No file loaded")
                    .foregroundStyle(.secondary)
            }

            offsetControl(side: side, track: track)
        }
        .padding(12)
        .background(backgroundStyle(for: side))
    }

    private func gainButton(side: TrackSide, track: LoadedTrack?) -> some View {
        Button {
            gainPopoverSide = side
        } label: {
            Image(systemName: "gearshape")
                .accessibilityLabel("\(side.title) Settings")
        }
        .buttonStyle(.borderless)
        .disabled(track == nil)
        .popover(
            isPresented: Binding(
                get: { gainPopoverSide == side },
                set: { isPresented in
                    gainPopoverSide = isPresented ? side : nil
                }
            ),
            arrowEdge: .trailing
        ) {
            gainPopoverContent(side: side, track: track)
                .padding()
                .frame(width: 300)
        }
    }

    private func gainPopoverContent(side: TrackSide, track: LoadedTrack?) -> some View {
        let gainValue = Int((track?.gainDB ?? 0).rounded())
        return VStack(alignment: .leading, spacing: 10) {
            Text("\(side.title) Gain")
                .font(.headline)
            Text("\(gainValue) dB")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ResettableSlider(
                    value: Binding(
                        get: { Double(gainValue) },
                        set: { controller.setGain(side, db: Float(Int($0.rounded()))) }
                    ),
                    range: -24...24,
                    resetValue: 0
                )
                NumericControlRow(
                    value: Binding(
                        get: { gainValue },
                        set: { controller.setGain(side, db: Float($0)) }
                    ),
                    configuration: .gain
                )
            }
            .disabled(track == nil)
        }
    }

    private func offsetControl(side: TrackSide, track: LoadedTrack?) -> some View {
        let offsetMs = Int(((track?.offsetSeconds ?? 0) * 1000).rounded())
        return VStack(alignment: .leading, spacing: 4) {
            Text("Offset \(offsetMs) ms")
                .font(.caption)
                .foregroundStyle(.secondary)
            NumericControlRow(
                value: Binding(
                    get: { offsetMs },
                    set: { controller.setOffset(side, seconds: Double($0) / 1000) }
                ),
                configuration: .offset
            )
            .disabled(track == nil)
        }
    }

    private func waveformLane(side: TrackSide, track: LoadedTrack?, width: CGFloat) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.background.opacity(0.01))

                if let track {
                    placeholderWaveform(for: side)
                        .frame(
                            width: max(CGFloat(track.duration / timelineSpan) * proxy.size.width, 1),
                            height: 58
                        )
                        .offset(
                            x: xPosition(for: track.offsetSeconds, width: proxy.size.width)
                        )
                        .foregroundStyle(side == .a ? .blue.opacity(0.55) : .green.opacity(0.55))
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

    private func placeholderWaveform(for side: TrackSide) -> some View {
        Canvas { context, size in
            let barCount = 96
            let barWidth = max(size.width / CGFloat(barCount * 2), 1)
            for index in 0..<barCount {
                let phase = Double(index) * 0.37 + (side == .a ? 0 : 0.8)
                let amplitude = 0.25 + 0.7 * abs(sin(phase) * cos(phase * 0.43))
                let height = size.height * amplitude
                let x = CGFloat(index) * size.width / CGFloat(barCount)
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .foreground)
            }
        }
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

    private func backgroundStyle(for side: TrackSide) -> some ShapeStyle {
        if dropTargetSide == side {
            return AnyShapeStyle(.blue.opacity(0.16))
        }
        return AnyShapeStyle(.quaternary.opacity(0.4))
    }

    private func dropBinding(for side: TrackSide) -> Binding<Bool> {
        Binding(
            get: { dropTargetSide == side },
            set: { isTargeted in
                dropTargetSide = isTargeted ? side : nil
            }
        )
    }

    private func handleDrop(providers: [NSItemProvider], side: TrackSide) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let url = extractDroppedFileURL(from: item) else { return }
            Task { @MainActor in
                await controller.loadTrack(side, from: url)
            }
        }

        return true
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
