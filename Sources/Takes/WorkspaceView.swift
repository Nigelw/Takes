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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var presentation: PlaylistPresentationState
    @StateObject private var openFiles: OpenFileCommandState
    @State private var mainWindow: NSWindow?
    @State private var didConfigure = false
    @State private var artworkResize: TakesWindowPolicy.ArtworkResize?
    @State private var didStart = false
    @State private var keyMonitor: KeyMonitor?
    @State private var externalOpenTask: Task<Void, Never>?
    @State private var isDropTargeted = false
    @State private var retainedPlaylistSize = TakesWindowPolicy.defaultSize(showsArtwork: true)
    /// Process-lifetime artwork cache for the cover; loads only the version
    /// on display.
    @State private var artworkStore = PlaylistArtworkStore()
    /// Vertical centre of the window buttons, measured from the window's top
    /// edge, so the visibility toggles line up with them.
    @State private var titlebarButtonCenterY: CGFloat = 14
    @State private var artworkIsHovered = false
    @State private var mainWindowIsKey = true
    @State private var textInputIsFocused = false
    /// The version whose cover is on screen: `coverVersion` once its artwork
    /// has loaded or is known to be missing. Until then the previous cover
    /// stays up, so switching versions never flashes the placeholder.
    @State private var shownCoverVersionID: PlaylistVersion.ID?
    /// The version the open Locate dialog is for, captured when it opens.
    @State private var presentedLocateVersionID: PlaylistVersion.ID?
    /// Track count before the first of a run of adds or removes, while the
    /// resize that fits them is pending (`fitWindowToContent`).
    @State private var contentFitBaseline: Int?
    @State private var contentFitTask: Task<Void, Never>?

    private var controller: PlaybackController { coordinator.controller }
    private var isComparison: Bool { coordinator.mode.itemID != nil }
    private var visibility: WorkspaceVisibility { settings.windowVisibility }
    private var showsTitlebarControls: Bool { !visibility.showsArtwork || artworkIsHovered }
    private var showsVisibilityToggles: Bool { showsTitlebarControls || (!visibility.showsPlayer && !visibility.showsPlaylist) }
    private var heightBelowArtwork: CGFloat {
        TakesWindowPolicy.heightBelowArtwork(for: visibility, isComparison: isComparison)
    }
    private var windowMinimumSize: CGSize {
        TakesWindowPolicy.minimumSize(for: visibility, isComparison: isComparison)
    }
    private var minimumHeightWithoutArtwork: CGFloat {
        TakesWindowPolicy.heightBelowArtwork(
            for: WorkspaceVisibility(showsArtwork: false, showsPlaylist: visibility.showsPlaylist), isComparison: isComparison
        )
    }
    private var commandContext: PlaylistCommandContext {
        .init(coordinator: coordinator, presentation: presentation, undoManager: undoManager)
    }
    private var imports: WorkspaceImports { .init(coordinator: coordinator, presentation: presentation) }

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
        let imports = WorkspaceImports(coordinator: coordinator, presentation: presentation)
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
                        await imports.submit([url], destination: destination, isWorkspaceOwned: true)
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
                        await imports.submit(selection.urls, destination: destination)
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
                        await imports.submit(urls, destination: destination)
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
                restoreModeHeight()
                configureOpenRouter()
            }
            .task(id: coverVersion?.id) {
                if let coverVersion { artworkStore.load(for: coverVersion) }
            }
            .onChange(of: coverState, initial: true) { _, state in
                if state.versionID == nil || state.isResolved { shownCoverVersionID = state.versionID }
            }
            .task(id: artworkResize) {
                guard let resize = artworkResize, let mainWindow else { return }
                await TakesWindowPolicy.resizeForArtwork(
                    mainWindow, to: resize.targetFrame, minimumHeight: minimumHeightWithoutArtwork, animate: !reduceMotion
                )
                guard !Task.isCancelled, artworkResize == resize else { return }
                artworkResize = nil
                updateWindowMinimumSize()
                // A screen-clamped toggle changes the height beyond the cover's.
                storePlaylistHeight()
            }
            .onChange(of: contentFitKey) { old, new in scheduleContentFit(from: old, to: new) }
            .onChange(of: coordinator.workspace.items.map { [$0.id] + $0.versions.map(\.id) }) { _, _ in
                presentation.prune(in: coordinator.workspace)
            }
            .onChange(of: presentation.locateVersionID) { _, id in
                if let id { presentedLocateVersionID = id }
            }
            .onChange(of: isComparison) { wasComparison, _ in
                switchModeHeight(wasComparison: wasComparison)
                refreshTextInputFocus()
            }
            .onChange(of: visibility.showsPlaylist) { _, _ in refreshTextInputFocus() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification)) { notification in
                guard notification.object as? NSWindow === mainWindow else { return }
                if visibility.showsPlaylist { storePlaylistHeight() }
                else { applyModeHeight() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
                guard notification.object as? NSWindow === mainWindow else { return }
                updateWindowMinimumSize()
                if !visibility.showsPlaylist { applyModeHeight() }
            }
            .onChange(of: showsTitlebarControls) { _, showsControls in
                if let mainWindow { updateWindowButtons(in: mainWindow, visible: showsControls) }
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
        GeometryReader { proxy in
            let fraction = artworkResize?.fraction(at: proxy.size.height) ?? (visibility.showsArtwork ? 1 : 0)
            let coverHeight = artworkResize?.coverHeight ?? (heightBelowArtwork == 0 ? proxy.size.height
                : TakesWindowPolicy.artworkHeight(in: proxy.size, reserving: heightBelowArtwork))
            workspaceContent(artworkFraction: fraction, coverHeight: coverHeight)
        }
            .frame(minWidth: TakesWindowPolicy.minimumWidth,
                   minHeight: (artworkResize == nil ? windowMinimumSize.height : minimumHeightWithoutArtwork)
                       - TakesWindowPolicy.hiddenTitlebarSafeAreaInset)
            .ignoresSafeArea(.container, edges: .top)
            .background(WindowBackground().ignoresSafeArea())
            .background {
                MainWindowConfigurationView { window in configureWindow(window) }
            }
            // Titlebar overlay: over the cover, or over the top of the
            // player when the cover is hidden. 10 pt from the trailing edge,
            // centred on the window buttons.
            // The overlay has its own safe area, so it must ignore the
            // titlebar inset too, or the toggles land below the titlebar.
            .overlay {
                if showsVisibilityToggles {
                    HStack(spacing: 0) {
                        ForEach(WorkspaceVisibility.Region.allCases, id: \.self) { region in
                            WorkspaceVisibilityButton(region: region, visibility: visibility) { toggleVisibility(region) }
                        }
                    }
                    .background(ArtworkControlsBackground())
                    .padding(.trailing, 10)
                    .padding(.top, max(titlebarButtonCenterY - WorkspaceVisibilityButton.size.height / 2, 0))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .ignoresSafeArea(.container, edges: .top)
                }
            }
            .environment(\.transportAppearance, settings.transportAppearance)
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
                        await imports.submit(urls, destination: destination, undoManager: undoManager)
                    }
                }
            }
            .sheet(isPresented: $openFiles.isPromptingForStreamingURL) { streamingSheet }
            .fileImporter(isPresented: Binding(
                get: { presentation.locateVersionID != nil },
                // Cancelling calls no completion, so dismissal must clear the
                // request itself; otherwise the next Locate for the same
                // version changes nothing and the dialog never opens again.
                // The completion reads the ID captured when it opened.
                set: { if !$0 { presentation.locateVersionID = nil } }
            ), allowedContentTypes: [.audio]) { result in
                let versionID = presentedLocateVersionID
                presentedLocateVersionID = nil
                presentation.locateVersionID = nil
                if case let .success(url) = result, let versionID {
                    Task { await coordinator.locateFile(versionID: versionID, url: url) }
                }
            }
            .fileDialogMessage(Text(locateFileMessage))
            .fileDialogConfirmationLabel(Text(presentation.locateVersionID == nil ? "Open" : "Locate"))
    }

    private var locateFileMessage: String {
        guard let version = coordinator.workspace.allVersions.first(where: { $0.id == presentation.locateVersionID }) else { return "" }
        return "Locate “\(version.file.storedURL.lastPathComponent)”"
    }

    private var focusedContent: some View {
        presentedContent
            .focusedSceneValue(\.openFileCommandState, persistence.restorationComplete ? openFiles : nil)
            .focusedSceneValue(\.playlistCommandContext, isComparison ? nil : commandContext)
            .focusedSceneValue(\.playlistOrganizationAvailability,
                               canUseShortcuts ? PlaylistOrganizationAvailability(commandContext) : nil)
            .focusedSceneValue(\.canShowActiveTrackInFinder, Self.targetVersion(coordinator: coordinator, presentation: presentation) != nil)
            .focusedSceneValue(\.canRemoveActiveTrack, isComparison ? controller.session.activeTrackID != nil : commandContext.canRemove)
            .focusedSceneValue(\.canClearTracks, !coordinator.workspace.items.isEmpty)
            .focusedSceneValue(\.canUseGlobalMenuShortcuts, canUseShortcuts)
            .focusedSceneValue(\.mainWindowCommandState, MainWindowCommandState(
                resetWindowSizing: { resetWindowSize() },
                visibility: visibility,
                toggleVisibility: { toggleVisibility($0) }
            ))
    }

    /// Menu shortcuts: off while text is being edited, so a plain-key
    /// equivalent like Space can't take keystrokes from a text field.
    private var canUseShortcuts: Bool { shortcutsAreAvailable && !textInputIsFocused }

    /// Everything but text editing, which the key monitor reads from the
    /// first responder at each key press instead.
    private var shortcutsAreAvailable: Bool {
        persistence.restorationComplete && !openFiles.isPromptingForStreamingURL
            && !openFiles.isImportingTracks && presentation.locateVersionID == nil
    }

    private func workspaceContent(artworkFraction: CGFloat, coverHeight: CGFloat) -> some View {
        let visibleCoverHeight = coverHeight * artworkFraction
        let animateClampedCover = artworkResize?.followsWindow == false && !reduceMotion
        return VStack(spacing: 0) {
            // Keep the same cover above the top edge when closed. Its bottom
            // edge travels with the transport on both opening and closing.
            artworkCover
                .frame(height: coverHeight)
                .geometryGroup()
                .offset(y: visibleCoverHeight - coverHeight)
                .frame(height: visibleCoverHeight, alignment: .top)
                .clipped()
                .componentDebugLabel("Cover", enabled: settings.showsComponentDebugLabels && visibility.showsArtwork)
                .overlay {
                    if visibility.showsArtwork {
                        HoverSensor(trackingActivity: .activeAlways) { artworkIsHovered = $0 }
                    }
                }
                .allowsHitTesting(visibility.showsArtwork)
                .contentShape(Rectangle())
                .accessibilityHidden(!visibility.showsArtwork)
                .accessibilityActions {
                    if visibility.showsArtwork && visibility.canToggle(.artwork) {
                        Button("Hide Artwork") { toggleVisibility(.artwork) }
                    }
                }
            if visibility.showsPlaylist { persistenceBanner }
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    playlistSurface
                        // Dimmed in the background, as compare is.
                        .windowActivityAppearance(isActive: mainWindowIsKey)
                        .frame(width: isComparison ? retainedPlaylistSize.width : proxy.size.width,
                               height: isComparison ? retainedPlaylistSize.height : proxy.size.height, alignment: .topLeading)
                        .opacity(isComparison ? 0 : 1)
                        .allowsHitTesting(!isComparison)
                        // Takes its controls out of the Tab loop while compare covers it.
                        .disabled(isComparison)
                        .accessibilityHidden(isComparison)
                    if isComparison {
                        ContentView(
                            coordinator: coordinator,
                            openFileCommandState: openFiles,
                            importProviders: importProviders,
                            locateVersion: { presentation.locateVersionID = $0 }
                        )
                            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                            .transition(.opacity)
                            .zIndex(1)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
                .animation(reduceMotion || !persistence.restorationComplete ? nil : .easeInOut(duration: 0.20),
                           value: isComparison)
                .onChange(of: proxy.size, initial: true) { _, size in
                    if !isComparison && size.width > 0 && size.height > 0 { retainedPlaylistSize = size }
                }
            }
            .overlay { if visibility.showsPlaylist { loadingOverlay } }
            .disabled(!persistence.restorationComplete)
            .geometryGroup()
        }
        .overlay { if !visibility.showsPlaylist { loadingOverlay } }
        .overlay(alignment: .bottom) { if !visibility.showsPlaylist { persistenceBanner } }
        .environment(\.controlBarTopPadding, TakesWindowPolicy.controlBarTopPadding(artworkFraction: artworkFraction))
        .animation(animateClampedCover ? .easeInOut(duration: TakesWindowPolicy.artworkResizeDuration) : nil,
                   value: visibility.showsArtwork)
    }

    private var artworkCover: some View {
        ArtworkCoverView(image: artworkStore.artwork(for: shownCoverVersionID),
                         showsTitlebarControls: showsVisibilityToggles)
            .overlay(alignment: .bottom) {
                if !visibility.showsPlayer && artworkIsHovered {
                    HStack(spacing: 7) {
                        if isComparison {
                            let buttons = CompareTransportButtons(
                                coordinator: coordinator, showsDebugLabels: settings.showsComponentDebugLabels
                            )
                            buttons.center(size: .mini)
                        } else {
                            BasicTransportButtons(coordinator: coordinator, size: .mini)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(ArtworkControlsBackground())
                    .padding(.bottom, 10)
                    .windowActivityAppearance(isActive: mainWindowIsKey)
                    .disabled(!persistence.restorationComplete)
                }
            }
    }

    @ViewBuilder
    private var persistenceBanner: some View {
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
            }
            .padding(12)
            .background(.background)
        }
    }

    @ViewBuilder
    private var loadingOverlay: some View {
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

    private var playlistSurface: some View {
        VStack(spacing: 0) {
            if visibility.showsPlayer {
                PlaylistTransportView(coordinator: coordinator)
            }
            if visibility.showsPlaylist {
                ControlBarDivider()
                PlaylistView(coordinator: coordinator, presentation: presentation, openFiles: openFiles, artworkStore: artworkStore)
                PlaylistBottomBar(coordinator: coordinator, presentation: presentation, openFiles: openFiles, undoManager: undoManager)
                    .componentDebugLabel("Bottom Bar", enabled: settings.showsComponentDebugLabels)
            }
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
            if presentation.selection.contains(.item(item.id)) { return item.keyVersion }
            if let version = item.versions.first(where: { presentation.selection.contains(.version($0.id)) }) { return version }
        }
        return coordinator.workspace.allVersions.first { $0.id == coordinator.currentVersionID }
    }

    private func configureOpenRouter() {
        appFileOpenRouter.setHandler { urls in
            let previous = externalOpenTask
            externalOpenTask = Task { @MainActor in
                await previous?.value
                await imports.submit(urls, destination: .playlist, undoManager: undoManager)
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
                        importedIDs.append(contentsOf: await imports.submit(
                            [url], destination: .playlist, isWorkspaceOwned: true,
                            undoManager: undoManager, selectResults: false
                        ))
                    } catch { coordinator.reportError(error.localizedDescription) }
                }
                imports.select(importedIDs)
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
        let undoManager = undoManager ?? mainWindow?.undoManager
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
            await imports.submit(
                AppOpenedURLResolver.audioFileURLs(from: urls), destination: destination,
                undoManager: undoManager
            )
        }
        return true
    }

    private func toggleVisibility(_ region: WorkspaceVisibility.Region) {
        let previous = visibility
        guard previous.canToggle(region) else { return }
        var updated = previous
        updated.toggle(region)
        if region == .artwork {
            setArtworkVisibility(updated)
            return
        }
        finishArtworkResize()
        if region == .playlist && previous.showsPlaylist { storePlaylistHeight() }
        settings.windowVisibility = updated
        updateWindowMinimumSize()
        guard let mainWindow, !mainWindow.styleMask.contains(.fullScreen) else { return }
        if region == .player && updated.showsPlaylist {
            let reduction = TakesWindowPolicy.playerHeightWithoutDivider(showsArtwork: updated.showsArtwork, isComparison: isComparison)
            let height = mainWindow.frame.height + (updated.showsPlayer ? reduction : -reduction)
            if let frame = frameSettingHeight(height, for: mainWindow) {
                mainWindow.setFrame(frame, display: true, animate: !reduceMotion)
            }
        } else {
            applyModeHeight(useDefaultPlaylistHeight: true)
        }
    }

    private func setArtworkVisibility(_ updated: WorkspaceVisibility) {
        let showsArtwork = updated.showsArtwork
        if artworkResize != nil {
            // Keep both endpoints, including screen clamping, on reversal.
            artworkResize?.showsArtwork = showsArtwork
        } else if let mainWindow, !mainWindow.styleMask.contains(.fullScreen) {
            let shown = WorkspaceVisibility(showsPlaylist: updated.showsPlaylist)
            artworkResize = .init(
                from: mainWindow.frame, showsArtwork: showsArtwork, visibleFrame: TakesWindowPolicy.visibleFrame(for: mainWindow),
                heightBelowArtwork: TakesWindowPolicy.heightBelowArtwork(for: shown, isComparison: isComparison),
                hiddenMinimumHeight: minimumHeightWithoutArtwork
            )
        }
        if !showsArtwork { artworkIsHovered = false }
        settings.windowVisibility = updated
    }

    private func finishArtworkResize() {
        guard let resize = artworkResize, let mainWindow else { return }
        artworkResize = nil
        mainWindow.setFrame(resize.targetFrame, display: true)
    }

    private func updateWindowMinimumSize() {
        guard let mainWindow, artworkResize == nil, !mainWindow.styleMask.contains(.fullScreen) else { return }
        mainWindow.minSize = windowMinimumSize
    }

    private func refreshTextInputFocus() {
        // A field torn down mid-edit never posts its end-of-editing notification.
        DispatchQueue.main.async {
            guard let mainWindow else { return }
            textInputIsFocused = !GlobalShortcutFocusPolicy.shouldHandleGlobalShortcut(firstResponder: mainWindow.firstResponder)
        }
    }

    private func configureWindow(_ window: NSWindow) {
        mainWindow = window
        mainWindowIsKey = window.isKeyWindow
        guard !didConfigure else { return }
        didConfigure = true
        TakesWindowPolicy.configureMainWindow(
            window,
            visibility: visibility,
            resetsLayoutForLaunch: usesTemporaryDefaultWindowLayout
        )
        measureTitlebarButtons(in: window)
        // The titlebar may not be laid out at its final size yet.
        DispatchQueue.main.async { measureTitlebarButtons(in: window) }
        updateWindowButtons(in: window, visible: showsTitlebarControls)
    }

    private func updateWindowButtons(in window: NSWindow, visible: Bool) {
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = !visible
        }
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
    /// (or current) version, as the readout shows. In comparison the audible
    /// version, so Switch Track swaps the cover (milestone 4 review) — except
    /// in Blind Listening Mode, where the item's playback version stays up so
    /// the cover can't reveal which version is audible.
    private var coverVersion: PlaylistVersion? {
        guard let itemID = coordinator.mode.itemID ?? coordinator.currentItemID,
              let item = coordinator.workspace.items.first(where: { $0.id == itemID }) else { return nil }
        if coordinator.mode.itemID == nil {
            return CoverVersionRule.playlist(item: item, currentVersionID: coordinator.currentVersionID)
        }
        let session = controller.session
        return CoverVersionRule.comparison(
            item: item,
            audibleVersionID: session.activeTrackID,
            isBlind: session.isBlindListeningModeEnabled
        )
    }

    // MARK: Mode heights

    /// Store the expanded playlist height normalized for the cover and player.
    private func storePlaylistHeight(wasComparison: Bool? = nil) {
        guard !(wasComparison ?? isComparison), visibility.showsPlaylist, let mainWindow, artworkResize == nil,
              !mainWindow.styleMask.contains(.fullScreen), persistence.restorationComplete else { return }
        TakesWindowPolicy.storePlaylistHeight(
            mainWindow.frame.size, showsArtwork: visibility.showsArtwork,
            heightBelowArtwork: TakesWindowPolicy.heightBelowArtwork(for: visibility, isComparison: false),
            playerHeightReduction: visibility.showsPlayer ? 0
                : TakesWindowPolicy.playerHeightWithoutDivider(showsArtwork: visibility.showsArtwork, isComparison: false)
        )
    }

    /// Entering compare stores the playlist's height and sizes the window to
    /// the item's lanes; leaving restores the playlist's height. The window
    /// still has the old mode's frame here, as the mode has only just changed.
    private func switchModeHeight(wasComparison: Bool) {
        guard persistence.restorationComplete else { return }
        finishArtworkResize()
        storePlaylistHeight(wasComparison: wasComparison)
        updateWindowMinimumSize()
        applyModeHeight()
    }

    /// Help ▸ Debug ▸ Reset Window Size: artwork on, the default width, and
    /// the mode's height (the playlist's default, which it then remembers,
    /// or compare's fit to its lanes).
    private func resetWindowSize() {
        guard let mainWindow, !mainWindow.styleMask.contains(.fullScreen) else { return }
        finishArtworkResize()
        if !visibility.showsArtwork { settings.windowVisibility.toggle(.artwork) }
        updateWindowMinimumSize()
        let height = isComparison && visibility.showsPlaylist
            ? compareFittingHeight(width: TakesWindowPolicy.defaultWidth)
            : visibility.showsPlaylist ? TakesWindowPolicy.defaultSize(for: visibility).height
                : compactHeight(width: TakesWindowPolicy.defaultWidth)
        let frame = TakesWindowPolicy.frameResettingSize(
            currentFrame: mainWindow.frame, height: height, visibleFrame: TakesWindowPolicy.visibleFrame(for: mainWindow)
        )
        if frame != mainWindow.frame { mainWindow.setFrame(frame, display: true, animate: !reduceMotion) }
        if !isComparison { storePlaylistHeight() }
    }

    /// At launch the autosaved frame is whichever mode was on screen at
    /// quit; give the restored mode its height.
    private func restoreModeHeight() {
        updateWindowMinimumSize()
        guard !usesTemporaryDefaultWindowLayout else { return }
        applyModeHeight(animate: false)
    }

    private func applyModeHeight(useDefaultPlaylistHeight: Bool = false, animate: Bool = true) {
        guard let mainWindow, artworkResize == nil, !mainWindow.styleMask.contains(.fullScreen) else { return }
        let width = mainWindow.frame.width
        let height: CGFloat
        if !visibility.showsPlaylist {
            height = compactHeight(width: width)
        } else if isComparison {
            height = compareFittingHeight(width: width)
        } else {
            let defaultHeight = useDefaultPlaylistHeight ? TakesWindowPolicy.defaultHeight(showsArtwork: false) : nil
            guard let stored = TakesWindowPolicy.storedPlaylistHeight() ?? defaultHeight else { return }
            height = TakesWindowPolicy.playlistHeight(restoring: stored, coverWidth: visibility.showsArtwork ? width : 0)
                - playerHeightReduction
        }
        if let frame = frameSettingHeight(height, for: mainWindow) {
            mainWindow.setFrame(frame, display: true, animate: animate && !reduceMotion)
        }
    }

    private func compactHeight(width: CGFloat) -> CGFloat {
        heightBelowArtwork + (visibility.showsArtwork ? width : 0)
    }

    private var playerHeightReduction: CGFloat {
        visibility.showsPlayer ? 0
            : TakesWindowPolicy.playerHeightWithoutDivider(showsArtwork: visibility.showsArtwork, isComparison: isComparison)
    }

    private func compareFittingHeight(width: CGFloat) -> CGFloat {
        TakesWindowPolicy.compareFittingHeight(
            laneCount: contentFitKey.trackCount, showsArtwork: visibility.showsArtwork, width: width
        ) - playerHeightReduction
    }

    private func frameSettingHeight(_ height: CGFloat, for window: NSWindow) -> CGRect? {
        TakesWindowPolicy.frameSettingHeight(
            height, minimum: windowMinimumSize.height,
            currentFrame: window.frame, visibleFrame: TakesWindowPolicy.visibleFrame(for: window)
        )
    }

    // MARK: Fitting the window to its tracks

    /// What `TakesWindowPolicy.frameFittingContent` follows: the playlist's
    /// tracks, or the compared item's versions (its lanes).
    private struct ContentFitKey: Equatable {
        var mode: PlaylistCoordinator.Mode
        var trackCount: Int
    }

    private var contentFitKey: ContentFitKey {
        let workspace = coordinator.workspace
        if let itemID = coordinator.mode.itemID {
            let count = workspace.items.first(where: { $0.id == itemID })?.versions.count ?? 0
            return ContentFitKey(mode: coordinator.mode, trackCount: count)
        }
        return ContentFitKey(mode: .playlist, trackCount: workspace.allVersions.count)
    }

    /// Adds and removes resize the window as in v2.9.0; mode switches,
    /// restoration and the artwork toggle's resize don't. The fit waits a
    /// moment so an import's selection and expansion (`WorkspaceImports`)
    /// land first, and a run of changes resizes once.
    private func scheduleContentFit(from old: ContentFitKey, to new: ContentFitKey) {
        guard old.mode == new.mode else {
            contentFitTask?.cancel()
            contentFitBaseline = nil
            return
        }
        guard old.trackCount != new.trackCount, persistence.restorationComplete else { return }
        if contentFitBaseline == nil { contentFitBaseline = old.trackCount }
        contentFitTask?.cancel()
        contentFitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            let previous = contentFitBaseline
            contentFitBaseline = nil
            guard let previous, contentFitKey.mode == new.mode else { return }
            fitWindowToContent(previousTrackCount: previous)
        }
    }

    private func fitWindowToContent(previousTrackCount: Int) {
        guard visibility.showsPlaylist, let mainWindow, artworkResize == nil,
              !mainWindow.styleMask.contains(.fullScreen) else { return }
        let fittingHeight: CGFloat
        if isComparison {
            fittingHeight = compareFittingHeight(width: mainWindow.frame.width)
        } else {
            let rows = presentation.visibleRows(in: coordinator.workspace)
            let itemRows = rows.filter { if case .item = $0 { return true }; return false }.count
            let width = mainWindow.frame.width
            let height = TakesWindowPolicy.playlistFittingHeight(
                itemRows: itemRows, versionRows: rows.count - itemRows, showsArtwork: visibility.showsArtwork, width: width
            ) - playerHeightReduction
            fittingHeight = max(height, heightBelowArtwork + (visibility.showsArtwork ? width : 0))
        }
        guard let frame = TakesWindowPolicy.frameFittingContent(
            previousTrackCount: previousTrackCount,
            newTrackCount: contentFitKey.trackCount,
            fittingHeight: fittingHeight,
            currentFrame: mainWindow.frame,
            visibleFrame: TakesWindowPolicy.visibleFrame(for: mainWindow)
        ) else { return }
        mainWindow.setFrame(frame, display: true, animate: !reduceMotion)
        storePlaylistHeight()
    }

    private struct CoverState: Equatable {
        var versionID: PlaylistVersion.ID?
        var isResolved: Bool
    }

    private var coverState: CoverState {
        let id = coverVersion?.id
        return CoverState(versionID: id, isResolved: artworkStore.hasResolvedArtwork(for: id))
    }

    private func setupKeyboard() {
        let monitor = KeyMonitor { event in
            guard let mainWindow, event.window === mainWindow else { return false }
            // Read the focus at the key press. The notification-driven flag
            // can go stale when a field is torn down mid-edit (a lane's
            // offset field when compare closes), which used to block every
            // global shortcut, Space included, until relaunch.
            let isEditingText = !GlobalShortcutFocusPolicy.shouldHandleGlobalShortcut(firstResponder: mainWindow.firstResponder)
            if textInputIsFocused != isEditingText { textInputIsFocused = isEditingText }
            guard !isEditingText, shortcutsAreAvailable else { return false }
            let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
            if isComparison {
                // Esc leaves compare, like the readout's back button (§9).
                if event.keyCode == 53 && flags.isEmpty {
                    guard visibility.showsPlaylist else { return false }
                    Task { await coordinator.backToPlaylist() }; return true
                }
                if let key = TrackNumberHotkey.hotkey(forKeyCode: event.keyCode, modifierFlags: flags), controller.canSelectTrackForHotkey(key) {
                    controller.selectTrackForHotkey(key); return true
                }
                if let direction = TrackSwitchArrowHotkey.direction(forKeyCode: event.keyCode, modifierFlags: flags), controller.session.canSwitchPlayback {
                    if direction == .previous { coordinator.previous() } else { coordinator.next() }; return true
                }
            } else if event.keyCode == 53 && flags.isEmpty && !presentation.selection.isEmpty {
                // Esc clears the playlist selection (⌘D is compare's Deselect).
                presentation.selection = []; return true
            }
            switch event.keyCode {
            case 49 where flags.isEmpty:
                coordinator.togglePlayback(); return true
            case 7 where isComparison && (flags.isEmpty || flags == .shift):
                // Switch Track; the playlist uses ⌘← / ⌘→ instead.
                if flags == .shift { coordinator.previous() } else { coordinator.next() }; return true
            case 123, 124:
                let forward = event.keyCode == 124
                if flags == .command {
                    // Compare jumps to the ends of the timeline; the playlist
                    // goes to the previous or next track.
                    if isComparison {
                        coordinator.seek(to: forward ? controller.session.timelineEnd : controller.session.timelineStart)
                    } else if forward ? coordinator.canNext : coordinator.canPrevious {
                        if forward { coordinator.next() } else { coordinator.previous() }
                    }
                    return true
                }
                // Compare skips on the plain arrows; the playlist's arrows
                // move through the list, so it skips with ⌥.
                let skipFlags: NSEvent.ModifierFlags = isComparison ? [] : [.option]
                guard flags == skipFlags || flags == skipFlags.union(.shift) else { return false }
                coordinator.skip(by: (forward ? 1 : -1) * (flags.contains(.shift) ? 10 : 1)); return true
            default: return false
            }
        }
        monitor.start()
        keyMonitor = monitor
    }
}

