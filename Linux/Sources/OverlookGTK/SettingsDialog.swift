import Foundation
import CDesktop
import OverlookCore

final class SettingsDialogController {
    unowned let desktop: Desktop
    var dialog: UnsafeMutableRawPointer?
    var isSyncing = false

    // Loaded remote state
    var config: KVMSystemConfig?
    var streamerState: KVMStreamerState?
    var ocrState: KVMStreamerOcrState?
    var hidState: KVMHidState?
    var keymaps: KVMHidKeymapsState?
    var atxState: KVMAtxState?
    var msdState: KVMMsdState?
    var msdPartitions: KVMMSDPartitionShowResult?
    var gpioState: KVMGpioState?
    var switchState: KVMSwitchState?
    var redfishSystem: KVMRedfishSystem?
    var systemInfo: KVMSystemInfo?
    var networkConfig: KVMNetworkConfig?
    var wifiConfig: KVMWifiConfig?
    var ethernetConfig: KVMEthernetConfig?
    var currentEdid = ""

    // Video & Capture widgets
    var videoModeCombo: UnsafeMutableRawPointer?
    var qualityPresetCombo: UnsafeMutableRawPointer?
    var edidCombo: UnsafeMutableRawPointer?
    var customEdidRow: UnsafeMutableRawPointer?
    var orientationCombo: UnsafeMutableRawPointer?
    var showCursorSwitch: UnsafeMutableRawPointer?
    var fpsSpin: UnsafeMutableRawPointer?
    var qualitySpin: UnsafeMutableRawPointer?
    var bitrateSpin: UnsafeMutableRawPointer?
    var gopSpin: UnsafeMutableRawPointer?
    var zeroDelaySwitch: UnsafeMutableRawPointer?
    var resolutionCombo: UnsafeMutableRawPointer?
    var customResolutionRow: UnsafeMutableRawPointer?
    var ocrPreferSwitch: UnsafeMutableRawPointer?
    var ocrLangCombo: UnsafeMutableRawPointer?
    var availableOcrLangs: [String] = ["eng"]
    var screenshotsEntry: UnsafeMutableRawPointer?
    var recordingsEntry: UnsafeMutableRawPointer?
    var codecCombo: UnsafeMutableRawPointer?
    var vaapiEntry: UnsafeMutableRawPointer?
    var vaapiStatusRow: UnsafeMutableRawPointer?

    // Input & HID widgets
    var mouseControlSwitch: UnsafeMutableRawPointer?
    var keyboardControlSwitch: UnsafeMutableRawPointer?
    var hidConnectedSwitch: UnsafeMutableRawPointer?
    var kbOutputCombo: UnsafeMutableRawPointer?
    var mouseOutputCombo: UnsafeMutableRawPointer?
    var kbOutputsList: [String] = ["usb", "ps2", "disabled"]
    var mouseOutputsList: [String] = ["usb", "usb_rel", "usb_win98", "ps2", "disabled"]
    var mouseModeCombo: UnsafeMutableRawPointer?
    var mousePollingSpin: UnsafeMutableRawPointer?
    var relativeSenseSpin: UnsafeMutableRawPointer?
    var scrollRateSpin: UnsafeMutableRawPointer?
    var scrollDirCombo: UnsafeMutableRawPointer?
    var jigglerSwitch: UnsafeMutableRawPointer?
    var localRelSenseSpin: UnsafeMutableRawPointer?
    var fingerbotSpin: UnsafeMutableRawPointer?
    var kbLedsRow: UnsafeMutableRawPointer?
    var keymapCombo: UnsafeMutableRawPointer?
    var keymapList: [String] = ["en-us"]
    var customShortcutEntry: UnsafeMutableRawPointer?
    var remoteTypeEntry: UnsafeMutableRawPointer?
    var remoteTypeSlowSwitch: UnsafeMutableRawPointer?
    var remoteTypeDelaySpin: UnsafeMutableRawPointer?

