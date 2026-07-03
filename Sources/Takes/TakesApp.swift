import AppKit
import Combine
import MediaPlayer
import SwiftUI
import UniformTypeIdentifiers

enum AppOpenedURLResolver {
    static func audioFileURLs(from urls: [URL], fileManager: FileManager = .default) -> [URL] {
        urls.flatMap { url in
            if isDirectory(url, fileManager: fileManager) {
                return audioFileURLs(in: url, fileManager: fileManager)
            }
            return isAudioFile(url) ? [url] : []
        }
    }

    private static func audioFileURLs(in directoryURL: URL, fileManager: FileManager) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return []
        }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { isRegularFile($0, fileManager: fileManager) && isAudioFile($0) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func isAudioFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio)
    }
}

@MainActor
final class AppFileOpenRouter {
    typealias Handler = @MainActor ([URL]) -> Void

    private var handler: Handler?
    private var pendingURLBatches: [[URL]] = []

    func setHandler(_ handler: @escaping Handler) {
        self.handler = handler

        let pendingURLBatches = self.pendingURLBatches
        self.pendingURLBatches.removeAll()
        pendingURLBatches.forEach(handler)
    }

    func open(_ urls: [URL]) {
        let audioFileURLs = AppOpenedURLResolver.audioFileURLs(from: urls)
        guard !audioFileURLs.isEmpty else { return }

        guard let handler else {
            pendingURLBatches.append(audioFileURLs)
            return
        }

        handler(audioFileURLs)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let fileOpenRouter = AppFileOpenRouter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        fileOpenRouter.open(urls)
    }
}

@MainActor
final class RemotePlaybackCommandController: ObservableObject {
    private struct CommandTarget {
        let command: MPRemoteCommand
        let target: Any
    }

    private weak var controller: PlaybackController?
    private let commandCenter: MPRemoteCommandCenter
    private let nowPlayingInfoCenter: MPNowPlayingInfoCenter
    private var commandTargets: [CommandTarget] = []
    private var sessionCancellable: AnyCancellable?

    init(
        commandCenter: MPRemoteCommandCenter = .shared(),
        nowPlayingInfoCenter: MPNowPlayingInfoCenter = .default()
    ) {
        self.commandCenter = commandCenter
        self.nowPlayingInfoCenter = nowPlayingInfoCenter
    }

    func connect(to controller: PlaybackController) {
        guard self.controller == nil else { return }
        self.controller = controller
        configureCommands()
        sessionCancellable = controller.$session.sink { [weak self] session in
            self?.updateRemoteState(for: session)
        }
        updateRemoteState(for: controller.session)
    }

    private func configureCommands() {
        addHandler(to: commandCenter.playCommand) { [weak self] in
            guard let controller = self?.controller, controller.session.isPlayable else { return }
            controller.play()
        }
        addHandler(to: commandCenter.pauseCommand) { [weak self] in
            guard let controller = self?.controller, controller.session.isPlaying else { return }
            controller.pause()
        }
        addHandler(to: commandCenter.togglePlayPauseCommand) { [weak self] in
            guard let controller = self?.controller, controller.session.isPlayable else { return }
            controller.session.isPlaying ? controller.pause() : controller.play()
        }
        addHandler(to: commandCenter.nextTrackCommand) { [weak self] in
            guard let controller = self?.controller, controller.session.canSwitchPlayback else { return }
            controller.selectNextTrack()
        }
        addHandler(to: commandCenter.previousTrackCommand) { [weak self] in
            guard let controller = self?.controller, controller.session.canSwitchPlayback else { return }
            controller.selectPreviousTrack()
        }
    }

    private func addHandler(to command: MPRemoteCommand, perform action: @escaping @MainActor () -> Void) {
        let target = command.addTarget { _ in
            Task { @MainActor in
                action()
            }
            return .success
        }
        commandTargets.append(CommandTarget(command: command, target: target))
    }

    private func updateRemoteState(for session: ComparisonSession) {
        commandCenter.playCommand.isEnabled = session.isPlayable && !session.isPlaying
        commandCenter.pauseCommand.isEnabled = session.isPlayable && session.isPlaying
        commandCenter.togglePlayPauseCommand.isEnabled = session.isPlayable
        commandCenter.nextTrackCommand.isEnabled = session.canSwitchPlayback
        commandCenter.previousTrackCommand.isEnabled = session.canSwitchPlayback

        if session.isPlayable {
            nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo(for: session)
            nowPlayingInfoCenter.playbackState = session.isPlaying ? .playing : .paused
        } else {
            nowPlayingInfoCenter.nowPlayingInfo = nil
            nowPlayingInfoCenter.playbackState = .stopped
        }
    }

