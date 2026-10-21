import Foundation
import CDesktop
import CNative
import OverlookCore

private final class HTTPCompletionBox {
    let run: (Int, Data, String?) -> Void
    init(_ run: @escaping (Int, Data, String?) -> Void) { self.run = run }
}

/// All state is confined to the GLib/GTK thread. The C media adapter marshals
/// streaming-thread callbacks onto that loop before calling into Swift.
final class NativeSession {
    struct Certificate { let key: String; let sha256: String; let reason: String }
    private enum Stage { case idle, login, janus }

    private var engine: OpaquePointer!
    private var signaling = JanusSignaling()
    private var timer: UInt32 = 0
    private(set) var base: URL?
    private var credentials: String?
    private var stage = Stage.idle
    private var started = Date()
    private var lastMessage = Date()
    private var lastKeepalive = Date()
    private var lastPing = Date()
    private var lastPingSentAt: Date?
    private(set) var receivedFrame = false
    private var stopped = false
    private var awaitingTrust = false

    private var hidReady = false
    private(set) var mouseAbsolute = true
    private(set) var captured = false
    var keyboardControlEnabled = true
    var mouseControlEnabled = true
    var relativeSensitivity = 1.0
    var reverseScrolling = "STANDARD"
    var showRemoteCursor = true

    private var keys: [String] = []
    private var buttons: Set<String> = []
    private var lastPoint: (x: Double, y: Double)?
    private var lastAbsolute: (x: Int, y: Int)?
    private var scroll = (x: 0.0, y: 0.0)
    private var releaseArmed = false

    private(set) var telemetry = StreamTelemetry()
    var onStatus: (String) -> Void = { _ in }
    var onNotice: (String) -> Void = { _ in }
    var onFrame: () -> Void = {}
    var onFailure: (String) -> Void = { _ in }
    var onCertificate: (Certificate) -> Void = { _ in }
    var onInputChanged: () -> Void = {}
    var onTelemetryChanged: () -> Void = {}
    var picture: UnsafeMutableRawPointer { ol_native_picture(engine)! }
    var inputAvailable: Bool { hidReady }
    var isRecording: Bool { engine != nil && ol_native_is_recording(engine) != 0 }

    init(trusted: [String: String]) {
        engine = ol_native_new({ event, text, number, context in
            let owner = Unmanaged<NativeSession>.fromOpaque(context!).takeUnretainedValue()
            owner.event(String(cString: event!), text: String(cString: text!), number: Int(number))
        }, Unmanaged.passUnretained(self).toOpaque())
        for (key, sha256) in trusted { ol_native_allow(engine, key, sha256) }
        ol_native_input(engine, { kind, code, x, y, context in
            Unmanaged<NativeSession>.fromOpaque(context!).takeUnretainedValue().input(Int(kind), Int(code), x, y)
        }, Unmanaged.passUnretained(self).toOpaque())
        timer = g_timeout_add_seconds(1, { context in
            Unmanaged<NativeSession>.fromOpaque(context!).takeUnretainedValue().tick()
            return 1
        }, Unmanaged.passUnretained(self).toOpaque())
    }
    deinit { stop() }

    func connect(base: URL, username: String, password: String, otp: String) {
        self.base = base
        ConnectionLog.shared.info(.lifecycle, "Connecting to \(base.host ?? base.absoluteString)")
        credentials = KVMRequest.form(["user": username, "passwd": password + otp])
        login()
    }
    private func login() {
        guard let base, let credentials else { return }
        stage = .login
        started = Date()
        onStatus("Signing in…")
        ol_native_http(engine, "POST", KVMRequest.endpoint(base, path: "api/auth/login").absoluteString, credentials)
    }
    private var origin: String {
        var origin = URLComponents(url: base!, resolvingAgainstBaseURL: false)!
        origin.path = ""; origin.query = nil; origin.fragment = nil
        return origin.url!.absoluteString
    }
    private func openJanus() {
        guard let base else { return }
        stage = .janus
        started = Date()
        onStatus("Opening video signaling…")
        ConnectionLog.shared.info(.signaling, "Opening Janus WebSocket")
        ol_native_socket(engine, KVMRequest.endpoint(base, path: "janus/ws", websocket: true).absoluteString, origin)
    }
    private func openHID() {
        guard let base else { return }
        telemetry.hidLink = .connecting
        onTelemetryChanged()
        ConnectionLog.shared.info(.hid, "Opening HID WebSocket")
        ol_native_hid_socket(engine, KVMRequest.endpoint(base, path: "api/ws", websocket: true).absoluteString, origin)
    }