    // Media & Hardware widgets
    var msdStatusRow: UnsafeMutableRawPointer?
    var msdMountedRow: UnsafeMutableRawPointer?
    var msdImageCombo: UnsafeMutableRawPointer?
    var msdImageList: [String] = []
    var msdTypeCombo: UnsafeMutableRawPointer?
    var msdRwSwitch: UnsafeMutableRawPointer?
    var msdLocalPathEntry: UnsafeMutableRawPointer?
    var msdRemoteUrlEntry: UnsafeMutableRawPointer?
    var msdRemoteNameEntry: UnsafeMutableRawPointer?
    var atxStatusRow: UnsafeMutableRawPointer?
    var atxWaitSwitch: UnsafeMutableRawPointer?
    var redfishStatusRow: UnsafeMutableRawPointer?
    var redfishResetCombo: UnsafeMutableRawPointer?
    var gpioInputsRow: UnsafeMutableRawPointer?
    var gpioOutputsGroup: UnsafeMutableRawPointer?
    var switchStatusRow: UnsafeMutableRawPointer?
    var switchPortEntry: UnsafeMutableRawPointer?
    var switchPortNameEntry: UnsafeMutableRawPointer?
    var switchDummySwitch: UnsafeMutableRawPointer?
    var switchBeaconEntry: UnsafeMutableRawPointer?

    // System & Network widgets
    var appearanceCombo: UnsafeMutableRawPointer?
    var webThemeCombo: UnsafeMutableRawPointer?
    var languageCombo: UnsafeMutableRawPointer?
    var timezoneCombo: UnsafeMutableRawPointer?
    var hwPlatformRow: UnsafeMutableRawPointer?
    var hwVersionsRow: UnsafeMutableRawPointer?
    var hwCpuMemRow: UnsafeMutableRawPointer?
    var hwTempFlagsRow: UnsafeMutableRawPointer?
    var netModeCombo: UnsafeMutableRawPointer?
    var netIpEntry: UnsafeMutableRawPointer?
    var netMaskEntry: UnsafeMutableRawPointer?
    var netGwEntry: UnsafeMutableRawPointer?
    var netDnsEntry: UnsafeMutableRawPointer?
    var wifiEnableSwitch: UnsafeMutableRawPointer?
    var wifiSsidEntry: UnsafeMutableRawPointer?
    var wifiPassEntry: UnsafeMutableRawPointer?
    var wifiStatusRow: UnsafeMutableRawPointer?
    var ethStatusRow: UnsafeMutableRawPointer?

    static let presetsOrder: [KVMVideoQualityPreset] = [.low, .medium, .high, .ultraHigh, .insane, .custom]
    static let orientations = [0, 90, 180, 270]
    static let resolutionPresets = ["", "1920x1080", "1600x900", "1280x720", "1024x768", "custom"]
    static let scrollDirections = ["STANDARD", "VERTICAL", "HORIZONTAL", "BOTH"]
    static let appearances = ["system", "light", "dark"]
    static let languages = ["auto", "en", "en-US", "en-GB", "es", "fr", "de", "ja", "zh-Hans", "zh-Hant"]
    static let timezones = ["UTC", "America/New_York", "America/Chicago", "America/Denver", "America/Los_Angeles", "Europe/London", "Europe/Paris", "Asia/Tokyo", "Asia/Shanghai", "Australia/Sydney"]

    init(desktop: Desktop) {
        self.desktop = desktop
    }

    func notify(_ text: String) {
        if let dialog {
            ad_prefs_dialog_toast(dialog, text)
        } else {
            desktop.toast(text)
        }
    }

    func present() {
        if let dialog {
            loadRemoteAll()
            ad_present(dialog, desktop.window)
            return
        }

        let dlg = ad_prefs_dialog("Overlook Settings", 760, 680)!
        self.dialog = dlg
        on(dlg, "closed") { [unowned self] in self.dialog = nil }

        ad_prefs_dialog_add(dlg, buildVideoAndCapturePage())
        ad_prefs_dialog_add(dlg, buildInputAndHidPage())
        ad_prefs_dialog_add(dlg, buildMediaAndHardwarePage())
        ad_prefs_dialog_add(dlg, buildSystemAndNetworkPage())

        syncUIFromState()
        loadRemoteAll()
        ad_present(dlg, desktop.window)
    }

    // MARK: - Page 1: Video & Capture

