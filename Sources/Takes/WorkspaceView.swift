import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    let coordinator: PlaylistCoordinator
    let persistence: PlaylistPersistenceController
    let appFileOpenRouter: AppFileOpenRouter
    let usesTemporaryDefaultWindowLayout: Bool
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.undoManager) private var undoManager
    @StateObject private var presentation: PlaylistPresentationState
    @StateObject private var openFiles: OpenFileCommandState
    @State private var mainWindow: NSWindow?
    @State private var didConfigure = false
    @State private var didStart = false
    @State private var keyMonitor: KeyMonitor?
    @State private var externalOpenTask: Task<Void, Never>?
    @State private var isDropTargeted = false
    @State private var retainedPlaylistSize = CGSize(width: 760, height: 520)
    @State private var playlistFrame: CGRect?
    @State private var mainWindowIsKey = true
    @State private var textInputIsFocused = false

    private var controller: PlaybackController { coordinator.controller }
    private var isComparison: Bool { coordinator.mode.itemID != nil }
    private var commandContext: PlaylistCommandContext {
        .init(coordinator: coordinator, presentation: presentation, undoManager: undoManager)
    }

    init(
        coordinator: PlaylistCoordinator,
        persistence: PlaylistPersistenceController,
        appFileOpenRouter: AppFileOpenRouter,
        usesTemporaryDefaultWindowLayout: Bool = false
    ) {
        self.coordinator = coordinator
        self.persistence = persistence
        self.appFileOpenRouter = appFileOpenRouter
        self.usesTemporaryDefaultWindowLayout = usesTemporaryDefaultWindowLayout
        let presentation = PlaylistPresentationState()
        _presentation = StateObject(wrappedValue: presentation)
        let state = OpenFileCommandState(
            loadStreamingURL: { rawURL, state in
                let destination = state.streamingDestination
                let operationID = UUID()
                let task = Task { @MainActor in
                    do {
                        let url = try await PlaylistStreamingImporter().download(from: rawURL) { status in
                            await MainActor.run { state.updateStreamingURLStatus(status, id: operationID) }
                        }
                        try Task.checkCancellation()
                        let importedIDs = await coordinator.importFiles(
                            [url], destination: destination, isWorkspaceOwned: true,
                            automaticGroupingMode: AppSettings.shared.automaticGroupingMode,
                            undoManager: NSApp.mainWindow?.undoManager
                        )
                        Self.revealImportedItems(importedIDs, presentation: presentation)
                        guard state.isCurrentStreamingURLTask(operationID) else { return }
                        state.finishStreamingURLTask(id: operationID)
                        if let error = coordinator.errorMessage { state.streamingURLStatus = .failed(error) }
                        else { state.dismissStreamingURLPrompt() }
                    } catch is CancellationError {
                        state.finishStreamingURLTask(id: operationID)
                    } catch {
                        state.updateStreamingURLStatus(.failed(error.localizedDescription), id: operationID)
                        state.finishStreamingURLTask(id: operationID)
                    }
                }
                state.registerStreamingURLTask(task, id: operationID)
            },
            loadAppleMusicSelection: {
                let destination = coordinator.captureImportDestination()
                Task { @MainActor in
                    do {
                        let selection = try LibraryTrackSelectionLoader().selectedTracks()
                        let importedIDs = await coordinator.importFiles(
                            selection.urls, destination: destination,
                            automaticGroupingMode: AppSettings.shared.automaticGroupingMode,
                            undoManager: NSApp.mainWindow?.undoManager
                        )
                        Self.revealImportedItems(importedIDs, presentation: presentation)
                        if !selection.failures.isEmpty {
                            coordinator.reportError("\(selection.failures.count) selected Music tracks could not be imported.")
                        }
                    } catch { coordinator.reportError(error.localizedDescription) }
                }
            },
            loadFinderSelection: {
                let destination = coordinator.captureImportDestination()
                Task { @MainActor in
                    do {
                        let urls = try FinderSelectionLoader().selectedAudioFileURLs()
                        let importedIDs = await coordinator.importFiles(
                            urls, destination: destination,
                            automaticGroupingMode: AppSettings.shared.automaticGroupingMode,
                            undoManager: NSApp.mainWindow?.undoManager
                        )
                        Self.revealImportedItems(importedIDs, presentation: presentation)
                    } catch { coordinator.reportError(error.localizedDescription) }
                }
            },
            showActiveTrackInFinder: {
                let version = Self.targetVersion(coordinator: coordinator, presentation: presentation)
                if let version, case let .available(url) = PlaylistWorkspaceStore.resolveFileReference(version.file) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            },
            removeActiveTrack: {
                if coordinator.mode.itemID != nil, let id = coordinator.controller.session.activeTrackID {
                    coordinator.removeVersion(id, undoManager: NSApp.mainWindow?.undoManager)
                } else {
                    PlaylistCommandContext(coordinator: coordinator, presentation: presentation, undoManager: NSApp.mainWindow?.undoManager).remove()
                }
            },
            clearAllTracks: {
                if let id = coordinator.mode.itemID { coordinator.removeItem(id, undoManager: NSApp.mainWindow?.undoManager) }
                else { coordinator.clearPlaylist(undoManager: NSApp.mainWindow?.undoManager) }
            }
        )
        state.captureDestination = { coordinator.captureImportDestination() }
        _openFiles = StateObject(wrappedValue: state)
    }

    var body: some View {
        focusedContent
            .task {
                guard !didStart else { return }
                didStart = true
                setupKeyboard()
                await persistence.start()
                configureOpenRouter()
                applyModeWindowSize(previousMode: nil)
            }
            .onChange(of: coordinator.mode) { previous, _ in applyModeWindowSize(previousMode: previous) }
            .onChange(of: settings.appearanceTheme, initial: true) { _, theme in NSApp.appearance = theme.nsAppearance }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                if notification.object as? NSWindow === mainWindow { mainWindowIsKey = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
                if notification.object as? NSWindow === mainWindow { mainWindowIsKey = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSControl.textDidBeginEditingNotification)) { _ in
                textInputIsFocused = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSControl.textDidEndEditingNotification)) { _ in
                textInputIsFocused = false
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { notification in
                guard !isComparison, let window = notification.object as? NSWindow, window === mainWindow else { return }
                playlistFrame = window.frame
                if !usesTemporaryDefaultWindowLayout { UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "playlistWindowFrame") }
            }
            .onDisappear { keyMonitor?.stop() }
    }

    private var windowContent: some View {
        workspaceContent
            .frame(minWidth: TakesWindowPolicy.minimumContentWidth,
                   minHeight: isComparison ? TakesWindowPolicy.rootViewMinimumHeight + TakesWindowPolicy.comparisonNavigationHeight : 340)
            .ignoresSafeArea(.container, edges: .top)
            .environment(\.transportAppearance, settings.transportAppearance)
            .background(WindowBackground().ignoresSafeArea())
            .background {
                MainWindowConfigurationView { window in configureWindow(window) }
            }
            .overlay {
                if !mainWindowIsKey { InactiveWindowInteractionShield(window: mainWindow).ignoresSafeArea() }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: importProviders)
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.primary, lineWidth: 3)
                        .padding(3).allowsHitTesting(false)
                }
            }
    }

    private var presentedContent: some View {
        windowContent
            .fileImporter(isPresented: $openFiles.isImportingTracks, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                let destination = openFiles.importDestination
                openFiles.dismissOpenDialog()
                if case let .success(urls) = result {
                    Task {
                        let importedIDs = await coordinator.importFiles(
                            urls, destination: destination,
                            automaticGroupingMode: settings.automaticGroupingMode,
                            undoManager: undoManager
                        )
                        Self.revealImportedItems(importedIDs, presentation: presentation)
                    }
                }
            }
            .sheet(isPresented: $openFiles.isPromptingForStreamingURL) { streamingSheet }
            .fileImporter(isPresented: Binding(
                get: { presentation.locateVersionID != nil },
                set: { if !$0 { /* The completion owns the captured version ID. */ } }
            ), allowedContentTypes: [.audio]) { result in
                let versionID = presentation.locateVersionID
                presentation.locateVersionID = nil
                if case let .success(url) = result, let versionID {
                    Task { await coordinator.locateFile(versionID: versionID, url: url) }
                }
            }
            .alert("Takes Error", isPresented: Binding(
                get: { coordinator.errorMessage != nil || controller.playbackError != nil },
                set: { if !$0 { coordinator.clearError(); controller.clearPlaybackError() } }
            )) {
                Button("OK") { coordinator.clearError(); controller.clearPlaybackError() }
            } message: { Text(coordinator.errorMessage ?? controller.playbackError?.localizedDescription ?? "") }
    }

    private var focusedContent: some View {
        presentedContent
            .focusedSceneValue(\.openFileCommandState, persistence.restorationComplete ? openFiles : nil)
            .focusedSceneValue(\.playlistCommandContext, isComparison ? nil : commandContext)
            .focusedSceneValue(\.canShowActiveTrackInFinder, Self.targetVersion(coordinator: coordinator, presentation: presentation) != nil)
            .focusedSceneValue(\.canRemoveActiveTrack, isComparison ? controller.session.activeTrackID != nil : commandContext.canRemove)
            .focusedSceneValue(\.canClearTracks, !coordinator.workspace.items.isEmpty)
            .focusedSceneValue(\.canUseGlobalMenuShortcuts, canUseShortcuts)
            .focusedSceneValue(\.mainWindowCommandState, MainWindowCommandState {
                guard let mainWindow else { return }
                if isComparison {
                    NotificationCenter.default.post(name: TakesWindowPolicy.resetComparisonLayoutNotification, object: nil)
                    TakesWindowPolicy.resetMainWindowSize(mainWindow)
                }
                else { setPlaylistFrame(TakesWindowPolicy.playlistDefaultSize, window: mainWindow) }
            })
    }

    private var canUseShortcuts: Bool {
        persistence.restorationComplete && !textInputIsFocused && !openFiles.isPromptingForStreamingURL
            && !openFiles.isImportingTracks && presentation.renamingItemID == nil && presentation.locateVersionID == nil
    }

    private var workspaceContent: some View {
        VStack(spacing: 0) {
            if let error = persistence.errorMessage {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    if persistence.recoveryAvailable {
                        Button("Use Recovered Playlist") { Task { await persistence.acceptRecoveredWorkspace() } }
                    } else if !persistence.savesEnabled {
                        Button("Retry") { Task { await persistence.retryRestoration() } }
                    } else {
                        Button("Dismiss") { persistence.dismissError() }
                    }
                }.padding(12).background(.background)
            }
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    playlistSurface
                        .frame(width: isComparison ? retainedPlaylistSize.width : proxy.size.width,
                               height: isComparison ? retainedPlaylistSize.height : proxy.size.height)
                        .opacity(isComparison ? 0 : 1)
                        .allowsHitTesting(!isComparison)
                        .accessibilityHidden(isComparison)
                    if isComparison {
                        ContentView(coordinator: coordinator, openFileCommandState: openFiles,
                                    usesTemporaryDefaultWindowLayout: usesTemporaryDefaultWindowLayout)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
                .onChange(of: proxy.size, initial: true) { _, size in
                    if !isComparison && size.width > 0 && size.height > 0 { retainedPlaylistSize = size }
                }
            }
            .overlay {
                if !persistence.restorationComplete {
                    ProgressView("Restoring Playlist…").padding(24).background(.regularMaterial)
                } else if coordinator.isLoading {
                    VStack(spacing: 12) {
                        ProgressView("Importing tracks…")
                        Button("Cancel Import") { coordinator.cancelCurrentImports() }
                    }
                    .padding(24)
                    .background(.regularMaterial)
                }
            }
            .disabled(!persistence.restorationComplete)
        }
    }

    private var playlistSurface: some View {
        VStack(spacing: 0) {
            PlaylistTransportView(coordinator: coordinator)
            if let summary = coordinator.importSummaryMessage {
                HStack(spacing: 8) {
                    Text(summary).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    Button { coordinator.clearImportSummary() } label: {
                        Image(systemName: "xmark").imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss Import Summary")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.thinMaterial)
            }
            PlaylistView(coordinator: coordinator, presentation: presentation, openFiles: openFiles)
        }
    }

    private var streamingSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open Streaming URL").font(.headline)
            TextField("Apple Music, Spotify, or YouTube URL", text: $openFiles.streamingURLText)
                .textFieldStyle(.roundedBorder).disabled(openFiles.streamingURLStatus.isWorking)
                .onSubmit { openFiles.submitStreamingURL() }
            if let status = openFiles.streamingURLStatus.message {
                HStack {
                    if openFiles.streamingURLStatus.isWorking { ProgressView().controlSize(.small) }
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { openFiles.dismissStreamingURLPrompt() }.keyboardShortcut(.cancelAction)
                Button("Open") { openFiles.submitStreamingURL() }.keyboardShortcut(.defaultAction)
                    .disabled(openFiles.streamingURLStatus.isWorking || openFiles.streamingURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 440)
    }

    private static func targetVersion(coordinator: PlaylistCoordinator, presentation: PlaylistPresentationState) -> PlaylistVersion? {
        if coordinator.mode.itemID != nil {
            return coordinator.workspace.allVersions.first { $0.id == coordinator.controller.session.activeTrackID }
        }
        for item in coordinator.workspace.items {
            if presentation.selection.contains(.item(item.id)) { return item.selectedVersion }
            if let version = item.versions.first(where: { presentation.selection.contains(.version($0.id)) }) { return version }
        }
        return coordinator.workspace.allVersions.first { $0.id == coordinator.currentVersionID }
    }

    @MainActor
    private static func revealImportedItems(
        _ itemIDs: [PlaylistItem.ID],
        presentation: PlaylistPresentationState
    ) {
        guard !itemIDs.isEmpty else { return }
        presentation.selection = Set(itemIDs.map(PlaylistRowID.item))
        presentation.expanded.formUnion(itemIDs)
    }

    private func configureOpenRouter() {
        appFileOpenRouter.setHandler { urls in
            let previous = externalOpenTask
            externalOpenTask = Task { @MainActor in
                await previous?.value
                let importedIDs = await coordinator.importFiles(
                    urls, destination: .playlist,
                    automaticGroupingMode: settings.automaticGroupingMode,
                    undoManager: undoManager
                )
                Self.revealImportedItems(importedIDs, presentation: presentation)
            }
        }
        appFileOpenRouter.setStreamingURLHandler { urls in
            let previous = externalOpenTask
            externalOpenTask = Task { @MainActor in
                await previous?.value
                var importedIDs: [PlaylistItem.ID] = []
                for rawURL in urls {
                    do {
                        let url = try await PlaylistStreamingImporter().download(from: rawURL)
                        importedIDs.append(contentsOf: await coordinator.importFiles(
                            [url], destination: .playlist, isWorkspaceOwned: true,
                            automaticGroupingMode: settings.automaticGroupingMode,
                            undoManager: undoManager
                        ))
                    } catch { coordinator.reportError(error.localizedDescription) }
                }
                Self.revealImportedItems(importedIDs, presentation: presentation)
            }
        }
    }

    private func importProviders(_ providers: [NSItemProvider]) -> Bool {
        // Internal comparison drags carry a file URL for dragging out to Finder.
        // Their private marker takes precedence over the external-file flavor.
        guard !providers.contains(where: { $0.hasItemConformingToTypeIdentifier(TrackReorderDrag.contentType.identifier) }) else { return false }
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty, persistence.restorationComplete else { return false }
        let destination = coordinator.captureImportDestination()
        Task { @MainActor in
            var urls: [URL] = []
            for provider in files {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                        let url: URL?
                        if let value = value as? URL { url = value }
                        else if let data = value as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                        else if let text = value as? String { url = URL(string: text) }
                        else { url = nil }
                        continuation.resume(returning: url)
                    }
                }
                if let url { urls.append(url) }
            }
            let importedIDs = await coordinator.importFiles(
                AppOpenedURLResolver.audioFileURLs(from: urls), destination: destination,
                automaticGroupingMode: settings.automaticGroupingMode,
                undoManager: undoManager
            )
            Self.revealImportedItems(importedIDs, presentation: presentation)
        }
        return true
    }

    private func configureWindow(_ window: NSWindow) {
        mainWindow = window
        mainWindowIsKey = window.isKeyWindow
        guard !didConfigure else { return }
        didConfigure = true
        TakesWindowPolicy.configureMainWindow(window, resetsLayoutForLaunch: usesTemporaryDefaultWindowLayout, playlistMode: true)
        if !usesTemporaryDefaultWindowLayout, let value = UserDefaults.standard.string(forKey: "playlistWindowFrame") {
            let frame = NSRectFromString(value)
            if frame.width >= TakesWindowPolicy.minimumContentWidth, frame.height >= 340 { playlistFrame = frame }
        }
        if let playlistFrame { window.setFrame(clampedFrame(playlistFrame, window: window), display: true) }
        else { setPlaylistFrame(TakesWindowPolicy.playlistDefaultSize, window: window) }
    }

    private func applyModeWindowSize(previousMode: PlaylistCoordinator.Mode?) {
        guard let mainWindow else { return }
        if isComparison {
            if previousMode == .playlist { playlistFrame = mainWindow.frame }
            TakesWindowPolicy.resizeMainWindow(mainWindow, displayingTrackRows: controller.displayedTrackRowCount, includesNavigation: true)
        } else if previousMode?.itemID != nil, let playlistFrame {
            mainWindow.setFrame(clampedFrame(playlistFrame, window: mainWindow), display: true)
        }
    }

    private func setPlaylistFrame(_ size: CGSize, window: NSWindow) {
        let frame = CGRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width, height: size.height)
        window.setFrame(clampedFrame(frame, window: window), display: true)
    }

    private func clampedFrame(_ frame: CGRect, window: NSWindow) -> CGRect {
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
        let width = min(frame.width, screen.width), height = min(frame.height, screen.height)
        return CGRect(x: min(max(frame.minX, screen.minX), screen.maxX - width),
                      y: min(max(frame.minY, screen.minY), screen.maxY - height), width: width, height: height)
    }

    private func setupKeyboard() {
        let monitor = KeyMonitor { event in
            guard canUseShortcuts, let mainWindow, event.window === mainWindow,
                  GlobalShortcutFocusPolicy.shouldHandleGlobalShortcut(firstResponder: mainWindow.firstResponder) else { return false }
            let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
            if isComparison {
                if let key = TrackNumberHotkey.hotkey(forKeyCode: event.keyCode, modifierFlags: flags), controller.canSelectTrackForHotkey(key) {
                    controller.selectTrackForHotkey(key); return true
                }
                if let direction = TrackSwitchArrowHotkey.direction(forKeyCode: event.keyCode, modifierFlags: flags), controller.session.canSwitchPlayback {
                    if direction == .previous { coordinator.previous() } else { coordinator.next() }; return true
                }
            }
            switch event.keyCode {
            case 49 where flags.isEmpty:
                coordinator.togglePlayback(); return true
            case 7 where flags.isEmpty || flags == .shift:
                if flags == .shift { coordinator.previous() } else { coordinator.next() }; return true
            case 123, 124:
                let forward = event.keyCode == 124
                if flags == .command {
                    coordinator.seek(to: forward ? controller.session.timelineEnd : controller.session.timelineStart); return true
                }
                if !isComparison && presentation.listHasFocus { return false }
                guard flags.isEmpty || flags == .shift else { return false }
                coordinator.skip(by: (forward ? 1 : -1) * (flags == .shift ? 10 : 1)); return true
            default: return false
            }
        }
        monitor.start()
        keyMonitor = monitor
    }
}