    /// Approve the presented certificate for this session and resume where it failed.
    func trust(_ certificate: Certificate) {
        guard !stopped else { return }
        awaitingTrust = false
        ol_native_allow(engine, certificate.key, certificate.sha256)
        switch stage {
        case .janus: openJanus()
        default: login()
        }
    }
    func rejectCertificate() { fail("The device certificate was not trusted.") }

    func test(h264: Bool = false) { onStatus("Testing \(h264 ? "H.264" : "VP8") locally…"); ol_native_test(engine, h264 ? 1 : 0) }
    func stop() {
        guard !stopped else { return }
        stopped = true
        credentials = nil
        releaseInputs()
        if timer != 0 { g_source_remove(timer); timer = 0 }
        if signaling.sessionID != nil { perform([signaling.destroy()]) }
        if let engine { ol_native_close(engine) }
        engine = nil
    }
    private func fail(_ text: String) {
        guard !stopped else { return }
        ConnectionLog.shared.error(.lifecycle, text)
        stop()
        onFailure(text)
    }
    private func tick() {
        guard !stopped, !awaitingTrust else { return }
        if !receivedFrame && Date().timeIntervalSince(started) > 30 {
            fail("No video arrived within 30 seconds. Check the credentials, codecs, and network path."); return
        }
        if signaling.sessionID != nil {
            if Date().timeIntervalSince(lastMessage) > 45 { fail("The video service stopped responding."); return }
            if Date().timeIntervalSince(lastKeepalive) >= 15 {
                perform([signaling.keepalive()]); lastKeepalive = Date()
            }
        }
        if hidReady && Date().timeIntervalSince(lastPing) >= 2 {
            lastPingSentAt = Date()
            ol_native_hid_text(engine, HIDFrame.ping); lastPing = Date()
        }
        if receivedFrame, let engine {
            ol_native_poll_stats(engine)
        }
    }
    private func perform(_ actions: [JanusSignaling.Action]) {
        for action in actions {
            switch action {
            case .send(let message):
                if let data = try? JSONSerialization.data(withJSONObject: message), let text = String(data: data, encoding: .utf8) {
                    ol_native_send(engine, text)
                }
            case .offer(let sdp):
                onStatus("Negotiating video…")
                ol_native_offer(engine, sdp)
            case .candidate(let line, let text): ol_native_ice(engine, UInt32(line), text)
            case .connected: onStatus("Waiting for video…")
            }
        }
    }
    private func event(_ event: String, text: String, number: Int) {
        guard !stopped else { return }
        switch event {
        case "error": fail(text)
        case "certificate":
            let parts = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { fail("The device certificate could not be read."); return }
            awaitingTrust = true
            ConnectionLog.shared.warning(.device, "Unverified certificate for \(parts[0])")
            onCertificate(Certificate(key: parts[0], sha256: parts[1], reason: parts[2]))
        case "http":
            guard stage == .login, let base else { return }
            stage = .idle
            guard (200...299).contains(number) else {
                fail(number == 401 || number == 403 ? "The username, password, or one-time code was rejected." : "Sign-in returned HTTP \(number)."); return
            }
            let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            if object?["ok"] as? Bool == false { fail("The device rejected the sign-in."); return }
            credentials = nil
            if let result = object?["result"] as? [String: Any], let token = result["token"] as? String {
                ol_native_cookie(engine, base.absoluteString, token)
            }
            ConnectionLog.shared.info(.lifecycle, "Authenticated with \(base.host ?? base.absoluteString)")
            // PiKVM normally returns Set-Cookie; libsoup's in-memory jar carries it
            // into both upgrades automatically. GLKVM can return a JSON token instead.
            openJanus()
            openHID()
        case "open":
            if telemetry.sessionConnectedAt == nil { telemetry.sessionConnectedAt = Date() }
            ConnectionLog.shared.info(.signaling, "Janus signaling connected")
            perform(signaling.begin())
        case "ws":
            lastMessage = Date()
            do { perform(try signaling.receive(Data(text.utf8))) }
            catch { fail(error.localizedDescription) }
        case "answer": perform([signaling.answer(text)])
        case "ice": perform([signaling.candidate(line: number, sdp: text)])
        case "frame":
            receivedFrame = true
            if telemetry.sessionConnectedAt == nil { telemetry.sessionConnectedAt = Date() }
            ConnectionLog.shared.info(.stream, "First WebRTC video frame received")
            onStatus(hidReady ? "Connected" : "Connected · View only")
            onFrame()
        case "hid-open":
            hidReady = true
            telemetry.hidLink = .connected
            lastPing = Date()
            lastPingSentAt = Date()
            ol_native_hid_text(engine, HIDFrame.ping)
            applyCursor()
            ConnectionLog.shared.info(.hid, "HID WebSocket connected")
            if receivedFrame { onStatus("Connected") }
            onInputChanged()
            onTelemetryChanged()
        case "hid":
            let data = Data(text.utf8)
            if telemetry.applyWebSocketEvent(data), let sent = lastPingSentAt {
                telemetry.hidRoundTripMs = max(1, Int((Date().timeIntervalSince(sent) * 1000).rounded()))
                lastPingSentAt = nil
            }
            if let absolute = HIDState.mouseAbsolute(data), absolute != mouseAbsolute {
                mouseAbsolute = absolute
                lastPoint = nil; lastAbsolute = nil
                applyCursor()
                onInputChanged()
            }
            onTelemetryChanged()
        case "hid-closed":
            guard hidReady || base != nil else { return }
            hidReady = false
            telemetry.hidLink = .disconnected
            keys.removeAll(); buttons.removeAll()
            ConnectionLog.shared.warning(.hid, "HID unavailable: \(text)")
            onNotice("Keyboard and mouse are unavailable: \(text)")
            if receivedFrame { onStatus("Connected · View only") }
            onInputChanged()
            onTelemetryChanged()
        case "stats":
            telemetry.applyNativeStatsJSON(Data(text.utf8))
            onTelemetryChanged()
        default: break
        }
    }

