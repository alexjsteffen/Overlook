// swiftlint:disable file_length type_body_length line_length
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Behaviour for the settings panel: loading remote config, debounced applies, EDID pushes,
/// streamer draft commits, and the `GLKVMSystemConfig` bindings the section views drive,
/// plus PiKVM/GLKVM actions for HID, ATX, MSD, GPIO, Switch, System Info/Logs, and Redfish.
@MainActor
struct WebUISettingsActions {
    typealias StreamerField = WebUISettingsPanelModel.StreamerField

    let model: WebUISettingsPanelModel
    let webRTCManager: WebRTCManager
    let inputManager: InputManager
    let connection: SessionConnection
    var ocrManager: OCRManager? = nil
    var captureManager: CaptureManager? = nil

    /// Resolution presets offered by the streamer resolution picker. `static` so the binding's
    /// getter does not rebuild a `Set` on every evaluation.
    static let streamerResolutionPresets: Set<String> = ["1920x1080", "1600x900", "1280x720", "1024x768"]

    var streamerFeatures: GLKVMStreamerState.Features? { model.streamerState?.features }
    var streamerLimits: GLKVMStreamerState.Limits? { model.streamerState?.limits }

    // MARK: - Focus mirroring

    /// The streamer text fields own a `@FocusState` (which cannot live in an `ObservableObject`);
    /// they mirror it here so the apply/sync logic can keep honouring "don't clobber what the user
    /// is typing" exactly as it did when the focus state lived on the panel view itself.
    func setFocusedStreamerField(_ field: StreamerField?) {
        model.focusedStreamerField = field
    }
}

/// Loading and applying remote device state.
extension WebUISettingsActions {
    // MARK: - Load

    func load() async {
        guard let client = connection.glkvmClient else {
            await MainActor.run {
                model.config = nil
                model.systemInfo = nil
                model.keymaps = nil
                model.hidState = nil
                model.atxState = nil
                model.streamerState = nil
                model.ocrState = nil
                model.msdState = nil
                model.msdPartitions = nil
                model.gpioState = nil
                model.switchState = nil
                model.redfishSystem = nil
                model.redfishMedia = nil
                model.currentEdid = ""
                model.selectedEdidOption = EDIDCatalog.customOptionID
                model.customEdidDraft = ""
                model.selectedVideoQualityPreset = 1
            }
            return
        }
        await MainActor.run {
            model.isLoading = true
        }
        // Read on its own, so the jiggler toggle shows the device's state even if the rest fails.
        async let jigglerRequest = try? client.getMouseJiggler()
        async let hidStateReq = try? client.getDetailedHidState()
        async let ocrReq = try? client.getStreamerOcrState()
        do {
            async let keymapsRequest = client.getHidKeymaps()
            async let streamer = client.getStreamerState()
            let loadedConfig = try await client.getSystemConfig()
            let km = try await keymapsRequest
            let st = try await streamer
            let edidValue = try await client.getEDID()
            let detailedHid = await hidStateReq
            let ocrState = await ocrReq
            await MainActor.run {
                model.config = loadedConfig
                inputManager.applyConfiguredMouseMode(isAbsolute: loadedConfig.isAbsoluteMouse)
                if let hidAbs = detailedHid?.mouse?.absolute {
                    inputManager.setGLKVMAbsoluteMouseMode(hidAbs)
                }
                webRTCManager.setPreferLowLatencyPlayout(loadedConfig.videoProcessing == "low_latency_first")
                // A connect after this one is refused up front if the device is in WebRTC (Native)
                // mode, which Overlook cannot stream from.
                if let address = connection.connectedDevice?.address {
                    webRTCManager.noteVideoMode(loadedConfig.videoMode, for: address)
                }
                model.keymaps = km
                model.hidState = detailedHid
                model.streamerState = st
                model.ocrState = ocrState
                ocrManager?.applyRemoteOcrState(ocrState)
                model.currentEdid = edidValue
                syncEdidSelectionFromCurrent()
                model.selectedVideoQualityPreset = Self.videoQualityPresetTag(forStreamQuality: loadedConfig.streamQuality)
                syncStreamerDraft(from: st)
                model.isLoading = false
            }
        } catch {
            let detailedHid = await hidStateReq
            let ocrState = await ocrReq
            await MainActor.run {
                model.hidState = detailedHid
                model.ocrState = ocrState
                ocrManager?.applyRemoteOcrState(ocrState)
                model.isLoading = false
                recordError("Failed to load settings: \(error)")
            }
        }
        if let jiggler = await jigglerRequest {
            inputManager.applyDeviceJigglerState(jiggler)
        }

        // Load collapsed optional subsystems only if their disclosure group is currently open.
        if model.isSystemExpanded {
            await refreshSystemInfo()
        }
        if model.isVirtualMediaExpanded {
            await refreshMsd()
        }
        if model.isGpioExpanded {
            await refreshGpio()
        }
        if model.isSwitchExpanded {
            await refreshSwitch()
        }
        if model.isAdvancedExpanded {
            await refreshPowerAndAdvanced()
        }
        if model.isNetworkExpanded {
            await loadNetworkSettings()
        }
    }

    func refreshPowerAndAdvanced() async {
        guard let client = connection.glkvmClient else { return }
        async let atxReq = try? client.getAtxState()
        async let rfReq = try? client.getRedfishSystem()
        async let rfMediaReq = try? client.getRedfishVirtualMedia()
        let (atx, rf, rfMedia) = await (atxReq, rfReq, rfMediaReq)
        await MainActor.run {
            model.atxState = atx
            model.redfishSystem = rf
            model.redfishMedia = rfMedia
        }
    }

