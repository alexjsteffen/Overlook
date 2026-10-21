import Foundation
import CDesktop
import OverlookCore

extension SettingsDialogController {
    // MARK: - Loading & Syncing State

    func loadRemoteAll() {
        guard let session = desktop.native else { return }

        session.requestJSON(path: "api/system/get_config", type: KVMSystemGetConfigResult.self) { [weak self] res in
            if case .success(let r) = res {
                self?.config = r.config
                self?.desktop.native?.mouseControlEnabled = r.config.mouseControl
                self?.desktop.native?.keyboardControlEnabled = r.config.keyboardControl
                self?.desktop.native?.reverseScrolling = r.config.reverseScrolling
                self?.desktop.native?.updateCursorVisibility(r.config.showCursor)
                self?.desktop.native?.setMouseAbsolute(r.config.isAbsoluteMouse)
                self?.syncUIFromState()
            }
        }
        session.requestJSON(path: "api/streamer", type: KVMStreamerState.self) { [weak self] res in
            if case .success(let st) = res {
                self?.streamerState = st
                self?.syncUIFromState()
            }
        }
        session.requestJSON(path: "api/streamer/ocr", type: KVMStreamerOcrState.self) { [weak self] res in
            if case .success(let ocr) = res {
                self?.ocrState = ocr
                self?.syncUIFromState()
            }
        }
        session.requestData(path: "api/upgrade/get_edid") { [weak self] res in
            if case .success(let data) = res, let edid = KVMAPIEndpoint.decodeEdidResponse(data) {
                self?.currentEdid = edid
                self?.syncUIFromState()
            }
        }
        session.requestJSON(path: "api/hid", type: KVMHidState.self) { [weak self] res in
            if case .success(let hid) = res {
                self?.hidState = hid
                if let abs = hid.mouse?.absolute { self?.desktop.native?.setMouseAbsolute(abs) }
                self?.syncUIFromState()
            }
        }
        session.requestJSON(path: "api/hid/keymaps", type: KVMHidKeymapsState.self) { [weak self] res in
            if case .success(let km) = res {
                self?.keymaps = km
                self?.syncUIFromState()
            }
        }

        refreshMsd()
        refreshAtxAndRedfish()
        refreshGpio()
        refreshSwitch()
        refreshSystemInfo()
        loadNetworkSettings()
    }