    // MARK: Keyboard and mouse

    func capture() { ol_native_focus(engine, 1) }
    func releaseCapture() { ol_native_focus(engine, 0) }

    func setMouseAbsolute(_ absolute: Bool) {
        guard mouseAbsolute != absolute else { return }
        mouseAbsolute = absolute
        lastPoint = nil; lastAbsolute = nil
        applyCursor()
        onInputChanged()
    }

    func updateCursorVisibility(_ show: Bool) {
        showRemoteCursor = show
        applyCursor()
    }

    func sendShortcut(_ names: [String]) {
        guard hidReady else { onNotice("Keyboard input is not connected."); return }
        for name in names { send(HIDFrame.key(name, pressed: true)) }
        for name in names.reversed() { send(HIDFrame.key(name, pressed: false)) }
    }

    func releaseInputs() {
        guard hidReady, engine != nil else { keys.removeAll(); buttons.removeAll(); return }
        // KVMD ignores an empty key name, so release each held key explicitly.
        for key in keys.reversed() { send(HIDFrame.key(key, pressed: false)) }
        for button in buttons { send(HIDFrame.mouseButton(button, pressed: false)) }
        keys.removeAll(); buttons.removeAll()
    }

    private func send(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { ol_native_hid_send(engine, $0.baseAddress, Int32($0.count)) }
    }

    private func applyCursor() {
        // The remote cursor is part of the video; hide the local one in relative mode or when hidden.
        let hide = (hidReady && !mouseAbsolute) || !showRemoteCursor
        ol_native_cursor(engine, hide ? "none" : "default")
    }

