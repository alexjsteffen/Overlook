import Foundation

/// Janus control protocol, independent of GTK, WebSockets and the media engine.
public struct JanusSignaling {
    public enum Action {
        case send([String: Any])
        case offer(String)
        case candidate(Int, String)
        case connected
    }
    public enum Failure: LocalizedError {
        case protocolError(String)
        public var errorDescription: String? { if case .protocolError(let text) = self { return text }; return nil }
    }
    public private(set) var sessionID: Int64?
    public private(set) var handleID: Int64?
    private var createTransaction: String?
    private var attachTransaction: String?
    public init() {}
    public mutating func begin() -> [Action] {
        let transaction = UUID().uuidString
        createTransaction = transaction
        return [.send(["janus": "create", "transaction": transaction])]
    }
    private func message(_ kind: String, handle: Bool = true, fields: [String: Any] = [:]) -> [String: Any] {
        var result = fields
        result["janus"] = kind
        result["transaction"] = UUID().uuidString
        if let sessionID { result["session_id"] = sessionID }
        if handle, let handleID { result["handle_id"] = handleID }
        return result
    }
    public func answer(_ sdp: String) -> Action {
        .send(message("message", fields: ["body": ["request": "start"], "jsep": ["type": "answer", "sdp": sdp]]))
    }
    public func candidate(line: Int, sdp: String) -> Action {
        // sdpMLineIndex is sufficient; do not invent an SDP mid for another track.
        .send(message("trickle", fields: ["candidate": ["candidate": sdp, "sdpMLineIndex": line]]))
    }
    public func keepalive() -> Action { .send(message("keepalive", handle: false)) }
    public func destroy() -> Action { .send(message("destroy", handle: false)) }

    public mutating func receive(_ data: Data) throws -> [Action] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["janus"] as? String else { throw Failure.protocolError("Invalid Janus message") }
        if kind == "error" {
            let error = object["error"] as? [String: Any]
            throw Failure.protocolError(error?["reason"] as? String ?? "Janus reported an error")
        }
        if let incoming = object["session_id"] as? Int64, let sessionID, incoming != sessionID { return [] }
        let transaction = object["transaction"] as? String
        // ACK means accepted for processing, not a create/attach result.
        if kind == "success", let transaction, transaction == createTransaction {
            guard let id = (object["data"] as? [String: Any])?["id"] as? Int64, id > 0 else {
                throw Failure.protocolError("Janus did not return a session ID")
            }
            sessionID = id; createTransaction = nil
            var attach = message("attach", handle: false, fields: ["plugin": "janus.plugin.ustreamer"])
            attachTransaction = UUID().uuidString
            attach["transaction"] = attachTransaction!
            return [.send(attach)]
        }
        if kind == "success", let transaction, transaction == attachTransaction {
            guard let id = (object["data"] as? [String: Any])?["id"] as? Int64, id > 0 else {
                throw Failure.protocolError("Janus did not return a plugin handle")
            }
            handleID = id; attachTransaction = nil
            return [.send(message("message", fields: ["body": ["request": "watch", "params": [
                "orientation": 0, "video": true, "audio": false, "mic": false, "camera": false
            ]] as [String: Any]]))]
        }
        if let sender = object["sender"] as? Int64, sender != handleID { return [] }
        if ["hangup", "detached", "timeout"].contains(kind) {
            throw Failure.protocolError(object["reason"] as? String ?? "Janus session ended (\(kind))")
        }
        if kind == "webrtcup" { return [.connected] }
        if kind == "trickle", let candidate = object["candidate"] as? [String: Any],
           let sdp = candidate["candidate"] as? String, let line = candidate["sdpMLineIndex"] as? Int, line >= 0, line <= 65535 {
            return [.candidate(line, sdp)]
        }
        if kind == "event" {
            if let plugin = object["plugindata"] as? [String: Any], let data = plugin["data"] as? [String: Any],
               let error = data["error"] as? String { throw Failure.protocolError(error) }
            if let jsep = object["jsep"] as? [String: Any], jsep["type"] as? String == "offer",
               let sdp = jsep["sdp"] as? String, !sdp.isEmpty, handleID != nil { return [.offer(sdp)] }
        }
        return []
    }
}

public enum KVMRequest {
    public static func form(_ fields: [String: String]) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return fields.keys.sorted().map { key in
            key.addingPercentEncoding(withAllowedCharacters: safe)! + "=" + fields[key]!.addingPercentEncoding(withAllowedCharacters: safe)!
        }.joined(separator: "&")
    }
    public static func endpoint(_ base: URL, path: String, websocket: Bool = false) -> URL {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        parts.path = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.path = "/" + ([parts.path, path].filter { !$0.isEmpty }.joined(separator: "/"))
        parts.query = nil; parts.fragment = nil
        if websocket { parts.scheme = base.scheme == "https" ? "wss" : "ws" }
        return parts.url!
    }
}