    // MARK: - Mouse jiggler

    /// Switches the device's mouse jiggler and shows what the device then reports.
    func setMouseJiggler(_ on: Bool) async {
        guard let client = connection.glkvmClient else { return }
        model.isApplyingJiggler = true
        do {
            try await client.setMouseJiggler(on)
            // The `hid` event on the HID socket reports the change too; reading it back here also
            // works while that socket is down.
            if let state = try await client.getMouseJiggler() {
                inputManager.applyDeviceJigglerState(state)
            }
            // The web UI stores its jiggler switch in `mouse_jiggle`. It moves nothing, but left
            // alone it would say the opposite of what the device is doing, so it is kept in step.
            // Writes merge, so this touches no other key.
            updateConfig { $0.mouseJiggle = on }
        } catch {
            recordError("Failed to switch the mouse jiggler: \(error)")
        }
        model.isApplyingJiggler = false
    }

    /// The jiggler toggle: on while the device reports the jiggler active.
    var mouseJigglerBinding: Binding<Bool> {
        Binding(
            get: { inputManager.deviceJiggler?.isActive ?? false },
            set: { on in
                Task { await setMouseJiggler(on) }
            }
        )
    }

    // MARK: - Network Actions

    func loadNetworkSettings() async {
        guard let client = connection.glkvmClient else {
            if let host = connection.connectedDevice?.host {
                model.networkIP = host
            }
            return
        }

        let net = try? await client.getNetworkConfig()
        let wifi = try? await client.getWifiConfig()
        let eth = try? await client.getEthernetConfig()

        await MainActor.run {
            if let net {
                model.networkConfig = net
                model.networkMode = net.mode
                model.networkIP = net.ip
                model.networkNetmask = net.netmask
                model.networkGateway = net.gateway
                model.networkDNS = net.dns
            } else if let host = connection.connectedDevice?.host {
                model.networkIP = host
            }

            if let wifi {
                model.wifiConfig = wifi
                model.wifiEnabled = wifi.enabled
                model.wifiSSID = wifi.ssid
                model.wifiStatus = wifi.status
            }

            if let eth {
                model.ethernetConfig = eth
                model.ethernetConnected = eth.connected
                model.ethernetSpeed = eth.speed
                model.ethernetIP = eth.ip
                model.ethernetMAC = eth.mac
            }
        }
    }

    func applyNetworkConfig() async {
        guard let client = connection.glkvmClient else { return }
        model.isApplyingNetwork = true
        defer { model.isApplyingNetwork = false }

        let newConfig = GLKVMNetworkConfig(
            mode: model.networkMode,
            ip: model.networkIP,
            netmask: model.networkNetmask,
            gateway: model.networkGateway,
            dns: model.networkDNS
        )

        do {
            let updated = try await client.setNetworkConfig(newConfig)
            model.networkConfig = updated
            model.networkMode = updated.mode
            model.networkIP = updated.ip
            model.networkNetmask = updated.netmask
            model.networkGateway = updated.gateway
            model.networkDNS = updated.dns
        } catch {
            recordError("Failed to apply network configuration: \(error.localizedDescription)")
        }
    }

    func applyWifiConfig() async {
        guard let client = connection.glkvmClient else { return }
        model.isApplyingWifi = true
        defer { model.isApplyingWifi = false }

        let newConfig = GLKVMWifiConfig(
            enabled: model.wifiEnabled,
            ssid: model.wifiSSID,
            password: model.wifiPassword.isEmpty ? nil : model.wifiPassword,
            status: "Connecting..."
        )

        do {
            let updated = try await client.setWifiConfig(newConfig)
            model.wifiConfig = updated
            model.wifiEnabled = updated.enabled
            model.wifiSSID = updated.ssid
            model.wifiStatus = updated.status
        } catch {
            recordError("Failed to apply Wi-Fi configuration: \(error.localizedDescription)")
        }
    }

    // MARK: - HID Actions

    func setHidConnected(_ connected: Bool) async {
        guard let client = connection.glkvmClient else { return }
        model.isApplyingHid = true
        defer { model.isApplyingHid = false }

        do {
            try await client.setHidConnected(connected)
            model.hidState = try await client.getDetailedHidState()
        } catch {
            recordError("Failed to set HID connection state: \(error.localizedDescription)")
        }
    }

    func setHidOutput(keyboard: String? = nil, mouse: String? = nil) async {
        guard let client = connection.glkvmClient else { return }
        model.isApplyingHid = true
        defer { model.isApplyingHid = false }

        var params: [String: String] = [:]
        if let keyboard, !keyboard.isEmpty { params["keyboard_output"] = keyboard }
        if let mouse, !mouse.isEmpty { params["mouse_output"] = mouse }
        guard !params.isEmpty else { return }

        do {
            try await client.setHIDParams(params)
            let updated = try await client.getDetailedHidState()
            model.hidState = updated
            if let abs = updated.mouse?.absolute {
                inputManager.setGLKVMAbsoluteMouseMode(abs)
            }
        } catch {
            recordError("Failed to update HID output parameters: \(error.localizedDescription)")
        }
    }

