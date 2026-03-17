import SwiftUI
import UniformTypeIdentifiers

struct NumericControlConfiguration {
    let range: ClosedRange<Int>
    let step: Int
    let largeStep: Int
    let suffix: String

    static let gain = NumericControlConfiguration(range: -24...24, step: 1, largeStep: 10, suffix: "dB")
    static let offset = NumericControlConfiguration(range: -5000...5000, step: 10, largeStep: 100, suffix: "ms")

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

    @State private var importingTrack = false
    @State private var pendingImportSide: TrackSide?
    @State private var sliderPosition = 0.0
    @State private var keyMonitor: KeyMonitor?
    @State private var mouseMonitor: MouseMonitor?
    @State private var dropTargetSide: TrackSide?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerSection
            transportSection
            controlsSection
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
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 520)
        .fileImporter(isPresented: $importingTrack, allowedContentTypes: [.audio]) { result in
            handleImport(result)
        }
        .onAppear {
            sliderPosition = controller.session.transportPosition
            setupKeyMonitor()
        }
        .onDisappear {
            keyMonitor?.stop()
            mouseMonitor?.stop()
        }
        .onChange(of: controller.session.transportPosition) { _, newValue in
            sliderPosition = newValue
        }
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 16) {
            trackHeader(side: .a, track: controller.session.trackA) {
                pendingImportSide = .a
                importingTrack = true
            }
            trackHeader(side: .b, track: controller.session.trackB) {
                pendingImportSide = .b
                importingTrack = true
            }
        }
    }

    private func trackHeader(side: TrackSide, track: LoadedTrack?, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(side.title)
                    .font(.headline)
                if controller.session.activeTrack == side {
                    Text("Active")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.blue.opacity(0.15), in: Capsule())
                }
            }
            if let track {
                Text(track.displayName)
                    .font(.title3.weight(.medium))
                    .lineLimit(1)
                Text(track.metadataSummary)
                    .foregroundStyle(.secondary)
            } else {
                Text("No file loaded")
                    .foregroundStyle(.secondary)
            }
            Button("Load \(side.title)", action: action)
            Button("Load Selected from Music") {
                Task {
                    await controller.loadSelectedLibraryTrack(side)
                }
            }
            Text("Drop audio file here")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundStyle(for: side), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: dropBinding(for: side)) { providers in
            handleDrop(providers: providers, side: side)
        }
    }

    private var transportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button(controller.session.isPlaying ? "Pause" : "Play") {
                    controller.session.isPlaying ? controller.pause() : controller.play()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!controller.session.isPlayable)

                Button("Rewind") {
                    controller.seek(to: 0)
                }
                .disabled(!controller.session.isPlayable)

                Button("Switch Playback") {
                    controller.toggleActiveTrack()
                }
                .keyboardShortcut("x", modifiers: [])
                .disabled(!controller.session.canToggleComparison)

                Spacer()

                Text("\(controller.session.transportPosition.formattedTimestamp) / \(controller.session.duration.formattedTimestamp)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { sliderPosition },
                    set: { sliderPosition = $0 }
                ),
                in: 0...max(controller.session.duration, 0.001),
                onEditingChanged: { editing in
                    if !editing {
                        controller.seek(to: sliderPosition)
                    }
                }
            )
            .disabled(!controller.session.isPlayable)
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var controlsSection: some View {
        HStack(alignment: .top, spacing: 16) {
            gainCard(side: .a, track: controller.session.trackA, showOffset: false)
            gainCard(side: .b, track: controller.session.trackB, showOffset: true)
        }
    }

    private func gainCard(side: TrackSide, track: LoadedTrack?, showOffset: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(side.title)
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                let gainValue = Int((track?.gainDB ?? 0).rounded())
                Text("Gain \(gainValue) dB")
                    .foregroundStyle(.secondary)
                HStack(alignment: .center, spacing: 10) {
                    ResettableSlider(
                        value: Binding(
                            get: { Double(gainValue) },
                            set: { controller.setGain(side, db: Float(Int($0.rounded()))) }
                        ),
                        range: -24...24,
                        resetValue: 0
                    )
                    .frame(maxWidth: .infinity)
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

            if showOffset {
                VStack(alignment: .leading, spacing: 6) {
                    let offsetMs = Int(((track?.offsetSeconds ?? 0) * 1000).rounded())
                    Text("Offset \(offsetMs) ms")
                        .foregroundStyle(.secondary)
                    HStack(alignment: .center, spacing: 10) {
                        ResettableSlider(
                            value: Binding(
                                get: { Double(offsetMs) },
                                set: { controller.setOffset(side, seconds: Double(Int($0.rounded())) / 1000) }
                            ),
                            range: -5000...5000,
                            resetValue: 0
                        )
                        .frame(maxWidth: .infinity)
                        NumericControlRow(
                            value: Binding(
                                get: { offsetMs },
                                set: { controller.setOffset(side, seconds: Double($0) / 1000) }
                            ),
                            configuration: .offset
                        )
                    }
                    .disabled(track == nil)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func handleImport(_ result: Result<URL, Error>) {
        let side = pendingImportSide
        importingTrack = false
        pendingImportSide = nil

        switch result {
        case let .success(url):
            guard let side else { return }
            Task {
                await controller.loadTrack(side, from: url)
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
                    controller.seek(to: 0)
                    return true
                }
                controller.skip(by: event.modifierFlags.contains(.shift) ? -10 : -1)
                return true
            case 124:
                if event.modifierFlags.contains(.command) {
                    controller.seek(to: controller.session.duration)
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
