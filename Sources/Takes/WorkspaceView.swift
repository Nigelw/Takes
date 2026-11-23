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
    @State private var retainedPlaylistSize = TakesWindowPolicy.defaultSize(showsArtwork: true)
    /// Process-lifetime artwork cache for the cover; loads only the version
    /// on display.
    @State private var artworkStore = PlaylistArtworkStore()
    /// Vertical centre of the window buttons, measured from the window's top
    /// edge, so the artwork toggle lines up with them.
    @State private var titlebarButtonCenterY: CGFloat = 14
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
            }
            .task(id: coverVersion?.id) {
                if let coverVersion { artworkStore.load(for: coverVersion) }
            }
            .onChange(of: settings.showsArtwork) { _, showsArtwork in
                guard let mainWindow else { return }
                // Next run-loop turn, after SwiftUI has applied the new root
                // minimum, so a shrink isn't held up by the old one.
                Task { @MainActor in TakesWindowPolicy.applyArtworkVisibility(showsArtwork, to: mainWindow) }
            }
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
            .onDisappear { keyMonitor?.stop() }
    }

    private var windowContent: some View {
        workspaceContent
            .frame(minWidth: TakesWindowPolicy.minimumWidth,
                   minHeight: TakesWindowPolicy.rootViewMinimumHeight(showsArtwork: settings.showsArtwork))
            .ignoresSafeArea(.container, edges: .top)
            .environment(\.transportAppearance, settings.transportAppearance)
            .background(WindowBackground().ignoresSafeArea())
            .background {
                MainWindowConfigurationView { window in configureWindow(window) }
            }
            // Titlebar overlay: over the cover, or over the top of the
            // control bar when the cover is hidden. 10 pt from the trailing
            // edge, centred on the window buttons.
            // The overlay has its own safe area, so it must ignore the
            // titlebar inset too, or the toggle lands below the titlebar.
            .overlay {
                ArtworkToggleButton(showsArtwork: $settings.showsArtwork)
                    .padding(.trailing, 10)
                    .padding(.top, max(titlebarButtonCenterY - ArtworkToggleButton.size.height / 2, 0))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .ignoresSafeArea(.container, edges: .top)
            }
            .overlay {
                if !mainWindowIsKey { InactiveWindowInteractionShield(window: mainWindow).ignoresSafeArea() }
            }
            .onDrop(of: [UTType.fileURL], delegate: WorkspaceFileDropDelegate(isTargeted: $isDropTargeted, perform: importProviders))
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
            .fileDialogMessage(Text(locateFileMessage))
            .fileDialogConfirmationLabel(Text(presentation.locateVersionID == nil ? "Open" : "Locate"))
            .alert("Takes Error", isPresented: Binding(
                get: { coordinator.errorMessage != nil || controller.playbackError != nil },
                set: { if !$0 { coordinator.clearError(); controller.clearPlaybackError() } }
            )) {
                Button("OK") { coordinator.clearError(); controller.clearPlaybackError() }
            } message: { Text(coordinator.errorMessage ?? controller.playbackError?.localizedDescription ?? "") }
    }

    private var locateFileMessage: String {
        guard let version = coordinator.workspace.allVersions.first(where: { $0.id == presentation.locateVersionID }) else { return "" }
        return "Locate “\(version.file.storedURL.lastPathComponent)”"
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
                }
                TakesWindowPolicy.resetMainWindowSize(mainWindow, showsArtwork: settings.showsArtwork)
            })
    }

    private var canUseShortcuts: Bool {
        persistence.restorationComplete && !textInputIsFocused && !openFiles.isPromptingForStreamingURL
            && !openFiles.isImportingTracks && presentation.renamingItemID == nil && presentation.locateVersionID == nil
    }

    private var workspaceContent: some View {
        VStack(spacing: 0) {
            // Shared by both modes: entering compare swaps only what is below
            // the control bar, never the cover.
            if settings.showsArtwork {
                ArtworkCoverView(image: artworkStore.artwork(for: coverVersion?.id))
            }
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
            PlaylistView(coordinator: coordinator, presentation: presentation, openFiles: openFiles, artworkStore: artworkStore)
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
        // Playlist row drags carry one too, and are handled by the playlist table.
        let internalTypes = [TrackReorderDrag.contentType.identifier, PlaylistItemDrag.type.identifier]
        guard !providers.contains(where: { provider in
            internalTypes.contains(where: provider.hasItemConformingToTypeIdentifier)
        }) else { return false }
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
        TakesWindowPolicy.configureMainWindow(
            window,
            showsArtwork: settings.showsArtwork,
            resetsLayoutForLaunch: usesTemporaryDefaultWindowLayout
        )
        measureTitlebarButtons(in: window)
        // The titlebar may not be laid out at its final size yet.
        DispatchQueue.main.async { measureTitlebarButtons(in: window) }
    }

    /// Centre of the close button measured inside its titlebar container,
    /// which is pinned to the window's top edge, so the value doesn't depend
    /// on the window's current height.
    private func measureTitlebarButtons(in window: NSWindow) {
        guard let button = window.standardWindowButton(.closeButton), let container = button.superview else { return }
        let midY = button.frame.midY
        let centerFromTop = container.isFlipped ? midY : container.bounds.height - midY
        if (4...44).contains(centerFromTop), abs(centerFromTop - titlebarButtonCenterY) > 0.25 {
            titlebarButtonCenterY = centerFromTop
        }
    }

    /// The version whose cover the window shows: in playlist mode the playing
    /// (or current) version, as the readout shows; in comparison the item's
    /// playback version, so switching the audible version doesn't swap the
    /// cover.
    private var coverVersion: PlaylistVersion? {
        guard let itemID = coordinator.mode.itemID ?? coordinator.currentItemID,
              let item = coordinator.workspace.items.first(where: { $0.id == itemID }) else { return nil }
        if coordinator.mode.itemID == nil, let current = item.versions.first(where: { $0.id == coordinator.currentVersionID }) {
            return current
        }
        return item.selectedVersion
    }

    private func setupKeyboard() {
        let monitor = KeyMonitor { event in
            guard canUseShortcuts, let mainWindow, event.window === mainWindow,
                  GlobalShortcutFocusPolicy.shouldHandleGlobalShortcut(firstResponder: mainWindow.firstResponder) else { return false }
            let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
            if isComparison {
                // Esc leaves compare, like the readout's back button (§9).
                if event.keyCode == 53 && flags.isEmpty {
                    Task { await coordinator.backToPlaylist() }; return true
                }
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

/// Playlist control bar (spec §5): Shuffle · Previous · Play · Next ·
/// Repeat over the two-line readout.
private struct PlaylistTransportView: View {
    let coordinator: PlaylistCoordinator
    @EnvironmentObject private var settings: AppSettings
    private var controller: PlaybackController { coordinator.controller }

    var body: some View {
        ControlBarLayout(showsArtwork: settings.showsArtwork) {
            Button { coordinator.toggleShuffle() } label: { Image(systemName: "shuffle") }
                .buttonStyle(ControlBarSideButtonStyle(isOn: coordinator.workspace.isShuffleEnabled))
                .help("Shuffle")
                .accessibilityLabel("Shuffle").accessibilityValue(coordinator.workspace.isShuffleEnabled ? "On" : "Off")
        } center: {
            Button { coordinator.previous() } label: { Image(systemName: "backward.end.fill") }
                .buttonStyle(CircleTransportButtonStyle(kind: .secondary, diameter: ControlBarMetrics.secondaryDiameter,
                                                        glyphSize: ControlBarMetrics.secondaryGlyphSize))
                .disabled(!coordinator.canPrevious).help("Previous Item").accessibilityLabel("Previous Item")
            Button { coordinator.togglePlayback() } label: { Image(systemName: coordinator.isPlaying ? "pause.fill" : "play.fill") }
                .buttonStyle(CircleTransportButtonStyle(kind: .primary, diameter: ControlBarMetrics.primaryDiameter,
                                                        glyphSize: ControlBarMetrics.primaryGlyphSize, pressedGlyphOffset: 1.5))
                .disabled(!coordinator.canPlay).help(coordinator.isPlaying ? "Pause" : "Play")
                .accessibilityLabel(coordinator.isPlaying ? "Pause" : "Play")
            Button { coordinator.next() } label: { Image(systemName: "forward.end.fill") }
                .buttonStyle(CircleTransportButtonStyle(kind: .secondary, diameter: ControlBarMetrics.secondaryDiameter,
                                                        glyphSize: ControlBarMetrics.secondaryGlyphSize))
                .disabled(!coordinator.canNext).help("Next Item").accessibilityLabel("Next Item")
        } trailing: {
            Button { coordinator.cyclePlaylistRepeatMode() } label: {
                Image(systemName: coordinator.workspace.playlistRepeatMode == .one ? "repeat.1" : "repeat")
            }
            .buttonStyle(ControlBarSideButtonStyle(isOn: coordinator.workspace.playlistRepeatMode != .off))
            .help("Repeat")
            .accessibilityLabel("Repeat").accessibilityValue(coordinator.workspace.playlistRepeatMode.rawValue.capitalized)
        } readout: {
            PlaylistControlBarReadout(
                controller: controller,
                title: ControlBarReadoutTitle.playlist(currentVersion),
                seek: coordinator.seek
            )
        }
    }

    /// The version the transport is showing: the current one, else the
    /// item's selected version (same fallback the coordinator uses).
    private var currentVersion: PlaylistVersion? {
        guard let item = coordinator.workspace.items.first(where: { $0.id == coordinator.currentItemID }) else { return nil }
        return item.versions.first { $0.id == coordinator.currentVersionID } ?? item.selectedVersion
    }
}

/// Window-wide file drop. Playlist row drags also carry a file URL (so rows
/// can be dragged out to Finder); they are rejected here so the import
/// highlight never appears for an in-app reorder.
private struct WorkspaceFileDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let perform: ([NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL.identifier])
            && !info.hasItemsConforming(to: [PlaylistItemDrag.type.identifier])
    }

    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropExited(info: DropInfo) { isTargeted = false }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        return perform(info.itemProviders(for: [UTType.fileURL.identifier]))
    }
}
