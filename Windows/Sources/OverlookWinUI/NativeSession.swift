import Foundation
import CNativeWin
import OverlookCore

struct NativeStats {
    var connected = false
    var hidReady = false
    var authenticated = false
    var transport = "Idle"
    var status = "Idle"
    var videoWidth = 0
    var videoHeight = 0
    var fps = 0.0
    var bitrateKbps = 0.0
    var frames: UInt64 = 0
    var keyFrames: UInt64 = 0
    var droppedFrames: UInt64 = 0
    var bytesReceived: UInt64 = 0
    var hidLatencyMs = 0.0
    var hidSent: UInt64 = 0
    var hidErrors: UInt64 = 0
    var decoderBackend = "Unknown"
    var audioActive = false
    var sessionUptimeSeconds = 0.0
}

final class NativeSession {
    let raw: OpaquePointer
    private(set) var stats = NativeStats()
    private(set) var keyboardCaptured = true
    private var pressedKeys = Set<String>()
    private var pressedButtons = Set<String>()
    private var lastX = 0.0
    private var lastY = 0.0
    private var hasLastPoint = false
    private var connectedAt: Date?

    /// User-configurable input and capture settings.
    var config = CaptureConfig() {
        didSet { applyConfig() }
    }

    var onChanged: (() -> Void)?
    var onError: ((String) -> Void)?
    var onCertificate: ((String, String, String) -> Bool)?
    /// Fired on user press of the release-capture hotkey (Right Ctrl + Right Alt or Scroll Lock).
    var onCaptureToggled: ((Bool) -> Void)?

    init?() {
        let box = Unmanaged.passRetained(Box()).toOpaque()
        guard let raw = ol_native_new(nativeEventCallback, box) else {
            Unmanaged<Box>.fromOpaque(box).release()
            return nil
        }
        self.raw = raw
        Unmanaged<Box>.fromOpaque(box).takeUnretainedValue().session = self
        ol_native_input(raw, nativeInputCallback, box)
        self.box = box
    }

    private let box: UnsafeMutableRawPointer

    deinit {
        ol_native_close(raw)
        ol_native_free(raw)
        Unmanaged<Box>.fromOpaque(box).release()
    }

    var widget: OLWidgetPtr {
        ol_native_widget(raw)
    }

    func connect(device: Device, username: String, password: String) {
        releaseAllInputs()
        stats = NativeStats()
        stats.status = "Connecting to \(device.displayName)"
        stats.transport = config.streamMode.description
        connectedAt = nil
        onChanged?()

        applyConfig()

        device.hostPort.withCString { host in
            username.withCString { user in
                password.withCString { pass in
                    ol_native_connect(raw, host, user, pass, nativeCertCallback, box)
                }
            }
        }
    }

    private func applyConfig() {
        ol_native_set_config(
            raw,
            Int32(config.streamMode.rawValue),
            config.preferHEVC ? 1 : 0,
            config.preferHWDecode ? 1 : 0,
            Int32(config.maxFPS),
            Int32(config.jitterBufferMs),
            config.enableAudio ? 1 : 0,
            config.audioVolume
        )
    }

    func disconnect() {
        releaseAllInputs()
        ol_native_close(raw)
        stats.connected = false
        stats.hidReady = false
        stats.authenticated = false
        stats.status = "Disconnected"
        connectedAt = nil
        onChanged?()
    }

    func startTestStream(h264: Bool = true) {
        stats.status = h264 ? "Starting H.264 test stream" : "Starting fallback test stream"
        stats.transport = h264 ? "GStreamer H.264 test" : "GStreamer raw test"
        onChanged?()
        ol_native_test(raw, h264 ? 1 : 0)
    }

    func setKeyboardCaptured(_ captured: Bool) {
        if !captured {
            releaseAllKeys()
        }
        keyboardCaptured = captured
        ol_native_set_inhibit(raw, captured ? 1 : 0)
        onChanged?()
        onCaptureToggled?(captured)
    }

    func sendCtrlAltDelete() {
        for key in ["ControlLeft", "AltLeft", "Delete"] {
            send(HIDFrame.key(code: key, down: true))
        }
        for key in ["Delete", "AltLeft", "ControlLeft"] {
            send(HIDFrame.key(code: key, down: false))
        }
    }

