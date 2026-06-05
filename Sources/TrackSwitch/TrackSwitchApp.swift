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
}

@main
struct TrackSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = PlaybackController()

    var body: some Scene {
        Window("TrackSwitch", id: TrackSwitchWindowPolicy.mainWindowID) {
            ContentView(controller: controller)
                .onAppear {
                    appDelegate.fileOpenRouter.setHandler { urls in
                        Task { await controller.loadImportedFiles(urls) }
                    }
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            FileCommands()

            CommandMenu("Playback") {
                Button(controller.session.isPlaying ? "Pause" : "Play") {
                    controller.session.isPlaying ? controller.pause() : controller.play()
                }
                .disabled(!controller.session.isPlayable)

                Button("Rewind") {
                    controller.seek(to: controller.session.timelineStart)
                }
                .disabled(!controller.session.isPlayable)

                Divider()

                Button("Switch Track") {
                    controller.selectNextTrack()
                }
                .disabled(!controller.session.canSwitchPlayback)

                Button("Switch to Previous Track") {
                    controller.selectPreviousTrack()
                }
                .disabled(!controller.session.canSwitchPlayback)

                Divider()

                Button("Skip Forward 1s") {
                    controller.skip(by: 1)
                }
                .disabled(!controller.session.isPlayable)

                Button("Skip Forward 10s") {
                    controller.skip(by: 10)
                }
                .disabled(!controller.session.isPlayable)

                Button("Skip Backward 1s") {
                    controller.skip(by: -1)
                }
                .disabled(!controller.session.isPlayable)

                Button("Skip Backward 10s") {
                    controller.skip(by: -10)
                }
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