    private func input(_ kind: Int, _ code: Int, _ x: Double, _ y: Double) {
        guard !stopped else { return }
        switch kind {
        case OL_INPUT_FOCUS_IN:
            captured = true; onInputChanged()
        case OL_INPUT_FOCUS_OUT:
            releaseInputs(); releaseArmed = false
            captured = false; onInputChanged()
        case OL_INPUT_KEY_DOWN:
            guard hidReady, keyboardControlEnabled, let name = HIDKeyMap.code(hardwareKeycode: code), !keys.contains(name) else { return }
            keys.append(name)
            releaseArmed = Set(keys) == ["ControlLeft", "AltLeft"] || (releaseArmed && Set(keys).isSubset(of: ["ControlLeft", "AltLeft"]))
            send(HIDFrame.key(name, pressed: true))
        case OL_INPUT_KEY_UP:
            guard let name = HIDKeyMap.code(hardwareKeycode: code), let index = keys.firstIndex(of: name) else { return }
            keys.remove(at: index)
            send(HIDFrame.key(name, pressed: false))
            if releaseArmed && keys.isEmpty { releaseArmed = false; releaseCapture() }
        case OL_INPUT_BUTTON_DOWN, OL_INPUT_BUTTON_UP:
            guard hidReady, mouseControlEnabled, let name = HIDFrame.buttonName(gdkButton: code) else { return }
            let down = kind == OL_INPUT_BUTTON_DOWN
            if down {
                move(x, y, force: true)
                buttons.insert(name)
            } else if buttons.remove(name) == nil { return }
            send(HIDFrame.mouseButton(name, pressed: down))
        case OL_INPUT_MOTION:
            guard hidReady, mouseControlEnabled else { return }
            move(x, y, force: false)
        case OL_INPUT_SCROLL:
            guard hidReady, mouseControlEnabled else { return }
            scroll.x += x; scroll.y += y
            let whole = (x: scroll.x.rounded(.towardZero), y: scroll.y.rounded(.towardZero))
            scroll.x -= whole.x; scroll.y -= whole.y
            var gx = whole.x, gy = whole.y
            if reverseScrolling == "VERTICAL" || reverseScrolling == "BOTH" { gy = -gy }
            if reverseScrolling == "HORIZONTAL" || reverseScrolling == "BOTH" { gx = -gx }
            if let delta = HIDFrame.wheelDelta(gtkDX: gx, gtkDY: gy) { send(HIDFrame.wheel(dx: delta.dx, dy: delta.dy)) }
        default: break
        }
    }

    private func move(_ x: Double, _ y: Double, force: Bool) {
        if mouseAbsolute {
            var width = 0.0, height = 0.0, videoWidth = 0.0, videoHeight = 0.0
            ol_native_geometry(engine, &width, &height, &videoWidth, &videoHeight)
            guard let point = VideoGeometry.absolute(x: x, y: y, widgetWidth: width, widgetHeight: height,
                                                     videoWidth: videoWidth, videoHeight: videoHeight) else { return }
            if !force, let last = lastAbsolute, last == point { return }
            lastAbsolute = point
            send(HIDFrame.mouseMove(x: point.x, y: point.y))
        } else {
            defer { lastPoint = (x, y) }
            guard let last = lastPoint else { return }
            let dx = Int(((x - last.x) * relativeSensitivity).rounded())
            let dy = Int(((y - last.y) * relativeSensitivity).rounded())
            for frame in HIDFrame.mouseRelative(dx: dx, dy: dy) { send(frame) }
        }
    }

    // MARK: Screenshot & VAAPI Recording