    /// Sends a named system key sequence (e.g. "Alt+Tab", "Alt+F4", "Meta", "Ctrl+Shift+Esc").
    func sendKeyCombo(_ keys: [String]) {
        for key in keys {
            send(HIDFrame.key(code: key, down: true))
        }
        for key in keys.reversed() {
            send(HIDFrame.key(code: key, down: false))
        }
    }

    func pasteText(_ text: String) {
        guard !text.isEmpty else { return }
        stats.status = "Typing \(text.count) characters"
        onChanged?()
        text.withCString { cText in
            ol_native_hid_text(raw, cText)
        }
    }

    func releaseAllInputs() {
        releaseAllKeys()
        for button in pressedButtons {
            send(HIDFrame.mouseButton(button: button, down: false))
        }
        pressedButtons.removeAll()
        send(HIDFrame.reset())
    }

    func releaseAllKeys() {
        for key in pressedKeys {
            send(HIDFrame.key(code: key, down: false))
        }
        pressedKeys.removeAll()
    }

    /// Refreshes live stats including uptime and C-layer counters.
    func pollStats() {
        if let connectedAt, stats.connected {
            stats.sessionUptimeSeconds = Date().timeIntervalSince(connectedAt)
        }
        ol_native_poll_stats(raw)
    }

    /// Captures the current video frame to a PNG file.
    func takeScreenshot(to path: String) -> Result<String, Error> {
        var errPtr: UnsafeMutablePointer<CChar>?
        let ok = path.withCString { cPath in
            ol_native_screenshot(raw, cPath, &errPtr)
        }
        defer {
            if let errPtr { ol_native_free_string(errPtr) }
        }
        if ok != 0 {
            return .success(path)
        }
        let message = errPtr.map { String(cString: $0) } ?? "Screenshot failed"
        return .failure(NSError(domain: "OverlookNative", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
    }

    /// Probes available hardware video encoders on Windows (MediaFoundation / NVENC / AMF / QSV).
    static func probeVAAPI(preferredDevice: String = "") -> String {
        let ptr = preferredDevice.withCString { cDev in
            ol_vaapi_probe(cDev.pointee == 0 ? nil : cDev)
        }
        guard let ptr else { return "Hardware encoder probe failed" }
        defer { ol_native_free_string(ptr) }
        return String(cString: ptr)
    }

    var isRecording: Bool {
        ol_native_is_recording(raw) != 0
    }

    /// Starts hardware-accelerated MP4 video recording (falls back to x264 if hardware encoder unavailable).
    func startRecording(to path: String, hevc: Bool = false, vaapiDevice: String = "") -> Result<(path: String, backend: String), Error> {
        var backendPtr: UnsafeMutablePointer<CChar>?
        var errPtr: UnsafeMutablePointer<CChar>?
        let ok = path.withCString { cPath in
            vaapiDevice.withCString { cDev in
                ol_native_record_start(raw, cPath, hevc ? 1 : 0, cDev.pointee == 0 ? nil : cDev, &backendPtr, &errPtr)
            }
        }
        defer {
            if let backendPtr { ol_native_free_string(backendPtr) }
            if let errPtr { ol_native_free_string(errPtr) }
        }
        if ok != 0 {
            let backend = backendPtr.map { String(cString: $0) } ?? "unknown"
            return .success((path, backend))
        }
        let message = errPtr.map { String(cString: $0) } ?? "Could not start recording"
        return .failure(NSError(domain: "OverlookNative", code: 3, userInfo: [NSLocalizedDescriptionKey: message]))
    }

    /// Stops an active video recording and finalizes the MP4 file.
    func stopRecording() -> Result<(duration: Double, frames: Int), Error> {
        var duration = 0.0
        var frames: Int32 = 0
        var errPtr: UnsafeMutablePointer<CChar>?
        let ok = ol_native_record_stop(raw, &duration, &frames, &errPtr)
        defer {
            if let errPtr { ol_native_free_string(errPtr) }
        }
        if ok != 0 {
            return .success((duration, Int(frames)))
        }
        let message = errPtr.map { String(cString: $0) } ?? "Could not stop recording"
        return .failure(NSError(domain: "OverlookNative", code: 4, userInfo: [NSLocalizedDescriptionKey: message]))
    }

    /// Performs an authenticated HTTP API call against the connected GLKVM device.
    func apiRequest(
        method: String = "GET",
        path: String,
        contentType: String? = nil,
        body: Data? = nil,
        completion: @escaping (Result<(status: Int, data: Data), Error>) -> Void
    ) {
        let reqBox = Unmanaged.passRetained(HTTPRequestBox(completion: completion)).toOpaque()
        method.withCString { cMethod in
            path.withCString { cPath in
                if let body, !body.isEmpty {
                    body.withUnsafeBytes { rawBuf in
                        let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                        if let contentType {
                            contentType.withCString { cType in
                                ol_native_request(raw, cMethod, cPath, cType, base, Int32(body.count), nativeHTTPCallback, reqBox)
                            }
                        } else {
                            ol_native_request(raw, cMethod, cPath, nil, base, Int32(body.count), nativeHTTPCallback, reqBox)
                        }
                    }
                } else if let contentType {
                    contentType.withCString { cType in
                        ol_native_request(raw, cMethod, cPath, cType, nil, 0, nativeHTTPCallback, reqBox)
                    }
                } else {
                    ol_native_request(raw, cMethod, cPath, nil, nil, 0, nativeHTTPCallback, reqBox)
                }
            }
        }
    }

    fileprivate func handleEvent(event: String, text: String, number: Int32) {
        switch event {
        case "status":
            stats.status = text
        case "authenticated":
            stats.authenticated = true
            stats.status = "Authenticated"
        case "transport":
            stats.transport = text
        case "decoder":
            stats.decoderBackend = text
        case "connected":
            stats.connected = true
            if connectedAt == nil { connectedAt = Date() }
            stats.status = "Streaming (\(stats.transport))"
            ol_native_cursor(raw, config.hideLocalCursor ? "none" : "default")
        case "disconnected":
            stats.connected = false
            stats.hidReady = false
            stats.status = text.isEmpty ? "Disconnected" : text
            ol_native_cursor(raw, "default")
        case "hid":
            stats.hidReady = number != 0
        case "resolution":
            let parts = text.split(separator: "x")
            if parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) {
                stats.videoWidth = width
                stats.videoHeight = height
            }
        case "fps":
            stats.fps = Double(number) / 10.0
            stats.frames += UInt64(max(number, 0)) / 10
        case "bitrate":
            stats.bitrateKbps = Double(number)
        case "stats_detail":
            // Format: "frames:keyframes:dropped:bytes:hid_sent:hid_errors:hid_latency_us"
            let parts = text.split(separator: ":")
            if parts.count >= 7 {
                stats.frames = UInt64(parts[0]) ?? stats.frames
                stats.keyFrames = UInt64(parts[1]) ?? stats.keyFrames
                stats.droppedFrames = UInt64(parts[2]) ?? stats.droppedFrames
                stats.bytesReceived = UInt64(parts[3]) ?? stats.bytesReceived
                stats.hidSent = UInt64(parts[4]) ?? stats.hidSent
                stats.hidErrors = UInt64(parts[5]) ?? stats.hidErrors
                if let us = Double(parts[6]) {
                    stats.hidLatencyMs = us / 1000.0
                }
            }
        case "audio":
            stats.audioActive = number != 0
        case "error":
            stats.status = text
            onError?(text)
        default:
            break
        }
        onChanged?()
    }

    fileprivate func handleInput(kind: Int32, code: Int32, x: Double, y: Double) {
        switch kind {
        case OL_INPUT_KEY_DOWN, OL_INPUT_KEY_UP:
            let down = kind == OL_INPUT_KEY_DOWN
            // Windows Set 1 scancode with optional 0x100 extended flag in high byte
            let scanCode = UInt16(code & 0xFF)
            let extended = (code & 0x100) != 0
            guard let mapped = HIDKeyMap.code(windowsScanCode: scanCode, extended: extended) else { return }

            // Release-capture hotkeys:
            // 1. ScrollLock press toggles capture
            // 2. Right Control + Right Alt press toggles capture
            if down {
                if mapped == "ScrollLock" && config.scrollLockReleasesCapture {
                    setKeyboardCaptured(!keyboardCaptured)
                    return
                }
                if (mapped == "AltRight" && pressedKeys.contains("ControlRight")) ||
                   (mapped == "ControlRight" && pressedKeys.contains("AltRight")) {
                    setKeyboardCaptured(!keyboardCaptured)
                    return
                }
            }

            guard keyboardCaptured else { return }
            if down {
                pressedKeys.insert(mapped)
            } else {
                pressedKeys.remove(mapped)
            }
            send(HIDFrame.key(code: mapped, down: down))

        case OL_INPUT_MOUSE_MOVE:
            var width = 0.0
            var height = 0.0
            var videoWidth = 0.0
            var videoHeight = 0.0
            ol_native_geometry(raw, &width, &height, &videoWidth, &videoHeight)

            if config.mouseMode == .relative {
                if hasLastPoint {
                    let speed = config.relativeSensitivity
                    let dx = Int(((x - lastX) * speed).rounded())
                    let dy = Int(((y - lastY) * speed).rounded())
                    if dx != 0 || dy != 0 {
                        send(HIDFrame.mouseMoveRelative(dx: dx, dy: dy))
                    }
                }
                lastX = x
                lastY = y
                hasLastPoint = true
            } else {
                guard let point = HIDGeometry.normalizedPoint(
                    viewX: x,
                    viewY: y,
                    viewWidth: width,
                    viewHeight: height,
                    videoWidth: videoWidth,
                    videoHeight: videoHeight
                ) else { return }
                send(HIDFrame.mouseMoveAbsolute(x: point.x, y: point.y))
            }

        case OL_INPUT_MOUSE_DOWN, OL_INPUT_MOUSE_UP:
            ol_native_focus(raw, 1)
            let down = kind == OL_INPUT_MOUSE_DOWN
            guard let button = HIDFrame.buttonName(windowsButton: UInt32(max(code, 0))) else { return }
            if down {
                pressedButtons.insert(button)
            } else {
                pressedButtons.remove(button)
            }
            send(HIDFrame.mouseButton(button: button, down: down))

        case OL_INPUT_SCROLL:
            let mult = (config.naturalScroll ? -1.0 : 1.0) * config.scrollSensitivity
            let delta = HIDFrame.wheelDelta(windowsDX: x * mult, windowsDY: y * mult)
            guard delta.x != 0 || delta.y != 0 else { return }
            send(HIDFrame.mouseWheel(deltaX: delta.x, deltaY: delta.y))

        case OL_INPUT_LEAVE:
            hasLastPoint = false

        case OL_INPUT_BLUR:
            hasLastPoint = false
            releaseAllKeys()

        default:
            break
        }
    }

    private func send(_ data: Data) {
        guard ol_native_hid_ready(raw) != 0 else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            ol_native_hid_send(raw, base, Int32(data.count))
        }
    }
}