    private func nowPlayingInfo(for session: ComparisonSession) -> [String: Any] {
        let title: String
        if session.isBlindListeningModeEnabled, let activeTrackIndex = session.activeTrackIndex {
            title = "Track \(activeTrackIndex + 1)"
        } else {
            title = session.activeTrack?.loadedTrack.displayName ?? "Takes"
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: session.playbackEnd - session.playbackStart,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: session.transportPosition - session.playbackStart,
            MPNowPlayingInfoPropertyPlaybackRate: session.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]

        if let activeTrackIndex = session.activeTrackIndex {
            info[MPMediaItemPropertyAlbumTrackNumber] = activeTrackIndex + 1
            info[MPMediaItemPropertyAlbumTrackCount] = session.tracks.count
        }

        return info
    }
}

enum TakesWindowPolicy {
    static let mainWindowID = "main"
    static let appearanceTunerWindowID = "appearance-tuner"
    static let replacesDefaultNewItemCommands = true
    static let mainWindowFrameAutosaveName = "NSWindow Frame \(mainWindowID)"
    static let minimumContentWidth: CGFloat = 640
    static let defaultWindowWidth: CGFloat = 700
    static let trackRowHeight: CGFloat = 96
    static let trackTimelineDividerHeight: CGFloat = 1
    static let trackTimelineHeaderHeight: CGFloat = 34
    static let contentPadding: CGFloat = 0
    static let rootVerticalSpacing: CGFloat = 1
    static let timelineHeaderSpacing: CGFloat = 1
    // Play button / readout (56) + vertical padding (20 top + 16 bottom,
    // optically shifted 2pt below true center).
    static let transportBarReservedHeight: CGFloat = 92
    static let minimumContentHeight = contentHeight(displayingTrackRows: 1)
    static let defaultContentHeight = contentHeight(displayingTrackRows: 1)
    // The root view ignores the top safe area, so the transport bar occupies
    // the hidden-titlebar region and the window adds no extra chrome height.
    static let windowChromeHeight: CGFloat = 0
    // The hidden titlebar still reports a top safe-area inset, and
    // NSHostingView adds that inset to the root view's declared minimum height
    // when it enforces the window's minimum size — even though the root view
    // ignores the inset and lays out under the titlebar. Declare the SwiftUI
    // minimum short by the inset so the enforced window minimum lands exactly
    // on `minimumContentHeight`.
    static let hiddenTitlebarSafeAreaInset: CGFloat = 28
    static let rootViewMinimumHeight = minimumContentHeight - hiddenTitlebarSafeAreaInset
    static let defaultWindowHeight = defaultContentHeight + windowChromeHeight
    static let minimumWindowSize = CGSize(
        width: minimumContentWidth,
        height: minimumContentHeight + windowChromeHeight
    )
    static let defaultWindowSize = CGSize(
        width: defaultWindowWidth,
        height: defaultWindowHeight
    )

    static func trackTimelineHeight(displayingTrackRows rowCount: Int) -> CGFloat {
        let rowCount = max(rowCount, 1)
        let dividerCount = max(rowCount - 1, 0)
        return trackRowHeight * CGFloat(rowCount) + trackTimelineDividerHeight * CGFloat(dividerCount)
    }

    static func contentHeight(displayingTrackRows rowCount: Int) -> CGFloat {
        contentPadding * 2
            + transportBarReservedHeight
            + rootVerticalSpacing
            + trackTimelineHeaderHeight
            + timelineHeaderSpacing
            + trackTimelineHeight(displayingTrackRows: rowCount)
    }

    static func windowHeight(displayingTrackRows rowCount: Int) -> CGFloat {
        contentHeight(displayingTrackRows: rowCount) + windowChromeHeight
    }