    func syncUIFromState() {
        guard dialog != nil else { return }
        isSyncing = true
        defer { isSyncing = false }

        if let cfg = config {
            ad_combo_set(videoModeCombo, cfg.videoProcessing == "quality_first" ? 1 : 0)
            let preset = KVMVideoQualityPreset.detect(config: cfg, streamer: streamerState)
            if let pIdx = Self.presetsOrder.firstIndex(of: preset) {
                ad_combo_set(qualityPresetCombo, Int32(pIdx))
            }
            if let oIdx = Self.orientations.firstIndex(of: cfg.orientation) {
                ad_combo_set(orientationCombo, Int32(oIdx))
            }
            ad_switch_set(showCursorSwitch, cfg.showCursor ? 1 : 0)
            ad_switch_set(mouseControlSwitch, cfg.mouseControl ? 1 : 0)
            ad_switch_set(keyboardControlSwitch, cfg.keyboardControl ? 1 : 0)
            ad_combo_set(mouseModeCombo, cfg.isAbsoluteMouse ? 0 : 1)
            ad_spin_set(mousePollingSpin, Double(cfg.mousePolling))
            ad_spin_set(relativeSenseSpin, Double(cfg.relativeSense))
            ad_spin_set(scrollRateSpin, Double(cfg.scrollRate))
            if let sIdx = Self.scrollDirections.firstIndex(of: cfg.reverseScrolling) {
                ad_combo_set(scrollDirCombo, Int32(sIdx))
            }
            ad_spin_set(fingerbotSpin, Double(cfg.fingerbotStrength))
            ad_combo_set(webThemeCombo, cfg.themeMode == "1" ? 1 : 0)
            if let lang = cfg.language, let lIdx = Self.languages.firstIndex(of: lang) {
                ad_combo_set(languageCombo, Int32(lIdx))
            }
            if let tz = cfg.timezone, let tIdx = Self.timezones.firstIndex(of: tz) {
                ad_combo_set(timezoneCombo, Int32(tIdx))
            }
        }

        let matchEdidID = EDIDCatalog.matchingOptionID(for: currentEdid)
        if let eIdx = EDIDCatalog.options.firstIndex(where: { $0.id == matchEdidID }) {
            ad_combo_set(edidCombo, Int32(eIdx))
        }
        if let customEdidRow, !currentEdid.isEmpty {
            ol_set_value(customEdidRow, currentEdid)
        }

        if let st = streamerState, let params = st.params {
            if let fps = params.desiredFps { ad_spin_set(fpsSpin, Double(fps)) }
            if let q = params.quality { ad_spin_set(qualitySpin, Double(q)) }
            if let br = params.h264Bitrate { ad_spin_set(bitrateSpin, Double(br)) }
            if let gop = params.h264Gop { ad_spin_set(gopSpin, Double(gop)) }
            if let zd = params.zeroDelay { ad_switch_set(zeroDelaySwitch, zd ? 1 : 0) }
            if let res = params.resolution {
                ol_set_value(customResolutionRow, res)
                if let rIdx = Self.resolutionPresets.firstIndex(of: res) {
                    ad_combo_set(resolutionCombo, Int32(rIdx))
                } else {
                    ad_combo_set(resolutionCombo, Int32(Self.resolutionPresets.count - 1))
                }
            }
        }

        if let ocr = ocrState?.ocr.langs?.available, !ocr.isEmpty {
            availableOcrLangs = ocr
            ad_combo_clear(ocrLangCombo)
            for l in ocr { ad_combo_append(ocrLangCombo, l) }
            let sel = ocr.firstIndex(of: desktop.preferences.serverOCRLanguage) ?? 0
            ad_combo_set(ocrLangCombo, Int32(sel))
        }

        if let hid = hidState {
            let conn = hid.connected ?? hid.online
            ad_switch_set(hidConnectedSwitch, conn ? 1 : 0)
            ad_switch_set(jigglerSwitch, hid.jiggler.enabled ? 1 : 0)
            if let kbOut = hid.keyboard?.outputs, !kbOut.available.isEmpty {
                kbOutputsList = kbOut.available
                ad_combo_clear(kbOutputCombo)
                for o in kbOutputsList { ad_combo_append(kbOutputCombo, o) }
                if let idx = kbOutputsList.firstIndex(of: kbOut.active) { ad_combo_set(kbOutputCombo, Int32(idx)) }
            }
            if let mOut = hid.mouse?.outputs, !mOut.available.isEmpty {
                mouseOutputsList = mOut.available
                ad_combo_clear(mouseOutputCombo)
                for o in mouseOutputsList { ad_combo_append(mouseOutputCombo, o) }
                if let idx = mouseOutputsList.firstIndex(of: mOut.active) { ad_combo_set(mouseOutputCombo, Int32(idx)) }
            }
            if let leds = hid.keyboard?.leds, let kbLedsRow {
                ad_action_row_subtitle(kbLedsRow, "CAPS: \(leds.caps ? "On" : "Off") · NUM: \(leds.num ? "On" : "Off") · SCROLL: \(leds.scroll ? "On" : "Off")")
            }
        }

        if let km = keymaps?.keymaps.available, !km.isEmpty {
            var list = km
            if let cur = config?.keymap, !cur.isEmpty, !list.contains(cur) { list.insert(cur, at: 0) }
            keymapList = list
            ad_combo_clear(keymapCombo)
            for k in keymapList { ad_combo_append(keymapCombo, k) }
            let currentKm = config?.keymap ?? keymaps?.keymaps.default ?? "en-us"
            if let idx = keymapList.firstIndex(of: currentKm) { ad_combo_set(keymapCombo, Int32(idx)) }
        }
    }

    // MARK: - Config Mutation

    func mutateConfig(switchesMouseMode: Bool = false, _ change: (inout KVMSystemConfig) -> Void) {
        var next = config ?? KVMSystemConfig()
        change(&next)
        config = next
        guard let session = desktop.native, let body = try? JSONEncoder().encode(next) else { return }
        session.requestJSON(method: "POST", path: "api/system/set_config", contentType: "application/json", body: body, type: KVMSystemGetConfigResult.self) { [weak self] res in
            switch res {
            case .success(let updated):
                self?.config = updated.config
                if switchesMouseMode {
                    self?.setHidParams(["mouse_output": updated.config.isAbsoluteMouse ? "usb" : "usb_rel"])
                }
            case .failure(let err):
                self?.notify("Failed to apply config: \(err.localizedDescription)")
            }
        }
    }

    // MARK: - Video & Streamer Actions

    func applyQualityPreset(_ preset: KVMVideoQualityPreset) {
        guard let params = preset.streamerParams, let session = desktop.native else { return }
        let query = params.map { ($0.key, $0.value) }
        session.requestEmpty(path: "api/streamer/set_params", query: query) { [weak self] res in
            switch res {
            case .success:
                if let sq = preset.configStreamQuality {
                    self?.mutateConfig { $0.streamQuality = sq }
                }
                session.requestJSON(path: "api/streamer", type: KVMStreamerState.self) { [weak self] stRes in
                    if case .success(let st) = stRes {
                        self?.streamerState = st
                        self?.syncUIFromState()
                    }
                }
                self?.notify("Applied \(preset.title) video quality preset.")
            case .failure(let err):
                self?.notify("Failed to apply quality preset: \(err.localizedDescription)")
            }
        }
    }

