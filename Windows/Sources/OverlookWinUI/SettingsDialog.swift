import Foundation
import CNativeWin
import OverlookCore

/// Comprehensive 4-page Settings & Device Management dialog for Overlook on Windows:
/// 1. Video & Capture (Stream mode, H.265/HEVC, hardware decode, GPU adapter, FPS cap, jitter buffer, scaling)
/// 2. Input & HID (Mouse mode, relative sensitivity, natural scroll, scroll speed, release hotkeys, keymap)
/// 3. Media & Hardware (Virtual media ISO/IMG mount/unmount, ATX power controls, Wake-on-LAN, EDID, USB identity, Tailscale)
/// 4. System & Network (Device diagnostics, firmware version, change password, trusted TLS certs, connection log)
final class SettingsDialog {
    let dialog: OLWidgetPtr

    // Video & Capture controls
    let streamModeCombo: OLWidgetPtr
    let hevcSwitch: OLWidgetPtr
    let hwDecodeSwitch: OLWidgetPtr
    let vaapiEntry: OLWidgetPtr
    let vaapiStatusRow: OLWidgetPtr
    let maxFpsSpin: OLWidgetPtr
    let jitterSpin: OLWidgetPtr
    let aspectSwitch: OLWidgetPtr
    let statsOverlaySwitch: OLWidgetPtr
    let reconnectSwitch: OLWidgetPtr
    let audioSwitch: OLWidgetPtr
    let audioVolSpin: OLWidgetPtr

    // Input & HID controls
    let mouseModeCombo: OLWidgetPtr
    let relSensSpin: OLWidgetPtr
    let naturalScrollSwitch: OLWidgetPtr
    let scrollSensSpin: OLWidgetPtr
    let hideCursorSwitch: OLWidgetPtr
    let scrollLockSwitch: OLWidgetPtr
    let keymapEntry: OLWidgetPtr

    // Media & Hardware controls
    let mediaStatusRow: OLWidgetPtr
    let mediaListGroup: OLWidgetPtr
    let mediaUploadEntry: OLWidgetPtr
    let atxStatusRow: OLWidgetPtr
    let wolMacEntry: OLWidgetPtr
    let edidCombo: OLWidgetPtr
    let edidCustomEntry: OLWidgetPtr
    let usbVendorEntry: OLWidgetPtr
    let usbProductEntry: OLWidgetPtr
    let usbManufacturerEntry: OLWidgetPtr
    let usbProductNameEntry: OLWidgetPtr
    let usbSerialEntry: OLWidgetPtr
    let tailscaleStatusRow: OLWidgetPtr

    // System & Network controls
    let sysInfoRow: OLWidgetPtr
    let firmwareRow: OLWidgetPtr
    let newPasswordEntry: OLWidgetPtr
    let confirmPasswordEntry: OLWidgetPtr
    let passwordStatusRow: OLWidgetPtr
    let certCountRow: OLWidgetPtr
    let logSummaryRow: OLWidgetPtr

    weak var session: NativeSession?
    let device: Device?
    let certificates: CertificateStore
    let connectionLog: ConnectionLog
    let onConfigChanged: (CaptureConfig) -> Void
    let onStatusToast: (String) -> Void
    private var selfPtr: UnsafeMutableRawPointer?

    static let edidPresets: [(label: String, value: String)] = [
        ("Keep Current / Default", ""),
        ("1920×1080 @ 60Hz (1080p FHD)", "1920x1080@60"),
        ("2560×1440 @ 60Hz (1440p QHD)", "2560x1440@60"),
        ("3840×2160 @ 60Hz (4K UHD)", "3840x2160@60"),
        ("3840×2160 @ 30Hz (4K 30Hz)", "3840x2160@30"),
        ("1920×1200 @ 60Hz (WUXGA 16:10)", "1920x1200@60"),
        ("1680×1050 @ 60Hz (WSXGA+)", "1680x1050@60"),
        ("1280×720 @ 60Hz (720p HD)", "1280x720@60"),
        ("1024×768 @ 60Hz (XGA BIOS Safe)", "1024x768@60"),
    ]

