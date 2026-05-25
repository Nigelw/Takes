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
            "Get Apple Music Selection"
        }
    }
}

enum ImportActionControlMetrics {
    static let controlWidth: CGFloat = 118
    static let controlHeight: CGFloat = 34
    static let primaryButtonWidth: CGFloat = 84
    static let menuButtonWidth: CGFloat = 33
}

enum TrackInfoLayoutMetrics {
    static let infoWidth: CGFloat = 300
    static let horizontalPadding: CGFloat = 16
    static let numberButtonWidth: CGFloat = 28
    static let numberToContentSpacing: CGFloat = 16
    static let controlSpacing: CGFloat = 16
}

enum NumericControlMetrics {
    static let leadingPadding: CGFloat = 7
    static let stepperWidth: CGFloat = 20
    static let controlHeight: CGFloat = 28
    static let fieldHeight: CGFloat = 26
    static let offsetValueWidth: CGFloat = 50
    static let offsetSuffixWidth: CGFloat = 20
    static let gainValueWidth: CGFloat = 42
    static let gainSuffixWidth: CGFloat = 24

    static let offsetControlWidth = leadingPadding + offsetValueWidth + offsetSuffixWidth + stepperWidth
    static let gainControlWidth = leadingPadding + gainValueWidth + gainSuffixWidth + stepperWidth
}

enum TransportControlMetrics {
    static let buttonWidth: CGFloat = 40
    static let buttonHeight: CGFloat = 32
    static let iconSize: CGFloat = 14
    static let buttonSpacing: CGFloat = 24
    static let cornerRadius: CGFloat = 7
}