/// Common handoff for the picker, drops, and app-open commands after they
/// resolve their source into URLs and capture a destination.
@MainActor
private struct WorkspaceImports {
    let coordinator: PlaylistCoordinator
    let presentation: PlaylistPresentationState

    @discardableResult
    func submit(
        _ urls: [URL],
        destination: PlaylistImportDestination,
        isWorkspaceOwned: Bool = false,
        undoManager: UndoManager? = nil,
        selectResults: Bool = true
    ) async -> [PlaylistItem.ID] {
        let itemIDs = await coordinator.importFiles(
            urls, destination: destination, isWorkspaceOwned: isWorkspaceOwned,
            automaticGroupingMode: AppSettings.shared.automaticGroupingMode,
            undoManager: undoManager ?? NSApp.mainWindow?.undoManager
        )
        if selectResults { select(itemIDs) }
        return itemIDs
    }

    func select(_ itemIDs: [PlaylistItem.ID]) {
        guard !itemIDs.isEmpty else { return }
        presentation.selection = Set(itemIDs.map(PlaylistRowID.item))
        presentation.expanded.formUnion(itemIDs)
    }
}

/// Playlist control bar (spec §5): Shuffle · Previous · Play · Next ·
/// Repeat over the two-line readout.
private struct PlaylistTransportView: View {
    let coordinator: PlaylistCoordinator
    @EnvironmentObject private var settings: AppSettings
    private var controller: PlaybackController { coordinator.controller }