    func applyCustomStreamerParams() {
        guard let session = desktop.native else { notify("Connect to a device first."); return }
        let fps = Int(ad_spin_get(fpsSpin))
        let quality = Int(ad_spin_get(qualitySpin))
        let bitrate = Int(ad_spin_get(bitrateSpin))
        let gop = Int(ad_spin_get(gopSpin))
        let zeroDelay = ad_switch_get(zeroDelaySwitch) != 0
        var query: [(String, String)] = [
            ("desired_fps", String(fps)),
            ("quality", String(quality)),
            ("h264_bitrate", String(bitrate)),
            ("h264_gop", String(gop)),
            ("zero_delay", zeroDelay ? "true" : "false")
        ]
        let rIdx = Int(ad_combo_get(resolutionCombo))
        var resValue = ""
        if rIdx >= 0 && rIdx < Self.resolutionPresets.count {
            let tag = Self.resolutionPresets[rIdx]
            resValue = tag == "custom" ? String(cString: ol_value(customResolutionRow)).trimmingCharacters(in: .whitespacesAndNewlines) : tag
        }
        if !resValue.isEmpty { query.append(("resolution", resValue)) }

        session.requestEmpty(path: "api/streamer/set_params", query: query) { [weak self] res in
            switch res {
            case .success:
                self?.notify("Streamer parameters applied.")
                session.requestJSON(path: "api/streamer", type: KVMStreamerState.self) { [weak self] stRes in
                    if case .success(let st) = stRes { self?.streamerState = st; self?.syncUIFromState() }
                }
            case .failure(let err):
                self?.notify("Failed to apply streamer parameters: \(err.localizedDescription)")
            }
        }
    }

    func applyEdid(_ edid: String) {
        guard let session = desktop.native else { notify("Connect to a device first."); return }
        let payload = KVMAPIEndpoint.multipartEdid(edid)
        session.requestData(method: "POST", path: "api/upgrade/edid", contentType: payload.contentType, body: payload.body) { [weak self] res in
            switch res {
            case .success:
                self?.currentEdid = edid
                self?.syncUIFromState()
                self?.notify("EDID applied.")
            case .failure(let err):
                self?.notify("Failed to apply EDID: \(err.localizedDescription)")
            }
        }
    }

    func deleteCachedSnapshot() {
        desktop.native?.requestEmpty(method: "DELETE", path: "api/streamer/snapshot", contentType: nil) { [weak self] res in
            switch res {
            case .success: self?.notify("Cleared cached streamer snapshot.")
            case .failure(let err): self?.notify("Failed to clear snapshot: \(err.localizedDescription)")
            }
        }
    }

    // MARK: - HID & Keyboard Actions

    func setHidConnected(_ connected: Bool) {
        desktop.native?.requestEmpty(path: "api/hid/set_connected", query: [("connected", connected ? "true" : "false")]) { [weak self] res in
            if case .failure(let err) = res { self?.notify("Failed to set HID connected: \(err.localizedDescription)") }
        }
    }

    func setHidParams(_ params: [String: String]) {
        guard let session = desktop.native else { return }
        let query = params.map { ($0.key, $0.value) }
        session.requestEmpty(path: "api/hid/set_params", query: query) { [weak self] res in
            switch res {
            case .success:
                session.requestJSON(path: "api/hid", type: KVMHidState.self) { [weak self] hidRes in
                    if case .success(let hid) = hidRes {
                        self?.hidState = hid
                        if let abs = hid.mouse?.absolute { self?.desktop.native?.setMouseAbsolute(abs) }
                        self?.syncUIFromState()
                    }
                }
            case .failure(let err):
                self?.notify("Failed to update HID parameters: \(err.localizedDescription)")
            }
        }
    }

    func sendShortcutKeys(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        if let session = desktop.native, session.inputAvailable {
            session.sendShortcut(keys)
            notify("Sent \(keys.joined(separator: "+")).")
        } else {
            desktop.native?.requestEmpty(path: "api/hid/events/send_shortcut", query: [("keys", keys.joined(separator: ","))]) { [weak self] res in
                switch res {
                case .success: self?.notify("Sent \(keys.joined(separator: "+")).")
                case .failure(let err): self?.notify("Shortcut failed: \(err.localizedDescription)")
                }
            }
        }
    }

