import Foundation
import CDesktop
import CNative
import OverlookCore

/// All state is confined to the GLib/GTK thread. The C media adapter marshals
/// streaming-thread callbacks onto that loop before calling into Swift.
final class NativeSession {
    struct Certificate { let key: String; let sha256: String; let reason: String }
    private enum Stage { case idle, login, janus }

    private var engine: OpaquePointer!
    private var signaling = JanusSignaling()
    private var timer: UInt32 = 0
    private var base: URL?
    private var credentials: String?
    private var stage = Stage.idle
    private var started = Date()
    private var lastMessage = Date()
    private var lastKeepalive = Date()
    private var lastPing = Date()
    private var receivedFrame = false
    private var stopped = false
    private var awaitingTrust = false

    private var hidReady = false
    private(set) var mouseAbsolute = true
    private(set) var captured = false
    private var keys: [String] = []
    private var buttons: Set<String> = []
    private var lastPoint: (x: Double, y: Double)?
    private var lastAbsolute: (x: Int, y: Int)?
    private var scroll = (x: 0.0, y: 0.0)
    private var releaseArmed = false

    var onStatus: (String) -> Void = { _ in }
    var onNotice: (String) -> Void = { _ in }
    var onFrame: () -> Void = {}
    var onFailure: (String) -> Void = { _ in }
    var onCertificate: (Certificate) -> Void = { _ in }
    var onInputChanged: () -> Void = {}
    var picture: UnsafeMutableRawPointer { ol_native_picture(engine)! }
    var inputAvailable: Bool { hidReady }

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
        ol_native_socket(engine, KVMRequest.endpoint(base, path: "janus/ws", websocket: true).absoluteString, origin)
    }
    private func openHID() {
        guard let base else { return }
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
            ol_native_hid_text(engine, HIDFrame.ping); lastPing = Date()
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
            // PiKVM normally returns Set-Cookie; libsoup's in-memory jar carries it
            // into both upgrades automatically. GLKVM can return a JSON token instead.
            openJanus()
            openHID()
        case "open": perform(signaling.begin())
        case "ws":
            lastMessage = Date()
            do { perform(try signaling.receive(Data(text.utf8))) }
            catch { fail(error.localizedDescription) }
        case "answer": perform([signaling.answer(text)])
        case "ice": perform([signaling.candidate(line: number, sdp: text)])
        case "frame":
            receivedFrame = true
            onStatus(hidReady ? "Connected" : "Connected · View only")
            onFrame()
        case "hid-open":
            hidReady = true
            lastPing = Date()
            applyCursor()
            if receivedFrame { onStatus("Connected") }
            onInputChanged()
        case "hid":
            if let absolute = HIDState.mouseAbsolute(Data(text.utf8)), absolute != mouseAbsolute {
                mouseAbsolute = absolute
                lastPoint = nil; lastAbsolute = nil
                applyCursor()
                onInputChanged()
            }
        case "hid-closed":
            guard hidReady || base != nil else { return }
            hidReady = false
            keys.removeAll(); buttons.removeAll()
            onNotice("Keyboard and mouse are unavailable: \(text)")
            if receivedFrame { onStatus("Connected · View only") }
            onInputChanged()
        default: break
        }
    }

    // MARK: Keyboard and mouse

    func capture() { ol_native_focus(engine, 1) }
    func releaseCapture() { ol_native_focus(engine, 0) }

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
        // The remote cursor is part of the video; hide the local one in relative mode.
        ol_native_cursor(engine, hidReady && !mouseAbsolute ? "none" : "default")
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
            guard hidReady, let name = HIDKeyMap.code(hardwareKeycode: code), !keys.contains(name) else { return }
            keys.append(name)
            releaseArmed = Set(keys) == ["ControlLeft", "AltLeft"] || (releaseArmed && Set(keys).isSubset(of: ["ControlLeft", "AltLeft"]))
            send(HIDFrame.key(name, pressed: true))
        case OL_INPUT_KEY_UP:
            guard let name = HIDKeyMap.code(hardwareKeycode: code), let index = keys.firstIndex(of: name) else { return }
            keys.remove(at: index)
            send(HIDFrame.key(name, pressed: false))
            if releaseArmed && keys.isEmpty { releaseArmed = false; releaseCapture() }
        case OL_INPUT_BUTTON_DOWN, OL_INPUT_BUTTON_UP:
            guard hidReady, let name = HIDFrame.buttonName(gdkButton: code) else { return }
            let down = kind == OL_INPUT_BUTTON_DOWN
            if down {
                move(x, y, force: true)
                buttons.insert(name)
            } else if buttons.remove(name) == nil { return }
            send(HIDFrame.mouseButton(name, pressed: down))
        case OL_INPUT_MOTION:
            guard hidReady else { return }
            move(x, y, force: false)
        case OL_INPUT_SCROLL:
            guard hidReady else { return }
            scroll.x += x; scroll.y += y
            let whole = (x: scroll.x.rounded(.towardZero), y: scroll.y.rounded(.towardZero))
            scroll.x -= whole.x; scroll.y -= whole.y
            if let delta = HIDFrame.wheelDelta(gtkDX: whole.x, gtkDY: whole.y) { send(HIDFrame.wheel(dx: delta.dx, dy: delta.dy)) }
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
            for frame in HIDFrame.mouseRelative(dx: Int((x - last.x).rounded()), dy: Int((y - last.y).rounded())) { send(frame) }
        }
    }
}
