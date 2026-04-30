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
