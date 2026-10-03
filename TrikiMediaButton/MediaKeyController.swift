import AppKit
import CoreGraphics

enum MediaKeyController {
    enum Key: Int {
        case volumeUp = 0, volumeDown = 1, playPause = 16

        var label: String {
            switch self {
            case .volumeUp: return "Volume up"
            case .volumeDown: return "Volume down"
            case .playPause: return "Play/Pause"
            }
        }
    }
    static func requestPermission() {
        if !CGPreflightPostEventAccess() {
            _ = CGRequestPostEventAccess()
            NSLog("Enable Triki Remote in System Settings > Privacy & Security > Accessibility")
        }
    }

    // NX_KEYTYPE_PLAY = 16, NX_SUBTYPE_AUX_CONTROL_BUTTONS = 8.
    // A complete system-defined down/up pair, with the repeat bit left clear.
    static func makeEvent(isDown: Bool, key: Key = .playPause) -> CGEvent? {
        let state = isDown ? 0xA : 0xB
        return NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: (key.rawValue << 16) | (state << 8),
            data2: -1
        )?.cgEvent
    }

    static func playPause() {
        send(.playPause)
    }

    static func send(_ key: Key) {
        guard CGPreflightPostEventAccess() else {
            NSLog("%@ blocked: Accessibility permission is required", key.label)
            return
        }
        guard let down = makeEvent(isDown: true, key: key), let up = makeEvent(isDown: false, key: key) else {
            NSLog("Could not create %@ media-key events", key.label)
            return
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        NSLog("%@ triggered", key.label)
    }
}
