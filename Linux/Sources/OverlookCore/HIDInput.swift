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

    private static let windowsExtendedNames: [Int: String] = [
        0x1C: "NumpadEnter",
        0x1D: "ControlRight",
        0x20: "AudioVolumeMute",
        0x2E: "AudioVolumeDown",
        0x30: "AudioVolumeUp",
        0x35: "NumpadDivide",
        0x37: "PrintScreen",
        0x38: "AltRight",
        0x45: "NumLock",
        0x46: "Pause",
        0x47: "Home",
        0x48: "ArrowUp",
        0x49: "PageUp",
        0x4B: "ArrowLeft",
        0x4D: "ArrowRight",
        0x4F: "End",
        0x50: "ArrowDown",
        0x51: "PageDown",
        0x52: "Insert",
        0x53: "Delete",
        0x5B: "MetaLeft",
        0x5C: "MetaRight",
        0x5D: "ContextMenu",
        0x5E: "Power"
    ]

    private static let windowsVirtualKeyNames: [Int: String] = {
        var map: [Int: String] = [
            0x08: "Backspace", 0x09: "Tab", 0x0D: "Enter", 0x13: "Pause", 0x14: "CapsLock",
            0x1B: "Escape", 0x20: "Space", 0x21: "PageUp", 0x22: "PageDown", 0x23: "End",
            0x24: "Home", 0x25: "ArrowLeft", 0x26: "ArrowUp", 0x27: "ArrowRight", 0x28: "ArrowDown",
            0x2C: "PrintScreen", 0x2D: "Insert", 0x2E: "Delete",
            0x5B: "MetaLeft", 0x5C: "MetaRight", 0x5D: "ContextMenu",
            0x60: "Numpad0", 0x61: "Numpad1", 0x62: "Numpad2", 0x63: "Numpad3", 0x64: "Numpad4",
            0x65: "Numpad5", 0x66: "Numpad6", 0x67: "Numpad7", 0x68: "Numpad8", 0x69: "Numpad9",
            0x6A: "NumpadMultiply", 0x6B: "NumpadAdd", 0x6D: "NumpadSubtract",
            0x6E: "NumpadDecimal", 0x6F: "NumpadDivide",
            0x90: "NumLock", 0x91: "ScrollLock",
            0xA0: "ShiftLeft", 0xA1: "ShiftRight",
            0xA2: "ControlLeft", 0xA3: "ControlRight",
            0xA4: "AltLeft", 0xA5: "AltRight",
            0xAD: "AudioVolumeMute", 0xAE: "AudioVolumeDown", 0xAF: "AudioVolumeUp",
            0xBA: "Semicolon", 0xBB: "Equal", 0xBC: "Comma", 0xBD: "Minus",
            0xBE: "Period", 0xBF: "Slash", 0xC0: "Backquote",
            0xDB: "BracketLeft", 0xDC: "Backslash", 0xDD: "BracketRight", 0xDE: "Quote",
            0xE2: "IntlBackslash"
        ]
        for n in 0...9 { map[0x30 + n] = "Digit\(n)" }
        for c in 0..<26 {
            let scalar = UnicodeScalar(65 + c)!
            map[0x41 + c] = "Key\(Character(scalar))"
        }
        for n in 1...24 { map[0x70 + n - 1] = "F\(n)" }
        return map
    }()

    public static func code(evdev: Int) -> String? { names[evdev] }
    public static func code(hardwareKeycode: Int) -> String? { code(evdev: hardwareKeycode - 8) }

    /// Maps a Windows Set 1 hardware scan code (with optional extended flag or `0x100`/`0xE000` bit)
    /// to a KVMD `KeyboardEvent.code` name.
    public static func code(windowsScanCode: Int, extended: Bool = false) -> String? {
        guard windowsScanCode > 0 else { return nil }
        let isExt = extended || (windowsScanCode & 0x100) != 0 || (windowsScanCode & 0xFF00) == 0xE000
        let raw = windowsScanCode & 0xFF
        guard raw > 0 else { return nil }
        if isExt {
            return windowsExtendedNames[raw]
        }
        if raw == 0x59 { return "NumpadEqual" }
        if (0x64...0x6F).contains(raw) {
            return "F\(raw - 0x64 + 13)"
        }
        return names[raw]
    }

    /// Fallback mapping from a Windows Virtual-Key (`VK_*`) code to a KVMD `KeyboardEvent.code` name.
    public static func code(windowsVirtualKey: Int) -> String? {
        windowsVirtualKeyNames[windowsVirtualKey]
    }
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
    /// Maps Windows / WinUI mouse button numbers (1=left, 2=middle, 3=right, 4/8=XButton1/back, 5/9=XButton2/forward).
    public static func buttonName(windowsButton: Int) -> String? {
        switch windowsButton {
        case 1: return "left"
        case 2: return "middle"
        case 3: return "right"
        case 4, 8: return "up"
        case 5, 9: return "down"
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
    /// Windows vertical wheel notches are positive for up (matching KVMD), and horizontal wheel notches are positive for right.
    public static func wheelDelta(windowsDX: Double, windowsDY: Double) -> (dx: Int, dy: Int)? {
        guard windowsDX.isFinite, windowsDY.isFinite else { return nil }
        let dx = Int(max(-127, min(127, (-windowsDX).rounded())))
        let dy = Int(max(-127, min(127, windowsDY.rounded())))
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
