import Foundation

/// Names are the subset of KeyboardEvent.code values in KVMD's WEB_TO_EVDEV table.
public enum HIDKeyMap {
    private static let names: [Int: String] = {
        var map: [Int: String] = [
            1: "Escape", 2: "Digit1", 3: "Digit2", 4: "Digit3", 5: "Digit4", 6: "Digit5", 7: "Digit6",
            8: "Digit7", 9: "Digit8", 10: "Digit9", 11: "Digit0", 12: "Minus", 13: "Equal", 14: "Backspace",
            15: "Tab", 16: "KeyQ", 17: "KeyW", 18: "KeyE", 19: "KeyR", 20: "KeyT", 21: "KeyY", 22: "KeyU",
            23: "KeyI", 24: "KeyO", 25: "KeyP", 26: "BracketLeft", 27: "BracketRight", 28: "Enter",
            29: "ControlLeft", 30: "KeyA", 31: "KeyS", 32: "KeyD", 33: "KeyF", 34: "KeyG", 35: "KeyH",
            36: "KeyJ", 37: "KeyK", 38: "KeyL", 39: "Semicolon", 40: "Quote", 41: "Backquote",
            42: "ShiftLeft", 43: "Backslash", 44: "KeyZ", 45: "KeyX", 46: "KeyC", 47: "KeyV", 48: "KeyB",
            49: "KeyN", 50: "KeyM", 51: "Comma", 52: "Period", 53: "Slash", 54: "ShiftRight",
            55: "NumpadMultiply", 56: "AltLeft", 57: "Space", 58: "CapsLock",
            69: "NumLock", 70: "ScrollLock",
            71: "Numpad7", 72: "Numpad8", 73: "Numpad9", 74: "NumpadSubtract", 75: "Numpad4", 76: "Numpad5",
            77: "Numpad6", 78: "NumpadAdd", 79: "Numpad1", 80: "Numpad2", 81: "Numpad3", 82: "Numpad0",
            83: "NumpadDecimal", 86: "IntlBackslash", 87: "F11", 88: "F12", 89: "IntlRo",
            90: "KanaMode", 92: "Convert", 94: "NonConvert",
            96: "NumpadEnter", 97: "ControlRight", 98: "NumpadDivide", 99: "PrintScreen", 100: "AltRight",
            102: "Home", 103: "ArrowUp", 104: "PageUp", 105: "ArrowLeft", 106: "ArrowRight", 107: "End",
            108: "ArrowDown", 109: "PageDown", 110: "Insert", 111: "Delete",
            113: "AudioVolumeMute", 114: "AudioVolumeDown", 115: "AudioVolumeUp", 116: "Power",
            119: "Pause", 124: "IntlYen", 125: "MetaLeft", 126: "MetaRight", 127: "ContextMenu",
        ]
        for n in 1...10 { map[58 + n] = "F\(n)" }       // KEY_F1 59 ... KEY_F10 68
        for n in 13...24 { map[170 + n] = "F\(n)" }     // KEY_F13 183 ... KEY_F24 194
        return map
    }()

    public static func code(evdev: Int) -> String? { names[evdev] }
    public static func code(hardwareKeycode: Int) -> String? { code(evdev: hardwareKeycode - 8) }
}

public enum HIDFrame {
    public static func key(_ code: String, pressed: Bool) -> [UInt8] { [0x01, pressed ? 1 : 0] + Array(code.utf8) }
    public static let releaseAllKeys: [UInt8] = [0x01, 0x00]
    public static func mouseButton(_ name: String, pressed: Bool) -> [UInt8] {
        [0x02, pressed ? 1 : 0] + Array(name.utf8)
    }
    public static func mouseMove(x: Int, y: Int) -> [UInt8] {
        let ux = UInt16(bitPattern: Int16(clamping: x)), uy = UInt16(bitPattern: Int16(clamping: y))
        return [0x03, UInt8(ux >> 8), UInt8(ux & 0xFF), UInt8(uy >> 8), UInt8(uy & 0xFF)]
    }
    public static func mouseRelative(dx: Int, dy: Int) -> [[UInt8]] {
        var frames: [[UInt8]] = []
        var x = dx, y = dy
        while x != 0 || y != 0 {
            let cx = max(-127, min(127, x)), cy = max(-127, min(127, y))
            frames.append([0x04, 0x00, UInt8(bitPattern: Int8(cx)), UInt8(bitPattern: Int8(cy))])
            x -= cx; y -= cy
        }
        return frames
    }
    public static func wheel(dx: Int, dy: Int) -> [UInt8] {
        [0x05, 0x00, UInt8(bitPattern: Int8(max(-127, min(127, dx)))), UInt8(bitPattern: Int8(max(-127, min(127, dy))))]
    }
    /// KVMD maps "up" to BTN_BACK and "down" to BTN_FORWARD (kvmd/mouse.py MOUSE_TO_EVDEV).
    public static func buttonName(gdkButton: Int) -> String? {
        switch gdkButton {
        case 1: return "left"
        case 2: return "middle"
        case 3: return "right"
        case 8: return "up"
        case 9: return "down"
        default: return nil
        }
    }
    /// KVMD wheel deltas are positive for up/left (HID convention, like AppKit scrollingDelta); GTK is positive for down/right.
    public static func wheelDelta(gtkDX: Double, gtkDY: Double) -> (dx: Int, dy: Int)? {
        guard gtkDX.isFinite, gtkDY.isFinite else { return nil }
        let dx = Int(max(-127, min(127, (-gtkDX).rounded())))
        let dy = Int(max(-127, min(127, (-gtkDY).rounded())))
        return dx == 0 && dy == 0 ? nil : (dx, dy)
    }
    public static let ping = #"{"event_type":"ping","event":{}}"#
}

public enum VideoGeometry {
    public static func absolute(x: Double, y: Double, widgetWidth: Double, widgetHeight: Double,
                                videoWidth: Double, videoHeight: Double) -> (x: Int, y: Int)? {
        guard widgetWidth > 0, widgetHeight > 0, videoWidth > 0, videoHeight > 0 else { return nil }
        let scale = min(widgetWidth / videoWidth, widgetHeight / videoHeight)
        let width = videoWidth * scale, height = videoHeight * scale
        let left = (widgetWidth - width) / 2, top = (widgetHeight - height) / 2
        let nx = (x - left) / width, ny = (y - top) / height
        guard (0...1).contains(nx), (0...1).contains(ny) else { return nil }
        return (Int(((nx * 2 - 1) * 32767).rounded()), Int(((ny * 2 - 1) * 32767).rounded()))
    }
}

public enum HIDState {
    public static func mouseAbsolute(_ data: Data) -> Bool? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["event_type"] as? String, type == "hid" || type == "hid_state",
              let mouse = (object["event"] as? [String: Any])?["mouse"] as? [String: Any],
              let absolute = mouse["absolute"] as? Bool else { return nil }
        return absolute
    }
}