    private func buildVideoAndCapturePage() -> UnsafeMutableRawPointer {
        let page = ad_prefs_page("Video & Capture", "video-display-symbolic")!

        let videoGroup = ad_group_desc("Video & Streamer", "Configure video processing mode, quality presets, EDID monitor emulation, and orientation.")!
        videoModeCombo = ad_combo_row("Processing Mode", "Low latency vs. Smart playout")
        ad_combo_append(videoModeCombo, "Low latency")
        ad_combo_append(videoModeCombo, "Smart")
        on(videoModeCombo!, "notify::selected") { [unowned self] (_: UnsafeMutableRawPointer?) in
            guard !isSyncing else { return }
            let val = ad_combo_get(videoModeCombo) == 1 ? "quality_first" : "low_latency_first"
            mutateConfig { $0.videoProcessing = val }
        }
        ad_group_add(videoGroup, videoModeCombo)

        qualityPresetCombo = ad_combo_row("Quality Preset", "Applies target H.264 bitrate and GOP")
        for p in Self.presetsOrder { ad_combo_append(qualityPresetCombo, p.title) }
        on(qualityPresetCombo!, "notify::selected") { [unowned self] (_: UnsafeMutableRawPointer?) in
            guard !isSyncing else { return }
            let idx = Int(ad_combo_get(qualityPresetCombo))
            guard idx >= 0 && idx < Self.presetsOrder.count else { return }
            applyQualityPreset(Self.presetsOrder[idx])
        }
        ad_group_add(videoGroup, qualityPresetCombo)

        edidCombo = ad_combo_row("EDID Emulation", "Monitor identity presented to the target HDMI port")
        for opt in EDIDCatalog.options { ad_combo_append(edidCombo, opt.label) }
        on(edidCombo!, "notify::selected") { [unowned self] (_: UnsafeMutableRawPointer?) in
            guard !isSyncing else { return }
            let idx = Int(ad_combo_get(edidCombo))
            guard idx >= 0 && idx < EDIDCatalog.options.count else { return }
            let opt = EDIDCatalog.options[idx]
            if let hex = EDIDCatalog.resolvedEdid(for: opt) {
                applyEdid(hex)
            }
        }
        ad_group_add(videoGroup, edidCombo)

        customEdidRow = ad_entry_row("Custom EDID Hex")
        let applyEdidBtn = ol_button("Apply EDID")!
        ad_css(applyEdidBtn, "flat"); ad_align(applyEdidBtn, alignFill, alignCenter)
        on(applyEdidBtn, "clicked") { [unowned self] in
            let text = String(cString: ol_value(customEdidRow)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { notify("Enter a custom EDID hex string first."); return }
            applyEdid(text)
        }
        ad_entry_suffix(customEdidRow, applyEdidBtn)
        ad_group_add(videoGroup, customEdidRow)

        orientationCombo = ad_combo_row("Orientation", nil)
        for deg in Self.orientations { ad_combo_append(orientationCombo, "\(deg)°") }
        on(orientationCombo!, "notify::selected") { [unowned self] (_: UnsafeMutableRawPointer?) in
            guard !isSyncing else { return }
            let idx = Int(ad_combo_get(orientationCombo))
            if idx >= 0 && idx < Self.orientations.count {
                mutateConfig { $0.orientation = Self.orientations[idx] }
            }
        }
        ad_group_add(videoGroup, orientationCombo)

        showCursorSwitch = ad_switch_row("Show Cursor", "Display local cursor over the remote video", 1)
        on(showCursorSwitch!, "notify::active") { [unowned self] (_: UnsafeMutableRawPointer?) in
            guard !isSyncing else { return }
            let show = ad_switch_get(showCursorSwitch) != 0
            desktop.native?.updateCursorVisibility(show)
            mutateConfig { $0.showCursor = show }
        }
        ad_group_add(videoGroup, showCursorSwitch)
        ad_prefs_page_add(page, videoGroup)

        // Custom Streamer Params
        let streamerGroup = ad_group_desc("Streamer Parameters (/api/streamer/set_params)", "Fine-tune ustreamer / hardware encoder FPS, quality, bitrate, GOP, and resolution.")!
        fpsSpin = ad_spin_row("Desired FPS", nil, 1, 60, 1, 0, 30)
        qualitySpin = ad_spin_row("Encoder Quality", nil, 1, 100, 1, 0, 80)
        bitrateSpin = ad_spin_row("H.264 Bitrate (kbps)", nil, 100, 20000, 100, 0, 2000)
        gopSpin = ad_spin_row("H.264 GOP", nil, 1, 300, 1, 0, 30)
        zeroDelaySwitch = ad_switch_row("Zero Delay", "Minimize encoder frame buffering", 0)
        resolutionCombo = ad_combo_row("Resolution", nil)
        for label in ["Auto", "1920x1080", "1600x900", "1280x720", "1024x768", "Custom"] {
            ad_combo_append(resolutionCombo, label)
        }
        customResolutionRow = ad_entry_row("Custom Resolution (e.g. 1920x1080)")
        let applyStreamerRow = ad_action_row("Apply Streamer Parameters", "Push FPS, quality, bitrate, GOP, and resolution to the device")!
        let applyStreamerBtn = ol_button("Apply")!
        ad_css(applyStreamerBtn, "suggested-action"); ad_align(applyStreamerBtn, alignFill, alignCenter)
        on(applyStreamerBtn, "clicked") { [unowned self] in applyCustomStreamerParams() }
        ad_action_row_suffix(applyStreamerRow, applyStreamerBtn)
        for r in [fpsSpin!, qualitySpin!, bitrateSpin!, gopSpin!, zeroDelaySwitch!, resolutionCombo!, customResolutionRow!, applyStreamerRow] {
            ad_group_add(streamerGroup, r)
        }
        ad_prefs_page_add(page, streamerGroup)

        // Streamer Snapshot & OCR
        let ocrGroup = ad_group_desc("Streamer Snapshot & Server OCR", "Capture direct JPEG snapshots or run PiKVM server-side Tesseract OCR.")!
        let snapRow = ad_action_row("Hardware Streamer Snapshot", "GET /api/streamer/snapshot")!
        let snapBtnBox = ol_box(0, 6)!
        ad_align(snapBtnBox, alignFill, alignCenter)
        let saveSnapBtn = ol_button("Save Snapshot")!
        on(saveSnapBtn, "clicked") { [unowned self] in desktop.saveStreamerSnapshot() }
        let clearSnapBtn = ol_button("Clear Cached")!
        on(clearSnapBtn, "clicked") { [unowned self] in deleteCachedSnapshot() }
        ol_append(snapBtnBox, saveSnapBtn)
        ol_append(snapBtnBox, clearSnapBtn)
        ad_action_row_suffix(snapRow, snapBtnBox)
        ad_group_add(ocrGroup, snapRow)

        ocrPreferSwitch = ad_switch_row("Prefer Server OCR (PiKVM Tesseract)", "Use GET /api/streamer/snapshot?ocr=true", desktop.preferences.preferServerOCR ? 1 : 0)
        on(ocrPreferSwitch!, "notify::active") { [unowned self] (_: UnsafeMutableRawPointer?) in
            guard !isSyncing else { return }
            desktop.preferences.preferServerOCR = ad_switch_get(ocrPreferSwitch) != 0
            desktop.savePreferences()
        }
        ad_group_add(ocrGroup, ocrPreferSwitch)

        ocrLangCombo = ad_combo_row("Server OCR Language", nil)
        ad_combo_append(ocrLangCombo, desktop.preferences.serverOCRLanguage)
        ad_combo_set(ocrLangCombo, 0)
        on(ocrLangCombo!, "notify::selected") { [unowned self] (_: UnsafeMutableRawPointer?) in
            guard !isSyncing else { return }
            let idx = Int(ad_combo_get(ocrLangCombo))
            if idx >= 0 && idx < availableOcrLangs.count {
                desktop.preferences.serverOCRLanguage = availableOcrLangs[idx]
                desktop.savePreferences()
            }
        }
        let runOcrBtn = ol_button("Extract Text (OCR)…")!
        ad_css(runOcrBtn, "flat"); ad_align(runOcrBtn, alignFill, alignCenter)
        on(runOcrBtn, "clicked") { [unowned self] in desktop.performServerOCR() }
        ad_action_row_suffix(ocrLangCombo, runOcrBtn)
        ad_group_add(ocrGroup, ocrLangCombo)
        ad_prefs_page_add(page, ocrGroup)

        // Local Capture & VAAPI Recording
        let capGroup = ad_group_desc("Capture & VAAPI Recording", "Ctrl+Shift+S saves a PNG screenshot; Ctrl+Shift+R starts/stops VAAPI hardware-accelerated MP4 recording.")!
        screenshotsEntry = ad_entry_row("Screenshots Folder")
        ol_set_value(screenshotsEntry, desktop.preferences.screenshotsFolder)
        let resetShotBtn = ol_button("Default")!
        ad_css(resetShotBtn, "flat"); ad_align(resetShotBtn, alignFill, alignCenter)
        on(resetShotBtn, "clicked") { [unowned self] in
            desktop.preferences.screenshotsFolder = AppPreferences.defaultScreenshotsURL.path
            ol_set_value(screenshotsEntry, desktop.preferences.screenshotsFolder)
            desktop.savePreferences()
        }
        on(screenshotsEntry!, "entry-activated") { [unowned self] in
            desktop.preferences.screenshotsFolder = String(cString: ol_value(screenshotsEntry))
            desktop.savePreferences()
            notify("Screenshots folder updated.")
        }
        ad_entry_suffix(screenshotsEntry, resetShotBtn)
        ad_group_add(capGroup, screenshotsEntry)

        recordingsEntry = ad_entry_row("Recordings Folder")
        ol_set_value(recordingsEntry, desktop.preferences.recordingsFolder)
        let resetRecBtn = ol_button("Default")!
        ad_css(resetRecBtn, "flat"); ad_align(resetRecBtn, alignFill, alignCenter)
        on(resetRecBtn, "clicked") { [unowned self] in
            desktop.preferences.recordingsFolder = AppPreferences.defaultRecordingsURL.path
            ol_set_value(recordingsEntry, desktop.preferences.recordingsFolder)
            desktop.savePreferences()
        }
        on(recordingsEntry!, "entry-activated") { [unowned self] in
            desktop.preferences.recordingsFolder = String(cString: ol_value(recordingsEntry))
            desktop.savePreferences()
            notify("Recordings folder updated.")
        }
        ad_entry_suffix(recordingsEntry, resetRecBtn)
        ad_group_add(capGroup, recordingsEntry)

        codecCombo = ad_combo_row("Recording Video Codec", "Hardware-accelerated via VAAPI")
        for c in RecordingVideoCodec.allCases { ad_combo_append(codecCombo, c.title) }
        ad_combo_set(codecCombo, desktop.preferences.videoCodec == .hevc ? 1 : 0)
        on(codecCombo!, "notify::selected") { [unowned self] (_: UnsafeMutableRawPointer?) in
            guard !isSyncing else { return }
            desktop.preferences.videoCodec = ad_combo_get(codecCombo) == 1 ? .hevc : .h264
            desktop.savePreferences()
        }
        ad_group_add(capGroup, codecCombo)

        vaapiEntry = ad_entry_row("VAAPI Render Device (Optional, e.g. /dev/dri/renderD129)")
        ol_set_value(vaapiEntry, desktop.preferences.vaapiDevice)
        let probeBtn = ol_button("Probe VAAPI")!
        ad_css(probeBtn, "flat"); ad_align(probeBtn, alignFill, alignCenter)
        on(probeBtn, "clicked") { [unowned self] in
            desktop.preferences.vaapiDevice = String(cString: ol_value(vaapiEntry)).trimmingCharacters(in: .whitespacesAndNewlines)
            desktop.savePreferences()
            desktop.refreshVAAPI()
            if let vaapiStatusRow { ad_action_row_subtitle(vaapiStatusRow, desktop.vaapiStatus.summary) }
            notify(desktop.vaapiStatus.summary)
        }
        ad_entry_suffix(vaapiEntry, probeBtn)
        ad_group_add(capGroup, vaapiEntry)

        vaapiStatusRow = ad_action_row("Detected VAAPI Status", desktop.vaapiStatus.summary)
        ad_group_add(capGroup, vaapiStatusRow)
        ad_prefs_page_add(page, capGroup)

        return page
    }

    // MARK: - Page 2: Input & HID

    private func buildInputAndHidPage() -> UnsafeMutableRawPointer {
        let page = ad_prefs_page("Input & HID", "input-keyboard-symbolic")!

        let hidGroup = ad_group_desc("Remote Device & HID", "Control emulated USB/PS2 keyboard and mouse gadgets, mouse modes, and polling.")!
        mouseControlSwitch = ad_switch_row("Mouse Control", "Forward pointer movement, buttons, and wheel to target", 1)
        on(mouseControlSwitch!, "notify::active") { [unowned self] (_: UnsafeMutableRawPointer?) in
            guard !isSyncing else { return }
            let val = ad_switch_get(mouseControlSwitch) != 0
            desktop.native?.mouseControlEnabled = val
            mutateConfig { $0.mouseControl = val }
        }
        ad_group_add(hidGroup, mouseControlSwitch)

        keyboardControlSwitch = ad_switch_row("Keyboard Control", "Forward physical key events while captured", 1)
        on(keyboardControlSwitch!, "notify::active") { [unowned self] (_: UnsafeMutableRawPointer?) in
            guard !isSyncing else { return }
            let val = ad_switch_get(keyboardControlSwitch) != 0
            desktop.native?.keyboardControlEnabled = val
            mutateConfig { $0.keyboardControl = val }
        }
        ad_group_add(hidGroup, keyboardControlSwitch)

        hidConnectedSwitch = ad_switch_row("USB HID Gadget Connected", "POST /api/hid/set_connected", 1)
        on(hidConnectedSwitch!, "notify::active") { [unowned self] (_: UnsafeMutableRawPointer?) in
            guard !isSyncing else { return }
            setHidConnected(ad_switch_get(hidConnectedSwitch) != 0)
        }
        ad_group_add(hidGroup, hidConnectedSwitch)

        kbOutputCombo = ad_combo_row("Keyboard Output", "Emulated keyboard interface")
        for o in kbOutputsList { ad_combo_append(kbOutputCombo, o) }
        on(kbOutputCombo!, "notify::selected") { [unowned self] (_: UnsafeMutableRawPointer?) in
            guard !isSyncing else { return }
            let idx = Int(ad_combo_get(kbOutputCombo))
            if idx >= 0 && idx < kbOutputsList.count {
                setHidParams(["keyboard_output": kbOutputsList[idx]])
            }
        }
        ad_group_add(hidGroup, kbOutputCombo)

        mouseOutputCombo = ad_combo_row("Mouse Output", "Emulated mouse interface")
        for o in mouseOutputsList { ad_combo_append(mouseOutputCombo, o) }
        on(mouseOutputCombo!, "notify::selected") { [unowned self] (_: UnsafeMutableRawPointer?) in
            guard !isSyncing else { return }
            let idx = Int(ad_combo_get(mouseOutputCombo))
            if idx >= 0 && idx < mouseOutputsList.count {
                setHidParams(["mouse_output": mouseOutputsList[idx]])
            }
        }
        ad_group_add(hidGroup, mouseOutputCombo)

        mouseModeCombo = ad_combo_row("Mouse Mode", "Absolute positioning vs. Relative deltas")
        ad_combo_append(mouseModeCombo, "Absolute")
        ad_combo_append(mouseModeCombo, "Relative")
        on(mouseModeCombo!, "notify::selected") { [unowned self] (_: UnsafeMutableRawPointer?) in
            guard !isSyncing else { return }
            let isAbs = ad_combo_get(mouseModeCombo) == 0
            desktop.native?.setMouseAbsolute(isAbs)
            mutateConfig(switchesMouseMode: true) { $0.isAbsoluteMouse = isAbs }
        }
        ad_group_add(hidGroup, mouseModeCombo)

        mousePollingSpin = ad_spin_row("Mouse Polling (ms)", nil, 1, 60, 1, 0, 10)
        on(mousePollingSpin!, "notify::value") { [unowned self] (_: UnsafeMutableRawPointer?) in
            guard !isSyncing else { return }
            mutateConfig { $0.mousePolling = Int(ad_spin_get(mousePollingSpin)) }
        }
        ad_group_add(hidGroup, mousePollingSpin)

        relativeSenseSpin = ad_spin_row("Device Relative Sensitivity", nil, 1, 60, 1, 0, 10)
        on(relativeSenseSpin!, "notify::value") { [unowned self] (_: UnsafeMutableRawPointer?) in
            guard !isSyncing else { return }
            mutateConfig { $0.relativeSense = Int(ad_spin_get(relativeSenseSpin)) }
        }
        ad_group_add(hidGroup, relativeSenseSpin)

        scrollRateSpin = ad_spin_row("Scroll Rate", nil, 1, 30, 1, 0, 5)
        on(scrollRateSpin!, "notify::value") { [unowned self] (_: UnsafeMutableRawPointer?) in
            guard !isSyncing else { return }
            mutateConfig { $0.scrollRate = Int(ad_spin_get(scrollRateSpin)) }
        }
        ad_group_add(hidGroup, scrollRateSpin)

        scrollDirCombo = ad_combo_row("Scroll Direction", nil)
        for label in ["Standard", "Vertical Reversed", "Horizontal Reversed", "Both Reversed"] {
            ad_combo_append(scrollDirCombo, label)
        }
        on(scrollDirCombo!, "notify::selected") { [unowned self] (_: UnsafeMutableRawPointer?) in
            guard !isSyncing else { return }
            let idx = Int(ad_combo_get(scrollDirCombo))
            if idx >= 0 && idx < Self.scrollDirections.count {
                let dir = Self.scrollDirections[idx]
                desktop.native?.reverseScrolling = dir
                mutateConfig { $0.reverseScrolling = dir }
            }
        }
        ad_group_add(hidGroup, scrollDirCombo)

        jigglerSwitch = ad_switch_row("Device Mouse Jiggler", "Periodically moves the target mouse to prevent sleep", 0)
        on(jigglerSwitch!, "notify::active") { [unowned self] (_: UnsafeMutableRawPointer?) in
            guard !isSyncing else { return }
            let enabled = ad_switch_get(jigglerSwitch) != 0
            setHidParams(["jiggler": enabled ? "true" : "false"])
        }
        ad_group_add(hidGroup, jigglerSwitch)

        localRelSenseSpin = ad_spin_row("Local Relative Sensitivity Multiplier", "Multiplier applied locally in Relative mouse mode", 0.25, 4.0, 0.05, 2, desktop.preferences.relativeSensitivity)
        on(localRelSenseSpin!, "notify::value") { [unowned self] (_: UnsafeMutableRawPointer?) in
            guard !isSyncing else { return }
            let val = ad_spin_get(localRelSenseSpin)
            desktop.preferences.relativeSensitivity = val
            desktop.native?.relativeSensitivity = val
            desktop.savePreferences()
        }
        ad_group_add(hidGroup, localRelSenseSpin)

        fingerbotSpin = ad_spin_row("Fingerbot Strength", nil, 0, 100, 1, 0, 0)
        on(fingerbotSpin!, "notify::value") { [unowned self] (_: UnsafeMutableRawPointer?) in
            guard !isSyncing else { return }
            mutateConfig { $0.fingerbotStrength = Int(ad_spin_get(fingerbotSpin)) }
        }
        ad_group_add(hidGroup, fingerbotSpin)

        let resetHidRow = ad_action_row("Reset HID Devices", "POST /api/hid/reset")!
        let resetHidBtn = ol_button("Reset HID")!
        ad_align(resetHidBtn, alignFill, alignCenter)
        on(resetHidBtn, "clicked") { [unowned self] in
            desktop.native?.requestEmpty(path: "api/hid/reset") { [weak self] res in
                switch res {
                case .success: self?.notify("HID devices reset.")
                case .failure(let err): self?.notify("HID reset failed: \(err.localizedDescription)")
                }
            }
        }
        ad_action_row_suffix(resetHidRow, resetHidBtn)
        ad_group_add(hidGroup, resetHidRow)
        ad_prefs_page_add(page, hidGroup)

        // Keyboard & Text Entry
        let kbGroup = ad_group_desc("Keyboard & Text Entry", "Keymap selection, quick shortcuts, and remote text typing (/api/hid/print).")!
        kbLedsRow = ad_action_row("Keyboard LEDs", desktop.native?.telemetry.keyboardLedsText ?? "CAPS: Off · NUM: Off · SCROLL: Off")
        ad_group_add(kbGroup, kbLedsRow)

        keymapCombo = ad_combo_row("Keymap", "Layout used for remote text typing")
        ad_combo_append(keymapCombo, "en-us")
        ad_combo_set(keymapCombo, 0)
        on(keymapCombo!, "notify::selected") { [unowned self] (_: UnsafeMutableRawPointer?) in
            guard !isSyncing else { return }
            let idx = Int(ad_combo_get(keymapCombo))
            if idx >= 0 && idx < keymapList.count {
                mutateConfig { $0.keymap = keymapList[idx] }
            }
        }
        ad_group_add(kbGroup, keymapCombo)

        let shortcutsRow = ad_action_row("Quick Shortcuts", "Send system key combinations to the remote host")!
        let scBox = ol_box(0, 4)!
        ad_align(scBox, alignFill, alignCenter)
        let quickShortcuts: [(String, [String])] = [
            ("Ctrl+Alt+Del", ["ControlLeft", "AltLeft", "Delete"]),
            ("Ctrl+Shift+Esc", ["ControlLeft", "ShiftLeft", "Escape"]),
            ("Alt+Tab", ["AltLeft", "Tab"]),
            ("Alt+F4", ["AltLeft", "F4"]),
            ("Super", ["MetaLeft"])
        ]
        for (label, keys) in quickShortcuts {
            let b = ol_button(label)!
            ad_css(b, "flat")
            on(b, "clicked") { [unowned self] in sendShortcutKeys(keys) }
            ol_append(scBox, b)
        }
        ad_action_row_suffix(shortcutsRow, scBox)
        ad_group_add(kbGroup, shortcutsRow)

        customShortcutEntry = ad_entry_row("Custom Shortcut (comma-separated, e.g. ControlLeft,KeyL)")
        ol_set_value(customShortcutEntry, "ControlLeft,AltLeft,Delete")
        let sendCustomScBtn = ol_button("Send")!
        ad_css(sendCustomScBtn, "flat"); ad_align(sendCustomScBtn, alignFill, alignCenter)
        on(sendCustomScBtn, "clicked") { [unowned self] in
            let raw = String(cString: ol_value(customShortcutEntry))
            let keys = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            sendShortcutKeys(keys)
        }
        ad_entry_suffix(customShortcutEntry, sendCustomScBtn)
        ad_group_add(kbGroup, customShortcutEntry)

        remoteTypeEntry = ad_entry_row("Type Text Remotely (/api/hid/print)")
        let pasteClipBtn = ol_button("Paste")!
        ad_css(pasteClipBtn, "flat"); ad_align(pasteClipBtn, alignFill, alignCenter)
        on(pasteClipBtn, "clicked") { [unowned self] in
            ol_clipboard_get(desktop.window, { textPtr, ctx in
                let ctrl = Unmanaged<SettingsDialogController>.fromOpaque(ctx!).takeUnretainedValue()
                if let textPtr, let row = ctrl.remoteTypeEntry {
                    ol_set_value(row, String(cString: textPtr))
                }
            }, Unmanaged.passUnretained(self).toOpaque())
        }
        let typeBtn = ol_button("Type on Remote")!
        ad_css(typeBtn, "suggested-action"); ad_align(typeBtn, alignFill, alignCenter)
        on(typeBtn, "clicked") { [unowned self] in sendRemoteTypedText() }
        ad_entry_suffix(remoteTypeEntry, pasteClipBtn)
        ad_entry_suffix(remoteTypeEntry, typeBtn)
        ad_group_add(kbGroup, remoteTypeEntry)

        remoteTypeSlowSwitch = ad_switch_row("Slow Typing Mode", "Insert delay between keystrokes for BIOS/UEFI", 0)
        remoteTypeDelaySpin = ad_spin_row("Inter-Key Delay (seconds)", nil, 0.00, 1.00, 0.01, 2, 0.02)
        ad_group_add(kbGroup, remoteTypeSlowSwitch)
        ad_group_add(kbGroup, remoteTypeDelaySpin)
        ad_prefs_page_add(page, kbGroup)

        return page
    }
}