    var body: some View {
        ControlBarLayout {
            Button { coordinator.toggleShuffle() } label: { Image(systemName: "shuffle") }
                .buttonStyle(ControlBarSideButtonStyle(isOn: coordinator.workspace.isShuffleEnabled))
                .help("Shuffle")
                .accessibilityLabel("Shuffle").accessibilityValue(coordinator.workspace.isShuffleEnabled ? "On" : "Off")
                .componentDebugLabel("Shuffle", enabled: showsLabels)
        } center: {
            BasicTransportButtons(coordinator: coordinator)
        } trailing: {
            Button { coordinator.cyclePlaylistRepeatMode() } label: {
                Image(systemName: coordinator.workspace.playlistRepeatMode == .one ? "repeat.1" : "repeat")
            }
            .buttonStyle(ControlBarSideButtonStyle(isOn: coordinator.workspace.playlistRepeatMode != .off))
            .help("Repeat")
            .accessibilityLabel("Repeat").accessibilityValue(coordinator.workspace.playlistRepeatMode.rawValue.capitalized)
            .componentDebugLabel("Repeat", enabled: showsLabels)
        } readout: {
            PlaylistControlBarReadout(
                controller: controller,
                title: ControlBarReadoutTitle.playlist(currentVersion),
                seek: coordinator.seek
            )
            .componentDebugLabel("Readout", enabled: showsLabels, color: .orange)
        }
        .componentDebugLabel("Control Bar", enabled: showsLabels)
    }