private struct PlaylistTransportView: View {
    let coordinator: PlaylistCoordinator
    @EnvironmentObject private var settings: AppSettings
    private var controller: PlaybackController { coordinator.controller }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Spacer(minLength: 64)
                Button { coordinator.previous() } label: { Image(systemName: "backward.end.fill") }
                    .buttonStyle(CircleTransportButtonStyle(kind: .secondary, diameter: 32, glyphSize: 13))
                    .disabled(!coordinator.canPrevious).accessibilityLabel("Previous Item")
                Button { coordinator.togglePlayback() } label: { Image(systemName: coordinator.isPlaying ? "pause.fill" : "play.fill") }
                    .buttonStyle(CircleTransportButtonStyle(kind: .primary, diameter: 48, glyphSize: 20))
                    .disabled(!coordinator.canPlay).accessibilityLabel(coordinator.isPlaying ? "Pause" : "Play")
                Button { coordinator.next() } label: { Image(systemName: "forward.end.fill") }
                    .buttonStyle(CircleTransportButtonStyle(kind: .secondary, diameter: 32, glyphSize: 13))
                    .disabled(!coordinator.canNext).accessibilityLabel("Next Item")
                Spacer(minLength: 8)
                DigitalTimeReadout(style: settings.readoutStyle, elapsed: coordinator.isPlaying ? controller.playingReadoutText : controller.session.transportPosition.formattedSignedTimestamp)
                    .allowsHitTesting(false)
                Spacer(minLength: 8)
                Button { coordinator.toggleShuffle() } label: { Image(systemName: "shuffle") }
                    .buttonStyle(CircleTransportButtonStyle(kind: .secondary, isOn: coordinator.workspace.isShuffleEnabled, diameter: 32, glyphSize: 13))
                    .accessibilityLabel("Shuffle").accessibilityValue(coordinator.workspace.isShuffleEnabled ? "On" : "Off")
                Button { coordinator.cyclePlaylistRepeatMode() } label: {
                    Image(systemName: coordinator.workspace.playlistRepeatMode == .one ? "repeat.1" : "repeat")
                }
                .buttonStyle(CircleTransportButtonStyle(kind: .secondary, isOn: coordinator.workspace.playlistRepeatMode != .off, diameter: 32, glyphSize: 13))
                .accessibilityLabel("Repeat").accessibilityValue(coordinator.workspace.playlistRepeatMode.rawValue.capitalized)
                Spacer(minLength: 8)
            }
            PlaylistSeekControl(controller: controller, seek: coordinator.seek)
                .frame(height: 18).padding(.horizontal, 20)
        }
        .padding(.top, 20).padding(.bottom, 10)
        .background(Theme.controlBarLift.allowsHitTesting(false))
        .background(WindowDragArea())
    }
}

