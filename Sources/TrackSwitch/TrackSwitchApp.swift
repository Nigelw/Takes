import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var pendingOpenFileURLs: [URL] = []
    private var consumedLaunchFileArguments = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        queueOpenedFiles([filename])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        queueOpenedFiles(filenames)
        sender.reply(toOpenOrPrint: .success)
    }

    func clearPendingOpenFileURLs() {
        pendingOpenFileURLs = []
    }

    func consumeLaunchFileArguments(from arguments: [String] = CommandLine.arguments) -> [URL] {
        guard !consumedLaunchFileArguments else { return [] }
        consumedLaunchFileArguments = true
        return LaunchFileArguments.audioFileURLs(from: arguments)
    }

    private func queueOpenedFiles(_ filenames: [String]) {
        pendingOpenFileURLs.append(contentsOf: filenames.map { URL(fileURLWithPath: $0) })
    }
}

enum LaunchFileArguments {
    static func audioFileURLs(from arguments: [String]) -> [URL] {
        arguments.dropFirst().compactMap { argument in
            guard !argument.hasPrefix("-") else { return nil }

            let url = URL(fileURLWithPath: argument)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
    }
}

@main
struct TrackSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = PlaybackController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
                .task {
                    let urls = appDelegate.consumeLaunchFileArguments()
                    guard !urls.isEmpty else { return }
                    await controller.loadImportedFiles(urls)
                }
                .onReceive(appDelegate.$pendingOpenFileURLs) { urls in
                    guard !urls.isEmpty else { return }
                    Task {
                        await controller.loadImportedFiles(urls)
                        appDelegate.clearPendingOpenFileURLs()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
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
