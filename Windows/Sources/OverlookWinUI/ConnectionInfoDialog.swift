import Foundation
import CNativeWin
import OverlookCore

final class ConnectionInfoDialog {
    let dialog: OLWidgetPtr

    // Video rows
    private let statusRow: OLWidgetPtr
    private let transportRow: OLWidgetPtr
    private let decoderRow: OLWidgetPtr
    private let resolutionRow: OLWidgetPtr
    private let fpsRow: OLWidgetPtr
    private let bitrateRow: OLWidgetPtr
    private let framesRow: OLWidgetPtr
    private let droppedRow: OLWidgetPtr
    private let bytesRow: OLWidgetPtr

    // HID & Audio rows
    private let hidStatusRow: OLWidgetPtr
    private let hidLatencyRow: OLWidgetPtr
    private let hidPacketsRow: OLWidgetPtr
    private let captureModeRow: OLWidgetPtr
    private let mouseModeRow: OLWidgetPtr
    private let audioRow: OLWidgetPtr

    // Security & Session rows
    private let deviceRow: OLWidgetPtr
    private let uptimeRow: OLWidgetPtr
    private let certRow: OLWidgetPtr
    private let vaapiRow: OLWidgetPtr

    private weak var session: NativeSession?
    private var device: Device?
    private var certRecord: TrustedCertificateRecord?
    private var timerId: UInt32 = 0
    private var selfPtr: UnsafeMutableRawPointer?

    init(session: NativeSession?, device: Device?, certificates: CertificateStore) {
        self.session = session
        self.device = device
        if let device {
            self.certRecord = certificates.record(for: device.hostPort)
        }

        dialog = ad_pref_dialog_new("Connection Information")
        let page = ad_pref_page_new("Diagnostics", "dialog-information-symbolic")

        // Group 1: Video Stream
        let videoGroup = ad_pref_group("Video Stream", "Live GStreamer pipeline and decoder telemetry")
        statusRow = ad_action_row("Stream Status", "Idle")
        transportRow = ad_action_row("Transport Protocol", "—")
        decoderRow = ad_action_row("Hardware / Software Decoder", "—")
        resolutionRow = ad_action_row("Video Resolution", "—")
        fpsRow = ad_action_row("Frame Rate", "0.0 fps")
        bitrateRow = ad_action_row("Bitrate", "0 kbps")
        framesRow = ad_action_row("Decoded Frames", "0 (0 keyframes)")
        droppedRow = ad_action_row("Dropped / QoS Frames", "0")
        bytesRow = ad_action_row("Total Video Data", "0 B")

        for row in [statusRow, transportRow, decoderRow, resolutionRow, fpsRow, bitrateRow, framesRow, droppedRow, bytesRow] {
            ad_pref_add(videoGroup, row)
        }
        ad_pref_page_add(page, videoGroup)

        // Group 2: HID & Audio
        let hidGroup = ad_pref_group("HID Input & Audio", "Keyboard, mouse, and audio stream metrics")
        hidStatusRow = ad_action_row("HID WebSocket", "Disconnected")
        hidLatencyRow = ad_action_row("HID Send Latency", "—")
        hidPacketsRow = ad_action_row("HID Frames Sent", "0 (0 errors)")
        captureModeRow = ad_action_row("Keyboard Capture", "—")
        mouseModeRow = ad_action_row("Mouse Mode", "—")
        audioRow = ad_action_row("Audio Stream", "—")

        for row in [hidStatusRow, hidLatencyRow, hidPacketsRow, captureModeRow, mouseModeRow, audioRow] {
            ad_pref_add(hidGroup, row)
        }
        ad_pref_page_add(page, hidGroup)

        // Group 3: Session & TLS Security
        let secGroup = ad_pref_group("Session & Security", "Device identity, uptime, and pinned TLS certificate")
        deviceRow = ad_action_row("Device", device?.displayName ?? "No device selected")
        uptimeRow = ad_action_row("Session Uptime", "—")
        certRow = ad_action_row("Pinned TLS Certificate (SHA-256)", "None")
        vaapiRow = ad_action_row("Hardware Video Encoders (MF / NVENC / AMF / QSV)", NativeSession.probeVAAPI(preferredDevice: session?.config.vaapiDevice ?? ""))

        let copyButton = ad_button("Copy Diagnostics", nil)
        let copyRow = ad_action_row("Export Report", "Copy full diagnostic snapshot to clipboard")
        ad_row_add_suffix(copyRow, copyButton)
        ad_row_activatable(copyRow, copyButton)

        for row in [deviceRow, uptimeRow, certRow, vaapiRow, copyRow] {
            ad_pref_add(secGroup, row)
        }
        ad_pref_page_add(page, secGroup)

        ad_pref_dialog_add(dialog, page)

        let rawSelf = Unmanaged.passRetained(self).toOpaque()
        self.selfPtr = rawSelf

        ol_signal_connect(copyButton, "clicked", { _, ctx in
            guard let ctx else { return }
            Unmanaged<ConnectionInfoDialog>.fromOpaque(ctx).takeUnretainedValue().copyDiagnostics()
        }, rawSelf)

        refresh()

        timerId = g_timeout_add(500, { ctx -> Int32 in
            guard let ctx else { return G_SOURCE_REMOVE }
            let dlg = Unmanaged<ConnectionInfoDialog>.fromOpaque(ctx).takeUnretainedValue()
            dlg.refresh()
            return G_SOURCE_CONTINUE
        }, rawSelf)
    }

