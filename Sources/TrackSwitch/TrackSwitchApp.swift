import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct TrackSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = PlaybackController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Controls") {
                Button(controller.session.isPlaying ? "Pause" : "Play") {
                    controller.session.isPlaying ? controller.pause() : controller.play()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!controller.session.isPlayable)

                Button("Switch Track") {
                    controller.toggleActiveTrack()
                }
                .keyboardShortcut("x", modifiers: [])
                .disabled(!controller.session.canSwitchPlayback)

                Button("Rewind") {
                    controller.seek(to: 0)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .disabled(!controller.session.isPlayable)

                Divider()

                Button("Seek Backward 1s") {
                    controller.skip(by: -1)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!controller.session.isPlayable)

                Button("Seek Forward 1s") {
                    controller.skip(by: 1)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!controller.session.isPlayable)

                Button("Seek Backward 10s") {
                    controller.skip(by: -10)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.shift])
                .disabled(!controller.session.isPlayable)

                Button("Seek Forward 10s") {
                    controller.skip(by: 10)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.shift])
                .disabled(!controller.session.isPlayable)
            }
        }
    }
}