private final class Box {
    weak var session: NativeSession?
}

private final class HTTPRequestBox {
    let completion: (Result<(status: Int, data: Data), Error>) -> Void
    init(completion: @escaping (Result<(status: Int, data: Data), Error>) -> Void) {
        self.completion = completion
    }
}

private func nativeEventCallback(
    _ event: UnsafePointer<CChar>?,
    _ text: UnsafePointer<CChar>?,
    _ number: Int32,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
    let eventName = event.map { String(cString: $0) } ?? ""
    let eventText = text.map { String(cString: $0) } ?? ""
    box.session?.handleEvent(event: eventName, text: eventText, number: number)
}

private func nativeInputCallback(
    _ kind: Int32,
    _ code: Int32,
    _ x: Double,
    _ y: Double,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
    box.session?.handleInput(kind: kind, code: code, x: x, y: y)
}

private func nativeCertCallback(
    _ host: UnsafePointer<CChar>?,
    _ fingerprint: UnsafePointer<CChar>?,
    _ summary: UnsafePointer<CChar>?,
    _ context: UnsafeMutableRawPointer?
) -> Int32 {
    guard let context else { return 0 }
    let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
    let hostValue = host.map { String(cString: $0) } ?? ""
    let fpValue = fingerprint.map { String(cString: $0) } ?? ""
    let summaryValue = summary.map { String(cString: $0) } ?? ""
    return (box.session?.onCertificate?(hostValue, fpValue, summaryValue) ?? false) ? 1 : 0
}

private func nativeHTTPCallback(
    _ status: Int32,
    _ data: UnsafePointer<UInt8>?,
    _ length: Int32,
    _ error: UnsafePointer<CChar>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let reqBox = Unmanaged<HTTPRequestBox>.fromOpaque(context).takeRetainedValue()
    if let error {
        let message = String(cString: error)
        reqBox.completion(.failure(NSError(domain: "OverlookHTTP", code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])))
        return
    }
    let body: Data
    if let data, length > 0 {
        body = Data(bytes: data, count: Int(length))
    } else {
        body = Data()
    }
    reqBox.completion(.success((Int(status), body)))
}