    func present(over parent: OLWidgetPtr) {
        ad_dialog_present(dialog, parent)
    }

    func refresh() {
        session?.pollStats()
        let stats = session?.stats ?? NativeStats()
        let cfg = session?.config ?? CaptureConfig()

        ad_action_set_subtitle(statusRow, stats.status)
        ad_action_set_subtitle(transportRow, stats.transport)
        ad_action_set_subtitle(decoderRow, stats.decoderBackend)

        if stats.videoWidth > 0 && stats.videoHeight > 0 {
            ad_action_set_subtitle(resolutionRow, "\(stats.videoWidth) × \(stats.videoHeight)")
        } else {
            ad_action_set_subtitle(resolutionRow, "Waiting for stream")
        }

        ad_action_set_subtitle(fpsRow, String(format: "%.1f fps (cap: %d fps)", stats.fps, cfg.maxFPS))
        if stats.bitrateKbps >= 1000 {
            ad_action_set_subtitle(bitrateRow, String(format: "%.2f Mbps (%.0f kbps)", stats.bitrateKbps / 1000.0, stats.bitrateKbps))
        } else {
            ad_action_set_subtitle(bitrateRow, String(format: "%.0f kbps", stats.bitrateKbps))
        }

        ad_action_set_subtitle(framesRow, "\(stats.frames) (\(stats.keyFrames) keyframes)")
        ad_action_set_subtitle(droppedRow, "\(stats.droppedFrames)")
        ad_action_set_subtitle(bytesRow, Self.formatBytes(stats.bytesReceived))

        ad_action_set_subtitle(hidStatusRow, stats.hidReady ? "Ready (Active)" : "Not ready")
        if stats.hidLatencyMs > 0 {
            ad_action_set_subtitle(hidLatencyRow, String(format: "%.2f ms", stats.hidLatencyMs))
        } else {
            ad_action_set_subtitle(hidLatencyRow, "—")
        }
        ad_action_set_subtitle(hidPacketsRow, "\(stats.hidSent) (\(stats.hidErrors) errors)")
        let capText = (session?.keyboardCaptured ?? false)
            ? "Captured (Right Ctrl + Right Alt or Scroll Lock to release)"
            : "Released (Host OS receives shortcuts)"
        ad_action_set_subtitle(captureModeRow, capText)
        ad_action_set_subtitle(mouseModeRow, "\(cfg.mouseMode.description) (sensitivity \(String(format: "%.1f×", cfg.relativeSensitivity)))")

        if !cfg.enableAudio {
            ad_action_set_subtitle(audioRow, "Disabled in settings")
        } else if stats.audioActive {
            ad_action_set_subtitle(audioRow, String(format: "Active (volume %.0f%%)", cfg.audioVolume * 100))
        } else {
            ad_action_set_subtitle(audioRow, "Standby (no audio track negotiated)")
        }

        if let device {
            ad_action_set_subtitle(deviceRow, "\(device.displayName) (\(device.hostPort))")
        }
        ad_action_set_subtitle(uptimeRow, Self.formatUptime(stats.sessionUptimeSeconds))

        if let certRecord {
            ad_action_set_subtitle(certRow, "\(certRecord.fingerprint) (trusted \(certRecord.trustedAt))")
        } else {
            ad_action_set_subtitle(certRow, "Not pinned / system CA")
        }
    }

    private func copyDiagnostics() {
        let stats = session?.stats ?? NativeStats()
        let cfg = session?.config ?? CaptureConfig()
        let report = """
        Overlook Windows Diagnostics
        ============================
        Device: \(device?.displayName ?? "None") (\(device?.hostPort ?? "—"))
        Status: \(stats.status)
        Transport: \(stats.transport)
        Decoder: \(stats.decoderBackend)
        Resolution: \(stats.videoWidth)x\(stats.videoHeight)
        FPS: \(String(format: "%.1f", stats.fps)) (max \(cfg.maxFPS))
        Bitrate: \(String(format: "%.0f kbps", stats.bitrateKbps))
        Frames: \(stats.frames) (keyframes: \(stats.keyFrames), dropped: \(stats.droppedFrames))
        Video Bytes: \(Self.formatBytes(stats.bytesReceived))
        HID Ready: \(stats.hidReady) (sent: \(stats.hidSent), errors: \(stats.hidErrors), latency: \(String(format: "%.2f ms", stats.hidLatencyMs)))
        Mouse Mode: \(cfg.mouseMode.description)
        Keyboard Captured: \(session?.keyboardCaptured ?? false)
        Uptime: \(Self.formatUptime(stats.sessionUptimeSeconds))
        Certificate SHA-256: \(certRecord?.fingerprint ?? "None")
        """
        ol_clipboard_set(dialog, report)
        ad_action_set_subtitle(statusRow, "\(stats.status) — Copied to clipboard")
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1024.0
        if kb < 1024.0 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024.0
        if mb < 1024.0 { return String(format: "%.2f MB", mb) }
        let gb = mb / 1024.0
        return String(format: "%.2f GB", gb)
    }

    static func formatUptime(_ seconds: Double) -> String {
        guard seconds > 0 else { return "Not connected" }
        let total = Int(seconds)
        let hrs = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hrs > 0 {
            return String(format: "%02d:%02d:%02d", hrs, mins, secs)
        }
        return String(format: "%02d:%02d", mins, secs)
    }
}
