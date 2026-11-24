import Foundation
import XCTest
@testable import OverlookCore

final class HIDTests: XCTestCase {
    func testKeyMap() {
        XCTAssertEqual(HIDKeyMap.code(evdev: 30), "KeyA")
        XCTAssertEqual(HIDKeyMap.code(hardwareKeycode: 38), "KeyA")
        XCTAssertEqual(HIDKeyMap.code(evdev: 28), "Enter")
        XCTAssertEqual(HIDKeyMap.code(evdev: 42), "ShiftLeft")
        XCTAssertEqual(HIDKeyMap.code(evdev: 125), "MetaLeft")
        XCTAssertEqual(HIDKeyMap.code(evdev: 103), "ArrowUp")
        XCTAssertEqual(HIDKeyMap.code(evdev: 59), "F1")
        XCTAssertEqual(HIDKeyMap.code(evdev: 68), "F10")
        XCTAssertEqual(HIDKeyMap.code(evdev: 87), "F11")
        XCTAssertEqual(HIDKeyMap.code(evdev: 183), "F13")
        XCTAssertEqual(HIDKeyMap.code(evdev: 194), "F24")
        XCTAssertEqual(HIDKeyMap.code(evdev: 96), "NumpadEnter")
        XCTAssertEqual(HIDKeyMap.code(evdev: 86), "IntlBackslash")
        XCTAssertEqual(HIDKeyMap.code(evdev: 127), "ContextMenu")
        XCTAssertEqual(HIDKeyMap.code(evdev: 100), "AltRight")
        XCTAssertNil(HIDKeyMap.code(evdev: 0))
        XCTAssertNil(HIDKeyMap.code(evdev: 9999))
        XCTAssertNil(HIDKeyMap.code(hardwareKeycode: 3))
        for evdev in 0..<256 { XCTAssertEqual(HIDKeyMap.code(hardwareKeycode: evdev + 8), HIDKeyMap.code(evdev: evdev)) }
    }
    func testFrames() {
        XCTAssertEqual(HIDFrame.key("KeyA", pressed: true), [0x01, 0x01, 0x4B, 0x65, 0x79, 0x41])
        XCTAssertEqual(HIDFrame.key("KeyA", pressed: false), [0x01, 0x00, 0x4B, 0x65, 0x79, 0x41])
        XCTAssertEqual(HIDFrame.releaseAllKeys, [0x01, 0x00])
        XCTAssertEqual(HIDFrame.mouseButton("left", pressed: true), [0x02, 0x01] + Array("left".utf8))
        XCTAssertEqual(HIDFrame.mouseMove(x: 1, y: -1), [0x03, 0x00, 0x01, 0xFF, 0xFF])
        XCTAssertEqual(HIDFrame.mouseMove(x: 100_000, y: -100_000), [0x03, 0x7F, 0xFF, 0x80, 0x00])
        XCTAssertEqual(HIDFrame.wheel(dx: -1, dy: 500), [0x05, 0x00, 0xFF, 0x7F])
        XCTAssertEqual(HIDFrame.wheel(dx: -500, dy: 0), [0x05, 0x00, 0x81, 0x00])
        XCTAssertEqual(HIDFrame.ping, #"{"event_type":"ping","event":{}}"#)
        let ping = try? JSONSerialization.jsonObject(with: Data(HIDFrame.ping.utf8)) as? [String: Any]
        XCTAssertEqual(ping?["event_type"] as? String, "ping")
    }
    func testRelativeChunking() {
        XCTAssertEqual(HIDFrame.mouseRelative(dx: 0, dy: 0), [])
        XCTAssertEqual(HIDFrame.mouseRelative(dx: 5, dy: -3), [[0x04, 0x00, 0x05, 0xFD]])
        XCTAssertEqual(HIDFrame.mouseRelative(dx: 300, dy: -10), [
            [0x04, 0x00, 0x7F, 0xF6], [0x04, 0x00, 0x7F, 0x00], [0x04, 0x00, 0x2E, 0x00],
        ])
        let frames = HIDFrame.mouseRelative(dx: -1000, dy: 400)
        XCTAssertEqual(frames.map { Int(Int8(bitPattern: $0[2])) }.reduce(0, +), -1000)
        XCTAssertEqual(frames.map { Int(Int8(bitPattern: $0[3])) }.reduce(0, +), 400)
        XCTAssertTrue(frames.allSatisfy { abs(Int(Int8(bitPattern: $0[2]))) <= 127 && Int8(bitPattern: $0[2]) != -128 })
    }
    func testButtonsAndWheel() {
        XCTAssertEqual(HIDFrame.buttonName(gdkButton: 1), "left")
        XCTAssertEqual(HIDFrame.buttonName(gdkButton: 2), "middle")
        XCTAssertEqual(HIDFrame.buttonName(gdkButton: 3), "right")
        XCTAssertEqual(HIDFrame.buttonName(gdkButton: 8), "up")
        XCTAssertEqual(HIDFrame.buttonName(gdkButton: 9), "down")
        XCTAssertNil(HIDFrame.buttonName(gdkButton: 4))
        // GTK positive dy scrolls down and positive dx pans right; KVMD positive dy scrolls up and positive dx pans right.
        XCTAssertEqual(HIDFrame.wheelDelta(gtkDX: 0, gtkDY: 1).map { [$0.dx, $0.dy] }, [0, -1])
        XCTAssertEqual(HIDFrame.wheelDelta(gtkDX: 0, gtkDY: -2).map { [$0.dx, $0.dy] }, [0, 2])
        XCTAssertEqual(HIDFrame.wheelDelta(gtkDX: 1, gtkDY: 0).map { [$0.dx, $0.dy] }, [1, 0])
        XCTAssertEqual(HIDFrame.wheelDelta(gtkDX: 0, gtkDY: 1000).map { [$0.dx, $0.dy] }, [0, -127])
        XCTAssertNil(HIDFrame.wheelDelta(gtkDX: 0.2, gtkDY: -0.4))
        XCTAssertNil(HIDFrame.wheelDelta(gtkDX: .nan, gtkDY: 1))
    }
    func testGeometry() {
        func map(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ vw: Double = 1920, _ vh: Double = 1080) -> [Int]? {
            VideoGeometry.absolute(x: x, y: y, widgetWidth: w, widgetHeight: h, videoWidth: vw, videoHeight: vh).map { [$0.x, $0.y] }
        }
        XCTAssertEqual(map(960, 540, 1920, 1080), [0, 0])
        XCTAssertEqual(map(0, 0, 1920, 1080), [-32767, -32767])
        XCTAssertEqual(map(1920, 1080, 1920, 1080), [32767, 32767])
        // Letterbox: 1000x1000 widget, video 1000x562.5 centred with top at 218.75.
        XCTAssertEqual(map(500, 500, 1000, 1000), [0, 0])
        XCTAssertEqual(map(0, 218.75, 1000, 1000), [-32767, -32767])
        XCTAssertEqual(map(1000, 781.25, 1000, 1000), [32767, 32767])
        XCTAssertNil(map(500, 100, 1000, 1000))
        XCTAssertNil(map(500, 900, 1000, 1000))
        // Pillarbox: 2000x1080 widget, video 1920 wide starting at x = 40.
        XCTAssertEqual(map(40, 0, 2000, 1080), [-32767, -32767])
        XCTAssertEqual(map(1960, 1080, 2000, 1080), [32767, 32767])
        XCTAssertNil(map(20, 540, 2000, 1080))
        XCTAssertNil(map(1990, 540, 2000, 1080))
        XCTAssertNil(map(-1, 0, 1920, 1080))
        XCTAssertNil(map(0, 0, 0, 1080))
        XCTAssertNil(map(0, 0, 100, 100, 0, 1080))
    }
    func testHIDState() {
        func parse(_ text: String) -> Bool? { HIDState.mouseAbsolute(Data(text.utf8)) }
        XCTAssertEqual(parse(#"{"event_type":"hid","event":{"mouse":{"absolute":true,"online":true}}}"#), true)
        XCTAssertEqual(parse(#"{"event_type":"hid_state","event":{"mouse":{"absolute":false}}}"#), false)
        XCTAssertNil(parse(#"{"event_type":"hid","event":{"keyboard":{"online":true}}}"#))
        XCTAssertNil(parse(#"{"event_type":"streamer","event":{"mouse":{"absolute":true}}}"#))
        XCTAssertNil(parse(#"{"event_type":"pong","event":{}}"#))
        XCTAssertNil(parse("not json"))
    }
    func testWindowsKeyAndMouseMappings() {
        XCTAssertEqual(HIDKeyMap.code(windowsScanCode: 0x1E), "KeyA")
        XCTAssertEqual(HIDKeyMap.code(windowsScanCode: 0x1C), "Enter")
        XCTAssertEqual(HIDKeyMap.code(windowsScanCode: 0x1C, extended: true), "NumpadEnter")
        XCTAssertEqual(HIDKeyMap.code(windowsScanCode: 0x11C), "NumpadEnter")
        XCTAssertEqual(HIDKeyMap.code(windowsScanCode: 0xE01D), "ControlRight")
        XCTAssertEqual(HIDKeyMap.code(windowsScanCode: 0x38, extended: true), "AltRight")
        XCTAssertEqual(HIDKeyMap.code(windowsScanCode: 0x48, extended: true), "ArrowUp")
        XCTAssertEqual(HIDKeyMap.code(windowsScanCode: 0x53, extended: true), "Delete")
        XCTAssertEqual(HIDKeyMap.code(windowsScanCode: 0x5B, extended: true), "MetaLeft")
        XCTAssertEqual(HIDKeyMap.code(windowsScanCode: 0x5D, extended: true), "ContextMenu")
        XCTAssertEqual(HIDKeyMap.code(windowsScanCode: 0x64), "F13")
        XCTAssertEqual(HIDKeyMap.code(windowsVirtualKey: 0x41), "KeyA")
        XCTAssertEqual(HIDKeyMap.code(windowsVirtualKey: 0x70), "F1")
        XCTAssertEqual(HIDKeyMap.code(windowsVirtualKey: 0x87), "F24")
        XCTAssertEqual(HIDFrame.buttonName(windowsButton: 1), "left")
        XCTAssertEqual(HIDFrame.buttonName(windowsButton: 4), "up")
        XCTAssertEqual(HIDFrame.buttonName(windowsButton: 5), "down")
        XCTAssertEqual(HIDFrame.wheelDelta(windowsDX: 0, windowsDY: 1).map { [$0.dx, $0.dy] }, [0, 1])
        XCTAssertEqual(HIDFrame.wheelDelta(windowsDX: 2, windowsDY: -1).map { [$0.dx, $0.dy] }, [2, -1])
    }

    func testHIDScrollAccumulator() {
        var acc = HIDScrollAccumulator()
        XCTAssertNil(acc.add(deltaX: 0.4, deltaY: 0, isPrecise: true, timestamp: 1.0))
        XCTAssertNil(acc.add(deltaX: 0.4, deltaY: 0, isPrecise: true, timestamp: 1.05))
        let step = acc.add(deltaX: 0.4, deltaY: 0, isPrecise: true, timestamp: 1.10)
        XCTAssertEqual(step?.dx, 1)
        XCTAssertEqual(step?.dy, 0)
        XCTAssertEqual(acc.pendingX, 0.2, accuracy: 0.001)

        // Spikes are capped at maxStepsPerEvent (5)
        let spike = acc.add(deltaX: 0, deltaY: 12.0, isPrecise: true, timestamp: 1.15)
        XCTAssertEqual(spike?.dy, HIDScrollAccumulator.maxStepsPerEvent)

        // Idle pause (> 0.25s) clears pending sub-step remainder
        acc.reset()
        XCTAssertNil(acc.add(deltaX: 0.9, deltaY: 0, isPrecise: true, timestamp: 2.0))
        XCTAssertNil(acc.add(deltaX: 0.3, deltaY: 0, isPrecise: true, timestamp: 2.3))

        // Non-precise (stepped wheel) flushes immediately and clears pending accumulator
        let discrete = acc.add(deltaX: -200, deltaY: 2, isPrecise: false, timestamp: 2.35)
        XCTAssertEqual(discrete?.dx, -127)
        XCTAssertEqual(discrete?.dy, 2)
        XCTAssertEqual(acc.pendingX, 0)
        XCTAssertEqual(acc.pendingY, 0)
    }

    func testCaptureChordTrackerFullscreenAndRelease() {
        var tracker = HIDCaptureChordTracker()

        // Ctrl+Alt+F triggers fullscreen toggle without forwarding KeyF or its repeats/key-up.
        XCTAssertEqual(tracker.keyDown("ControlLeft"), .forward)
        XCTAssertEqual(tracker.keyDown("AltLeft"), .forward)
        XCTAssertEqual(tracker.keyDown("KeyF"), .toggleFullscreen)
        tracker.clearHeldKeys()
        XCTAssertEqual(tracker.keyDown("KeyF"), .ignore)
        XCTAssertEqual(tracker.keyUp("KeyF"), .ignore)
        XCTAssertEqual(tracker.keyUp("AltLeft"), .ignore)
        XCTAssertEqual(tracker.keyUp("ControlLeft"), .ignore)

        // AltLeft first + ControlRight + KeyF also triggers fullscreen toggle.
        XCTAssertEqual(tracker.keyDown("AltLeft"), .forward)
        XCTAssertEqual(tracker.keyDown("ControlRight"), .forward)
        XCTAssertEqual(tracker.keyDown("KeyF"), .toggleFullscreen)
        tracker.reset()

        // AltGr (ControlLeft + AltRight) + KeyF must forward to the target.
        XCTAssertEqual(tracker.keyDown("ControlLeft"), .forward)
        XCTAssertEqual(tracker.keyDown("AltRight"), .forward)
        XCTAssertEqual(tracker.keyDown("KeyF"), .forward)
        tracker.reset()

        // Extra modifiers (Ctrl+Alt+Shift+F) must forward to the target.
        XCTAssertEqual(tracker.keyDown("ControlLeft"), .forward)
        XCTAssertEqual(tracker.keyDown("AltLeft"), .forward)
        XCTAssertEqual(tracker.keyDown("ShiftLeft"), .forward)
        XCTAssertEqual(tracker.keyDown("KeyF"), .forward)
        tracker.reset()

        // Bare F11 while captured goes to the target.
        XCTAssertEqual(tracker.keyDown("F11"), .forward)
        XCTAssertEqual(tracker.keyUp("F11"), .forward(releaseCapture: false))

        // Left Ctrl + Left Alt press and release disarms capture on final key-up.
        XCTAssertEqual(tracker.keyDown("ControlLeft"), .forward)
        XCTAssertEqual(tracker.keyDown("AltLeft"), .forward)
        XCTAssertEqual(tracker.keyUp("AltLeft"), .forward(releaseCapture: false))
        XCTAssertEqual(tracker.keyUp("ControlLeft"), .forward(releaseCapture: true))

        // Ctrl+Alt+Delete disarms capture release and forwards all keys.
        XCTAssertEqual(tracker.keyDown("ControlLeft"), .forward)
        XCTAssertEqual(tracker.keyDown("AltLeft"), .forward)
        XCTAssertEqual(tracker.keyDown("Delete"), .forward)
        XCTAssertEqual(tracker.keyUp("Delete"), .forward(releaseCapture: false))
        XCTAssertEqual(tracker.keyUp("AltLeft"), .forward(releaseCapture: false))
        XCTAssertEqual(tracker.keyUp("ControlLeft"), .forward(releaseCapture: false))
    }
}
