import AppKit
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

enum TakesWindowPolicy {
    static let mainWindowID = "main"
    static let replacesDefaultNewItemCommands = true
    static let mainWindowFrameAutosaveName = "NSWindow Frame \(mainWindowID)"
    static let minimumContentWidth: CGFloat = 500
    static let defaultWindowWidth: CGFloat = 700
    static let trackRowHeight: CGFloat = 124
    static let trackTimelineDividerHeight: CGFloat = 1
    static let trackTimelineHeaderHeight: CGFloat = 34
    static let contentPadding: CGFloat = 20
    static let rootVerticalSpacing: CGFloat = 14
    static let timelineHeaderSpacing: CGFloat = 8
    static let transportBarReservedHeight: CGFloat = 54
    static let zoomBarReservedHeight: CGFloat = 30
    static let minimumContentHeight = contentHeight(displayingTrackRows: 1)
    static let defaultContentHeight = contentHeight(displayingTrackRows: 1)
    static let windowChromeHeight: CGFloat = 28
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
            + rootVerticalSpacing
            + zoomBarReservedHeight
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
                    appDelegate.fileOpenRouter.setHandler { urls in
                        Task { await controller.loadImportedFiles(urls) }
                    }
                }
        }
        .defaultSize(
            width: TakesWindowPolicy.defaultWindowWidth,
            height: TakesWindowPolicy.defaultWindowHeight
        )
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
            }

            FileCommands()

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
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(updater)
        }
    }
}

private struct FileCommands: Commands {
    @FocusedValue(\.openFileCommandState) private var openFileCommandState
    @FocusedValue(\.canShowActiveTrackInFinder) private var canShowActiveTrackInFinder
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

            Button("Clear All Tracks") {
                openFileCommandState?.clearAllTracks()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(openFileCommandState == nil || canClearTracks != true)
        }
    }
}