enum TrackSwitchStyle {
    static let accent = Color(red: 0.05, green: 0.66, blue: 1.0)
    static let activeStroke = Color(red: 0.03, green: 0.58, blue: 0.96)
    static let dropStroke = Color(red: 0.36, green: 0.72, blue: 1.0)
    static let waveformActive = Color(red: 0.0, green: 0.55, blue: 1.0).opacity(0.88)
    static let waveformInactive = Color.white.opacity(0.36)
    static let primaryText = Color.white.opacity(0.88)
    static let secondaryText = Color.white.opacity(0.58)
    static let hairline = Color.white.opacity(0.13)
    static let rulerTick = Color.white.opacity(0.30)
    static let zeroLine = Color.white.opacity(0.16)
    static let windowBackground = LinearGradient(
        colors: [
            Color(red: 0.06, green: 0.075, blue: 0.08),
            Color(red: 0.015, green: 0.023, blue: 0.026)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
    static let toolbarBackground = LinearGradient(
        colors: [
            Color(red: 0.10, green: 0.115, blue: 0.12),
            Color(red: 0.045, green: 0.055, blue: 0.06)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
    static let headerBackground = LinearGradient(
        colors: [
            Color(red: 0.08, green: 0.095, blue: 0.10),
            Color(red: 0.045, green: 0.055, blue: 0.06)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
    static let timelineBackground = Color(red: 0.02, green: 0.031, blue: 0.034)
    static let rowBackground = Color(red: 0.055, green: 0.067, blue: 0.07)
    static let activeRowBackground = LinearGradient(
        colors: [
            Color(red: 0.02, green: 0.16, blue: 0.23).opacity(0.88),
            Color(red: 0.01, green: 0.09, blue: 0.13).opacity(0.88)
        ],
        startPoint: .leading,
        endPoint: .trailing
    )
    static let displayBackground = LinearGradient(
        colors: [
            Color.black.opacity(0.88),
            Color(red: 0.02, green: 0.027, blue: 0.03).opacity(0.94)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
    static let controlBackground = LinearGradient(
        colors: [
            Color.white.opacity(0.12),
            Color.black.opacity(0.24)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
    static let controlStroke = Color.white.opacity(0.18)
    static let transportControlBackground = LinearGradient(
        colors: [
            Color.white.opacity(0.065),
            Color.black.opacity(0.20)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
    static let activeTransportControlBackground = LinearGradient(
        colors: [
            Color(red: 0.015, green: 0.18, blue: 0.29),
            Color(red: 0.008, green: 0.075, blue: 0.12)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
    static let transportControlStroke = Color.white.opacity(0.12)
    static let numberBackground = LinearGradient(
        colors: [
            Color.white.opacity(0.11),
            Color.black.opacity(0.22)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
    static let activeNumberBackground = LinearGradient(
        colors: [
            Color(red: 0.02, green: 0.35, blue: 0.55),
            Color(red: 0.01, green: 0.14, blue: 0.22)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
    static let activeNumberText = Color(red: 0.32, green: 0.86, blue: 1.0)
}

struct ContentView: View {
    @ObservedObject var controller: PlaybackController

    @State private var importingTracks = false
    @State private var keyMonitor: KeyMonitor?
    @State private var mouseMonitor: MouseMonitor?
    @State private var dropTargetTrackID: SessionTrack.ID?
    @State private var reorderInsertionTarget: TrackReorderInsertionTarget?
    @State private var emptyTrackIsDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            transportBar
            if let error = controller.playbackError {
                Text(error.localizedDescription)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
            }
            trackTimelineSection
            Spacer(minLength: 0)
        }
        .background(TrackSwitchStyle.windowBackground)
        .background(WindowChromeConfigurator())
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 980, minHeight: 620)
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
        ZStack(alignment: .top) {
            HStack {
                Spacer()
                Text("TrackSwitch")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TrackSwitchStyle.primaryText.opacity(0.72))
                    .padding(.top, 0)
                    .offset(y: -4)
                Spacer()
            }
            .allowsHitTesting(false)

            HStack(spacing: TransportControlMetrics.buttonSpacing) {
                Spacer(minLength: 0)

                transportButton(
                    systemName: "backward.fill",
                    title: "Rewind",
                    isProminent: false,
                    isEnabled: controller.session.isPlayable
                ) {
                    controller.seek(to: controller.session.timelineStart)
                }

                transportButton(
                    systemName: controller.session.isPlaying ? "pause.fill" : "play.fill",
                    title: controller.session.isPlaying ? "Pause" : "Play",
                    isProminent: true,
                    isEnabled: controller.session.isPlayable
                ) {
                    controller.session.isPlaying ? controller.pause() : controller.play()
                }

                transportButton(
                    systemName: "forward.end.fill",
                    title: "Switch",
                    isProminent: false,
                    isEnabled: controller.session.canSwitchPlayback
                ) {
                    controller.selectNextTrack()
                }

                timeDisplay
                    .padding(.horizontal, 22)

                Spacer(minLength: 0)
            }
            .padding(.top, 42)
            .padding(.horizontal, 28)
        }
        .frame(height: 116)
        .background(TrackSwitchStyle.toolbarBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TrackSwitchStyle.hairline)
                .frame(height: 1)
        }
    }

    private func transportButton(
        systemName: String,
        title: String,
        isProminent: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: TransportControlMetrics.iconSize, weight: .bold))
                .foregroundStyle(isProminent ? TrackSwitchStyle.accent : TrackSwitchStyle.primaryText)
                .frame(width: TransportControlMetrics.buttonWidth, height: TransportControlMetrics.buttonHeight)
                .background(
                    isProminent ? TrackSwitchStyle.activeTransportControlBackground : TrackSwitchStyle.transportControlBackground,
                    in: RoundedRectangle(cornerRadius: TransportControlMetrics.cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: TransportControlMetrics.cornerRadius, style: .continuous)
                        .stroke(isProminent ? TrackSwitchStyle.accent.opacity(0.52) : TrackSwitchStyle.transportControlStroke, lineWidth: 1)
                }
                .accessibilityLabel(title)
            }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private var timeDisplay: some View {
        HStack(alignment: .lastTextBaseline, spacing: 9) {
            Text(controller.session.transportPosition.formattedSignedTimestamp)
                .font(.system(size: 31, weight: .regular, design: .monospaced))
                .foregroundStyle(TrackSwitchStyle.primaryText)
            Text("/")
                .font(.system(size: 20, weight: .regular, design: .monospaced))
                .foregroundStyle(TrackSwitchStyle.secondaryText)
            Text(controller.session.timelineEnd.formattedSignedTimestamp)
                .font(.system(size: 20, weight: .regular, design: .monospaced))
                .foregroundStyle(TrackSwitchStyle.secondaryText)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(TrackSwitchStyle.displayBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var timelineSpan: TimeInterval {
        max(controller.session.timelineEnd - controller.session.timelineStart, 0.001)
    }

    private var trackRowHeight: CGFloat {
        124
    }

    private var trackInfoWidth: CGFloat {
        TrackInfoLayoutMetrics.infoWidth
    }

    private var trackHeaderHeight: CGFloat {
        44
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
            VStack(alignment: .leading, spacing: 0) {
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
                        .background(TrackSwitchStyle.timelineBackground)

                        if controller.session.isPlayable {
                            Rectangle()
                                .fill(TrackSwitchStyle.accent)
                                .frame(width: 2, height: trackTimelineHeight - 10)
                                .offset(
                                    x: trackInfoWidth + xPosition(for: controller.session.transportPosition, width: waveformWidth),
                                    y: 5
                                )
                        }
                    }
                    .frame(width: proxy.size.width)
                }
            }
        }
        .frame(height: trackHeaderHeight + min(trackTimelineHeight, 520))
    }

    private func trackTimelineHeader(waveformWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    performImportAction(.open)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Import")
                            .font(.system(size: 13, weight: .medium))
                    }
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
                .menuIndicator(.hidden)
                .help("Open Track Menu")
            }
            .frame(width: ImportActionControlMetrics.controlWidth, height: ImportActionControlMetrics.controlHeight)
            .foregroundStyle(TrackSwitchStyle.primaryText)
            .background(TrackSwitchStyle.controlBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(TrackSwitchStyle.controlStroke, lineWidth: 1)
            )
            .padding(.leading, 20)
            .frame(width: trackInfoWidth, alignment: .leading)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(TrackSwitchStyle.hairline)
                    .frame(width: 1)
            }

            timelineHeaderRuler(width: waveformWidth)
                .frame(maxWidth: .infinity)
        }
        .background(TrackSwitchStyle.headerBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TrackSwitchStyle.hairline)
                .frame(height: 1)
        }
    }

    private func timelineHeaderRuler(width: CGFloat) -> some View {
        let markers = TimelineHeaderMarker.markers(
            timelineStart: controller.session.timelineStart,
            timelineEnd: controller.session.timelineEnd,
            targetMarkerCount: timelineHeaderTargetMarkerCount
        )

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.clear)

            if markers.isEmpty {
                Text("00:00")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(TrackSwitchStyle.secondaryText)
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
                .fill(TrackSwitchStyle.rulerTick)
                .frame(width: 1, height: 8)
                .offset(x: tickX)

            if labelLayout.isVisible {
                Text(marker.label)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(TrackSwitchStyle.primaryText.opacity(0.86))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: labelWidth, alignment: .leading)
                    .offset(x: CGFloat(labelLayout.x), y: 11)
            }
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
        let isDropTarget = dropTargetTrackID == sessionTrack.id
        return HStack(spacing: 0) {
            trackInfoArea(index: index, sessionTrack: sessionTrack, isActive: isActive)
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
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(TrackSwitchStyle.hairline)
                        .frame(width: 1)
                }

            waveformLane(index: index, sessionTrack: sessionTrack, isActive: isActive)
                .frame(maxWidth: .infinity)
                .frame(height: trackRowHeight)
        }
        .frame(height: trackRowHeight)
        .background(rowBackground(isActive: isActive, isDropTarget: isDropTarget))
        .overlay {
            if isActive || isDropTarget {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(isDropTarget ? TrackSwitchStyle.dropStroke : TrackSwitchStyle.activeStroke, lineWidth: 1.25)
            }
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
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(TrackSwitchStyle.hairline)
                    .frame(width: 1)
            }

            waveformLane(index: 0, sessionTrack: nil, isActive: false)
                .frame(maxWidth: .infinity)
                .frame(height: trackRowHeight)
        }
        .frame(height: trackRowHeight)
        .background(backgroundStyle(for: TrackDropHighlight.empty(isTargeted: emptyTrackIsDropTargeted)))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $emptyTrackIsDropTargeted) { providers in
            loadDroppedURLs(from: providers, targetTrackID: nil)
        }
    }

    private func trackInfoArea(index: Int, sessionTrack: SessionTrack, isActive: Bool) -> some View {
        let track = sessionTrack.loadedTrack
        return HStack(alignment: .top, spacing: TrackInfoLayoutMetrics.numberToContentSpacing) {
            trackNumberButton(index: index, isActive: isActive)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.displayName)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(TrackSwitchStyle.primaryText)
                            .lineLimit(1)
                        Text(track.metadataSummary)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(TrackSwitchStyle.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    Button {
                        controller.removeTrack(sessionTrack.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(TrackSwitchStyle.secondaryText)
                            .frame(width: 30, height: 30)
                            .accessibilityLabel("Remove Track \(index + 1)")
                    }
                    .buttonStyle(.plain)
                    .help("Remove Track \(index + 1)")
                }

                HStack(spacing: TrackInfoLayoutMetrics.controlSpacing) {
                    offsetControl(sessionTrack: sessionTrack)
                    gainControl(sessionTrack: sessionTrack)
                }
            }
        }
        .padding(.horizontal, TrackInfoLayoutMetrics.horizontalPadding)
        .padding(.vertical, 14)
    }

    private func trackNumberButton(index: Int, isActive: Bool) -> some View {
        Text("\(index + 1)")
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(isActive ? TrackSwitchStyle.activeNumberText : TrackSwitchStyle.primaryText)
            .frame(width: TrackInfoLayoutMetrics.numberButtonWidth, height: TrackInfoLayoutMetrics.numberButtonWidth)
            .background(
                isActive ? TrackSwitchStyle.activeNumberBackground : TrackSwitchStyle.numberBackground,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(isActive ? TrackSwitchStyle.activeStroke : TrackSwitchStyle.controlStroke, lineWidth: 1)
            }
    }

    private func offsetControl(sessionTrack: SessionTrack) -> some View {
        let offsetMs = Int((sessionTrack.loadedTrack.offsetSeconds * 1000).rounded())
        return compactControl(
            title: "Offset",
            value: Binding(
                get: { offsetMs },
                set: { controller.setOffset(sessionTrack.id, seconds: Double($0) / 1000) }
            ),
            configuration: .offset
        )
    }

    private func gainControl(sessionTrack: SessionTrack) -> some View {
        let gainValue = Int(sessionTrack.loadedTrack.gainDB.rounded())
        return compactControl(
            title: "Gain",
            value: Binding(
                get: { gainValue },
                set: { controller.setGain(sessionTrack.id, db: Float($0)) }
            ),
            configuration: .gain
        )
    }

    private func compactControl(
        title: String,
        value: Binding<Int>,
        configuration: NumericControlConfiguration
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TrackSwitchStyle.secondaryText)
            NumericControlRow(
                value: value,
                configuration: configuration
            )
        }
    }

    private func waveformLane(index: Int, sessionTrack: SessionTrack?, isActive: Bool) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.clear)

                if let track = sessionTrack?.loadedTrack {
                    placeholderWaveform(index: index)
                        .frame(
                            width: max(CGFloat(track.duration / timelineSpan) * proxy.size.width, 1),
                            height: isActive ? 68 : 56
                        )
                        .offset(
                            x: xPosition(for: track.offsetSeconds, width: proxy.size.width)
                        )
                        .foregroundStyle(isActive ? TrackSwitchStyle.waveformActive : TrackSwitchStyle.waveformInactive)
                } else {
                    Text("Drop audio file here")
                        .font(.caption)
                        .foregroundStyle(TrackSwitchStyle.secondaryText)
                        .padding(.leading, 16)
                }

                Rectangle()
                    .fill(TrackSwitchStyle.zeroLine)
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

    private func performImportAction(_ item: ImportActionMenuItem) {
        switch item {
        case .open:
            importingTracks = true
        case .musicSelection:
            Task { await controller.loadSelectedLibraryTracks() }
        }
    }

    private func backgroundStyle(for trackID: SessionTrack.ID) -> some ShapeStyle {
        backgroundStyle(for: dropTargetTrackID == trackID ? .dropTarget : .normal)
    }

    private func backgroundStyle(for highlight: TrackDropHighlight) -> some ShapeStyle {
        if highlight == .dropTarget {
            return AnyShapeStyle(TrackSwitchStyle.activeRowBackground)
        }
        return AnyShapeStyle(TrackSwitchStyle.rowBackground)
    }

    private func rowBackground(isActive: Bool, isDropTarget: Bool) -> some ShapeStyle {
        if isActive || isDropTarget {
            return AnyShapeStyle(TrackSwitchStyle.activeRowBackground)
        }
        return AnyShapeStyle(TrackSwitchStyle.rowBackground)
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
        HStack(spacing: 0) {
            IntegerInputField(value: $value, configuration: configuration)
                .frame(
                    width: configuration.suffix == "ms" ? NumericControlMetrics.offsetValueWidth : NumericControlMetrics.gainValueWidth,
                    height: NumericControlMetrics.fieldHeight
                )

            Text(configuration.suffix)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(TrackSwitchStyle.secondaryText)
                .frame(
                    width: configuration.suffix == "ms" ? NumericControlMetrics.offsetSuffixWidth : NumericControlMetrics.gainSuffixWidth,
                    alignment: .leading
                )

            VStack(spacing: 0) {
                stepButton(systemName: "chevron.up", direction: 1)
                Rectangle()
                    .fill(TrackSwitchStyle.hairline)
                    .frame(height: 1)
                stepButton(systemName: "chevron.down", direction: -1)
            }
            .frame(width: NumericControlMetrics.stepperWidth, height: NumericControlMetrics.fieldHeight)
            .background(Color.black.opacity(0.20))
        }
        .padding(.leading, NumericControlMetrics.leadingPadding)
        .frame(height: NumericControlMetrics.controlHeight)
        .background(TrackSwitchStyle.controlBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(TrackSwitchStyle.controlStroke, lineWidth: 1)
        }
    }

    private func stepButton(systemName: String, direction: Int) -> some View {
        Button {
            value = configuration.steppedValue(
                from: value,
                direction: direction,
                largeStep: NumericControlConfiguration.isLargeStepModifierFlags(NSEvent.modifierFlags)
            )
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(TrackSwitchStyle.secondaryText)
                .frame(width: NumericControlMetrics.stepperWidth, height: NumericControlMetrics.fieldHeight / 2)
        }
        .buttonStyle(.plain)
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
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .default
        textField.textColor = NSColor.white.withAlphaComponent(0.88)
        textField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
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

private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
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
