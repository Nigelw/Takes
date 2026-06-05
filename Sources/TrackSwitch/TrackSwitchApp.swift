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

enum TrackSwitchWindowPolicy {
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
    static let minimumContentHeight = contentHeight(displayingTrackRows: 1)
    static let defaultContentHeight = contentHeight(displayingTrackRows: 2)
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
    }

    static func clearSavedMainWindowFrame(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: mainWindowFrameAutosaveName)
    }

    @MainActor
    static func configureMainWindow(_ window: NSWindow) {
        window.setFrameAutosaveName("")
        window.minSize = minimumWindowSize

        let frame = window.frame
        let defaultFrame = CGRect(
            x: frame.minX,
            y: frame.maxY - defaultWindowSize.height,
            width: defaultWindowSize.width,
            height: defaultWindowSize.height
        )
        window.setFrame(defaultFrame, display: true)
    }
}

@main
struct TrackSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = PlaybackController()

    init() {
        TrackSwitchWindowPolicy.clearSavedMainWindowFrame()
    }

    var body: some Scene {
        Window("TrackSwitch", id: TrackSwitchWindowPolicy.mainWindowID) {
            ContentView(controller: controller)
                .onAppear {
                    appDelegate.fileOpenRouter.setHandler { urls in
                        Task { await controller.loadImportedFiles(urls) }
                    }
                }
        }
        .defaultSize(
            width: TrackSwitchWindowPolicy.defaultWindowWidth,
            height: TrackSwitchWindowPolicy.defaultWindowHeight
        )
        .windowResizability(.contentMinSize)
        .commands {
            FileCommands()

            CommandMenu("Playback") {
                Button(controller.session.isPlaying ? "Pause" : "Play") {
                    controller.session.isPlaying ? controller.pause() : controller.play()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!controller.session.isPlayable)

                Button("Rewind") {
                    controller.seek(to: controller.session.timelineStart)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .disabled(!controller.session.isPlayable)

                Divider()

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
            }
        }
    }
}

private struct FileCommands: Commands {
    @FocusedValue(\.openFileCommandState) private var openFileCommandState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") {
                openFileCommandState?.presentOpenDialog()
            }
            .keyboardShortcut("o")
            .disabled(openFileCommandState == nil)

            Button(ImportActionMenuItem.musicSelection.title) {
                openFileCommandState?.openAppleMusicSelection()
            }
            .keyboardShortcut("m", modifiers: [.shift, .command])
            .disabled(openFileCommandState == nil)
        }
    }
}