    func sendRemoteTypedText() {
        guard let session = desktop.native, let remoteTypeEntry else { return }
        let text = String(cString: ol_value(remoteTypeEntry))
        guard !text.isEmpty else { notify("Enter text to type on the remote host."); return }
        let slow = ad_switch_get(remoteTypeSlowSwitch) != 0
        let delay = ad_spin_get(remoteTypeDelaySpin)
        let kmIdx = Int(ad_combo_get(keymapCombo))
        let km = (kmIdx >= 0 && kmIdx < keymapList.count) ? keymapList[kmIdx] : (config?.keymap ?? "en-us")
        var query: [(String, String)] = [("keymap", km), ("slow", slow ? "true" : "false")]
        if slow { query.append(("delay", String(format: "%.3f", delay))) }
        session.requestEmpty(path: "api/hid/print", query: query, contentType: "text/plain; charset=utf-8", body: Data(text.utf8)) { [weak self] res in
            switch res {
            case .success:
                ol_set_value(remoteTypeEntry, "")
                self?.notify("Typed text on remote host.")
            case .failure(let err):
                self?.notify("Remote typing failed: \(err.localizedDescription)")
            }
        }
    }

    // MARK: - Virtual Media (MSD) Actions

    func refreshMsd() {
        desktop.native?.requestJSON(path: "api/msd", type: KVMMsdState.self) { [weak self] res in
            guard let self else { return }
            if case .success(let msd) = res {
                self.msdState = msd
                self.updateMsdUI()
            }
        }
    }

    private func updateMsdUI() {
        guard dialog != nil, let msd = msdState else { return }
        isSyncing = true
        defer { isSyncing = false }

        let status = (msd.drive?.connected == true) ? "Connected to Host" : (msd.online ? "Disconnected from Host" : "MSD Offline")
        var storageText = ""
        if let st = msd.storage, st.size > 0 {
            let freeMB = st.free / (1024 * 1024)
            let totalMB = st.size / (1024 * 1024)
            storageText = " · \(freeMB) MB free / \(totalMB) MB"
        }
        if let msdStatusRow { ad_action_row_subtitle(msdStatusRow, "\(status)\(storageText)") }
        if let msdMountedRow { ad_action_row_subtitle(msdMountedRow, msd.drive?.imageName ?? "None") }

        let imgs = msd.storage?.images.map(\.name) ?? []
        msdImageList = imgs
        ad_combo_clear(msdImageCombo)
        ad_combo_append(msdImageCombo, "None")
        for img in imgs { ad_combo_append(msdImageCombo, img) }
        if let current = msd.drive?.imageName, let idx = imgs.firstIndex(of: current) {
            ad_combo_set(msdImageCombo, Int32(idx + 1))
        } else if !imgs.isEmpty {
            ad_combo_set(msdImageCombo, 1)
        } else {
            ad_combo_set(msdImageCombo, 0)
        }
        if let drive = msd.drive {
            ad_combo_set(msdTypeCombo, drive.cdrom ? 0 : 1)
            ad_switch_set(msdRwSwitch, drive.rw ? 1 : 0)
        }
    }

    func applyMsdParams() {
        guard let session = desktop.native else { return }
        let idx = Int(ad_combo_get(msdImageCombo))
        let image = (idx > 0 && idx - 1 < msdImageList.count) ? msdImageList[idx - 1] : ""
        let cdrom = ad_combo_get(msdTypeCombo) == 0
        let rw = !cdrom && (ad_switch_get(msdRwSwitch) != 0)
        var query: [(String, String)] = [
            ("cdrom", cdrom ? "1" : "0"),
            ("rw", rw ? "1" : "0")
        ]
        if !image.isEmpty { query.append(("image", image)) }
        session.requestEmpty(path: "api/msd/set_params", query: query) { [weak self] res in
            switch res {
            case .success:
                self?.notify("MSD parameters updated.")
                self?.refreshMsd()
            case .failure(let err):
                self?.notify("Failed to update MSD parameters: \(err.localizedDescription)")
            }
        }
    }

    func setMsdConnected(_ connected: Bool) {
        desktop.native?.requestEmpty(path: "api/msd/set_connected", query: [("connected", connected ? "1" : "0")]) { [weak self] res in
            switch res {
            case .success:
                self?.notify(connected ? "Virtual drive connected." : "Virtual drive disconnected.")
                self?.refreshMsd()
            case .failure(let err):
                self?.notify("MSD connection change failed: \(err.localizedDescription)")
            }
        }
    }