    static func frame(fittingTrackRows rowCount: Int, currentFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        let desiredHeight = windowHeight(displayingTrackRows: rowCount)
        let maximumHeightBeforeMonitorBottom = max(currentFrame.maxY - visibleFrame.minY, 0)
        let height = min(desiredHeight, maximumHeightBeforeMonitorBottom)

        return CGRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - height,
            width: currentFrame.width,
            height: height
        )
    }

    static func defaultFrame(visibleFrame: CGRect) -> CGRect {
        CGRect(
            x: visibleFrame.minX,
            y: visibleFrame.maxY - defaultWindowSize.height,
            width: defaultWindowSize.width,
            height: defaultWindowSize.height
        )
    }

    static func shouldAutoGrowWindow(
        previousTrackRowCount: Int,
        newTrackRowCount: Int,
        currentWindowHeight: CGFloat
    ) -> Bool {
        guard newTrackRowCount > previousTrackRowCount else { return false }

        let desiredHeight = windowHeight(displayingTrackRows: newTrackRowCount)
        return desiredHeight > currentWindowHeight + 0.5
    }

    static func shouldAutoShrinkWindow(
        previousTrackRowCount: Int,
        newTrackRowCount: Int,
        currentWindowHeight: CGFloat
    ) -> Bool {
        guard newTrackRowCount < previousTrackRowCount else { return false }

        let desiredHeight = windowHeight(displayingTrackRows: newTrackRowCount)
        return desiredHeight < currentWindowHeight - 0.5
    }

    static func clearSavedMainWindowFrame(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: mainWindowFrameAutosaveName)
    }

    @MainActor
    static func configureMainWindow(_ window: NSWindow) {
        window.setFrameAutosaveName("")
        window.minSize = minimumWindowSize

        // Unify the titlebar with the transport bar: let content draw up
        // behind a transparent titlebar so the top bar reads as one surface,
        // with only the traffic lights floating over it.
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false

        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        window.setFrame(defaultFrame(visibleFrame: visibleFrame), display: true)
    }

    @MainActor
    static func resizeMainWindow(_ window: NSWindow, displayingTrackRows rowCount: Int) {
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let resizedFrame = frame(
            fittingTrackRows: rowCount,
            currentFrame: window.frame,
            visibleFrame: visibleFrame
        )

        guard abs(resizedFrame.height - window.frame.height) > 0.5 else { return }
        window.setFrame(resizedFrame, display: true, animate: true)
    }
}

@main
struct TakesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = PlaybackController()
    @StateObject private var remotePlaybackCommands = RemotePlaybackCommandController()
    @StateObject private var settings = AppSettings()
    @StateObject private var updater = SoftwareUpdater()

    init() {
        TakesWindowPolicy.clearSavedMainWindowFrame()
    }

    var body: some Scene {
        Window("Takes", id: TakesWindowPolicy.mainWindowID) {
            ContentView(controller: controller)
                .environmentObject(settings)
                .environmentObject(updater)
                .onAppear {
                    remotePlaybackCommands.connect(to: controller)
                    appDelegate.fileOpenRouter.setHandler { urls in
                        Task { await controller.loadImportedFiles(urls) }
                    }
                }
        }
        .defaultSize(
            width: TakesWindowPolicy.defaultWindowWidth,
            height: TakesWindowPolicy.defaultWindowHeight
        )
        // Declared on the scene (not just patched onto the NSWindow later) so
        // SwiftUI sizes the hosting view full-height from creation, letting
        // the window background genuinely draw under the titlebar.
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
            }

            FileCommands()
            ViewCommands(controller: controller)

            CommandGroup(after: .pasteboard) {
                Button("Deselect") {
                    controller.deselectLoop()
                }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(controller.session.loopRegion == nil)
            }

            CommandMenu("Playback") {
                Button(controller.session.isPlaying ? "Pause" : "Play") {
                    controller.session.isPlaying ? controller.pause() : controller.play()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!controller.session.isPlayable)

                Button("Switch Track") {
                    controller.selectNextTrack()
                }
                .keyboardShortcut("x", modifiers: [])
                .disabled(!controller.session.canSwitchPlayback)

                Button("Switch to Previous Track") {
                    controller.selectPreviousTrack()
                }
                .keyboardShortcut("x", modifiers: [.shift])
                .disabled(!controller.session.canSwitchPlayback)

                Divider()

                Button("Auto-Align Tracks") {
                    controller.autoAlignTracks()
                }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(!controller.session.canSwitchPlayback || controller.isAligning)

                Menu("Repeat") {
                    Picker("Repeat", selection: Binding(
                        get: { controller.session.repeatMode },
                        set: { controller.setRepeatMode($0) }
                    )) {
                        Text("Off").tag(RepeatMode.off)
                        Text("One").tag(RepeatMode.one)
                        Text("Switch & Repeat").tag(RepeatMode.switchAndRepeat)
                    }
                    .pickerStyle(.inline)
                }
                .disabled(!controller.session.isPlayable)

                Divider()

                Button("Skip Forward 1s") {
                    controller.skip(by: 1)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!controller.session.isPlayable)

                Button("Skip Forward 10s") {
                    controller.skip(by: 10)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.shift])
                .disabled(!controller.session.isPlayable)

                Button("Skip Backward 1s") {
                    controller.skip(by: -1)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!controller.session.isPlayable)

                Button("Skip Backward 10s") {
                    controller.skip(by: -10)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.shift])
                .disabled(!controller.session.isPlayable)
                
                Divider()
                
                Button("Jump to Beginning") {
                    controller.seek(to: controller.session.timelineStart)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .disabled(!controller.session.isPlayable)

                Button("Jump to End") {
                    controller.seek(to: controller.session.timelineEnd)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .disabled(!controller.session.isPlayable)
            }

            CommandGroup(replacing: .help) {
                Link("Release Notes", destination: URL(string: "https://nigelw.github.io/Takes/changelog.html")!)

                Divider()

                Menu("Debug") {
                    Toggle("Show Component Names", isOn: $settings.showsComponentDebugLabels)
                    OpenAppearanceTunerButton()
                }
            }
        }

        Window("Appearance Tuner", id: TakesWindowPolicy.appearanceTunerWindowID) {
            AppearanceTunerView(settings: settings)
        }
        .defaultSize(width: 320, height: 680)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(updater)
        }
    }
}

