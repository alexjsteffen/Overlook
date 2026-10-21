import Foundation
import CDesktop
import OverlookCore

final class ConnectionInfoController {
    unowned let desktop: Desktop
    private var dialog: UnsafeMutableRawPointer?
    private var timer: UInt32 = 0

    // Live rows
    private var statusRow: UnsafeMutableRawPointer?
    private var uptimeRow: UnsafeMutableRawPointer?
    private var hidLinkRow: UnsafeMutableRawPointer?
    private var hidRttRow: UnsafeMutableRawPointer?
    private var ledsRow: UnsafeMutableRawPointer?
    private var atxLedsRow: UnsafeMutableRawPointer?
    private var hdmiRow: UnsafeMutableRawPointer?
    private var videoRow: UnsafeMutableRawPointer?
    private var codecRow: UnsafeMutableRawPointer?
    private var jitterRow: UnsafeMutableRawPointer?
    private var lostRow: UnsafeMutableRawPointer?
    private var repairRow: UnsafeMutableRawPointer?
    private var iceRttRow: UnsafeMutableRawPointer?
    private var pathRow: UnsafeMutableRawPointer?
    private var remoteRow: UnsafeMutableRawPointer?
    private var vaapiRow: UnsafeMutableRawPointer?
    private var recRow: UnsafeMutableRawPointer?
    private var lastProblemRow: UnsafeMutableRawPointer?

    init(desktop: Desktop) {
        self.desktop = desktop
    }

    deinit {
        stopTimer()
    }

    private func stopTimer() {
        if timer != 0 {
            g_source_remove(timer)
            timer = 0
        }
    }

