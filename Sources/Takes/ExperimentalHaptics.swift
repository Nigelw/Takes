import AppKit
import SwiftUI

enum ExperimentalHapticPatternOption: String, CaseIterable, Identifiable {
    case off
    case alignment
    case levelChange
    case generic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .alignment: return "Alignment"
        case .levelChange: return "Level Change"
        case .generic: return "Generic"
        }
    }

    var feedbackPattern: NSHapticFeedbackManager.FeedbackPattern? {
        switch self {
        case .off: return nil
        case .alignment: return .alignment
        case .levelChange: return .levelChange
        case .generic: return .generic
        }
    }
}

enum ExperimentalHapticEvent: String, CaseIterable, Identifiable {
    case playheadDragTimelineEdges
    case scrollTimelineEdges
    case zoomControlThresholds
    case pinchZoomThresholds
    case transportBarButtonPresses
    case playheadHover
    case loopSelectionControlHover

    var id: String { rawValue }

    static let timelineEvents: [Self] = [
        .playheadDragTimelineEdges,
        .scrollTimelineEdges
    ]

    static let zoomEvents: [Self] = [
        .zoomControlThresholds,
        .pinchZoomThresholds
    ]

    static let transportEvents: [Self] = [
        .transportBarButtonPresses
    ]

    static let hoverEvents: [Self] = [
        .playheadHover,
        .loopSelectionControlHover
    ]

    var title: String {
        switch self {
        case .playheadDragTimelineEdges: return "Playhead Drag to Timeline Edges"
        case .scrollTimelineEdges: return "Scroll to Timeline Edges"
        case .zoomControlThresholds: return "Zoom Controls Threshold Triggers"
        case .pinchZoomThresholds: return "Pinch Zoom Threshold Triggers"
        case .transportBarButtonPresses: return "Transport Bar Button Presses"
        case .playheadHover: return "Hover Over Playhead / Handle"
        case .loopSelectionControlHover: return "Hover Over Loop Selection Controls"
        }
    }

    var detail: String {
        switch self {
        case .playheadDragTimelineEdges:
            return "While ruler dragging clamps against the start or end of the timeline."
        case .scrollTimelineEdges:
            return "When horizontal scrolling first reaches the left or right boundary."
        case .zoomControlThresholds:
            return "Quarter-range stops plus fit/max while using the +/- buttons or zoom slider."
        case .pinchZoomThresholds:
            return "The same threshold stops while trackpad pinch zoom is active on the timeline."
        case .transportBarButtonPresses:
            return "Play, Switch Track, Repeat, and Blind Listening Mode."
        case .playheadHover:
            return "When the pointer enters the playhead grab zone in the ruler."
        case .loopSelectionControlHover:
            return "When the pointer enters a loop resize handle hot zone."
        }
    }

    var defaultPattern: ExperimentalHapticPatternOption {
        switch self {
        case .playheadDragTimelineEdges, .scrollTimelineEdges, .playheadHover, .loopSelectionControlHover:
            return .alignment
        case .zoomControlThresholds, .pinchZoomThresholds:
            return .levelChange
        case .transportBarButtonPresses:
            return .generic
        }
    }
}

enum ExperimentalHapticEdge: Equatable {
    case leading
    case trailing
}

enum ExperimentalHapticTriggerGate {
    private static let fitTolerance = 0.0001
    private static let maximumTolerance = 0.9999

    static func shouldFireOnEntry<State: Equatable>(previous: State?, current: State?) -> Bool {
        guard let current else { return false }
        return previous != current
    }

    static func shouldFireHover(previous: Bool, current: Bool) -> Bool {
        !previous && current
    }

    static func zoomThresholdBucket(for progress: Double) -> Int {
        let clamped = clamp(progress)
        switch clamped {
        case ...fitTolerance:
            return 0
        case ..<0.25:
            return 1
        case ..<0.5:
            return 2
        case ..<0.75:
            return 3
        case ..<maximumTolerance:
            return 4
        default:
            return 5
        }
    }

    private static func clamp(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
        return min(max(progress, 0), 1)
    }
}

@MainActor
final class ExperimentalHapticsController: ObservableObject {
    @Published private var patterns = Dictionary(
        uniqueKeysWithValues: ExperimentalHapticEvent.allCases.map { ($0, $0.defaultPattern) }
    )

    private var activeEdges: [ExperimentalHapticEvent: ExperimentalHapticEdge?] = [:]
    private var hoverStates: [ExperimentalHapticEvent: Bool] = [:]
    private var zoomThresholdBuckets: [ExperimentalHapticEvent: Int] = [:]
    private let performer: NSHapticFeedbackPerformer

    init(performer: NSHapticFeedbackPerformer = NSHapticFeedbackManager.defaultPerformer) {
        self.performer = performer
    }

    func pattern(for event: ExperimentalHapticEvent) -> ExperimentalHapticPatternOption {
        patterns[event] ?? event.defaultPattern
    }

