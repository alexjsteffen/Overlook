import Foundation

public struct StreamTelemetry: Equatable, Sendable {
    public enum HIDLink: String, Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting
    }

    // Device & HID
    public var hidLink: HIDLink = .disconnected
    public var hidRoundTripMs: Int?
    public var hidQueueDepth: Int = 0
    public var hidUSBConnected: Bool?
    public var capsLock: Bool = false
    public var numLock: Bool = false
    public var scrollLock: Bool = false
    public var powerLED: Bool?
    public var hddLED: Bool?

    // HDMI source
    public var hdmiOnline: Bool?
    public var hdmiResolution: String?
    public var hdmiCapturedFps: Int?
    public var hdmiDesiredFps: Int?

    // Session
    public var sessionConnectedAt: Date?
    public var sessionReconnectCount: Int = 0
    public var sessionLastReconnectReason: String?
    public var sessionLastReconnectAt: Date?

    // WebRTC stream
    public var videoWidth: Int?
    public var videoHeight: Int?
    public var videoKbps: Int?
    public var videoFps: Int?
    public var videoJitterMs: Int?
    public var videoPacketsLost: Int?
    public var videoFramesDropped: Int?
    public var videoPliCount: Int?
    public var videoNackCount: Int?
    public var videoRoundTripTimeMs: Int?
    public var videoCodec: String?
    public var networkPath: String?
    public var networkRemoteAddress: String?

    public init() {}

    public static let empty = StreamTelemetry()

    public mutating func clearStreamStats() {
        videoWidth = nil
        videoHeight = nil
        videoKbps = nil
        videoFps = nil
        videoJitterMs = nil
        videoPacketsLost = nil
        videoFramesDropped = nil
        videoPliCount = nil
        videoNackCount = nil
        videoRoundTripTimeMs = nil
        videoCodec = nil
        networkPath = nil
        networkRemoteAddress = nil
    }

    public mutating func clearDevice() {
        hidLink = .disconnected
        hidRoundTripMs = nil
        hidQueueDepth = 0
        hidUSBConnected = nil
        capsLock = false
        numLock = false
        scrollLock = false
        powerLED = nil
        hddLED = nil
        hdmiOnline = nil
        hdmiResolution = nil
        hdmiCapturedFps = nil
        hdmiDesiredFps = nil
    }

    public mutating func clearSession() {
        sessionConnectedAt = nil
        sessionReconnectCount = 0
        sessionLastReconnectReason = nil
        sessionLastReconnectAt = nil
    }

    // MARK: Formatting

    public static func msText(_ value: Int?) -> String {
        value.map { "\($0) ms" } ?? "—"
    }

    public static func countText(_ value: Int?, unit: String) -> String {
        guard let value else { return "—" }
        return "\(value) \(unit)\(value == 1 ? "" : "s")"
    }

    public var hidLinkText: String {
        let link: String
        switch hidLink {
        case .disconnected: link = "Disconnected"
        case .connecting: link = "Connecting…"
        case .connected: link = "Connected"
        case .reconnecting: link = "Reconnecting…"
        }
        var parts = [link]
        if hidLink == .connected {
            parts.append("queue \(hidQueueDepth)")
        }
        if let usb = hidUSBConnected {
            parts.append(usb ? "USB up" : "USB down")
        }
        return parts.joined(separator: " · ")
    }

    public var hidRttText: String {
        hidRoundTripMs.map { "\($0) ms" } ?? "—"
    }

    public var keyboardLedsText: String {
        "CAPS: \(capsLock ? "On" : "Off") · NUM: \(numLock ? "On" : "Off") · SCROLL: \(scrollLock ? "On" : "Off")"
    }

    public var atxLedsText: String {
        guard powerLED != nil || hddLED != nil else { return "—" }
        let p = (powerLED == true) ? "On" : "Off"
        let h = (hddLED == true) ? "Active" : "Idle"
        return "Power: \(p) · HDD: \(h)"
    }

    public var hdmiText: String {
        guard let online = hdmiOnline else { return "—" }
        guard online else { return "No signal" }
        var parts: [String] = []
        if let resolution = hdmiResolution, !resolution.isEmpty {
            parts.append(resolution)
        }
        switch (hdmiCapturedFps, hdmiDesiredFps) {
        case (let captured?, let desired?) where captured != desired:
            parts.append("\(captured) fps (\(desired) wanted)")
        case (let captured?, _):
            parts.append("\(captured) fps")
        case (nil, let desired?):
            parts.append("\(desired) fps wanted")
        default:
            break
        }
        parts.append("signal")
        return parts.joined(separator: " · ")
    }

    public var videoText: String {
        let res: String = {
            if let w = videoWidth, let h = videoHeight, w > 0, h > 0 {
                return "\(w)x\(h)"
            }
            if let hdmi = hdmiResolution, !hdmi.isEmpty {
                return hdmi
            }
            return "—"
        }()
        let fpsText = videoFps.map { "\($0) fps" } ?? "— fps"
        let kbpsText = videoKbps.map { "\($0) kbps" } ?? "— kbps"
        return "\(res) · \(fpsText) · \(kbpsText)"
    }

    public var codecText: String {
        videoCodec ?? "—"
    }

    public var repairText: String {
        guard videoPliCount != nil || videoNackCount != nil else { return "—" }
        return "\(videoPliCount ?? 0) PLI · \(videoNackCount ?? 0) NACK"
    }

    public func sessionHistoryText(now: Date = Date()) -> String {
        guard let connectedAt = sessionConnectedAt else { return "Not connected" }
        var parts = ["Up \(Self.uptimeText(seconds: now.timeIntervalSince(connectedAt)))"]
        if sessionReconnectCount > 0 {
            parts.append("\(sessionReconnectCount) reconnect\(sessionReconnectCount == 1 ? "" : "s")")
            if let reason = sessionLastReconnectReason, !reason.isEmpty {
                parts.append("last: \(reason)")
            }
        }
        return parts.joined(separator: " · ")
    }

    public var compactHeaderSubtitle: String {
        var parts: [String] = []
        if let w = videoWidth, let h = videoHeight, w > 0, h > 0 {
            parts.append("\(w)x\(h)")
        } else if let res = hdmiResolution, !res.isEmpty {
            parts.append(res)
        }
        if let fps = videoFps {
            parts.append("\(fps) fps")
        }
        if let kbps = videoKbps, kbps > 0 {
            parts.append("\(kbps) kbps")
        }
        if let rtt = hidRoundTripMs {
            parts.append("\(rtt) ms RTT")
        }
        return parts.joined(separator: " · ")
    }

    public static func uptimeText(seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes < 1 { return "<1 min" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    /// Applies a JSON stats dictionary emitted by `CNative` `ol_native_poll_stats`.
    public mutating func applyNativeStatsJSON(_ data: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let w = obj["width"] as? Int, w > 0 { videoWidth = w }
        if let h = obj["height"] as? Int, h > 0 { videoHeight = h }
        if let fps = obj["fps"] as? Int { videoFps = fps }
        if let kbps = obj["kbps"] as? Int { videoKbps = kbps }
        if let jitter = obj["jitter_ms"] as? Int { videoJitterMs = jitter }
        if let lost = obj["packets_lost"] as? Int { videoPacketsLost = lost }
        if let pli = obj["pli_count"] as? Int { videoPliCount = pli }
        if let nack = obj["nack_count"] as? Int { videoNackCount = nack }
        if let rtt = obj["rtt_ms"] as? Int { videoRoundTripTimeMs = rtt }
        if let codec = obj["codec"] as? String, !codec.isEmpty { videoCodec = codec }
        if let path = obj["path"] as? String, !path.isEmpty { networkPath = path }
        if let remote = obj["remote"] as? String, !remote.isEmpty { networkRemoteAddress = remote }
    }

    /// Applies an event received on `/api/ws` (pong, hid/hid_state, streamer/streamer_state, atx/atx_state).
    /// Returns true if the event was a `pong`.
    @discardableResult
    public mutating func applyWebSocketEvent(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["event_type"] as? String else { return false }
        if type == "pong" {
            return true
        }
        let event = object["event"] as? [String: Any]
        if type == "hid" || type == "hid_state" {
            if let connected = event?["connected"] as? Bool {
                hidUSBConnected = connected
            } else if let online = event?["online"] as? Bool {
                hidUSBConnected = online
            }
            if let kb = event?["keyboard"] as? [String: Any],
               let leds = kb["leds"] as? [String: Any] {
                if let caps = leds["caps"] as? Bool { capsLock = caps }
                if let num = leds["num"] as? Bool { numLock = num }
                if let scroll = leds["scroll"] as? Bool { scrollLock = scroll }
            }
        } else if type == "streamer" || type == "streamer_state" {
            let streamer = (event?["streamer"] as? [String: Any]) ?? event
            if let source = streamer?["source"] as? [String: Any] {
                if let online = source["online"] as? Bool { hdmiOnline = online }
                if let capFps = source["captured_fps"] as? Int { hdmiCapturedFps = capFps }
                if let desFps = source["desired_fps"] as? Int { hdmiDesiredFps = desFps }
                if let res = source["resolution"] as? [String: Any],
                   let w = res["width"] as? Int,
                   let h = res["height"] as? Int, w > 0, h > 0 {
                    hdmiResolution = "\(w)x\(h)"
                }
            }
            if let h264 = streamer?["h264"] as? [String: Any] {
                if videoKbps == nil, let br = h264["bitrate"] as? Int { videoKbps = br }
                if videoCodec == nil, (h264["online"] as? Bool) == true { videoCodec = "H264" }
            }
        } else if type == "atx" || type == "atx_state" {
            if let leds = event?["leds"] as? [String: Any] {
                if let power = leds["power"] as? Bool { powerLED = power }
                if let hdd = leds["hdd"] as? Bool { hddLED = hdd }
            }
        }
        return false
    }
}
