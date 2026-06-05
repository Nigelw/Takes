import AppKit
import SwiftUI

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
        guard !urls.isEmpty else { return }

        guard let handler else {
            pendingURLBatches.append(urls)
            return
        }

        handler(urls)
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

            CommandMenu("Controls") {
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
            .disabled(openFileCommandState == nil)
        }
    }
}