    func present() {
        if let dialog {
            refresh()
            ad_present(dialog, desktop.window)
            return
        }

        let pageBox = ol_box(1, 18)!
        ol_margin(pageBox, 18)

        // 1. Session Group
        let sessionGroup = ad_group("Session")!
        let hostText = desktop.host.isEmpty ? "Not Connected" : desktop.host
        let stateText: String = {
            switch desktop.mode {
            case .idle: return "Disconnected"
            case .native: return desktop.native?.receivedFrame == true ? "Connected (Native WebRTC)" : "Connecting…"
            case .web: return "Connected (Web Console)"
            }
        }()
        statusRow = ad_action_row(hostText, stateText)
        let actionBox = ol_box(0, 6)!
        ad_align(actionBox, alignFill, alignCenter)
        let reconnectBtn = ol_button("Reconnect")!
        ad_css(reconnectBtn, "flat")
        ad_sensitive(reconnectBtn, desktop.mode == .idle ? 0 : 1)
        on(reconnectBtn, "clicked") { [unowned self] in
            if let d = self.dialog { ad_dialog_close(d) }
            self.desktop.reload()
        }
        ol_append(actionBox, reconnectBtn)

        if desktop.mode == .native {
            let logoutBtn = ol_button("Logout")!
            ad_css(logoutBtn, "flat")
            ad_tooltip(logoutBtn, "Invalidate token via POST /api/auth/logout and disconnect")
            on(logoutBtn, "clicked") { [unowned self] in
                if let d = self.dialog { ad_dialog_close(d) }
                self.desktop.logoutAndDisconnect()
            }
            ol_append(actionBox, logoutBtn)
        }

        let disconnectBtn = ol_button("Disconnect")!
        ad_css(disconnectBtn, "destructive-action")
        ad_sensitive(disconnectBtn, desktop.mode == .idle ? 0 : 1)
        on(disconnectBtn, "clicked") { [unowned self] in
            if let d = self.dialog { ad_dialog_close(d) }
            self.desktop.disconnect()
            self.desktop.show("Disconnected", notice: "Disconnected. Session data discarded.")
        }
        ol_append(actionBox, disconnectBtn)
        ad_action_row_suffix(statusRow, actionBox)
        ad_group_add(sessionGroup, statusRow)

        uptimeRow = ad_action_row("Session History", "—")
        ad_group_add(sessionGroup, uptimeRow)
        ol_append(pageBox, sessionGroup)

        // 2. Device & HID Telemetry Group
        let deviceGroup = ad_group("Device & HID")!
        hidLinkRow = ad_action_row("HID Link", "—")
        hidRttRow = ad_action_row("HID Round-Trip Time (RTT)", "—")
        ledsRow = ad_action_row("Keyboard LEDs", "—")
        atxLedsRow = ad_action_row("ATX LEDs", "—")
        hdmiRow = ad_action_row("HDMI Input", "—")
        for r in [hidLinkRow!, hidRttRow!, ledsRow!, atxLedsRow!, hdmiRow!] {
            ad_group_add(deviceGroup, r)
        }
        ol_append(pageBox, deviceGroup)

        // 3. WebRTC Stream Telemetry Group
        let streamGroup = ad_group("WebRTC Stream")!
        videoRow = ad_action_row("Video Stream", "—")
        codecRow = ad_action_row("Codec", "—")
        jitterRow = ad_action_row("Jitter", "—")
        lostRow = ad_action_row("Packets Lost", "—")
        repairRow = ad_action_row("Repair (PLI / NACK)", "—")
        iceRttRow = ad_action_row("ICE Round-Trip Time", "—")
        pathRow = ad_action_row("Network Path", "—")
        remoteRow = ad_action_row("Remote Candidate", "—")
        for r in [videoRow!, codecRow!, jitterRow!, lostRow!, repairRow!, iceRttRow!, pathRow!, remoteRow!] {
            ad_group_add(streamGroup, r)
        }
        ol_append(pageBox, streamGroup)

        // 4. Capture & VAAPI Group
        let captureGroup = ad_group("Capture & VAAPI Hardware Acceleration")!
        vaapiRow = ad_action_row("VAAPI Encoder", desktop.vaapiStatus.summary)
        recRow = ad_action_row("Recording Status", desktop.recordingStatusText)
        let capBtnBox = ol_box(0, 6)!
        ad_align(capBtnBox, alignFill, alignCenter)
        let shotBtn = ol_button("Screenshot")!
        ad_css(shotBtn, "flat")
        ad_sensitive(shotBtn, desktop.mode == .native ? 1 : 0)
        on(shotBtn, "clicked") { [unowned self] in
            self.desktop.takeScreenshot()
            self.refresh()
        }
        let recBtn = ol_button(desktop.isRecording ? "Stop Recording" : "Record")!
        ad_css(recBtn, desktop.isRecording ? "destructive-action" : "flat")
        ad_sensitive(recBtn, (desktop.mode == .native || desktop.isRecording) ? 1 : 0)
        on(recBtn, "clicked") { [unowned self] in
            self.desktop.toggleRecording()
            self.refresh()
        }
        ol_append(capBtnBox, shotBtn)
        ol_append(capBtnBox, recBtn)
        ad_action_row_suffix(recRow, capBtnBox)
        ad_group_add(captureGroup, vaapiRow)
        ad_group_add(captureGroup, recRow)
        ol_append(pageBox, captureGroup)

        // 5. Connection Log Summary Group
        let logGroup = ad_group("Diagnostics & Connection Log")!
        lastProblemRow = ad_action_row("Last Problem", "No problems recorded")
        let openLogBtn = ol_button("Open Connection Log (\(ConnectionLog.shared.events.count))")!
        ad_css(openLogBtn, "flat")
        ad_align(openLogBtn, alignFill, alignCenter)
        on(openLogBtn, "clicked") { [unowned self] in
            self.presentConnectionLog()
        }
        ad_action_row_suffix(lastProblemRow, openLogBtn)
        ad_group_add(logGroup, lastProblemRow)
        ol_append(pageBox, logGroup)

        let clamp = ad_clamp(pageBox, 640)!
        let scroll = ol_scroll(clamp)!
        ol_expand(scroll, 1, 1)

        let dlg = ad_dialog("Connection Information", scroll, 660, 680)!
        self.dialog = dlg
        on(dlg, "closed") { [unowned self] in
            self.stopTimer()
            self.dialog = nil
        }

        refresh()
        timer = g_timeout_add_seconds(1, { ctx in
            let ctrl = Unmanaged<ConnectionInfoController>.fromOpaque(ctx!).takeUnretainedValue()
            guard ctrl.dialog != nil else { return 0 }
            ctrl.refresh()
            return 1
        }, Unmanaged.passUnretained(self).toOpaque())

        ad_present(dlg, desktop.window)
    }

