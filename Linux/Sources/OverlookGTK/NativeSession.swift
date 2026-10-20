import Foundation
import CDesktop
import CNative
import OverlookCore

/// All state is confined to the GLib/GTK thread. The C media adapter marshals
/// streaming-thread callbacks onto that loop before calling into Swift.
final class NativeSession {
    private var engine: OpaquePointer!
    private var signaling = JanusSignaling()
    private var timer: UInt32 = 0
    private var base: URL?
    private var started = Date()
    private var lastMessage = Date()
    private var lastKeepalive = Date()
    private var receivedFrame = false
    private var stopped = false
    private var loginPending = false
    private let onStatus: (String) -> Void
    private let onFrame: () -> Void
    private let onFailure: () -> Void
    var picture: UnsafeMutableRawPointer { ol_native_picture(engine)! }

    init(onStatus: @escaping (String) -> Void, onFrame: @escaping () -> Void, onFailure: @escaping () -> Void) {
        self.onStatus = onStatus; self.onFrame = onFrame; self.onFailure = onFailure
        engine = ol_native_new({ event, text, number, context in
            let owner = Unmanaged<NativeSession>.fromOpaque(context!).takeUnretainedValue()
            owner.event(String(cString: event!), text: String(cString: text!), number: Int(number))
        }, Unmanaged.passUnretained(self).toOpaque())
        timer = g_timeout_add_seconds(1, { context in
            let owner = Unmanaged<NativeSession>.fromOpaque(context!).takeUnretainedValue()
            owner.tick()
            return 1
        }, Unmanaged.passUnretained(self).toOpaque())
    }
    deinit { stop() }
    func connect(base: URL, username: String, password: String, otp: String) {
        self.base = base
        loginPending = true
        onStatus("Authenticating with the KVM…")
        ol_native_http(engine, "POST", KVMRequest.endpoint(base, path: "api/auth/login").absoluteString,
                       KVMRequest.form(["user": username, "passwd": password + otp]))
    }
    func test(h264: Bool = false) { onStatus("Testing native \(h264 ? "H.264" : "VP8") WebRTC over local ICE/DTLS/SRTP…"); ol_native_test(engine, h264 ? 1 : 0) }
    func stop() {
        guard !stopped else { return }
        stopped = true
        if timer != 0 { g_source_remove(timer); timer = 0 }
        if signaling.sessionID != nil { perform([signaling.destroy()]) }
        if let engine { ol_native_close(engine) }
        engine = nil
    }
    private func fail(_ text: String) {
        onStatus("Native connection failed: \(text)")
        stop()
        onFailure()
    }
    private func tick() {
        guard !stopped else { return }
        if !receivedFrame && Date().timeIntervalSince(started) > 30 {
            fail("No video frame arrived within 30 seconds. Check credentials, certificates, codecs, and Janus availability."); return
        }
        if signaling.sessionID != nil {
            if Date().timeIntervalSince(lastMessage) > 45 { fail("Janus stopped responding."); return }
            if Date().timeIntervalSince(lastKeepalive) >= 15 {
                perform([signaling.keepalive()]); lastKeepalive = Date()
            }
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
                onStatus("Negotiating native WebRTC video…")
                ol_native_offer(engine, sdp)
            case .candidate(let line, let text): ol_native_ice(engine, UInt32(line), text)
            case .connected: onStatus("WebRTC connected. Waiting for the first decoded frame…")
            }
        }
    }
    private func event(_ event: String, text: String, number: Int) {
        guard !stopped else { return }
        switch event {
        case "error": fail(text)
        case "http":
            guard loginPending, let base else { return }
            loginPending = false
            guard (200...299).contains(number) else { fail("Authentication returned HTTP \(number)."); return }
            let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            if object?["ok"] as? Bool == false { fail("The device rejected authentication."); return }
            if let result = object?["result"] as? [String: Any], let token = result["token"] as? String {
                ol_native_cookie(engine, base.absoluteString, token)
            }
            // PiKVM normally returns Set-Cookie; libsoup's in-memory jar carries it
            // into the upgrade automatically. GLKVM can return a JSON token instead.
            var origin = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            origin.path = ""; origin.query = nil; origin.fragment = nil
            onStatus("Opening Janus signaling…")
            ol_native_socket(engine, KVMRequest.endpoint(base, path: "janus/ws", websocket: true).absoluteString, origin.url!.absoluteString)
        case "open": perform(signaling.begin())
        case "ws":
            lastMessage = Date()
            do { perform(try signaling.receive(Data(text.utf8))) }
            catch { fail(error.localizedDescription) }
        case "answer": perform([signaling.answer(text)])
        case "ice": perform([signaling.candidate(line: number, sdp: text)])
        case "frame": receivedFrame = true; onStatus("Native WebRTC video • GStreamer → GTK4 • View-only preview"); onFrame()
        default: break
        }
    }
}