    func binding(for event: ExperimentalHapticEvent) -> Binding<ExperimentalHapticPatternOption> {
        Binding(
            get: { self.pattern(for: event) },
            set: { self.patterns[event] = $0 }
        )
    }

    func restoreDefaults() {
        patterns = Dictionary(uniqueKeysWithValues: ExperimentalHapticEvent.allCases.map { ($0, $0.defaultPattern) })
    }

    func disableAll() {
        for event in ExperimentalHapticEvent.allCases {
            patterns[event] = .off
        }
    }

    func perform(_ event: ExperimentalHapticEvent) {
        perform(pattern(for: event))
    }

    func updateTimelineEdge(for event: ExperimentalHapticEvent, edge: ExperimentalHapticEdge?) {
        let previous = activeEdges[event] ?? nil
        activeEdges[event] = edge
        guard ExperimentalHapticTriggerGate.shouldFireOnEntry(previous: previous, current: edge) else { return }
        perform(event)
    }

    func resetTimelineEdge(for event: ExperimentalHapticEvent) {
        activeEdges[event] = nil
    }

    func syncZoomProgress(for event: ExperimentalHapticEvent, progress: Double) {
        zoomThresholdBuckets[event] = ExperimentalHapticTriggerGate.zoomThresholdBucket(for: progress)
    }

    func updateZoomProgress(for event: ExperimentalHapticEvent, progress: Double) {
        let bucket = ExperimentalHapticTriggerGate.zoomThresholdBucket(for: progress)
        defer { zoomThresholdBuckets[event] = bucket }
        guard let previousBucket = zoomThresholdBuckets[event], previousBucket != bucket else { return }
        perform(event)
    }

    func updateHover(for event: ExperimentalHapticEvent, isActive: Bool) {
        let previous = hoverStates[event] ?? false
        hoverStates[event] = isActive
        guard ExperimentalHapticTriggerGate.shouldFireHover(previous: previous, current: isActive) else { return }
        perform(event)
    }

    func resetHoverStates() {
        hoverStates.removeAll()
    }

    private func perform(_ pattern: ExperimentalHapticPatternOption) {
        guard let feedbackPattern = pattern.feedbackPattern else { return }
        performer.perform(feedbackPattern, performanceTime: .now)
    }
}

@MainActor
final class ExperimentalHapticsPanelController {
    private var panel: NSPanel?

    func show(controller: ExperimentalHapticsController) {
        if let panel {
            reparent(panel)
            panel.orderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: ExperimentalHapticsSettingsView(controller: controller))
        let panel = NSPanel(contentViewController: hosting)
        panel.title = "Experimental Haptics"
        panel.styleMask = [.titled, .closable, .utilityWindow, .nonactivatingPanel]
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.isReleasedWhenClosed = false
        panel.setContentSize(NSSize(width: 520, height: 500))
        panel.setFrameAutosaveName("ExperimentalHapticsPanel")
        panel.center()
        self.panel = panel
        reparent(panel)
        panel.orderFront(nil)
    }

    private func reparent(_ panel: NSPanel) {
        let parent = NSApp.mainWindow ?? NSApp.windows.first { $0 !== panel && $0.isVisible }
        guard let parent, parent !== panel else { return }
        panel.parent?.removeChildWindow(panel)
        parent.addChildWindow(panel, ordered: .above)
    }
}

private struct ExperimentalHapticsSettingsView: View {
    @ObservedObject var controller: ExperimentalHapticsController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Experimental Haptics")
                    .font(.title2.weight(.semibold))
                Text("Session-only debug controls for trying native macOS haptic patterns in Takes.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                settingsSection("Timeline", events: ExperimentalHapticEvent.timelineEvents)
                settingsSection("Zoom", events: ExperimentalHapticEvent.zoomEvents)
                settingsSection("Transport", events: ExperimentalHapticEvent.transportEvents)
                settingsSection("Hover", events: ExperimentalHapticEvent.hoverEvents)
            }
            .formStyle(.grouped)

            VStack(alignment: .leading, spacing: 6) {
                Text("Limitations")
                    .font(.headline)
                Text("Edge haptics fire on boundary entry only; holding against an edge will not retrigger until the interaction resets.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Hover haptics reuse the existing timeline cursor hit-testing, so they only apply to the playhead grab zone and loop resize handles while the main window is active.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Zoom thresholds are fit, 25%, 50%, 75%, and max. Menu and keyboard zoom commands are not part of this experiment.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("All Off") {
                    controller.disableAll()
                }
                Spacer()
                Button("Restore Defaults") {
                    controller.restoreDefaults()
                }
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func settingsSection(_ title: String, events: [ExperimentalHapticEvent]) -> some View {
        Section(title) {
            ForEach(events) { event in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title)
                        Text(event.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Picker(event.title, selection: controller.binding(for: event)) {
                        ForEach(ExperimentalHapticPatternOption.allCases) { pattern in
                            Text(pattern.title).tag(pattern)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 150, alignment: .trailing)
                }
                .padding(.vertical, 3)
            }
        }
    }
}
