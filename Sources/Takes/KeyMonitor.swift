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

enum TrackNumberHotkey {
    private static let keyCodes: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 0,
        83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9, 82: 0
    ]

    static func hotkey(forKeyCode keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Int? {
        guard modifierFlags.intersection([.shift, .command, .control, .option]).isEmpty else {
            return nil
        }
        return keyCodes[keyCode]
    }
}

enum TrackSwitchArrowHotkey {
    enum Direction {
        case previous
        case next
    }

    static func direction(forKeyCode keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Direction? {
        guard modifierFlags.intersection([.shift, .command, .control, .option]).isEmpty else {
            return nil
        }

        switch keyCode {
        case 126:
            return .previous
        case 125:
            return .next
        default:
            return nil
        }
    }
}

final class MouseMonitor {
    private var monitor: Any?
    private let handler: (NSEvent) -> Void

    init(handler: @escaping (NSEvent) -> Void) {
        self.handler = handler
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved]) { [weak self] event in
            self?.handler(event)
            return event
        }
    }

    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}