/// Opens the standalone Appearance Tuner window from the Debug menu. A tiny
/// view (rather than an inline command button) so it can read `openWindow`.
private struct OpenAppearanceTunerButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Appearance Tuner") {
            openWindow(id: TakesWindowPolicy.appearanceTunerWindowID)
        }
    }
}

private struct FileCommands: Commands {
    @FocusedValue(\.openFileCommandState) private var openFileCommandState
    @FocusedValue(\.canShowActiveTrackInFinder) private var canShowActiveTrackInFinder
    @FocusedValue(\.canRemoveActiveTrack) private var canRemoveActiveTrack
    @FocusedValue(\.canUseGlobalMenuShortcuts) private var canUseGlobalMenuShortcuts
    @FocusedValue(\.canClearTracks) private var canClearTracks

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") {
                openFileCommandState?.presentOpenDialog()
            }
            .keyboardShortcut("o")
            .disabled(openFileCommandState == nil)

            Button(ImportActionMenuItem.finderSelection.title) {
                openFileCommandState?.openFinderSelection()
            }
            .keyboardShortcut("f", modifiers: [.shift, .command])
            .disabled(openFileCommandState == nil)

            Button(ImportActionMenuItem.musicSelection.title) {
                openFileCommandState?.openAppleMusicSelection()
            }
            .keyboardShortcut("m", modifiers: [.shift, .command])
            .disabled(openFileCommandState == nil)

            Divider()

            Button("Show in Finder") {
                openFileCommandState?.showActiveTrackInFinder()
            }
            .keyboardShortcut("r", modifiers: [.shift, .command])
            .disabled(openFileCommandState == nil || canShowActiveTrackInFinder != true)

            Divider()

            Button("Remove Track") {
                openFileCommandState?.removeActiveTrack()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(
                openFileCommandState == nil
                    || canRemoveActiveTrack != true
                    || canUseGlobalMenuShortcuts != true
            )

            Button("Remove All Tracks") {
                openFileCommandState?.clearAllTracks()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(openFileCommandState == nil || canClearTracks != true)
        }
    }
}

private struct ViewCommands: Commands {
    @ObservedObject var controller: PlaybackController
    @FocusedValue(\.canUseGlobalMenuShortcuts) private var canUseGlobalMenuShortcuts

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Toggle(
                "Blind Listening Mode",
                isOn: Binding(
                    get: { controller.session.isBlindListeningModeEnabled },
                    set: { controller.setBlindListeningMode($0) }
                )
            )
            .keyboardShortcut("b", modifiers: [.command])

            Divider()
        }

        CommandGroup(after: .toolbar) {
            Button("Zoom In") {
                controller.stepZoom(zoomingIn: true)
            }
            .keyboardShortcut("+", modifiers: [.command])
            .disabled(!canUseZoomShortcuts || !controller.canZoomTimeline)

            Button("Zoom Out") {
                controller.stepZoom(zoomingIn: false)
            }
            .keyboardShortcut("-", modifiers: [.command])
            .disabled(!canUseZoomShortcuts || !controller.canZoomTimeline)

            Button("Zoom to Selection") {
                controller.zoomToSelection()
            }
            .keyboardShortcut("+", modifiers: [.command, .option])
            .disabled(
                !canUseZoomShortcuts
                    || !controller.canZoomTimeline
                    || controller.session.loopRegion == nil
            )

            Button("Zoom to Fit") {
                controller.zoomToFit()
            }
            .keyboardShortcut("-", modifiers: [.command, .option])
            .disabled(!canUseZoomShortcuts || !controller.canZoomTimeline)

            Divider()
        }
    }

    private var canUseZoomShortcuts: Bool {
        canUseGlobalMenuShortcuts == true
    }
}