    func refresh() {
        guard dialog != nil else { return }
        let t = desktop.native?.telemetry ?? StreamTelemetry.empty
        let stateText: String = {
            switch desktop.mode {
            case .idle: return "Disconnected"
            case .native: return desktop.native?.receivedFrame == true ? "Connected · Native WebRTC" : "Connecting…"
            case .web: return "Connected · Web Console"
            }
        }()
        if let statusRow { ad_action_row_subtitle(statusRow, stateText) }
        if let uptimeRow { ad_action_row_subtitle(uptimeRow, t.sessionHistoryText()) }
        if let hidLinkRow { ad_action_row_subtitle(hidLinkRow, t.hidLinkText) }
        if let hidRttRow { ad_action_row_subtitle(hidRttRow, t.hidRttText) }
        if let ledsRow { ad_action_row_subtitle(ledsRow, t.keyboardLedsText) }
        if let atxLedsRow { ad_action_row_subtitle(atxLedsRow, t.atxLedsText) }
        if let hdmiRow { ad_action_row_subtitle(hdmiRow, t.hdmiText) }
        if let videoRow { ad_action_row_subtitle(videoRow, t.videoText) }
        if let codecRow { ad_action_row_subtitle(codecRow, t.codecText) }
        if let jitterRow { ad_action_row_subtitle(jitterRow, StreamTelemetry.msText(t.videoJitterMs)) }
        if let lostRow { ad_action_row_subtitle(lostRow, StreamTelemetry.countText(t.videoPacketsLost, unit: "packet")) }
        if let repairRow { ad_action_row_subtitle(repairRow, t.repairText) }
        if let iceRttRow { ad_action_row_subtitle(iceRttRow, StreamTelemetry.msText(t.videoRoundTripTimeMs)) }
        if let pathRow { ad_action_row_subtitle(pathRow, t.networkPath ?? "—") }
        if let remoteRow { ad_action_row_subtitle(remoteRow, t.networkRemoteAddress ?? "—") }
        if let vaapiRow { ad_action_row_subtitle(vaapiRow, desktop.vaapiStatus.summary) }
        if let recRow { ad_action_row_subtitle(recRow, desktop.recordingStatusText) }
        if let lastProblemRow {
            if let prob = ConnectionLog.shared.lastProblem {
                ad_action_row_subtitle(lastProblemRow, "[\(prob.category.rawValue)] \(prob.message)")
            } else {
                ad_action_row_subtitle(lastProblemRow, "No problems recorded")
            }
        }
    }

    func presentConnectionLog() {
        ConnectionLog.shared.markProblemsViewed()
        let root = ol_box(1, 12)!
        ol_margin(root, 14)

        let filterBar = ol_box(0, 8)!
        let levelGroup = ad_group(nil)!
        let levelCombo = ad_combo_row("Minimum Level", nil)!
        for name in ["All (Debug+)", "Info+", "Warnings & Errors"] {
            ad_combo_append(levelCombo, name)
        }
        ad_combo_set(levelCombo, 0)
        ad_group_add(levelGroup, levelCombo)

        let catCombo = ad_combo_row("Category", nil)!
        ad_combo_append(catCombo, "All Categories")
        for cat in ConnectionLogCategory.allCases {
            ad_combo_append(catCombo, cat.rawValue)
        }
        ad_combo_set(catCombo, 0)
        ad_group_add(levelGroup, catCombo)
        ol_expand(levelGroup, 1, 0)
        ol_append(filterBar, levelGroup)
        ol_append(root, filterBar)

        let textView = ol_text_view(ConnectionLog.shared.formattedText(), 0, 1)!
        let scroll = ol_scroll(textView)!
        ol_expand(scroll, 1, 1)
        ol_append(root, scroll)

        let updateText = {
            let lvlIdx = Int(ad_combo_get(levelCombo))
            let minLevel: ConnectionLogLevel = lvlIdx == 2 ? .warning : (lvlIdx == 1 ? .info : .debug)
            let catIdx = Int(ad_combo_get(catCombo))
            let cat: ConnectionLogCategory? = (catIdx > 0 && catIdx - 1 < ConnectionLogCategory.allCases.count)
                ? ConnectionLogCategory.allCases[catIdx - 1]
                : nil
            ol_text_view_set(textView, ConnectionLog.shared.formattedText(minimumLevel: minLevel, category: cat))
        }

        on(levelCombo, "notify::selected") { (_: UnsafeMutableRawPointer?) in updateText() }
        on(catCombo, "notify::selected") { (_: UnsafeMutableRawPointer?) in updateText() }

        let actions = ol_box(0, 8)!
        let copyBtn = ol_button("Copy All")!
        on(copyBtn, "clicked") { [unowned self] in
            if let raw = ol_text_view_get(textView) {
                ol_clipboard_set(self.desktop.window, String(cString: raw))
                g_free(raw)
                self.desktop.toast("Connection log copied to clipboard.")
            }
        }
        let clearBtn = ol_button("Clear Log")!
        ad_css(clearBtn, "destructive-action")
        on(clearBtn, "clicked") {
            ConnectionLog.shared.clear()
            updateText()
        }
        let pathLabel = ad_label(ConnectionLog.shared.fileURL.path, "caption")!
        ad_css(pathLabel, "dim-label")
        ol_expand(pathLabel, 1, 0)
        ol_append(actions, pathLabel)
        ol_append(actions, copyBtn)
        ol_append(actions, clearBtn)
        ol_append(root, actions)

        let dlg = ad_dialog("Connection Log", root, 760, 540)!
        ad_present(dlg, desktop.window)
    }
}