    private var showsLabels: Bool { settings.showsComponentDebugLabels }

    /// The version the transport is showing: the current one, else the
    /// item's key version (same fallback the coordinator uses).
    private var currentVersion: PlaylistVersion? {
        guard let item = coordinator.workspace.items.first(where: { $0.id == coordinator.currentItemID }) else { return nil }
        return item.versions.first { $0.id == coordinator.currentVersionID } ?? item.keyVersion
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

/// Which version's artwork the cover shows (A2 §13).
enum CoverVersionRule {
    /// Playlist: the playing (or current) version, as the readout shows.
    static func playlist(item: PlaylistItem, currentVersionID: PlaylistVersion.ID?) -> PlaylistVersion? {
        item.versions.first(where: { $0.id == currentVersionID }) ?? item.keyVersion
    }

    /// Compare: the audible version, so Switch Track swaps the cover. Blind
    /// Listening Mode keeps the item's key version up instead, so the
    /// cover can't reveal which version is audible.
    static func comparison(item: PlaylistItem, audibleVersionID: PlaylistVersion.ID?, isBlind: Bool) -> PlaylistVersion? {
        guard !isBlind, let audible = item.versions.first(where: { $0.id == audibleVersionID }) else {
            return item.keyVersion
        }
        return audible
    }
}