/// Only transport anchor events update this leaf. Core Animation moves the thumb
/// between anchors; native input and accessibility write seeks back to transport.
private struct PlaylistSeekControl: NSViewRepresentable {
    let controller: PlaybackController
    let seek: (TimeInterval) -> Void

    func makeNSView(context: Context) -> PlaylistSeekView { PlaylistSeekView() }
    func updateNSView(_ view: PlaylistSeekView, context: Context) {
        _ = controller.session.transportPosition
        view.configure(position: controller.displayTransportPosition(), duration: controller.session.duration,
                       playing: controller.session.isPlaying, seek: seek)
    }
}

private final class PlaylistSeekView: NSView {
    private let rail = CALayer()
    private let thumb = CALayer()
    private var duration: TimeInterval = 0
    private var position: TimeInterval = 0
    private var playing = false
    private var anchorTime: TimeInterval = 0
    private var seek: (TimeInterval) -> Void = { _ in }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(rail); layer?.addSublayer(thumb)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Playback Position")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(position: TimeInterval, duration: TimeInterval, playing: Bool, seek: @escaping (TimeInterval) -> Void) {
        self.position = position; self.duration = duration; self.playing = playing
        self.anchorTime = CACurrentMediaTime(); self.seek = seek
        setAccessibilityEnabled(duration > 0)
        redraw()
    }
    override func layout() { super.layout(); redraw() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); redraw() }
    private var currentPosition: TimeInterval {
        min(max(position + (playing ? CACurrentMediaTime() - anchorTime : 0), 0), duration)
    }
    private func redraw() {
        let current = currentPosition
        let x = duration > 0 ? 6 + (bounds.width - 12) * current / duration : 6
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rail.frame = CGRect(x: 6, y: bounds.midY - 2, width: max(bounds.width - 12, 0), height: 4)
        rail.cornerRadius = 2; rail.backgroundColor = NSColor.separatorColor.cgColor
        thumb.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        thumb.cornerRadius = 6; thumb.backgroundColor = NSColor.controlAccentColor.cgColor
        thumb.removeAnimation(forKey: "position")
        thumb.position = CGPoint(x: x, y: bounds.midY)
        if playing && duration > current {
            let animation = CABasicAnimation(keyPath: "position.x")
            animation.fromValue = x; animation.toValue = bounds.width - 6
            animation.duration = duration - current; animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.fillMode = .forwards; animation.isRemovedOnCompletion = false
            thumb.add(animation, forKey: "position")
        }
        CATransaction.commit()
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); scrub(event) }
    override func mouseDragged(with event: NSEvent) { scrub(event) }
    private func scrub(_ event: NSEvent) {
        guard duration > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        seek(min(max((point.x - 6) / max(bounds.width - 12, 1), 0), 1) * duration)
    }
    override func accessibilityValue() -> Any? { currentPosition.formattedSignedTimestamp }
    override func accessibilityPerformIncrement() -> Bool { seek(min(currentPosition + 1, duration)); return duration > 0 }
    override func accessibilityPerformDecrement() -> Bool { seek(max(currentPosition - 1, 0)); return duration > 0 }
}
