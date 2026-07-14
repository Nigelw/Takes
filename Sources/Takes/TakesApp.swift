import AppKit
import MediaPlayer
import SwiftUI
import UniformTypeIdentifiers

enum AppOpenedURLResolver {
    static func audioFileURLs(from urls: [URL], fileManager: FileManager = .default) -> [URL] {
        let inputURLs = urls.flatMap { url in
            automationFileURLs(from: url) ?? [url]
        }

        return inputURLs.flatMap { url in
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

    static func streamingURLStrings(from urls: [URL]) -> [String] {
        urls.compactMap(streamingURLString)
    }

    static func streamingURLString(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "takes",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let command = automationCommand(from: components),
              command == "open-url",
              let value = components.queryItems?.first(where: { $0.name == "url" })?.value?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              URL(string: value)?.scheme != nil
        else {
            return nil
        }
        return value
    }

    static func automationFileURLs(from url: URL) -> [URL]? {
        guard url.scheme?.lowercased() == "takes",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let command = automationCommand(from: components),
              command == "open-file"
        else {
            return nil
        }

        let fileURLs = components.queryItems?
            .filter { $0.name == "url" }
            .compactMap(\.value)
            .compactMap { URL(string: $0) }
            .filter { $0.isFileURL } ?? []

        return fileURLs.isEmpty ? nil : fileURLs
    }

    private static func automationCommand(from components: URLComponents) -> String? {
        if let host = components.host?.lowercased(), !host.isEmpty {
            return host
        }

        return components.path
            .split(separator: "/")
            .first
            .map { String($0).lowercased() }
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
    typealias AudioFileHandler = @MainActor ([URL]) -> Void
    typealias StreamingURLHandler = @MainActor ([String]) -> Void

    private var audioFileHandler: AudioFileHandler?
    private var streamingURLHandler: StreamingURLHandler?
    private var pendingURLBatches: [[URL]] = []
    private var pendingStreamingURLBatches: [[String]] = []

    func setHandler(_ handler: @escaping AudioFileHandler) {
        audioFileHandler = handler

        let pendingURLBatches = self.pendingURLBatches
        self.pendingURLBatches.removeAll()
        pendingURLBatches.forEach(handler)
    }

    func setStreamingURLHandler(_ handler: @escaping StreamingURLHandler) {
        streamingURLHandler = handler

        let pendingStreamingURLBatches = self.pendingStreamingURLBatches
        self.pendingStreamingURLBatches.removeAll()
        pendingStreamingURLBatches.forEach(handler)
    }

    func open(_ urls: [URL]) {
        let audioFileURLs = AppOpenedURLResolver.audioFileURLs(from: urls)
        if !audioFileURLs.isEmpty {
            if let audioFileHandler {
                audioFileHandler(audioFileURLs)
            } else {
                pendingURLBatches.append(audioFileURLs)
            }
        }

        let streamingURLStrings = AppOpenedURLResolver.streamingURLStrings(from: urls)
        guard !streamingURLStrings.isEmpty else { return }
        if let streamingURLHandler {
            streamingURLHandler(streamingURLStrings)
        } else {
            pendingStreamingURLBatches.append(streamingURLStrings)
        }
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

enum TakesAboutPanel {
    static let creditsText = """
    Lead designer & developer
    Nigel M. Warren: https://nigelwarren.com

    Third-Party Resources
    Sparkle: https://sparkle-project.org
    yt-dlp: https://github.com/yt-dlp/yt-dlp
    Tabler Icons: https://tabler.io
    """

    private static let creditLinks: [(label: String, destination: String)] = [
        ("https://nigelwarren.com", "https://nigelwarren.com"),
        ("https://sparkle-project.org", "https://sparkle-project.org"),
        ("https://github.com/yt-dlp/yt-dlp", "https://github.com/yt-dlp/yt-dlp"),
        ("https://tabler.io", "https://tabler.io")
    ]

    static var options: [NSApplication.AboutPanelOptionKey: Any] {
        [.credits: credits]
    }

    static var credits: NSAttributedString {
        let credits = NSMutableAttributedString(string: creditsText)
        let fullRange = NSRange(location: 0, length: credits.length)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.paragraphSpacing = 6

        credits.addAttributes([
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle
        ], range: fullRange)

        for (label, destination) in creditLinks {
            guard let range = credits.string.range(of: label),
                  let url = URL(string: destination)
            else { continue }

            credits.addAttributes([
                .link: url,
                .foregroundColor: NSColor.linkColor
            ], range: NSRange(range, in: credits.string))
        }

        return credits
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
        refreshRemoteState()
    }

    /// Push the current transport snapshot to the system, re-arming
    /// observation so the next transport change (play/pause/seek/track
    /// switch/loop wrap) pushes again. The snapshot deliberately has no
    /// dependency on per-tick state, so this does not run during steady
    /// playback — the system extrapolates position from elapsed + rate.
    private func refreshRemoteState() {
        guard let controller else { return }
        let snapshot = withObservationTracking {
            controller.remotePlaybackSnapshot()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshRemoteState()
            }
        }
        updateRemoteState(with: snapshot)
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

    private func updateRemoteState(with snapshot: PlaybackController.RemotePlaybackSnapshot) {
        commandCenter.playCommand.isEnabled = snapshot.isPlayable && !snapshot.isPlaying
        commandCenter.pauseCommand.isEnabled = snapshot.isPlayable && snapshot.isPlaying
        commandCenter.togglePlayPauseCommand.isEnabled = snapshot.isPlayable
        commandCenter.nextTrackCommand.isEnabled = snapshot.canSwitchPlayback
        commandCenter.previousTrackCommand.isEnabled = snapshot.canSwitchPlayback

        if snapshot.isPlayable {
            nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo(for: snapshot)
            nowPlayingInfoCenter.playbackState = snapshot.isPlaying ? .playing : .paused
        } else {
            nowPlayingInfoCenter.nowPlayingInfo = nil
            nowPlayingInfoCenter.playbackState = .stopped
        }
    }

    private func nowPlayingInfo(for snapshot: PlaybackController.RemotePlaybackSnapshot) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPMediaItemPropertyPlaybackDuration: snapshot.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]

        if let trackNumber = snapshot.trackNumber {
            info[MPMediaItemPropertyAlbumTrackNumber] = trackNumber
            info[MPMediaItemPropertyAlbumTrackCount] = snapshot.trackCount
        }

        return info
    }
}

enum TakesWindowPolicy {
    static let mainWindowID = "main"
    static let analysisWindowID = "analysis"
    static let replacesDefaultNewItemCommands = true
    static let mainWindowFrameAutosaveName = "NSWindow Frame \(mainWindowID)"
    static let minimumContentWidth: CGFloat = 640
    static let defaultWindowWidth: CGFloat = 700
    static let trackInfoColumnWidthKey = "trackInfoColumnWidth"
    static let defaultTrackInfoColumnWidth: CGFloat = 240
    static let minimumTrackInfoColumnWidth: CGFloat = defaultTrackInfoColumnWidth - 10
    static let minimumWaveformColumnWidth: CGFloat = 240
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

    static func clampedTrackInfoColumnWidth(_ width: CGFloat, sectionWidth: CGFloat) -> CGFloat {
        let maximumWidth = max(minimumTrackInfoColumnWidth, sectionWidth - minimumWaveformColumnWidth)
        return min(max(width, minimumTrackInfoColumnWidth), maximumWidth)
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

    static func frameResettingHeight(currentFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        let height = min(defaultWindowHeight, max(currentFrame.maxY - visibleFrame.minY, 0))
        return CGRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - height,
            width: currentFrame.width,
            height: height
        )
    }

    static func frameResettingSize(currentFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        let height = min(defaultWindowHeight, max(currentFrame.maxY - visibleFrame.minY, 0))
        return CGRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - height,
            width: defaultWindowWidth,
            height: height
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

    static func hasSavedMainWindowFrame(defaults: UserDefaults = .standard) -> Bool {
        hasSavedMainWindowFrame(objectForKey: defaults.object(forKey:))
    }

    static func hasSavedMainWindowFrame(objectForKey: (String) -> Any?) -> Bool {
        objectForKey(mainWindowFrameAutosaveName) != nil
    }

    @MainActor
    static func configureMainWindow(
        _ window: NSWindow,
        defaults: UserDefaults = .standard,
        resetsLayoutForLaunch: Bool = false
    ) {
        let hasSavedFrame = hasSavedMainWindowFrame(defaults: defaults)
        window.minSize = minimumWindowSize

        // Unify the titlebar with the transport bar: let content draw up
        // behind a transparent titlebar so the top bar reads as one surface,
        // with only the traffic lights floating over it.
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false

        guard !resetsLayoutForLaunch else {
            resetMainWindowSize(window, animate: false)
            return
        }

        window.setFrameAutosaveName(mainWindowID)
        if !hasSavedFrame {
            let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
            window.setFrame(defaultFrame(visibleFrame: visibleFrame), display: true)
        } else {
            resetMainWindowHeight(window, animate: false)
        }
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

    @MainActor
    static func resetMainWindowHeight(_ window: NSWindow, animate: Bool) {
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let resetFrame = frameResettingHeight(currentFrame: window.frame, visibleFrame: visibleFrame)
        guard abs(resetFrame.height - window.frame.height) > 0.5 else { return }
        window.setFrame(resetFrame, display: true, animate: animate)
    }

    @MainActor
    static func resetMainWindowSize(_ window: NSWindow, animate: Bool = true) {
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let resetFrame = frameResettingSize(currentFrame: window.frame, visibleFrame: visibleFrame)
        guard resetFrame != window.frame else { return }
        window.setFrame(resetFrame, display: true, animate: animate)
    }
}

struct TakesLaunchOptions {
    static let defaultWindowLayoutArgument = "--default-window-layout"

    var usesDefaultWindowLayout = false

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        usesDefaultWindowLayout = arguments.contains(Self.defaultWindowLayoutArgument)
    }
}

@main
struct TakesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller = PlaybackController()
    @StateObject private var remotePlaybackCommands = RemotePlaybackCommandController()
    @StateObject private var settings = AppSettings()
    @StateObject private var updater = SoftwareUpdater()
    @StateObject private var ytdlpUpdates = YTDLPUpdateState()
    @StateObject private var zoomHaptics = ZoomHapticsController()
    private let launchOptions = TakesLaunchOptions()
    private let appearanceTunerPanel = AppearanceTunerPanelController()
    private let analysisWindowController = AnalysisWindowController()

    var body: some Scene {
        Window("Takes", id: TakesWindowPolicy.mainWindowID) {
            ContentView(
                controller: controller,
                appFileOpenRouter: appDelegate.fileOpenRouter,
                usesTemporaryDefaultWindowLayout: launchOptions.usesDefaultWindowLayout
            )
                .environmentObject(settings)
                .environmentObject(updater)
                .environmentObject(zoomHaptics)
                .onAppear {
                    controller.settings = settings
                    remotePlaybackCommands.connect(to: controller)
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
            CommandGroup(replacing: .appInfo) {
                Button("About Takes") {
                    NSApp.orderFrontStandardAboutPanel(options: TakesAboutPanel.options)
                }

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
                Link("Visit Website", destination: URL(string: "https://takes.nigelwarren.com")!)
                Link("Release Notes", destination: URL(string: "https://takes.nigelwarren.com/changelog.html")!)

                Divider()

                Menu("Debug") {
                    Toggle("Show Component Names", isOn: $settings.showsComponentDebugLabels)
                    ResetMainWindowSizeButton()
                    OpenAppearanceTunerButton(panel: appearanceTunerPanel, settings: settings)
                    OpenAnalysisWindowButton(controller: analysisWindowController)
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(updater)
                .environmentObject(ytdlpUpdates)
        }
        .windowResizability(.contentSize)
    }
}

/// Opens the Appearance Tuner from the Debug menu as a floating palette that
/// stays above the main window without stealing key focus, so slider tweaks
/// update the transport controls live in the window behind it.
private struct OpenAppearanceTunerButton: View {
    let panel: AppearanceTunerPanelController
    let settings: AppSettings

    var body: some View {
        Button("Appearance Tuner") {
            panel.show(settings: settings)
        }
    }
}

/// Hosts the Appearance Tuner in a non-activating utility `NSPanel`. A panel
/// (rather than a SwiftUI `Window` scene) gives us a floating palette that
/// never becomes the key window on its own — so adjusting a slider leaves the
/// main window key and the transport buttons visibly updating behind it — and
/// keeps the tuner out of the standard Window menu.
///
/// The panel is attached as a *child* of the main window rather than raised to
/// the global floating level, so it hovers above the Takes window only and
/// drops behind other apps normally instead of floating over everything.
@MainActor
final class AppearanceTunerPanelController {
    private var panel: NSPanel?

    func show(settings: AppSettings) {
        if let panel {
            reparent(panel)
            panel.orderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: AppearanceTunerView(settings: settings))
        let panel = NSPanel(contentViewController: hosting)
        panel.title = "Appearance Tuner"
        panel.styleMask = [.titled, .closable, .utilityWindow, .nonactivatingPanel]
        // Takes key only when a control that needs text entry is focused, so it
        // never steals focus from the main window by itself.
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        // We hold the only strong reference; closing just orders it out so it
        // can be reopened without reconstructing the view.
        panel.isReleasedWhenClosed = false
        panel.setContentSize(NSSize(width: 320, height: 680))
        panel.setFrameAutosaveName("AppearanceTunerPanel")
        panel.center()
        self.panel = panel
        reparent(panel)
        panel.orderFront(nil)
    }

    /// Attach the panel above the current main window so it tracks that window's
    /// stacking (above it, hidden with it) instead of floating over every app.
    private func reparent(_ panel: NSPanel) {
        let parent = NSApp.mainWindow ?? NSApp.windows.first { $0 !== panel && $0.isVisible }
        guard let parent, parent !== panel else { return }
        panel.parent?.removeChildWindow(panel)
        parent.addChildWindow(panel, ordered: .above)
    }
}

/// Hosts the experimental Analysis tool outside SwiftUI's `Window` scene list
/// so it remains reachable only from Help > Debug instead of Window > Analysis.
@MainActor
final class AnalysisWindowController {
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: AnalysisWindowView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Analysis"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isExcludedFromWindowsMenu = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 760, height: 640))
        window.setFrameAutosaveName(TakesWindowPolicy.analysisWindowID)
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Opens the experimental single-file Analysis window from the Debug menu.
private struct OpenAnalysisWindowButton: View {
    let controller: AnalysisWindowController

    var body: some View {
        Button("Analysis") {
            controller.show()
        }
        .keyboardShortcut("l", modifiers: [.command])
    }
}

private struct ResetMainWindowSizeButton: View {
    @FocusedValue(\.mainWindowCommandState) private var mainWindowCommandState

    var body: some View {
        Button("Reset Window Size") {
            mainWindowCommandState?.resetWindowSizing()
        }
        .disabled(mainWindowCommandState == nil)
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

            Button(ImportActionMenuItem.streamingURL.title) {
                openFileCommandState?.presentStreamingURLPrompt()
            }
            .keyboardShortcut("o", modifiers: [.shift, .command])
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
    var controller: PlaybackController
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