    func resetHidOnly() async {
        guard let client = connection.glkvmClient else { return }
        model.isApplyingHid = true
        defer { model.isApplyingHid = false }

        do {
            try await client.resetHid()
            model.hidState = try? await client.getDetailedHidState()
        } catch {
            recordError("Failed to reset HID: \(error.localizedDescription)")
        }
    }

    func sendShortcut(_ keys: [String]) async {
        guard let client = connection.glkvmClient else { return }
        let cleaned = keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }

        model.isSendingHidTextOrShortcut = true
        defer { model.isSendingHidTextOrShortcut = false }

        do {
            try await client.sendHidShortcut(keys: cleaned)
        } catch {
            recordError("Failed to send shortcut (\(cleaned.joined(separator: "+"))): \(error.localizedDescription)")
        }
    }

    func sendSingleKey(_ key: String, finish: Bool = true) async {
        guard let client = connection.glkvmClient else { return }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        model.isSendingHidTextOrShortcut = true
        defer { model.isSendingHidTextOrShortcut = false }

        do {
            try await client.sendHidKey(key: trimmed, state: true, finish: finish)
        } catch {
            recordError("Failed to send key (\(trimmed)): \(error.localizedDescription)")
        }
    }

    func sendRemoteTypedText() async {
        guard let client = connection.glkvmClient else { return }
        let text = model.remoteTypeTextDraft
        guard !text.isEmpty else { return }

        model.isSendingHidTextOrShortcut = true
        defer { model.isSendingHidTextOrShortcut = false }

        do {
            let keymap = model.config?.keymap ?? model.keymaps?.keymaps.default
            let delay = model.remoteTypeSlowMode ? model.remoteTypeDelaySeconds : nil
            try await client.hidPrint(
                text: text,
                keymap: keymap,
                limit: max(0, model.remoteTypeLimit),
                slow: model.remoteTypeSlowMode,
                delay: delay
            )
            model.remoteTypeTextDraft = ""
        } catch {
            recordError("Failed to type text on remote host: \(error.localizedDescription)")
        }
    }

    // MARK: - ATX Power & Button Actions

    func performAtxAction(_ action: GLKVMClient.AtxPowerAction) async {
        guard let client = connection.glkvmClient else { return }
        model.isApplyingAtx = true
        defer { model.isApplyingAtx = false }

        do {
            try await client.atxPower(action, wait: model.atxWaitForCompletion)
            model.atxState = try await client.getAtxState()
        } catch {
            recordError("Failed to perform ATX power action (\(action.displayName)): \(error.localizedDescription)")
        }
    }

    func performAtxButtonClick(_ button: GLKVMClient.AtxButton) async {
        guard let client = connection.glkvmClient else { return }
        model.isApplyingAtx = true
        defer { model.isApplyingAtx = false }

        do {
            try await client.atxClick(button, wait: model.atxWaitForCompletion)
            model.atxState = try await client.getAtxState()
        } catch {
            recordError("Failed to click ATX button (\(button.displayName)): \(error.localizedDescription)")
        }
    }

    // MARK: - Virtual Media (MSD) Actions

    func syncMsdDraft(from state: GLKVMMsdState) {
        if let drive = state.drive {
            model.msdCdromMode = drive.cdrom
            model.msdReadWriteMode = drive.rw
            if let img = drive.imageName, !img.isEmpty {
                model.msdSelectedImage = img
            } else if model.msdSelectedImage.isEmpty, let first = state.storage?.images.first?.name {
                model.msdSelectedImage = first
            }
        }
    }

    func refreshMsd(includePartitions: Bool = false) async {
        guard let client = connection.glkvmClient else { return }
        model.msdState = try? await client.getMsdState()
        if includePartitions {
            model.msdPartitions = try? await client.msdPartitionShow()
        }
        if let st = model.msdState {
            syncMsdDraft(from: st)
        }
    }

    func applyMsdParams() async {
        guard let client = connection.glkvmClient else { return }
        model.isApplyingMsd = true
        defer { model.isApplyingMsd = false }

        do {
            let imageParam = model.msdSelectedImage.trimmingCharacters(in: .whitespacesAndNewlines)
            try await client.setMsdParams(
                image: imageParam.isEmpty ? nil : imageParam,
                cdrom: model.msdCdromMode,
                rw: model.msdCdromMode ? false : model.msdReadWriteMode,
                user: model.msdRemoteUserDraft.isEmpty ? nil : model.msdRemoteUserDraft,
                passwd: model.msdRemotePasswordDraft.isEmpty ? nil : model.msdRemotePasswordDraft,
                verify: model.msdRemoteVerifyTLS
            )
            await refreshMsd()
        } catch {
            recordError("Failed to update MSD parameters: \(error.localizedDescription)")
        }
    }

    func setMsdConnected(_ connected: Bool) async {
        guard let client = connection.glkvmClient else { return }
        model.isApplyingMsd = true
        defer { model.isApplyingMsd = false }

        do {
            if connected,
               model.msdState?.drive?.imageName == nil,
               !model.msdSelectedImage.isEmpty {
                try await client.setMsdParams(
                    image: model.msdSelectedImage,
                    cdrom: model.msdCdromMode,
                    rw: model.msdCdromMode ? false : model.msdReadWriteMode
                )
            }
            try await client.setMsdConnected(connected)
            await refreshMsd()
        } catch {
            recordError("Failed to \(connected ? "connect" : "disconnect") virtual drive: \(error.localizedDescription)")
        }
    }

    func chooseAndUploadLocalMsdImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Upload Image"
        panel.message = "Select a disk image (.iso, .img, .bin, .flp) to upload to the KVM Mass Storage Drive."
        guard panel.runModal() == .OK, let fileURL = panel.url else { return }

        Task {
            await uploadLocalMsdImage(from: fileURL)
        }
    }

    func uploadLocalMsdImage(from fileURL: URL) async {
        guard let client = connection.glkvmClient else { return }
        model.isApplyingMsd = true
        defer { model.isApplyingMsd = false }

        do {
            let data = try Data(contentsOf: fileURL)
            let name = fileURL.lastPathComponent
            _ = try await client.msdWrite(image: name, data: data, removeIncomplete: true)
            model.msdSelectedImage = name
            await refreshMsd()
        } catch {
            recordError("Failed to upload disk image: \(error.localizedDescription)")
        }
    }

    func uploadRemoteMsdImageByURL() async {
        guard let client = connection.glkvmClient else { return }
        let rawURL = model.msdRemoteURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawURL), !rawURL.isEmpty else {
            recordError("Enter a valid HTTP/HTTPS URL for the remote disk image.")
            return
        }

        model.isApplyingMsd = true
        defer { model.isApplyingMsd = false }

        let customName = model.msdRemoteImageNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await client.msdWriteRemote(
                url: url,
                image: customName.isEmpty ? nil : customName,
                insecure: !model.msdRemoteVerifyTLS,
                timeout: 30,
                removeIncomplete: true
            )
            model.msdRemoteURLDraft = ""
            model.msdRemoteImageNameDraft = ""
            await refreshMsd()
        } catch {
            recordError("Failed to download remote image to MSD: \(error.localizedDescription)")
        }
    }

    func removeMsdImage(_ imageName: String) async {
        guard let client = connection.glkvmClient else { return }
        model.isApplyingMsd = true
        defer { model.isApplyingMsd = false }

        do {
            try await client.msdRemove(image: imageName)
            if model.msdSelectedImage == imageName {
                model.msdSelectedImage = ""
            }
            await refreshMsd()
        } catch {
            recordError("Failed to remove MSD image (\(imageName)): \(error.localizedDescription)")
        }
    }

    func downloadMsdImage(_ imageName: String) {
        guard let client = connection.glkvmClient else { return }
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = imageName
        savePanel.canCreateDirectories = true
        guard savePanel.runModal() == .OK, let targetURL = savePanel.url else { return }

        Task {
            model.isApplyingMsd = true
            defer { model.isApplyingMsd = false }
            do {
                let data = try await client.msdRead(image: imageName)
                try data.write(to: targetURL, options: .atomic)
            } catch {
                recordError("Failed to download image (\(imageName)): \(error.localizedDescription)")
            }
        }
    }

    func resetMsd() async {
        guard let client = connection.glkvmClient else { return }
        model.isApplyingMsd = true
        defer { model.isApplyingMsd = false }

        do {
            try await client.msdReset()
            await refreshMsd()
        } catch {
            recordError("Failed to reset Mass Storage Drive: \(error.localizedDescription)")
        }
    }

    func connectMsdPartition() async {
        guard let client = connection.glkvmClient else { return }
        model.isApplyingMsd = true
        defer { model.isApplyingMsd = false }
        do {
            try await client.msdPartitionConnect()
            await refreshMsd(includePartitions: true)
        } catch {
            recordError("Failed to connect MSD partition: \(error.localizedDescription)")
        }
    }

    func disconnectMsdPartition() async {
        guard let client = connection.glkvmClient else { return }
        model.isApplyingMsd = true
        defer { model.isApplyingMsd = false }
        do {
            try await client.msdPartitionDisconnect()
            await refreshMsd(includePartitions: true)
        } catch {
            recordError("Failed to disconnect MSD partition: \(error.localizedDescription)")
        }
    }

    // MARK: - GPIO Actions

    func refreshGpio() async {
        guard let client = connection.glkvmClient else { return }
        model.gpioState = try? await client.getGpioState()
    }

    func switchGpio(channel: String, state: Bool) async {
        guard let client = connection.glkvmClient else { return }
        model.isApplyingGpio = true
        defer { model.isApplyingGpio = false }

        do {
            try await client.switchGpioChannel(channel: channel, state: state, wait: false)
            model.gpioState = try await client.getGpioState()
        } catch {
            recordError("Failed to switch GPIO channel \(channel): \(error.localizedDescription)")
        }
    }

    func pulseGpio(channel: String, delay: Double? = nil) async {
        guard let client = connection.glkvmClient else { return }
        model.isApplyingGpio = true
        defer { model.isApplyingGpio = false }

        do {
            try await client.pulseGpioChannel(channel: channel, delay: delay, wait: false)
            model.gpioState = try await client.getGpioState()
        } catch {
            recordError("Failed to pulse GPIO channel \(channel): \(error.localizedDescription)")
        }
    }

    // MARK: - PiKVM Switch Actions

    func refreshSwitch() async {
        guard let client = connection.glkvmClient else { return }
        let sw = try? await client.getSwitchState()
        model.switchState = sw
        if let active = sw?.activePort {
            model.switchTargetPortDraft = active
        }
    }

    func switchSelectPort(_ port: String) async {
        guard let client = connection.glkvmClient else { return }
        model.isApplyingSwitch = true
        defer { model.isApplyingSwitch = false }

        do {
            try await client.switchSetActive(port: port)
            model.switchState = try? await client.getSwitchState()
        } catch {
            recordError("Failed to switch to port \(port): \(error.localizedDescription)")
        }
    }

    func switchSelectPrevPort() async {
        guard let client = connection.glkvmClient else { return }
        model.isApplyingSwitch = true
        defer { model.isApplyingSwitch = false }

        do {
            try await client.switchSetActivePrev()
            model.switchState = try? await client.getSwitchState()
        } catch {
            recordError("Failed to switch to previous port: \(error.localizedDescription)")
        }
    }

    func switchSelectNextPort() async {
        guard let client = connection.glkvmClient else { return }
        model.isApplyingSwitch = true
        defer { model.isApplyingSwitch = false }

        do {
            try await client.switchSetActiveNext()
            model.switchState = try? await client.getSwitchState()
        } catch {
            recordError("Failed to switch to next port: \(error.localizedDescription)")
        }
    }

    func switchSetBeacon(state: Bool, port: String? = nil) async {
        guard let client = connection.glkvmClient else { return }
        model.isApplyingSwitch = true
        defer { model.isApplyingSwitch = false }

        do {
            try await client.switchSetBeacon(state: state, port: port)
            model.switchState = try? await client.getSwitchState()
        } catch {
            recordError("Failed to set switch beacon: \(error.localizedDescription)")
        }
    }

    func switchApplyBeaconColors() async {
        guard let client = connection.glkvmClient else { return }
        let spec = model.switchBeaconColorDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spec.isEmpty else { return }

        model.isApplyingSwitch = true
        defer { model.isApplyingSwitch = false }

        do {
            try await client.switchSetColors(beaconHexSpec: spec)
            model.switchState = try? await client.getSwitchState()
        } catch {
            recordError("Failed to set switch beacon color: \(error.localizedDescription)")
        }
    }

    func switchApplyPortParams() async {
        guard let client = connection.glkvmClient else { return }
        let port = model.switchTargetPortDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !port.isEmpty else { return }

        model.isApplyingSwitch = true
        defer { model.isApplyingSwitch = false }

        do {
            let name = model.switchPortNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let edid = model.switchPortEdidIdDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            try await client.switchSetPortParams(
                port: port,
                edidId: edid.isEmpty ? nil : edid,
                dummy: model.switchPortDummyDraft,
                name: name.isEmpty ? nil : name
            )
            model.switchState = try? await client.getSwitchState()
        } catch {
            recordError("Failed to configure switch port \(port): \(error.localizedDescription)")
        }
    }

    func switchPerformAtxPower(port: String, action: GLKVMClient.AtxPowerAction) async {
        guard let client = connection.glkvmClient else { return }
        model.isApplyingSwitch = true
        defer { model.isApplyingSwitch = false }

        do {
            try await client.switchAtxPower(port: port, action: action)
        } catch {
            recordError("Failed to perform switch ATX power on port \(port): \(error.localizedDescription)")
        }
    }

    func switchPerformAtxClick(port: String, button: GLKVMClient.AtxButton) async {
        guard let client = connection.glkvmClient else { return }
        model.isApplyingSwitch = true
        defer { model.isApplyingSwitch = false }

        do {
            try await client.switchAtxClick(port: port, button: button)
        } catch {
            recordError("Failed to click switch ATX button on port \(port): \(error.localizedDescription)")
        }
    }

    func switchRebootUnit(_ unit: Int, bootloader: Bool = false) async {
        guard let client = connection.glkvmClient else { return }
        model.isApplyingSwitch = true
        defer { model.isApplyingSwitch = false }

        do {
            try await client.switchReset(unit: unit, bootloader: bootloader)
        } catch {
            recordError("Failed to reboot switch unit \(unit): \(error.localizedDescription)")
        }
    }

    // MARK: - Redfish Actions

    func performRedfishReset(_ resetType: GLKVMClient.RedfishResetType) async {
        guard let client = connection.glkvmClient else { return }
        model.isApplyingRedfish = true
        defer { model.isApplyingRedfish = false }

        do {
            try await client.redfishSystemReset(resetType: resetType)
            model.redfishSystem = try? await client.getRedfishSystem()
        } catch {
            recordError("Redfish reset (\(resetType.rawValue)) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - System Info, Logs & Prometheus

    func refreshSystemInfo() async {
        guard let client = connection.glkvmClient else { return }
        model.systemInfo = try? await client.getSystemInfo()
    }

    func fetchDeviceServiceLog() async {
        guard let client = connection.glkvmClient else { return }
        model.isFetchingLogs = true
        defer { model.isFetchingLogs = false }

        do {
            let logText = try await client.getSystemLog(seekSeconds: model.logSeekSeconds, follow: false)
            model.deviceServiceLogText = logText.isEmpty ? "(No KVMD log entries returned for the selected window)" : logText
            model.showingDeviceLogSheet = true
        } catch {
            recordError("Failed to fetch KVMD service logs: \(error.localizedDescription)")
        }
    }

    func fetchPrometheusMetrics() async {
        guard let client = connection.glkvmClient else { return }
        model.isFetchingLogs = true
        defer { model.isFetchingLogs = false }

        do {
            let metrics = try await client.getPrometheusMetrics()
            model.prometheusMetricsText = metrics.isEmpty ? "(No Prometheus metrics returned)" : metrics
            model.showingPrometheusSheet = true
        } catch {
            recordError("Failed to fetch Prometheus metrics: \(error.localizedDescription)")
        }
    }

    func deleteCachedStreamerSnapshot() async {
        guard let client = connection.glkvmClient else { return }
        do {
            try await client.deleteStreamerSnapshot()
        } catch {
            recordError("Failed to delete cached streamer snapshot: \(error.localizedDescription)")
        }
    }

    // MARK: - Errors

    func recordError(_ message: String) {
        model.errorMessage = message
        model.errorHistory.insert(WebUISettingsPanelModel.ErrorEntry(date: Date(), message: message), at: 0)
        if model.errorHistory.count > 50 {
            model.errorHistory.removeLast(model.errorHistory.count - 50)
        }
    }

    // MARK: - Keyboard

    func availableKeymaps() -> [String] {
        if let loadedKeymaps = model.keymaps {
            let list = loadedKeymaps.keymaps.available
            if let current = model.config?.keymap, !current.isEmpty, !list.contains(current) {
                return [current] + list
            }
            return list
        }
        if let current = model.config?.keymap, !current.isEmpty {
            return [current]
        }
        return ["en-us"]
    }

    // MARK: - Video quality presets

    /// The Quality picker entry for a stored `stream_quality`: the preset with that value, or
    /// Custom for any other value (Auto, 5, among them) and for none (missing, or not a number).
    nonisolated static func videoQualityPresetTag(forStreamQuality streamQuality: Int?) -> Int {
        streamQuality.flatMap { QualityPreset(rawValue: $0)?.rawValue } ?? WebUISettingsPanelModel.videoQualityCustomTag
    }

    /// Whether the device's current EDID, as last read from it, is a 4K catalog entry. False
    /// while the EDID is not loaded yet.
    var isCurrentEdid4K: Bool {
        QualityPreset.is4K(edidCatalogID: currentEdidCatalogID)
    }

    func applyVideoQualityPreset(_ tag: Int) async {
        guard tag != WebUISettingsPanelModel.videoQualityCustomTag else { return }
        guard let client = connection.glkvmClient else { return }
        guard let preset = QualityPreset(rawValue: tag) else { return }

        let params = QualityPreset.params(for: preset, is4K: isCurrentEdid4K)

        await MainActor.run {
            model.isApplyingStreamer = true
        }

        do {
            try await client.setStreamerParams(params)
            try? await Task.sleep(nanoseconds: 300_000_000)
            let st = try? await client.getStreamerState()
            await MainActor.run {
                model.streamerState = st
                syncStreamerDraft(from: st)
            }
        } catch {
            await MainActor.run {
                recordError("Failed to apply quality preset: \(error)")
            }
        }

        await MainActor.run {
            model.isApplyingStreamer = false
            updateConfig { $0.streamQuality = preset.streamQuality }
        }
    }

    // MARK: - EDID

    func normalizedEdid(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .lowercased()
    }

    /// The catalog id of the entry whose bytes are the device's current EDID (`currentEdid`, as
    /// last read from the device); nil when that is not loaded yet or matches no entry.
    var currentEdidCatalogID: String? {
        let normalizedCurrent = normalizedEdid(model.currentEdid)
        guard !normalizedCurrent.isEmpty else { return nil }
        return EDIDCatalog.options.first(where: { opt in
            guard let edid = EDIDCatalog.resolvedEdid(for: opt) else { return false }
            return normalizedEdid(edid) == normalizedCurrent
        })?.id
    }

    func syncEdidSelectionFromCurrent() {
        model.isProgrammaticEdidSelectionUpdate = true
        defer {
            Task { @MainActor in
                await Task.yield()
                model.isProgrammaticEdidSelectionUpdate = false
            }
        }

        let normalizedCurrent = normalizedEdid(model.currentEdid)
        if normalizedCurrent.isEmpty {
            model.selectedEdidOption = EDIDCatalog.customOptionID
            model.customEdidDraft = ""
            return
        }

        if let matchID = currentEdidCatalogID {
            model.selectedEdidOption = matchID
            model.customEdidDraft = model.currentEdid
            return
        }

        model.selectedEdidOption = EDIDCatalog.customOptionID
        model.customEdidDraft = model.currentEdid
    }

    func applyEdid(_ value: String) async {
        guard let client = connection.glkvmClient else { return }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        model.isApplyingEdid = true

        do {
            try await client.setEDID(trimmed)
            let updated = try await client.getEDID()
            model.currentEdid = updated
            syncEdidSelectionFromCurrent()
            model.isApplyingEdid = false
        } catch {
            model.isApplyingEdid = false
            recordError("Failed to apply EDID: \(error)")
        }
    }
}

/// Streamer parameter drafts, debounced apply, and commit-on-blur.
extension WebUISettingsActions {
    // MARK: - Streamer params

    func syncStreamerDraft(from state: GLKVMStreamerState?) {
        guard let params = state?.params else { return }

        if model.focusedStreamerField != nil { return }

        model.isProgrammaticStreamerDraftUpdate = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            model.isProgrammaticStreamerDraftUpdate = false
        }

        if let desiredFps = params.desiredFps { model.streamerDesiredFps = desiredFps }
        if let quality = params.quality { model.streamerQuality = quality }
        if let bitrate = params.h264Bitrate { model.streamerH264Bitrate = bitrate }
        if let gop = params.h264Gop { model.streamerH264Gop = gop }
        if let zeroDelay = params.zeroDelay { model.streamerZeroDelay = zeroDelay }
        if let resolution = params.resolution { model.streamerResolution = resolution }

        model.streamerDesiredFpsText = String(model.streamerDesiredFps)
        model.streamerQualityText = String(model.streamerQuality)
        model.streamerH264BitrateText = String(model.streamerH264Bitrate)
        model.streamerH264GopText = String(model.streamerH264Gop)
    }

    func scheduleStreamerApply() {
        guard model.isProgrammaticStreamerDraftUpdate == false else { return }
        model.applyStreamerTask?.cancel()
        model.applyStreamerTask = Task {
            // Debounced like `scheduleApply`, for the same reason.
            guard await Self.debounce(nanoseconds: 250_000_000) else { return }
            model.applyStreamerTask = nil
            await applyStreamerParams()
        }
    }

    func applyStreamerParams() async {
        guard let client = connection.glkvmClient else { return }
        guard model.streamerState != nil else { return }

        guard model.isProgrammaticStreamerDraftUpdate == false else { return }

        model.isApplyingStreamer = true

        let features = streamerFeatures

        let desiredFpsMin = streamerLimits?.desiredFps.min ?? 1
        let desiredFpsMax = streamerLimits?.desiredFps.max ?? 60
        let bitrateMin = streamerLimits?.h264Bitrate.min ?? 100
        let bitrateMax = streamerLimits?.h264Bitrate.max ?? 20000
        let gopMin = streamerLimits?.h264Gop.min ?? 1
        let gopMax = streamerLimits?.h264Gop.max ?? 300

        let clampedFps = clamp(model.streamerDesiredFps, min: desiredFpsMin, max: desiredFpsMax)
        let clampedQuality = clamp(model.streamerQuality, min: 0, max: 100)
        let clampedBitrate = clamp(model.streamerH264Bitrate, min: bitrateMin, max: bitrateMax)
        let clampedGop = clamp(model.streamerH264Gop, min: gopMin, max: gopMax)

        var params: [String: String] = [:]
        params["desired_fps"] = String(clampedFps)

        if features?.quality != false {
            params["quality"] = String(clampedQuality)
        }

        if features?.h264 != false {
            params["h264_bitrate"] = String(clampedBitrate)
            params["h264_gop"] = String(clampedGop)
        }

        if features?.zeroDelay != false {
            params["zero_delay"] = model.streamerZeroDelay ? "true" : "false"
        }

        if features?.resolution != false {
            let trimmed = model.streamerResolution.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                params["resolution"] = trimmed
            }
        }

        do {
            try await client.setStreamerParams(params)
            try? await Task.sleep(nanoseconds: 300_000_000)
            let st = try? await client.getStreamerState()
            model.streamerState = st
            syncStreamerDraft(from: st)
            model.isApplyingStreamer = false
        } catch {
            model.isApplyingStreamer = false
            recordError("Failed to apply streamer params: \(error)")
        }
    }

    func commitStreamerEditsAndApplyIfNeeded() {
        guard model.isProgrammaticStreamerDraftUpdate == false else { return }

        model.isProgrammaticStreamerDraftUpdate = true
        defer {
            Task { @MainActor in
                await Task.yield()
                model.isProgrammaticStreamerDraftUpdate = false
            }
        }

        let desiredFpsMin = streamerLimits?.desiredFps.min ?? 1
        let desiredFpsMax = streamerLimits?.desiredFps.max ?? 60
        let bitrateMin = streamerLimits?.h264Bitrate.min ?? 100
        let bitrateMax = streamerLimits?.h264Bitrate.max ?? 20000
        let gopMin = streamerLimits?.h264Gop.min ?? 1
        let gopMax = streamerLimits?.h264Gop.max ?? 300

        let parsedFps = Int(model.streamerDesiredFpsText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? model.streamerDesiredFps
        let parsedQuality = Int(model.streamerQualityText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? model.streamerQuality
        let parsedBitrate = Int(model.streamerH264BitrateText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? model.streamerH264Bitrate
        let parsedGop = Int(model.streamerH264GopText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? model.streamerH264Gop

        let nextFps = clamp(parsedFps, min: desiredFpsMin, max: desiredFpsMax)
        let nextQuality = clamp(parsedQuality, min: 0, max: 100)
        let nextBitrate = clamp(parsedBitrate, min: bitrateMin, max: bitrateMax)
        let nextGop = clamp(parsedGop, min: gopMin, max: gopMax)

        if nextFps != model.streamerDesiredFps { model.streamerDesiredFps = nextFps }
        if nextQuality != model.streamerQuality { model.streamerQuality = nextQuality }
        if nextBitrate != model.streamerH264Bitrate { model.streamerH264Bitrate = nextBitrate }
        if nextGop != model.streamerH264Gop { model.streamerH264Gop = nextGop }

        model.streamerDesiredFpsText = String(model.streamerDesiredFps)
        model.streamerQualityText = String(model.streamerQuality)
        model.streamerH264BitrateText = String(model.streamerH264Bitrate)
        model.streamerH264GopText = String(model.streamerH264Gop)

        // Apply once after commit.
        Task { @MainActor in
            await Task.yield()
            scheduleStreamerApply()
        }
    }

    var streamerResolutionSelection: Binding<String> {
        Binding(
            get: {
                let trimmed = model.streamerResolution.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return "" }
                if Self.streamerResolutionPresets.contains(trimmed) {
                    return trimmed
                }
                return "custom"
            },
            set: { newValue in
                if newValue == "custom" {
                    return
                }
                model.streamerResolution = newValue
                scheduleStreamerApply()
            }
        )
    }

    func setPreferLowLatencyPlayout(_ prefer: Bool) {
        webRTCManager.setPreferLowLatencyPlayout(prefer)
    }

    // MARK: - Misc actions

    func clamp(_ value: Int, min: Int, max: Int) -> Int {
        if value < min { return min }
        if value > max { return max }
        return value
    }

    func resetKVM() async {
        guard let client = connection.glkvmClient else { return }
        do {
            try await client.resetHid()
            try await client.resetStreamer()
        } catch {
            await MainActor.run {
                recordError("Failed to reset: \(error)")
            }
        }
    }
}

/// `GLKVMSystemConfig` plumbing: debounced writes and the bindings the section views drive.
extension WebUISettingsActions {
    // MARK: - Config plumbing

    /// Changes the shown config and queues the keys that changed for the next write. Only those
    /// keys are written, over the config as the device holds it (`updateSystemConfig`).
    func updateConfig(_ mutate: (inout GLKVMSystemConfig) -> Void) {
        guard var next = model.config else { return }
        let previous = next
        mutate(&next)
        model.config = next
        let changes = next.changes(from: previous)
        guard !changes.isEmpty else { return }
        // Changes made within one debounce window go out together in one write.
        model.pendingConfigChanges.merge(changes) { _, newer in newer }
        scheduleApply()
    }

    func scheduleApply() {
        model.applyTask?.cancel()
        model.applyTask = Task {
            guard await Self.debounce(nanoseconds: 150_000_000) else { return }
            // From here the write is under way. Let go of the handle so a change made while it is
            // on its way only cancels its own wait: cancelling this task now would cancel the
            // request half-sent.
            model.applyTask = nil
            await applyPendingConfigChanges()
        }
    }

    /// Waits out a debounce window. Returns false when a newer change cancelled the wait, in which
    /// case the caller writes nothing and the newer change writes instead.
    static func debounce(nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
            return false
        }
        return !Task.isCancelled
    }

    /// Writes the changes queued since the last write.
    func applyPendingConfigChanges() async {
        let changes = model.pendingConfigChanges
        model.pendingConfigChanges = [:]
        guard !changes.isEmpty else { return }
        await apply(changes)
    }

    func apply(_ changes: GLKVMJSONObject) async {
        guard let client = connection.glkvmClient else { return }
        model.configWritesInFlight += 1
        model.isApplying = true
        do {
            let updated = try await client.updateSystemConfig(changes)
            // The config only records the WebUI's preference; the device's HID gadget is switched
            // through hid/set_params, and it reports the result in a `hid` event. Without this the
            // toggle changed which reports Overlook sent, not which ones the device accepted.
            if changes[GLKVMSystemConfig.CodingKeys.isAbsoluteMouse.rawValue] != nil {
                try await client.setHIDParams(["mouse_output": updated.isAbsoluteMouse ? "usb" : "usb_rel"])
            }
            model.configWritesInFlight -= 1
            model.isApplying = model.configWritesInFlight > 0
            // While another write is on its way, or a change waits for one, this write's result
            // is not the latest; showing it would undo that change on screen until it lands.
            if model.configWritesInFlight == 0, model.pendingConfigChanges.isEmpty {
                model.config = updated
            }
            inputManager.setGLKVMAbsoluteMouseMode(updated.isAbsoluteMouse)
        } catch {
            model.configWritesInFlight -= 1
            model.isApplying = model.configWritesInFlight > 0
            recordError("Failed to apply settings: \(error)")
        }
    }

    // MARK: - Config bindings

    func bindingString(
        get: @escaping (GLKVMSystemConfig) -> String,
        set: @escaping (inout GLKVMSystemConfig, String) -> Void,
        defaultValue: String
    ) -> Binding<String> {
        Binding(
            get: { model.config.map(get) ?? defaultValue },
            set: { newValue in
                guard model.config != nil, !model.isLoading, !model.isApplying else { return }
                updateConfig { set(&$0, newValue) }
            }
        )
    }

    func bindingInt(
        get: @escaping (GLKVMSystemConfig) -> Int,
        set: @escaping (inout GLKVMSystemConfig, Int) -> Void,
        defaultValue: Int
    ) -> Binding<Int> {
        Binding(
            get: { model.config.map(get) ?? defaultValue },
            set: { newValue in
                guard model.config != nil, !model.isLoading, !model.isApplying else { return }
                updateConfig { set(&$0, newValue) }
            }
        )
    }

    func bindingBool(
        get: @escaping (GLKVMSystemConfig) -> Bool,
        set: @escaping (inout GLKVMSystemConfig, Bool) -> Void,
        defaultValue: Bool
    ) -> Binding<Bool> {
        Binding(
            get: { model.config.map(get) ?? defaultValue },
            set: { newValue in
                guard model.config != nil, !model.isLoading, !model.isApplying else { return }
                updateConfig { set(&$0, newValue) }
            }
        )
    }

    func bindingIntValue(get: @escaping (GLKVMSystemConfig) -> Int, defaultValue: Int) -> Int {
        model.config.map(get) ?? defaultValue
    }
}
