import Foundation
import CNativeWin
import OverlookCore

extension SettingsDialog {
    func wireSignals(
        rawSelf: UnsafeMutableRawPointer,
        probeBtn: OLWidgetPtr,
        applyBtn: OLWidgetPtr,
        resetBtn: OLWidgetPtr,
        mediaRefreshBtn: OLWidgetPtr,
        mediaUnmountBtn: OLWidgetPtr,
        uploadBtn: OLWidgetPtr,
        pwrShortBtn: OLWidgetPtr,
        pwrLongBtn: OLWidgetPtr,
        pwrResetBtn: OLWidgetPtr,
        wolBtn: OLWidgetPtr,
        edidApplyBtn: OLWidgetPtr,
        usbApplyBtn: OLWidgetPtr,
        tsRefreshBtn: OLWidgetPtr,
        tsStartBtn: OLWidgetPtr,
        tsStopBtn: OLWidgetPtr,
        querySysBtn: OLWidgetPtr,
        rebootAppBtn: OLWidgetPtr,
        changePwdBtn: OLWidgetPtr,
        clearCertsBtn: OLWidgetPtr,
        copyLogBtn: OLWidgetPtr,
        clearLogBtn: OLWidgetPtr
    ) {
        ol_signal_connect(probeBtn, "clicked", { _, ctx in
            guard let ctx else { return }
            let dlg = Unmanaged<SettingsDialog>.fromOpaque(ctx).takeUnretainedValue()
            let dev = dlg.readText(dlg.vaapiEntry)
            ad_action_set_subtitle(dlg.vaapiStatusRow, NativeSession.probeVAAPI(preferredDevice: dev))
        }, rawSelf)

        ol_signal_connect(applyBtn, "clicked", { _, ctx in
            guard let ctx else { return }
            Unmanaged<SettingsDialog>.fromOpaque(ctx).takeUnretainedValue().saveAndApplyConfig()
        }, rawSelf)

        ol_signal_connect(resetBtn, "clicked", { _, ctx in
            guard let ctx else { return }
            Unmanaged<SettingsDialog>.fromOpaque(ctx).takeUnretainedValue().resetToDefaults()
        }, rawSelf)

        ol_signal_connect(mediaRefreshBtn, "clicked", { _, ctx in
            guard let ctx else { return }
            Unmanaged<SettingsDialog>.fromOpaque(ctx).takeUnretainedValue().queryVirtualMedia()
        }, rawSelf)

        ol_signal_connect(mediaUnmountBtn, "clicked", { _, ctx in
            guard let ctx else { return }
            Unmanaged<SettingsDialog>.fromOpaque(ctx).takeUnretainedValue().unmountVirtualMedia()
        }, rawSelf)

        ol_signal_connect(uploadBtn, "clicked", { _, ctx in
            guard let ctx else { return }
            Unmanaged<SettingsDialog>.fromOpaque(ctx).takeUnretainedValue().uploadVirtualMedia()
        }, rawSelf)

        ol_signal_connect(pwrShortBtn, "clicked", { _, ctx in
            guard let ctx else { return }
            Unmanaged<SettingsDialog>.fromOpaque(ctx).takeUnretainedValue().sendATXAction("power_short")
        }, rawSelf)

        ol_signal_connect(pwrLongBtn, "clicked", { _, ctx in
            guard let ctx else { return }
            Unmanaged<SettingsDialog>.fromOpaque(ctx).takeUnretainedValue().sendATXAction("power_long")
        }, rawSelf)

        ol_signal_connect(pwrResetBtn, "clicked", { _, ctx in
            guard let ctx else { return }
            Unmanaged<SettingsDialog>.fromOpaque(ctx).takeUnretainedValue().sendATXAction("reset")
        }, rawSelf)

        ol_signal_connect(wolBtn, "clicked", { _, ctx in
            guard let ctx else { return }
            Unmanaged<SettingsDialog>.fromOpaque(ctx).takeUnretainedValue().sendWakeOnLAN()
        }, rawSelf)

        ol_signal_connect(edidApplyBtn, "clicked", { _, ctx in
            guard let ctx else { return }
            Unmanaged<SettingsDialog>.fromOpaque(ctx).takeUnretainedValue().applyEDID()
        }, rawSelf)

        ol_signal_connect(usbApplyBtn, "clicked", { _, ctx in
            guard let ctx else { return }
            Unmanaged<SettingsDialog>.fromOpaque(ctx).takeUnretainedValue().applyUSBIdentity()
        }, rawSelf)

        ol_signal_connect(tsRefreshBtn, "clicked", { _, ctx in
            guard let ctx else { return }
            Unmanaged<SettingsDialog>.fromOpaque(ctx).takeUnretainedValue().queryTailscale()
        }, rawSelf)

        ol_signal_connect(tsStartBtn, "clicked", { _, ctx in
            guard let ctx else { return }
            Unmanaged<SettingsDialog>.fromOpaque(ctx).takeUnretainedValue().setTailscale(enabled: true)
        }, rawSelf)

        ol_signal_connect(tsStopBtn, "clicked", { _, ctx in
            guard let ctx else { return }
            Unmanaged<SettingsDialog>.fromOpaque(ctx).takeUnretainedValue().setTailscale(enabled: false)
        }, rawSelf)

        ol_signal_connect(querySysBtn, "clicked", { _, ctx in
            guard let ctx else { return }
            Unmanaged<SettingsDialog>.fromOpaque(ctx).takeUnretainedValue().querySystemInfo()
        }, rawSelf)

        ol_signal_connect(rebootAppBtn, "clicked", { _, ctx in
            guard let ctx else { return }
            Unmanaged<SettingsDialog>.fromOpaque(ctx).takeUnretainedValue().rebootAppliance()
        }, rawSelf)

        ol_signal_connect(changePwdBtn, "clicked", { _, ctx in
            guard let ctx else { return }
            Unmanaged<SettingsDialog>.fromOpaque(ctx).takeUnretainedValue().changeAdminPassword()
        }, rawSelf)

        ol_signal_connect(clearCertsBtn, "clicked", { _, ctx in
            guard let ctx else { return }
            let dlg = Unmanaged<SettingsDialog>.fromOpaque(ctx).takeUnretainedValue()
            try? dlg.certificates.removeAll()
            ad_action_set_subtitle(dlg.certCountRow, "0 trusted host(s) — cleared")
            dlg.onStatusToast("Cleared all pinned TLS certificates")
        }, rawSelf)

        ol_signal_connect(copyLogBtn, "clicked", { _, ctx in
            guard let ctx else { return }
            let dlg = Unmanaged<SettingsDialog>.fromOpaque(ctx).takeUnretainedValue()
            let entries = dlg.connectionLog.recentEntries(limit: 100)
            let text = entries.map { "[\($0.timestamp)] \($0.device): \($0.event) — \($0.detail)" }.joined(separator: "\n")
            ol_clipboard_set(dlg.dialog, text.isEmpty ? "No connection log entries" : text)
            ad_action_set_subtitle(dlg.logSummaryRow, "Copied \(entries.count) entries to clipboard")
        }, rawSelf)

        ol_signal_connect(clearLogBtn, "clicked", { _, ctx in
            guard let ctx else { return }
            let dlg = Unmanaged<SettingsDialog>.fromOpaque(ctx).takeUnretainedValue()
            dlg.connectionLog.clear()
            ad_action_set_subtitle(dlg.logSummaryRow, "Log cleared")
        }, rawSelf)
    }