    init(
        session: NativeSession?,
        device: Device?,
        certificates: CertificateStore,
        connectionLog: ConnectionLog,
        onConfigChanged: @escaping (CaptureConfig) -> Void,
        onStatusToast: @escaping (String) -> Void
    ) {
        self.session = session
        self.device = device
        self.certificates = certificates
        self.connectionLog = connectionLog
        self.onConfigChanged = onConfigChanged
        self.onStatusToast = onStatusToast

        let cfg = session?.config ?? CaptureConfig.load()
        dialog = ad_pref_dialog_new("Overlook Preferences & Device Settings")

        // =====================================================================
        // PAGE 1: Video & Capture
        // =====================================================================
        let videoPage = ad_pref_page_new("Video & Capture", "video-display-symbolic")

        let transportGroup = ad_pref_group("Stream Transport & Codec", "Configure WebRTC / H.264 / H.265 negotiation and hardware acceleration")
        streamModeCombo = ad_combo_row(
            "Stream Transport Mode",
            "Automatic prefers low-latency WebRTC and falls back to H.264 over WebSocket",
            CaptureConfig.StreamMode.allCases.map(\.description)
        )
        ad_combo_set(streamModeCombo, UInt32(cfg.streamMode.rawValue))

        hevcSwitch = ad_switch_row("Prefer H.265 / HEVC", "Negotiate H.265 when supported by the GLKVM device and local decoder")
        ad_switch_set(hevcSwitch, cfg.preferHEVC ? 1 : 0)

        hwDecodeSwitch = ad_switch_row("Hardware Accelerated Decoding", "Use D3D11 / MediaFoundation / NVDEC hardware decoders before software fallback")
        ad_switch_set(hwDecodeSwitch, cfg.preferHWDecode ? 1 : 0)

        vaapiEntry = ad_entry_row("Preferred GPU / Encoder Device (optional, e.g. adapter0)")
        ad_editable_set(vaapiEntry, cfg.vaapiDevice)

        vaapiStatusRow = ad_action_row("Detected Hardware Encoders", NativeSession.probeVAAPI(preferredDevice: cfg.vaapiDevice))
        let probeBtn = ad_button("Re-probe GPU", nil)
        ad_row_add_suffix(vaapiStatusRow, probeBtn)

        maxFpsSpin = ad_spin_row("Maximum Frame Rate (FPS)", "Cap decoded frame rate to reduce CPU/GPU usage", 15, 120, 5)
        ad_spin_set(maxFpsSpin, Double(cfg.maxFPS))

        jitterSpin = ad_spin_row("WebRTC Jitter Buffer (ms)", "Lower values reduce latency; higher values smooth network jitter", 0, 500, 10)
        ad_spin_set(jitterSpin, Double(cfg.jitterBufferMs))

        for row in [streamModeCombo, hevcSwitch, hwDecodeSwitch, vaapiEntry, vaapiStatusRow, maxFpsSpin, jitterSpin] {
            ad_pref_add(transportGroup, row)
        }
        ad_pref_page_add(videoPage, transportGroup)

        let displayGroup = ad_pref_group("Display, Audio & Reconnection", "Viewport scaling, audio pipeline, and resilience")
        aspectSwitch = ad_switch_row("Preserve Aspect Ratio", "Letterbox the remote video to match its native resolution")
        ad_switch_set(aspectSwitch, cfg.keepAspectRatio ? 1 : 0)

        statsOverlaySwitch = ad_switch_row("Show Live Telemetry Bar", "Display resolution, FPS, bitrate, and HID status in the bottom bar")
        ad_switch_set(statsOverlaySwitch, cfg.showStatsOverlay ? 1 : 0)

        reconnectSwitch = ad_switch_row("Auto-Reconnect on Drop", "Automatically re-establish the stream if the connection drops")
        ad_switch_set(reconnectSwitch, cfg.autoReconnect ? 1 : 0)

        audioSwitch = ad_switch_row("Enable Remote Audio", "Play HDMI audio captured from the target device when available")
        ad_switch_set(audioSwitch, cfg.enableAudio ? 1 : 0)

        audioVolSpin = ad_spin_row("Audio Volume (%)", "Output gain for remote audio playback", 0, 150, 5)
        ad_spin_set(audioVolSpin, (cfg.audioVolume * 100.0).rounded())

        for row in [aspectSwitch, statsOverlaySwitch, reconnectSwitch, audioSwitch, audioVolSpin] {
            ad_pref_add(displayGroup, row)
        }
        ad_pref_page_add(videoPage, displayGroup)
        ad_pref_dialog_add(dialog, videoPage)

        // =====================================================================
        // PAGE 2: Input & HID
        // =====================================================================
        let inputPage = ad_pref_page_new("Input & HID", "input-keyboard-symbolic")

        let mouseGroup = ad_pref_group("Mouse & Scroll Behavior", "Choose between absolute tablet-style positioning and relative delta motion")
        mouseModeCombo = ad_combo_row(
            "Pointer Mode",
            "Absolute maps cursor position directly; Relative sends delta motion for 3D/BIOS screens",
            CaptureConfig.MouseMode.allCases.map(\.description)
        )
        ad_combo_set(mouseModeCombo, UInt32(cfg.mouseMode.rawValue))

        relSensSpin = ad_spin_row("Relative Pointer Sensitivity (%)", "Multiplier applied in Relative mouse mode (100% = 1.0×)", 25, 300, 5)
        ad_spin_set(relSensSpin, (cfg.relativeSensitivity * 100.0).rounded())

        naturalScrollSwitch = ad_switch_row("Natural (Inverted) Scrolling", "Invert vertical and horizontal mouse wheel direction")
        ad_switch_set(naturalScrollSwitch, cfg.naturalScroll ? 1 : 0)

        scrollSensSpin = ad_spin_row("Scroll Wheel Speed (%)", "Multiplier for mouse wheel and touchpad scroll events", 25, 300, 5)
        ad_spin_set(scrollSensSpin, (cfg.scrollSensitivity * 100.0).rounded())

        hideCursorSwitch = ad_switch_row("Hide Local Cursor Over Video", "Hide the host Windows cursor while hovering the active remote display")
        ad_switch_set(hideCursorSwitch, cfg.hideLocalCursor ? 1 : 0)

        for row in [mouseModeCombo, relSensSpin, naturalScrollSwitch, scrollSensSpin, hideCursorSwitch] {
            ad_pref_add(mouseGroup, row)
        }
        ad_pref_page_add(inputPage, mouseGroup)

        let keyGroup = ad_pref_group("Keyboard Capture & Hotkeys", "Control how system shortcuts (Alt+Tab, Win key) are routed")
        scrollLockSwitch = ad_switch_row(
            "Scroll Lock Releases Capture",
            "Press Scroll Lock (or Right Ctrl + Right Alt) to toggle between remote capture and host Windows"
        )
        ad_switch_set(scrollLockSwitch, cfg.scrollLockReleasesCapture ? 1 : 0)

        keymapEntry = ad_entry_row("Keymap Override (e.g. us, de, fr, dvorak)")
        ad_editable_set(keymapEntry, cfg.keymapName)

        let applyBtn = ad_button("Save & Apply Preferences", "suggested-action")
        let applyRow = ad_action_row("Persist Configuration", "Save preferences to %APPDATA%\\Overlook\\preferences.json")
        ad_row_add_suffix(applyRow, applyBtn)
        ad_row_activatable(applyRow, applyBtn)

        let resetBtn = ad_button("Reset Defaults", "destructive-action")
        let resetRow = ad_action_row("Restore Default Settings", "Reset all video and input preferences to factory defaults")
        ad_row_add_suffix(resetRow, resetBtn)
        ad_row_activatable(resetRow, resetBtn)

        for row in [scrollLockSwitch, keymapEntry, applyRow, resetRow] {
            ad_pref_add(keyGroup, row)
        }
        ad_pref_page_add(inputPage, keyGroup)
        ad_pref_dialog_add(dialog, inputPage)

        // =====================================================================
        // PAGE 3: Media & Hardware (GLKVM Device Controls)
        // =====================================================================
        let hwPage = ad_pref_page_new("Media & Hardware", "drive-optical-symbolic")

        let mediaGroup = ad_pref_group("Virtual Media (MSD / ISO / IMG)", "Mount bootable ISO/IMG images stored on the GLKVM device")
        mediaStatusRow = ad_action_row("Mounted Image", "Click Refresh to query virtual media status")
        let mediaRefreshBtn = ad_button("Refresh", nil)
        let mediaUnmountBtn = ad_button("Unmount", "destructive-action")
        ad_row_add_suffix(mediaStatusRow, mediaRefreshBtn)
        ad_row_add_suffix(mediaStatusRow, mediaUnmountBtn)
        ad_pref_add(mediaGroup, mediaStatusRow)

        mediaUploadEntry = ad_entry_row("Local ISO/IMG Path to Upload (e.g. C:\\ISOs\\win11.iso)")
        let uploadBtn = ad_button("Upload Image", "suggested-action")
        ad_row_add_suffix(mediaUploadEntry, uploadBtn)
        ad_pref_add(mediaGroup, mediaUploadEntry)
        ad_pref_page_add(hwPage, mediaGroup)

        mediaListGroup = ad_pref_group("Available Images on Device", "Click Mount on an image to attach it as a virtual USB drive / CD-ROM")
        ad_pref_page_add(hwPage, mediaListGroup)

        let atxGroup = ad_pref_group("ATX Power & Wake-on-LAN", "Control physical power header pins and send magic packets")
        atxStatusRow = ad_action_row("ATX Power State", "Querying power state…")
        let pwrShortBtn = ad_button("Power Tap", nil)
        let pwrLongBtn = ad_button("Force Off (Long)", "destructive-action")
        let pwrResetBtn = ad_button("Reset", nil)
        ad_row_add_suffix(atxStatusRow, pwrShortBtn)
        ad_row_add_suffix(atxStatusRow, pwrResetBtn)
        ad_row_add_suffix(atxStatusRow, pwrLongBtn)
        ad_pref_add(atxGroup, atxStatusRow)

        wolMacEntry = ad_entry_row("Wake-on-LAN Target MAC (e.g. AA:BB:CC:DD:EE:FF)")
        let wolBtn = ad_button("Send WoL", "suggested-action")
        ad_row_add_suffix(wolMacEntry, wolBtn)
        ad_pref_add(atxGroup, wolMacEntry)
        ad_pref_page_add(hwPage, atxGroup)

        let edidGroup = ad_pref_group("HDMI EDID & Display Emulation", "Configure the resolution advertised to the target host GPU")
        edidCombo = ad_combo_row("EDID Preset", "Select a standard display profile", Self.edidPresets.map(\.label))
        edidCustomEntry = ad_entry_row("Custom EDID / Resolution String (optional)")
        let edidApplyBtn = ad_button("Apply EDID", "suggested-action")
        ad_row_add_suffix(edidCustomEntry, edidApplyBtn)
        ad_pref_add(edidGroup, edidCombo)
        ad_pref_add(edidGroup, edidCustomEntry)
        ad_pref_page_add(hwPage, edidGroup)

        let usbGroup = ad_pref_group("USB HID Gadget Identity", "Spoof USB Vendor/Product IDs and descriptors presented to the target host")
        usbVendorEntry = ad_entry_row("Vendor ID (hex, e.g. 0x1d6b)")
        usbProductEntry = ad_entry_row("Product ID (hex, e.g. 0x0104)")
        usbManufacturerEntry = ad_entry_row("Manufacturer String")
        usbProductNameEntry = ad_entry_row("Product Name String")
        usbSerialEntry = ad_entry_row("Serial Number")
        let usbApplyBtn = ad_button("Apply USB Identity", "suggested-action")
        let usbApplyRow = ad_action_row("Update USB Descriptors", "Rebinds the composite HID gadget on the KVM device")
        ad_row_add_suffix(usbApplyRow, usbApplyBtn)
        ad_row_activatable(usbApplyRow, usbApplyBtn)

        for row in [usbVendorEntry, usbProductEntry, usbManufacturerEntry, usbProductNameEntry, usbSerialEntry, usbApplyRow] {
            ad_pref_add(usbGroup, row)
        }
        ad_pref_page_add(hwPage, usbGroup)

        let tsGroup = ad_pref_group("Tailscale Mesh VPN", "Manage Tailscale status on the GLKVM appliance")
        tailscaleStatusRow = ad_action_row("Tailscale Status", "Click Refresh to query")
        let tsRefreshBtn = ad_button("Refresh", nil)
        let tsStartBtn = ad_button("Enable", "suggested-action")
        let tsStopBtn = ad_button("Disable", nil)
        ad_row_add_suffix(tailscaleStatusRow, tsRefreshBtn)
        ad_row_add_suffix(tailscaleStatusRow, tsStartBtn)
        ad_row_add_suffix(tailscaleStatusRow, tsStopBtn)
        ad_pref_add(tsGroup, tailscaleStatusRow)
        ad_pref_page_add(hwPage, tsGroup)

        ad_pref_dialog_add(dialog, hwPage)

        // =====================================================================
        // PAGE 4: System & Network
        // =====================================================================
        let sysPage = ad_pref_page_new("System & Security", "preferences-system-symbolic")

        let appGroup = ad_pref_group("GLKVM Appliance System", "Firmware version, system status, and reboot controls")
        sysInfoRow = ad_action_row("Appliance Info", device?.displayName ?? "No active device")
        firmwareRow = ad_action_row("Firmware Version", "Click Query Appliance to inspect")
        let querySysBtn = ad_button("Query Appliance", nil)
        let rebootAppBtn = ad_button("Reboot KVM Appliance", "destructive-action")
        ad_row_add_suffix(firmwareRow, querySysBtn)
        ad_row_add_suffix(firmwareRow, rebootAppBtn)
        ad_pref_add(appGroup, sysInfoRow)
        ad_pref_add(appGroup, firmwareRow)
        ad_pref_page_add(sysPage, appGroup)

        let pwdGroup = ad_pref_group("Device Admin Password", "Change the administrator password on the connected GLKVM device")
        newPasswordEntry = ad_password_row("New Admin Password")
        confirmPasswordEntry = ad_password_row("Confirm New Password")
        passwordStatusRow = ad_action_row("Password Change", "Enter and confirm a new password")
        let changePwdBtn = ad_button("Update Password", "suggested-action")
        ad_row_add_suffix(passwordStatusRow, changePwdBtn)
        ad_row_activatable(passwordStatusRow, changePwdBtn)
        for row in [newPasswordEntry, confirmPasswordEntry, passwordStatusRow] {
            ad_pref_add(pwdGroup, row)
        }
        ad_pref_page_add(sysPage, pwdGroup)

        let secGroup = ad_pref_group("Trusted TLS Certificates & Audit Log", "Manage TOFU pinned certificates and connection history")
        let allCerts = certificates.allRecords()
        certCountRow = ad_action_row("Pinned Certificates", "\(allCerts.count) trusted host(s)")
        let clearCertsBtn = ad_button("Clear All Pins", "destructive-action")
        ad_row_add_suffix(certCountRow, clearCertsBtn)
        ad_pref_add(secGroup, certCountRow)

        let recentLogs = connectionLog.recentEntries(limit: 5)
        let latestSummary = recentLogs.last.map { "\($0.timestamp): \($0.event) (\($0.device))" } ?? "No recent events"
        logSummaryRow = ad_action_row("Connection Log (\(recentLogs.count) recent)", latestSummary)
        let copyLogBtn = ad_button("Copy Log", nil)
        let clearLogBtn = ad_button("Clear Log", nil)
        ad_row_add_suffix(logSummaryRow, copyLogBtn)
        ad_row_add_suffix(logSummaryRow, clearLogBtn)
        ad_pref_add(secGroup, logSummaryRow)
        ad_pref_page_add(sysPage, secGroup)

        ad_pref_dialog_add(dialog, sysPage)

        let rawSelf = Unmanaged.passRetained(self).toOpaque()
        self.selfPtr = rawSelf

        wireSignals(
            rawSelf: rawSelf,
            probeBtn: probeBtn,
            applyBtn: applyBtn,
            resetBtn: resetBtn,
            mediaRefreshBtn: mediaRefreshBtn,
            mediaUnmountBtn: mediaUnmountBtn,
            uploadBtn: uploadBtn,
            pwrShortBtn: pwrShortBtn,
            pwrLongBtn: pwrLongBtn,
            pwrResetBtn: pwrResetBtn,
            wolBtn: wolBtn,
            edidApplyBtn: edidApplyBtn,
            usbApplyBtn: usbApplyBtn,
            tsRefreshBtn: tsRefreshBtn,
            tsStartBtn: tsStartBtn,
            tsStopBtn: tsStopBtn,
            querySysBtn: querySysBtn,
            rebootAppBtn: rebootAppBtn,
            changePwdBtn: changePwdBtn,
            clearCertsBtn: clearCertsBtn,
            copyLogBtn: copyLogBtn,
            clearLogBtn: clearLogBtn
        )
    }

    func present(over parent: OLWidgetPtr) {
        ad_dialog_present(dialog, parent)
        if session?.stats.authenticated == true {
            refreshDeviceStatus()
        }
    }
}