    enum CaptureError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let msg) = self { return msg }; return nil }
    }

    static func probeVAAPI(preferredDevice: String = "") -> VAAPIProbeStatus {
        guard let raw = ol_vaapi_probe(preferredDevice) else { return VAAPIProbeStatus() }
        let json = String(cString: raw)
        g_free(raw)
        return (try? JSONDecoder().decode(VAAPIProbeStatus.self, from: Data(json.utf8))) ?? VAAPIProbeStatus()
    }

    func saveScreenshot(to url: URL) throws {
        guard let engine else { throw CaptureError.failed("No active video session.") }
        var errPtr: UnsafeMutablePointer<CChar>?
        let ok = ol_native_screenshot(engine, url.path, &errPtr)
        if ok == 0 {
            let msg = errPtr.map { String(cString: $0) } ?? "Screenshot failed."
            if let errPtr { g_free(errPtr) }
            throw CaptureError.failed(msg)
        }
        ConnectionLog.shared.info(.stream, "Saved screenshot \(url.lastPathComponent)")
    }

    func startRecording(to url: URL, codec: RecordingVideoCodec, vaapiDevice: String = "") throws -> String {
        guard let engine else { throw CaptureError.failed("No active video session.") }
        var backendPtr: UnsafeMutablePointer<CChar>?
        var errPtr: UnsafeMutablePointer<CChar>?
        let ok = ol_native_record_start(engine, url.path, codec == .hevc ? 1 : 0, vaapiDevice, &backendPtr, &errPtr)
        if ok == 0 {
            let msg = errPtr.map { String(cString: $0) } ?? "Could not start recording."
            if let errPtr { g_free(errPtr) }
            if let backendPtr { g_free(backendPtr) }
            throw CaptureError.failed(msg)
        }
        let backend = backendPtr.map { String(cString: $0) } ?? "VAAPI"
        if let backendPtr { g_free(backendPtr) }
        ConnectionLog.shared.info(.stream, "Started recording \(url.lastPathComponent) (\(backend))")
        return backend
    }

    func stopRecording() throws -> (duration: Double, frames: Int) {
        guard let engine else { throw CaptureError.failed("No active video session.") }
        var duration = 0.0
        var frames: Int32 = 0
        var errPtr: UnsafeMutablePointer<CChar>?
        let ok = ol_native_record_stop(engine, &duration, &frames, &errPtr)
        if ok == 0 {
            let msg = errPtr.map { String(cString: $0) } ?? "Recording failed to finalize."
            if let errPtr { g_free(errPtr) }
            throw CaptureError.failed(msg)
        }
        ConnectionLog.shared.info(.stream, "Finished recording (\(Int(frames)) frames, \(String(format: "%.1fs", duration)))")
        return (duration, Int(frames))
    }

    // MARK: Authenticated Device HTTP API

    func requestData(
        method: String = "GET",
        path: String,
        query: [(String, String)] = [],
        contentType: String? = nil,
        body: Data? = nil,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        guard !stopped, let engine, let base else {
            completion(.failure(CaptureError.failed("Not connected to a device.")))
            return
        }
        let url = KVMAPIEndpoint.url(base, path: path, query: query)
        let box = Unmanaged.passRetained(HTTPCompletionBox { status, data, error in
            if let error {
                completion(.failure(CaptureError.failed(error)))
                return
            }
            guard (200...299).contains(status) else {
                let message = KVMAPIEndpoint.extractErrorMessage(data, status: status)
                completion(.failure(CaptureError.failed(message)))
                return
            }
            completion(.success(data))
        }).toOpaque()

        let cb: OLNativeHTTPResponse = { status, ptr, len, errPtr, ctx in
            let handler = Unmanaged<HTTPCompletionBox>.fromOpaque(ctx!).takeRetainedValue()
            let data = (ptr != nil && len > 0) ? Data(bytes: ptr!, count: Int(len)) : Data()
            let err = errPtr.map { String(cString: $0) }
            handler.run(Int(status), data, err)
        }

        if let body, !body.isEmpty {
            body.withUnsafeBytes { raw in
                let basePtr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
                ol_native_request(engine, method, url.absoluteString, contentType, basePtr, Int32(body.count), cb, box)
            }
        } else {
            ol_native_request(engine, method, url.absoluteString, contentType, nil, 0, cb, box)
        }
    }

    func requestJSON<T: Decodable>(
        method: String = "GET",
        path: String,
        query: [(String, String)] = [],
        contentType: String? = nil,
        body: Data? = nil,
        type: T.Type,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        requestData(method: method, path: path, query: query, contentType: contentType, body: body) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let data):
                do {
                    let wrapped = try JSONDecoder().decode(KVMResponse<T>.self, from: data)
                    completion(.success(wrapped.result))
                } catch {
                    if let direct = try? JSONDecoder().decode(T.self, from: data) {
                        completion(.success(direct))
                    } else {
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    func requestEmpty(
        method: String = "POST",
        path: String,
        query: [(String, String)] = [],
        contentType: String? = "application/x-www-form-urlencoded",
        body: Data? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        requestData(method: method, path: path, query: query, contentType: contentType, body: body) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success: completion(.success(()))
            }
        }
    }
}
