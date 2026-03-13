import AppKit
import Foundation

final class KeyMonitor {
    private var monitor: Any?
    private let handler: (NSEvent) -> Bool

    init(handler: @escaping (NSEvent) -> Bool) {
        self.handler = handler
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handler(event) ? nil : event
        }
    }

    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}