    func removeSelectedMsdImage() {
        let idx = Int(ad_combo_get(msdImageCombo))
        guard idx > 0 && idx - 1 < msdImageList.count else { notify("Select an image to remove first."); return }
        let image = msdImageList[idx - 1]
        desktop.native?.requestEmpty(path: "api/msd/remove", query: [("image", image)]) { [weak self] res in
            switch res {
            case .success:
                self?.notify("Removed \(image).")
                self?.refreshMsd()
            case .failure(let err):
                self?.notify("Failed to remove image: \(err.localizedDescription)")
            }
        }
    }

    func resetMsd() {
        desktop.native?.requestEmpty(path: "api/msd/reset") { [weak self] res in
            switch res {
            case .success:
                self?.notify("Mass Storage Drive reset.")
                self?.refreshMsd()
            case .failure(let err):
                self?.notify("Failed to reset MSD: \(err.localizedDescription)")
            }
        }
    }

    func uploadLocalMsdFile() {
        guard let session = desktop.native, let msdLocalPathEntry else { return }
        let rawPath = String(cString: ol_value(msdLocalPathEntry)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { notify("Enter a local .iso or .img file path."); return }
        let expanded = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        do {
            let data = try Data(contentsOf: url)
            let name = url.lastPathComponent
            notify("Uploading \(name)…")
            session.requestData(method: "POST", path: "api/msd/write", query: [("image", name), ("remove_incomplete", "true")], contentType: "application/octet-stream", body: data) { [weak self] res in
                switch res {
                case .success:
                    self?.notify("Uploaded \(name) to KVM.")
                    self?.refreshMsd()
                case .failure(let err):
                    self?.notify("Upload failed: \(err.localizedDescription)")
                }
            }
        } catch {
            notify("Could not read local file: \(error.localizedDescription)")
        }
    }

    func uploadRemoteMsdByURL() {
        guard let session = desktop.native, let msdRemoteUrlEntry, let msdRemoteNameEntry else { return }
        let urlStr = String(cString: ol_value(msdRemoteUrlEntry)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlStr.isEmpty else { notify("Enter a remote image URL."); return }
        let nameStr = String(cString: ol_value(msdRemoteNameEntry)).trimmingCharacters(in: .whitespacesAndNewlines)
        var query: [(String, String)] = [("url", urlStr), ("timeout", "30"), ("remove_incomplete", "true")]
        if !nameStr.isEmpty { query.append(("image", nameStr)) }
        notify("Downloading remote image to KVM…")
        session.requestEmpty(path: "api/msd/write_remote", query: query) { [weak self] res in
            switch res {
            case .success:
                ol_set_value(msdRemoteUrlEntry, "")
                ol_set_value(msdRemoteNameEntry, "")
                self?.notify("Remote image downloaded to KVM.")
                self?.refreshMsd()
            case .failure(let err):
                self?.notify("Remote download failed: \(err.localizedDescription)")
            }
        }
    }

    func msdPartitionAction(connect: Bool) {
        let path = connect ? "api/msd/partition_connect" : "api/msd/partition_disconnect"
        desktop.native?.requestEmpty(method: "GET", path: path, contentType: nil) { [weak self] res in
            switch res {
            case .success:
                self?.notify(connect ? "MSD partition connected." : "MSD partition disconnected.")
                self?.refreshMsd()
            case .failure(let err):
                self?.notify("Partition operation failed: \(err.localizedDescription)")
            }
        }
    }

    // MARK: - Power, ATX & Redfish Actions

    func refreshAtxAndRedfish() {
        desktop.native?.requestJSON(path: "api/atx", type: KVMAtxState.self) { [weak self] res in
            if case .success(let atx) = res {
                self?.atxState = atx
                if let row = self?.atxStatusRow {
                    ad_action_row_subtitle(row, "Power LED: \(atx.leds.power ? "On" : "Off") · HDD LED: \(atx.leds.hdd ? "Active" : "Idle")\(atx.busy ? " · Busy" : "")")
                }
            }
        }
        desktop.native?.requestJSON(path: "redfish/v1/Systems/0", type: KVMRedfishSystem.self) { [weak self] res in
            if case .success(let rf) = res {
                self?.redfishSystem = rf
                if let row = self?.redfishStatusRow {
                    ad_action_row_subtitle(row, "Host: \(rf.hostName ?? "System 0") · PowerState: \(rf.powerState ?? "Unknown")")
                }
            }
        }
    }

    func performAtxPower(_ action: KVMAtxPowerAction) {
        let wait = ad_switch_get(atxWaitSwitch) != 0
        desktop.native?.requestEmpty(path: "api/atx/power", query: [("action", action.rawValue), ("wait", wait ? "true" : "false")]) { [weak self] res in
            switch res {
            case .success:
                self?.notify("ATX \(action.displayName) sent.")
                self?.refreshAtxAndRedfish()
            case .failure(let err):
                self?.notify("ATX power failed: \(err.localizedDescription)")
            }
        }
    }

    func performAtxClick(_ button: KVMAtxButton) {
        let wait = ad_switch_get(atxWaitSwitch) != 0
        desktop.native?.requestEmpty(path: "api/atx/click", query: [("button", button.rawValue), ("wait", wait ? "true" : "false")]) { [weak self] res in
            switch res {
            case .success:
                self?.notify("ATX \(button.displayName) sent.")
                self?.refreshAtxAndRedfish()
            case .failure(let err):
                self?.notify("ATX button failed: \(err.localizedDescription)")
            }
        }
    }

    func performRedfishReset() {
        let idx = Int(ad_combo_get(redfishResetCombo))
        let types = KVMRedfishResetType.allCases
        guard idx >= 0 && idx < types.count, let session = desktop.native else { return }
        let rt = types[idx]
        let payload: [String: String] = ["ResetType": rt.rawValue]
        let body = try? JSONEncoder().encode(payload)
        session.requestData(method: "POST", path: "redfish/v1/Systems/0/Actions/ComputerSystem.Reset", contentType: "application/json", body: body) { [weak self] res in
            switch res {
            case .success:
                self?.notify("Redfish \(rt.rawValue) sent.")
                self?.refreshAtxAndRedfish()
            case .failure(let err):
                self?.notify("Redfish reset failed: \(err.localizedDescription)")
            }
        }
    }

    func resetKvmAll() {
        guard let session = desktop.native else { return }
        session.requestEmpty(path: "api/hid/reset") { _ in }
        session.requestEmpty(path: "api/streamer/reset") { [weak self] res in
            switch res {
            case .success: self?.notify("Reset HID and Streamer.")
            case .failure(let err): self?.notify("Reset failed: \(err.localizedDescription)")
            }
        }
    }

    // MARK: - GPIO & Switch Actions

    func refreshGpio() {
        desktop.native?.requestJSON(path: "api/gpio", type: KVMGpioState.self) { [weak self] res in
            guard let self else { return }
            if case .success(let gpio) = res {
                self.gpioState = gpio
                var parts: [String] = []
                for ch in gpio.inputChannels {
                    let st = gpio.inputs[ch]?.state == true ? "HIGH" : "LOW"
                    parts.append("IN \(ch): \(st)")
                }
                for (ch, out) in gpio.outputs.sorted(by: { $0.key < $1.key }) {
                    parts.append("OUT \(ch): \(out.state ? "ON" : "OFF")")
                }
                if let row = self.gpioInputsRow {
                    ad_action_row_subtitle(row, parts.isEmpty ? "No user GPIO channels configured" : parts.joined(separator: " · "))
                }
            }
        }
    }

    func refreshSwitch() {
        desktop.native?.requestJSON(path: "api/switch", type: KVMSwitchState.self) { [weak self] res in
            guard let self else { return }
            if case .success(let sw) = res {
                self.switchState = sw
                let portsText = sw.ports.map { "\($0.name) (#\($0.port))" }.joined(separator: ", ")
                let sub = "Active Port: \(sw.activePort ?? "None")" + (portsText.isEmpty ? "" : " · Ports: \(portsText)")
                if let row = self.switchStatusRow { ad_action_row_subtitle(row, sub) }
                if let active = sw.activePort, let entry = self.switchPortEntry {
                    ol_set_value(entry, active)
                }
            }
        }
    }

    func switchPrevNext(next: Bool) {
        let path = next ? "api/switch/set_active_next" : "api/switch/set_active_prev"
        desktop.native?.requestEmpty(path: path) { [weak self] res in
            switch res {
            case .success: self?.refreshSwitch()
            case .failure(let err): self?.notify("Switch port change failed: \(err.localizedDescription)")
            }
        }
    }

    func switchSelectPort(_ port: String) {
        let trimmed = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        desktop.native?.requestEmpty(path: "api/switch/set_active", query: [("port", trimmed)]) { [weak self] res in
            switch res {
            case .success:
                self?.notify("Switched to port \(trimmed).")
                self?.refreshSwitch()
            case .failure(let err):
                self?.notify("Failed to switch port: \(err.localizedDescription)")
            }
        }
    }

    func switchSetBeacon(state: Bool, port: String) {
        let trimmed = port.trimmingCharacters(in: .whitespacesAndNewlines)
        var query: [(String, String)] = [("state", state ? "1" : "0")]
        if !trimmed.isEmpty { query.append(("port", trimmed)) }
        desktop.native?.requestEmpty(path: "api/switch/set_beacon", query: query) { [weak self] res in
            switch res {
            case .success:
                self?.notify("Beacon \(state ? "enabled" : "disabled").")
                self?.refreshSwitch()
            case .failure(let err):
                self?.notify("Beacon update failed: \(err.localizedDescription)")
            }
        }
    }

    func switchApplyPortParams() {
        let port = String(cString: ol_value(switchPortEntry)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !port.isEmpty else { return }
        let name = String(cString: ol_value(switchPortNameEntry)).trimmingCharacters(in: .whitespacesAndNewlines)
        let dummy = ad_switch_get(switchDummySwitch) != 0
        var query: [(String, String)] = [("port", port), ("dummy", dummy ? "1" : "0")]
        if !name.isEmpty { query.append(("name", name)) }
        desktop.native?.requestEmpty(path: "api/switch/set_port_params", query: query) { [weak self] res in
            switch res {
            case .success:
                self?.notify("Saved port \(port) parameters.")
                self?.refreshSwitch()
            case .failure(let err):
                self?.notify("Failed to save port parameters: \(err.localizedDescription)")
            }
        }
    }

    func switchApplyBeaconColors() {
        let spec = String(cString: ol_value(switchBeaconEntry)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spec.isEmpty else { return }
        desktop.native?.requestEmpty(path: "api/switch/set_colors", query: [("beacon", spec)], contentType: "text/plain; charset=utf-8", body: Data(spec.utf8)) { [weak self] res in
            switch res {
            case .success: self?.notify("Updated switch beacon color.")
            case .failure(let err): self?.notify("Beacon color failed: \(err.localizedDescription)")
            }
        }
    }

    // MARK: - System Health, Logs, Prometheus & Network Actions

    func refreshSystemInfo() {
        desktop.native?.requestJSON(path: "api/info", type: KVMSystemInfo.self) { [weak self] res in
            guard let self else { return }
            if case .success(let info) = res {
                self.systemInfo = info
                let base = info.hw?.platform?.base ?? info.hw?.platform?.model ?? "Unknown Platform"
                let serial = info.hw?.platform?.serial.flatMap { $0.isEmpty ? nil : " · Serial \($0)" } ?? ""
                if let row = self.hwPlatformRow { ad_action_row_subtitle(row, "\(base)\(serial)") }

                let kvmdVer = info.system?.kvmd?.version.map { "KVMD \($0)" } ?? "KVMD"
                let stVer = info.system?.streamer?.version.map { " · ustreamer \($0)" } ?? ""
                let kText = [info.system?.kernel?.system, info.system?.kernel?.release, info.system?.kernel?.machine].compactMap { $0 }.joined(separator: " ")
                if let row = self.hwVersionsRow { ad_action_row_subtitle(row, "\(kvmdVer)\(stVer)" + (kText.isEmpty ? "" : " · \(kText)")) }

                let cpu = info.hw?.health?.cpu?.percent.map { String(format: "CPU %.1f%%", $0) } ?? "CPU —"
                let mem = info.hw?.health?.mem?.percent.map { String(format: "Memory %.1f%%", $0) } ?? "Memory —"
                if let row = self.hwCpuMemRow { ad_action_row_subtitle(row, "\(cpu) · \(mem)") }

                let temp = info.hw?.health?.temp?.cpu.map { String(format: "CPU %.1f°C", $0) } ?? "Temp —"
                let gpuTemp = info.hw?.health?.temp?.gpu.map { String(format: " · GPU %.1f°C", $0) } ?? ""
                var flagsStr = "Healthy"
                if let flags = info.hw?.health?.throttling?.parsedFlags {
                    let warnings = [
                        (flags.undervoltage?.now == true || flags.undervoltage?.past == true) ? "Undervoltage" : nil,
                        (flags.throttled?.now == true || flags.throttled?.past == true) ? "Throttled" : nil,
                        (flags.freqCapped?.now == true || flags.freqCapped?.past == true) ? "Freq Capped" : nil
                    ].compactMap { $0 }
                    if !warnings.isEmpty { flagsStr = warnings.joined(separator: ", ") }
                }
                if let row = self.hwTempFlagsRow { ad_action_row_subtitle(row, "\(temp)\(gpuTemp) · Power: \(flagsStr)") }
            }
        }
    }

    func fetchAndShowDeviceLogs() {
        desktop.native?.requestData(path: "api/log", query: [("seek", "3600"), ("follow", "0")]) { [weak self] res in
            guard let self else { return }
            switch res {
            case .success(let data):
                let text = String(decoding: data, as: UTF8.self)
                self.presentTextReport(title: "KVMD Service Logs (/api/log)", text: text.isEmpty ? "(No KVMD log entries returned)" : text)
            case .failure(let err):
                self.notify("Failed to fetch KVMD logs: \(err.localizedDescription)")
            }
        }
    }

    func fetchAndShowPrometheus() {
        desktop.native?.requestData(path: "api/export/prometheus/metrics") { [weak self] res in
            guard let self else { return }
            switch res {
            case .success(let data):
                let text = String(decoding: data, as: UTF8.self)
                self.presentTextReport(title: "Prometheus Metrics (/api/export/prometheus/metrics)", text: text.isEmpty ? "(No Prometheus metrics returned)" : text)
            case .failure(let err):
                self.notify("Failed to fetch Prometheus metrics: \(err.localizedDescription)")
            }
        }
    }

    func presentTextReport(title: String, text: String) {
        let box = ol_box(1, 10)!
        ol_margin(box, 14)
        let tv = ol_text_view(text, 0, 1)!
        let scroll = ol_scroll(tv)!
        ol_expand(scroll, 1, 1)
        ol_append(box, scroll)

        let actions = ol_box(0, 8)!
        let copyBtn = ol_button("Copy All")!
        on(copyBtn, "clicked") { [unowned self] in
            ol_clipboard_set(self.desktop.window, text)
            self.notify("Copied to clipboard.")
        }
        ol_append(actions, copyBtn)
        ol_append(box, actions)

        let dlg = ad_dialog(title, box, 700, 480)!
        ad_present(dlg, desktop.window)
    }

    func loadNetworkSettings() {
        guard let session = desktop.native else { return }
        session.requestJSON(path: "api/network/config", type: KVMNetworkConfig.self) { [weak self] res in
            guard let self, case .success(let net) = res else { return }
            self.networkConfig = net
            self.isSyncing = true
            ad_combo_set(self.netModeCombo, net.mode == "static" ? 1 : 0)
            ol_set_value(self.netIpEntry, net.ip)
            ol_set_value(self.netMaskEntry, net.netmask)
            ol_set_value(self.netGwEntry, net.gateway)
            ol_set_value(self.netDnsEntry, net.dns)
            self.isSyncing = false
        }
        session.requestJSON(path: "api/network/wifi", type: KVMWifiConfig.self) { [weak self] res in
            guard let self, case .success(let wifi) = res else { return }
            self.wifiConfig = wifi
            self.isSyncing = true
            ad_switch_set(self.wifiEnableSwitch, wifi.enabled ? 1 : 0)
            ol_set_value(self.wifiSsidEntry, wifi.ssid)
            if let row = self.wifiStatusRow { ad_action_row_subtitle(row, wifi.status) }
            self.isSyncing = false
        }
        session.requestJSON(path: "api/network/ethernet", type: KVMEthernetConfig.self) { [weak self] res in
            guard let self, case .success(let eth) = res else { return }
            self.ethernetConfig = eth
            if let row = self.ethStatusRow {
                ad_action_row_subtitle(row, "\(eth.connected ? "Connected" : "Disconnected") · \(eth.speed) · IP \(eth.ip) · MAC \(eth.mac)")
            }
        }
    }

    func applyNetworkConfig() {
        guard let session = desktop.native else { return }
        let cfg = KVMNetworkConfig(
            mode: ad_combo_get(netModeCombo) == 1 ? "static" : "dhcp",
            ip: String(cString: ol_value(netIpEntry)),
            netmask: String(cString: ol_value(netMaskEntry)),
            gateway: String(cString: ol_value(netGwEntry)),
            dns: String(cString: ol_value(netDnsEntry))
        )
        guard let body = try? JSONEncoder().encode(cfg) else { return }
        session.requestJSON(method: "POST", path: "api/network/config", contentType: "application/json", body: body, type: KVMNetworkConfig.self) { [weak self] res in
            switch res {
            case .success: self?.notify("Network IP settings applied.")
            case .failure(let err): self?.notify("Failed to apply network settings: \(err.localizedDescription)")
            }
        }
    }

    func applyWifiConfig() {
        guard let session = desktop.native else { return }
        let pass = String(cString: ol_value(wifiPassEntry))
        let cfg = KVMWifiConfig(
            enabled: ad_switch_get(wifiEnableSwitch) != 0,
            ssid: String(cString: ol_value(wifiSsidEntry)),
            password: pass.isEmpty ? nil : pass,
            status: "Connecting..."
        )
        guard let body = try? JSONEncoder().encode(cfg) else { return }
        session.requestJSON(method: "POST", path: "api/network/wifi", contentType: "application/json", body: body, type: KVMWifiConfig.self) { [weak self] res in
            switch res {
            case .success(let updated):
                if let row = self?.wifiStatusRow { ad_action_row_subtitle(row, updated.status) }
                self?.notify("Wi-Fi configuration applied.")
            case .failure(let err):
                self?.notify("Failed to apply Wi-Fi config: \(err.localizedDescription)")
            }
        }
    }
}