    func saveAndApplyConfig() {
        var cfg = CaptureConfig()
        cfg.streamMode = CaptureConfig.StreamMode(rawValue: Int(ad_combo_get(streamModeCombo))) ?? .automatic
        cfg.preferHEVC = ad_switch_get(hevcSwitch) != 0
        cfg.preferHWDecode = ad_switch_get(hwDecodeSwitch) != 0
        cfg.vaapiDevice = readText(vaapiEntry)
        cfg.maxFPS = Int(ad_spin_get(maxFpsSpin))
        cfg.jitterBufferMs = Int(ad_spin_get(jitterSpin))
        cfg.keepAspectRatio = ad_switch_get(aspectSwitch) != 0
        cfg.showStatsOverlay = ad_switch_get(statsOverlaySwitch) != 0
        cfg.autoReconnect = ad_switch_get(reconnectSwitch) != 0
        cfg.enableAudio = ad_switch_get(audioSwitch) != 0
        cfg.audioVolume = ad_spin_get(audioVolSpin) / 100.0

        cfg.mouseMode = CaptureConfig.MouseMode(rawValue: Int(ad_combo_get(mouseModeCombo))) ?? .absolute
        cfg.relativeSensitivity = ad_spin_get(relSensSpin) / 100.0
        cfg.naturalScroll = ad_switch_get(naturalScrollSwitch) != 0
        cfg.scrollSensitivity = ad_spin_get(scrollSensSpin) / 100.0
        cfg.hideLocalCursor = ad_switch_get(hideCursorSwitch) != 0
        cfg.scrollLockReleasesCapture = ad_switch_get(scrollLockSwitch) != 0
        let km = readText(keymapEntry)
        cfg.keymapName = km.isEmpty ? "us" : km

        try? cfg.save()
        session?.config = cfg
        onConfigChanged(cfg)
        onStatusToast("Preferences saved and applied")
    }

    func resetToDefaults() {
        let cfg = CaptureConfig()
        ad_combo_set(streamModeCombo, UInt32(cfg.streamMode.rawValue))
        ad_switch_set(hevcSwitch, cfg.preferHEVC ? 1 : 0)
        ad_switch_set(hwDecodeSwitch, cfg.preferHWDecode ? 1 : 0)
        ad_editable_set(vaapiEntry, cfg.vaapiDevice)
        ad_spin_set(maxFpsSpin, Double(cfg.maxFPS))
        ad_spin_set(jitterSpin, Double(cfg.jitterBufferMs))
        ad_switch_set(aspectSwitch, cfg.keepAspectRatio ? 1 : 0)
        ad_switch_set(statsOverlaySwitch, cfg.showStatsOverlay ? 1 : 0)
        ad_switch_set(reconnectSwitch, cfg.autoReconnect ? 1 : 0)
        ad_switch_set(audioSwitch, cfg.enableAudio ? 1 : 0)
        ad_spin_set(audioVolSpin, cfg.audioVolume * 100.0)
        ad_combo_set(mouseModeCombo, UInt32(cfg.mouseMode.rawValue))
        ad_spin_set(relSensSpin, cfg.relativeSensitivity * 100.0)
        ad_switch_set(naturalScrollSwitch, cfg.naturalScroll ? 1 : 0)
        ad_spin_set(scrollSensSpin, cfg.scrollSensitivity * 100.0)
        ad_switch_set(hideCursorSwitch, cfg.hideLocalCursor ? 1 : 0)
        ad_switch_set(scrollLockSwitch, cfg.scrollLockReleasesCapture ? 1 : 0)
        ad_editable_set(keymapEntry, cfg.keymapName)

        try? cfg.save()
        session?.config = cfg
        onConfigChanged(cfg)
        onStatusToast("Restored default preferences")
    }

    func refreshDeviceStatus() {
        queryVirtualMedia()
        queryATXState()
        queryTailscale()
        querySystemInfo()
    }

    func readText(_ row: OLWidgetPtr) -> String {
        guard let ptr = ad_editable_get(row) else { return "" }
        return String(cString: ptr).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
