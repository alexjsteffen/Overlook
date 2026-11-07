import Foundation
import CNativeWin
import OverlookCore

enum SmokeMode {
    case none
    case ui
    case nativeStream
    case captureDialog
}

final class OverlookDesktopController {
    let app: OLAppPtr
    let smokeMode: SmokeMode

    private let store = DeviceStore()
    private let passwords = PasswordStore()
    private let certificates = CertificateStore()
    private let connectionLog = ConnectionLog()
    private var devices: [Device] = []
    private var selectedDevice: Device?
    private var pendingCertificateHost: String?
    private var pendingCertificateFingerprint: String?
    private let nativeSession = NativeSession()
    private var activeSettingsDialog: SettingsDialog?
    private var activeInfoDialog: ConnectionInfoDialog?
    private var reconnectTimerId: UInt32 = 0
    private var lastCredentials: (device: Device, username: String, password: String)?

    private var window: OLWidgetPtr!
    private var splitView: OLWidgetPtr!
    private var stack: OLWidgetPtr!
    private var deviceList: OLWidgetPtr!
    private var emptyDeviceStatus: OLWidgetPtr!
    private var sidebarStack: OLWidgetPtr!

    private var nameRow: OLWidgetPtr!
    private var addressRow: OLWidgetPtr!
    private var usernameRow: OLWidgetPtr!
    private var passwordRow: OLWidgetPtr!
    private var keyringRow: OLWidgetPtr!
    private var trustRow: OLWidgetPtr!
    private var forgetTrustButton: OLWidgetPtr!

    private var banner: OLWidgetPtr!
    private var captureBanner: OLWidgetPtr!
    private var statusBar: OLWidgetPtr!
    private var statusLabel: OLWidgetPtr!
    private var metricsLabel: OLWidgetPtr!
    private var spinner: OLWidgetPtr!
    private var captureButton: OLWidgetPtr!
    private var mouseModeButton: OLWidgetPtr!
    private var recordButton: OLWidgetPtr!
    private var pasteEntry: OLWidgetPtr!

    private var web: OLWidgetPtr?
    private var webContainer: OLWidgetPtr!

    init(app: OLAppPtr, smokeMode: SmokeMode) {
        self.app = app
        self.smokeMode = smokeMode
    }

    func startup() {
        ad_load_css("")
        nativeSession?.config = CaptureConfig.load()
        installActions()
    }

    func activate() {
        devices = store.load()
        selectedDevice = devices.first

        window = ad_window_new(app, "Overlook", 1360, 860)
        let toolbar = ad_toolbar_view_new()
        let header = buildHeader()
        ad_toolbar_add_top(toolbar, header)

        banner = ad_banner("")
        ad_banner_set_button(banner, "Dismiss")
        ol_signal_connect(banner, "button-clicked", { banner, _ in
            guard let banner else { return }
            ad_banner_show(banner, "", 0)
        }, nil)
        ad_toolbar_add_top(toolbar, banner)

        captureBanner = ad_banner("System shortcuts released to host Windows — Press Right Ctrl + Right Alt or Scroll Lock to recapture")
        ad_banner_set_button(captureBanner, "Recapture Keys")
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        ol_signal_connect(captureBanner, "button-clicked", { _, ctx in
            guard let ctx else { return }
            let me = Unmanaged<OverlookDesktopController>.fromOpaque(ctx).takeUnretainedValue()
            me.nativeSession?.setKeyboardCaptured(true)
        }, selfPtr)
        ad_toolbar_add_top(toolbar, captureBanner)

        splitView = ad_split_view_new()
        ad_split_set_sidebar(splitView, buildSidebar())
        ad_split_set_content(splitView, buildMainStack())
        ad_toolbar_set_content(toolbar, splitView)
        statusBar = buildStatusBar()
        ad_toolbar_add_bottom(toolbar, statusBar)

        ad_window_set_content(window, toolbar)
        wireNativeSession()
        applyConfigToUI(nativeSession?.config ?? CaptureConfig())
        reloadDeviceList()
        populateSelectedDevice()
        ad_window_present(window)

        switch smokeMode {
        case .none:
            break
        case .ui:
            _ = g_timeout_add_seconds(1, { context -> Int32 in
                guard let context else { return G_SOURCE_REMOVE }
                let controller = Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue()
                g_application_quit(controller.app)
                return G_SOURCE_REMOVE
            }, Unmanaged.passUnretained(self).toOpaque())
        case .nativeStream:
            ad_stack_set_visible(stack, "native")
            nativeSession?.startTestStream(h264: true)
            _ = g_timeout_add_seconds(2, { context -> Int32 in
                guard let context else { return G_SOURCE_REMOVE }
                let controller = Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue()
                let ok = (controller.nativeSession?.stats.connected ?? false) && (controller.nativeSession?.stats.videoWidth ?? 0) > 0
                if !ok {
                    fputs("Native stream smoke test did not produce frames: \(controller.nativeSession?.stats.status ?? "no session")\n", stderr)
                    exit(2)
                }
                g_application_quit(controller.app)
                return G_SOURCE_REMOVE
            }, Unmanaged.passUnretained(self).toOpaque())
        case .captureDialog:
            showSettingsDialog()
            showConnectionInfoDialog()
            _ = g_timeout_add_seconds(1, { context -> Int32 in
                guard let context else { return G_SOURCE_REMOVE }
                let controller = Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue()
                g_application_quit(controller.app)
                return G_SOURCE_REMOVE
            }, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    private func buildHeader() -> OLWidgetPtr {
        let header = ad_header_new()
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let sidebarButton = ad_button_icon("sidebar-show-symbolic", "Toggle device sidebar (F9)")
        ol_signal_connect(sidebarButton, "clicked", { _, context in
            guard let context else { return }
            let me = Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue()
            let current = ad_split_get_show_sidebar(me.splitView)
            ad_split_set_show_sidebar(me.splitView, current == 0 ? 1 : 0)
        }, selfPtr)
        ad_header_pack_start(header, sidebarButton)

        let addButton = ad_button_icon("list-add-symbolic", "New device (Ctrl+N)")
        ol_signal_connect(addButton, "clicked", { _, context in
            guard let context else { return }
            Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().beginNewDevice()
        }, selfPtr)
        ad_header_pack_start(header, addButton)

        stack = ad_stack_new()
        let switcher = ad_switcher_new(stack)
        ad_header_pack_start(header, switcher)

        let menu = buildMenu()
        let menuButton = ad_menu_button("open-menu-symbolic", "Session, shortcuts, and power actions", menu)
        ad_header_pack_end(header, menuButton)

        let settingsButton = ad_button_icon("emblem-system-symbolic", "Preferences & Device Hardware (Ctrl+,)")
        ol_signal_connect(settingsButton, "clicked", { _, context in
            guard let context else { return }
            Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().showSettingsDialog()
        }, selfPtr)
        ad_header_pack_end(header, settingsButton)

        let infoButton = ad_button_icon("dialog-information-symbolic", "Connection Diagnostics (Ctrl+I)")
        ol_signal_connect(infoButton, "clicked", { _, context in
            guard let context else { return }
            Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().showConnectionInfoDialog()
        }, selfPtr)
        ad_header_pack_end(header, infoButton)

        let screenshotButton = ad_button_icon("camera-photo-symbolic", "Save Screenshot to Pictures (Ctrl+Shift+S)")
        ol_signal_connect(screenshotButton, "clicked", { _, context in
            guard let context else { return }
            Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().captureScreenshot()
        }, selfPtr)
        ad_header_pack_end(header, screenshotButton)

        recordButton = ad_toggle_icon("media-record-symbolic", "Record MP4 Video with Hardware/x264 Encoder (Ctrl+Shift+R)")
        ol_signal_connect(recordButton, "toggled", { button, context in
            guard let button, let context else { return }
            let me = Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue()
            me.toggleRecording(active: ad_toggle_get(button) != 0)
        }, selfPtr)
        ad_header_pack_end(header, recordButton)

        let fullscreenButton = ad_button_icon("view-fullscreen-symbolic", "Toggle fullscreen (F11)")
        ol_signal_connect(fullscreenButton, "clicked", { _, context in
            guard let context else { return }
            Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().toggleFullscreen()
        }, selfPtr)
        ad_header_pack_end(header, fullscreenButton)

        mouseModeButton = ad_toggle_icon("input-mouse-symbolic", "Toggle Relative / Absolute Mouse Mode (Ctrl+M)")
        ol_signal_connect(mouseModeButton, "toggled", { button, context in
            guard let button, let context else { return }
            let me = Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue()
            let rel = ad_toggle_get(button) != 0
            me.nativeSession?.config.mouseMode = rel ? .relative : .absolute
            try? me.nativeSession?.config.save()
            me.refreshNativeState()
        }, selfPtr)
        ad_header_pack_end(header, mouseModeButton)

        captureButton = ad_toggle_icon("input-keyboard-symbolic", "Capture keyboard & system shortcuts (Right Ctrl+Right Alt or Scroll Lock to release)")
        ad_toggle_set(captureButton, 1)
        ol_signal_connect(captureButton, "toggled", { button, context in
            guard let button, let context else { return }
            let me = Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue()
            let captured = ad_toggle_get(button) != 0
            me.nativeSession?.setKeyboardCaptured(captured)
        }, selfPtr)
        ad_header_pack_end(header, captureButton)

        return header
    }

    private func buildMenu() -> OLMenuPtr {
        let root = g_menu_new()

        let sessionSection = g_menu_new()
        g_menu_append(sessionSection, "Connect Native Stream", "app.connect-native")
        g_menu_append(sessionSection, "Open Web Console", "app.open-web")
        g_menu_append(sessionSection, "Disconnect", "app.disconnect")
        g_menu_append(sessionSection, "Connection Diagnostics…", "app.connection-info")
        g_menu_append(sessionSection, "Preferences & Hardware…", "app.settings")
        g_menu_append_section(root, "Session", sessionSection)

        let captureSection = g_menu_new()
        g_menu_append(captureSection, "Save Screenshot (PNG)", "app.screenshot")
        g_menu_append(captureSection, "Start / Stop Recording (MP4)", "app.toggle-recording")
        g_menu_append(captureSection, "Copy Screen Text (OCR)", "app.ocr-clipboard")
        g_menu_append(captureSection, "Paste Host Clipboard to Remote", "app.paste-clipboard")
        g_menu_append(captureSection, "Release Stuck Keys", "app.release-keys")
        g_menu_append_section(root, "Capture & Clipboard", captureSection)

        let keysSection = g_menu_new()
        g_menu_append(keysSection, "Send Ctrl+Alt+Delete", "app.ctrl-alt-delete")
        g_menu_append(keysSection, "Send Alt+Tab", "app.send-alt-tab")
        g_menu_append(keysSection, "Send Alt+F4", "app.send-alt-f4")
        g_menu_append(keysSection, "Send Super / Windows Key", "app.send-meta")
        g_menu_append(keysSection, "Send Ctrl+Shift+Esc (Task Manager)", "app.send-taskmgr")
        g_menu_append(keysSection, "Send PrintScreen", "app.send-printscreen")
        g_menu_append_section(root, "Remote Key Combos", keysSection)

        let testSection = g_menu_new()
        g_menu_append(testSection, "Start H.264 Test Stream", "app.test-stream")
        g_menu_append_section(root, "Diagnostics", testSection)

        return root
    }

    private func buildSidebar() -> OLWidgetPtr {
        sidebarStack = ad_stack_new()

        deviceList = ad_list_sidebar()
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        ol_signal_connect(deviceList, "row-selected", { _, row, context in
            guard let context else { return }
            let me = Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue()
            let index = Int(ad_list_row_index(row))
            guard index >= 0 && index < me.devices.count else { return }
            me.selectedDevice = me.devices[index]
            me.populateSelectedDevice()
        }, selfPtr)

        let listScrolled = ad_scrolled(deviceList)
        ad_stack_add_named(sidebarStack, listScrolled, "list", "Devices")

        let emptyButton = ad_button("Add Device", "suggested-action")
        ol_signal_connect(emptyButton, "clicked", { _, context in
            guard let context else { return }
            Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().beginNewDevice()
        }, selfPtr)
        emptyDeviceStatus = ad_status_page(
            "network-server-symbolic",
            "No KVM Devices",
            "Save a GL.iNet Comet or GLKVM device to connect with native H.264/HEVC or Web Console.",
            emptyButton
        )
        ad_stack_add_named(sidebarStack, emptyDeviceStatus, "empty", "Empty")

        return sidebarStack
    }

    private func buildMainStack() -> OLWidgetPtr {
        let nativePage = buildNativePage()
        let connectPage = buildConnectPage()
        let webPage = buildWebPage()

        ad_stack_add_named(stack, nativePage, "native", "Native Stream")
        ad_stack_add_named(stack, connectPage, "connect", "Connect")
        ad_stack_add_named(stack, webPage, "web", "Web Console")
        ad_stack_set_visible(stack, "connect")
        return stack
    }

    private func buildNativePage() -> OLWidgetPtr {
        let box = ad_box_v(0)
        if let widget = nativeSession?.widget {
            ad_box_append(box, widget)
        } else {
            let fallback = ad_status_page(
                "dialog-error-symbolic",
                "Native Stream Unavailable",
                "GStreamer or WinHTTP could not initialize. Use the Web Console tab or check runtime dependencies.",
                nil
            )
            ad_box_append(box, fallback)
        }
        return box
    }

    private func buildConnectPage() -> OLWidgetPtr {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let outer = ad_box_v(18)
        ad_margins(outer, 24, 24, 24, 24)

        let deviceGroup = ad_pref_group("GLKVM Device", "Connect directly with the native GStreamer stream or the appliance web console.")
        nameRow = ad_entry_row("Display Name")
        addressRow = ad_entry_row("Host or IP Address (e.g. 192.168.1.100:443)")
        usernameRow = ad_entry_row("Username")
        passwordRow = ad_password_row("Password")

        ad_pref_add(deviceGroup, nameRow)
        ad_pref_add(deviceGroup, addressRow)
        ad_pref_add(deviceGroup, usernameRow)
        ad_pref_add(deviceGroup, passwordRow)
        ad_box_append(outer, deviceGroup)

        let securityGroup = ad_pref_group("Credentials and TLS", "Passwords are stored in Windows Credential Manager; self-signed certificates use trust-on-first-use pinning.")
        keyringRow = ad_action_row("Windows Credential Manager", "Checking Windows Credential Manager…")
        trustRow = ad_action_row("Pinned Certificate", "No certificate pinned for this host")
        forgetTrustButton = ad_button("Forget", "destructive-action")
        ol_signal_connect(forgetTrustButton, "clicked", { _, context in
            guard let context else { return }
            Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().forgetSelectedCertificate()
        }, selfPtr)
        ad_row_add_suffix(trustRow, forgetTrustButton)
        ad_pref_add(securityGroup, keyringRow)
        ad_pref_add(securityGroup, trustRow)
        ad_box_append(outer, securityGroup)

        let actions = ad_box_h(10)
        let connectNativeButton = ad_button("Connect Native Stream", "suggested-action")
        ol_signal_connect(connectNativeButton, "clicked", { _, context in
            guard let context else { return }
            Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().saveAndConnectNative()
        }, selfPtr)

        let connectWebButton = ad_button("Open Web Console", nil)
        ol_signal_connect(connectWebButton, "clicked", { _, context in
            guard let context else { return }
            Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().saveAndOpenWeb()
        }, selfPtr)

        let saveButton = ad_button("Save Device", nil)
        ol_signal_connect(saveButton, "clicked", { _, context in
            guard let context else { return }
            _ = Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().saveDeviceFromForm()
        }, selfPtr)

        let deleteButton = ad_button("Delete", "destructive-action")
        ol_signal_connect(deleteButton, "clicked", { _, context in
            guard let context else { return }
            Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().deleteSelectedDevice()
        }, selfPtr)

        ad_box_append(actions, connectNativeButton)
        ad_box_append(actions, connectWebButton)
        ad_box_append(actions, saveButton)
        ad_box_append(actions, deleteButton)
        ad_box_append(outer, actions)

        let hidGroup = ad_pref_group("Remote Input Utilities", "Send text or key combinations through the native HID WebSocket.")
        pasteEntry = ad_entry_row("Type Text on Remote Host")
        let sendTextButton = ad_button("Send", nil)
        ol_signal_connect(sendTextButton, "clicked", { _, context in
            guard let context else { return }
            let me = Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue()
            let text = me.text(of: me.pasteEntry)
            me.nativeSession?.pasteText(text)
            ad_editable_set(me.pasteEntry, "")
        }, selfPtr)
        ad_row_add_suffix(pasteEntry, sendTextButton)
        ad_pref_add(hidGroup, pasteEntry)

        let pasteClipRow = ad_action_row("Host Clipboard", "Type current Windows clipboard contents on the remote machine (Ctrl+Shift+V)")
        let pasteClipBtn = ad_button("Paste Clipboard", nil)
        ol_signal_connect(pasteClipBtn, "clicked", { _, context in
            guard let context else { return }
            Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().pasteHostClipboard()
        }, selfPtr)
        ad_row_add_suffix(pasteClipRow, pasteClipBtn)
        ad_row_activatable(pasteClipRow, pasteClipBtn)
        ad_pref_add(hidGroup, pasteClipRow)

        let cadRow = ad_action_row("System Key Sequence", "Send Ctrl+Alt+Delete to the remote machine")
        let cadButton = ad_button("Ctrl+Alt+Delete", nil)
        ol_signal_connect(cadButton, "clicked", { _, context in
            guard let context else { return }
            Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().nativeSession?.sendCtrlAltDelete()
        }, selfPtr)
        ad_row_add_suffix(cadRow, cadButton)
        ad_row_activatable(cadRow, cadButton)
        ad_pref_add(hidGroup, cadRow)
        ad_box_append(outer, hidGroup)

        return ad_scrolled(ad_clamp(outer, 780))
    }

    private func buildWebPage() -> OLWidgetPtr {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let box = ad_box_v(0)
        let controls = ad_box_h(8)
        ad_margins(controls, 8, 8, 12, 12)

        let back = ad_button_icon("go-previous-symbolic", "Back")
        ol_signal_connect(back, "clicked", { _, context in
            guard let context else { return }
            let me = Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue()
            if let web = me.web { ol_web_back(web) }
        }, selfPtr)

        let forward = ad_button_icon("go-next-symbolic", "Forward")
        ol_signal_connect(forward, "clicked", { _, context in
            guard let context else { return }
            let me = Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue()
            if let web = me.web { ol_web_forward(web) }
        }, selfPtr)

        let reload = ad_button_icon("view-refresh-symbolic", "Reload")
        ol_signal_connect(reload, "clicked", { _, context in
            guard let context else { return }
            let me = Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue()
            if let web = me.web { ol_web_reload(web) }
        }, selfPtr)

        ad_box_append(controls, back)
        ad_box_append(controls, forward)
        ad_box_append(controls, reload)
        ad_box_append(box, controls)

        webContainer = ad_box_v(0)
        ad_expand(webContainer, 1, 1)
        let placeholder = ad_status_page(
            "applications-internet-symbolic",
            "Web Console Idle",
            "Click Open Web Console to load the GLKVM management interface in WebView2.",
            nil
        )
        ad_box_append(webContainer, placeholder)
        ad_box_append(box, webContainer)
        return box
    }

    private func ensureWebView() -> OLWidgetPtr {
        if let web { return web }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let created = ol_web_new()
        self.web = created
        ol_web_on_certificate(created, { host, fingerprint, summary, context -> Int32 in
            guard let context else { return 0 }
            let me = Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue()
            let hostValue = host.map { String(cString: $0) } ?? ""
            let fpValue = fingerprint.map { String(cString: $0) } ?? ""
            let summaryValue = summary.map { String(cString: $0) } ?? ""
            return me.evaluateCertificate(host: hostValue, fingerprint: fpValue, summary: summaryValue) ? 1 : 0
        }, selfPtr)
        ol_web_on_load_failed(created, { uri, message, context in
            guard let context else { return }
            let me = Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue()
            let uriText = uri.map { String(cString: $0) } ?? ""
            let msgText = message.map { String(cString: $0) } ?? "Load failed"
            ad_banner_show(me.banner, "Web console error (\(uriText)): \(msgText)", 1)
        }, selfPtr)
        ad_box_append(webContainer, ol_web_widget(created))
        return created
    }

    private func buildStatusBar() -> OLWidgetPtr {
        let bar = ad_box_h(12)
        ad_add_class(bar, "overlook-statusbar")
        ad_margins(bar, 6, 6, 12, 12)

        spinner = ad_spinner()
        statusLabel = ad_label("Ready")
        ad_expand(statusLabel, 1, 0)
        metricsLabel = ad_label("Video idle · HID idle · Absolute mouse")
        ad_add_class(metricsLabel, "overlook-pill")

        ad_box_append(bar, spinner)
        ad_box_append(bar, statusLabel)
        ad_box_append(bar, metricsLabel)
        return bar
    }

    private func installActions() {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        ad_add_action(app, "connect-native", { _, _, context in
            guard let context else { return }
            Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().saveAndConnectNative()
        }, selfPtr)
        ad_set_accel(app, "app.connect-native", "<Primary><Shift>Return")

        ad_add_action(app, "open-web", { _, _, context in
            guard let context else { return }
            Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().saveAndOpenWeb()
        }, selfPtr)
        ad_set_accel(app, "app.open-web", "<Primary>u")

        ad_add_action(app, "disconnect", { _, _, context in
            guard let context else { return }
            let me = Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue()
            me.lastCredentials = nil
            me.nativeSession?.disconnect()
        }, selfPtr)
        ad_set_accel(app, "app.disconnect", "<Primary>d")

        ad_add_action(app, "settings", { _, _, context in
            guard let context else { return }
            Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().showSettingsDialog()
        }, selfPtr)
        ad_set_accel(app, "app.settings", "<Primary>comma")

        ad_add_action(app, "connection-info", { _, _, context in
            guard let context else { return }
            Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().showConnectionInfoDialog()
        }, selfPtr)
        ad_set_accel(app, "app.connection-info", "<Primary>i")

        ad_add_action(app, "screenshot", { _, _, context in
            guard let context else { return }
            Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().captureScreenshot()
        }, selfPtr)
        ad_set_accel(app, "app.screenshot", "<Primary><Shift>s")

        ad_add_action(app, "toggle-recording", { _, _, context in
            guard let context else { return }
            let me = Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue()
            let next = !(me.nativeSession?.isRecording ?? false)
            ad_toggle_set(me.recordButton, next ? 1 : 0)
        }, selfPtr)
        ad_set_accel(app, "app.toggle-recording", "<Primary><Shift>r")

        ad_add_action(app, "ocr-clipboard", { _, _, context in
            guard let context else { return }
            Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().ocrCurrentFrameToClipboard()
        }, selfPtr)
        ad_set_accel(app, "app.ocr-clipboard", "<Primary><Shift>o")

        ad_add_action(app, "paste-clipboard", { _, _, context in
            guard let context else { return }
            Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().pasteHostClipboard()
        }, selfPtr)
        ad_set_accel(app, "app.paste-clipboard", "<Primary><Shift>v")

        ad_add_action(app, "ctrl-alt-delete", { _, _, context in
            guard let context else { return }
            Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().nativeSession?.sendCtrlAltDelete()
        }, selfPtr)
        ad_set_accel(app, "app.ctrl-alt-delete", "<Primary><Alt>Delete")

        ad_add_action(app, "send-alt-tab", { _, _, context in
            guard let context else { return }
            Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().nativeSession?.sendKeyCombo(["AltLeft", "Tab"])
        }, selfPtr)

        ad_add_action(app, "send-alt-f4", { _, _, context in
            guard let context else { return }
            Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().nativeSession?.sendKeyCombo(["AltLeft", "F4"])
        }, selfPtr)

        ad_add_action(app, "send-meta", { _, _, context in
            guard let context else { return }
            Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().nativeSession?.sendKeyCombo(["MetaLeft"])
        }, selfPtr)

        ad_add_action(app, "send-taskmgr", { _, _, context in
            guard let context else { return }
            Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().nativeSession?.sendKeyCombo(["ControlLeft", "ShiftLeft", "Escape"])
        }, selfPtr)

        ad_add_action(app, "send-printscreen", { _, _, context in
            guard let context else { return }
            Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().nativeSession?.sendKeyCombo(["PrintScreen"])
        }, selfPtr)

        ad_add_action(app, "release-keys", { _, _, context in
            guard let context else { return }
            Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().nativeSession?.releaseAllInputs()
        }, selfPtr)

        ad_add_action(app, "test-stream", { _, _, context in
            guard let context else { return }
            let me = Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue()
            ad_stack_set_visible(me.stack, "native")
            me.nativeSession?.startTestStream(h264: true)
        }, selfPtr)
        ad_set_accel(app, "app.test-stream", "<Primary>t")
    }

    private func wireNativeSession() {
        nativeSession?.onChanged = { [weak self] in
            self?.refreshNativeState()
        }
        nativeSession?.onError = { [weak self] message in
            guard let self else { return }
            ad_banner_show(self.banner, message, 1)
            self.connectionLog.record(device: self.selectedDevice?.hostPort ?? "unknown", event: "error", detail: message)
            self.scheduleAutoReconnectIfNeeded(reason: message)
        }
        nativeSession?.onCertificate = { [weak self] host, fingerprint, summary in
            self?.evaluateCertificate(host: host, fingerprint: fingerprint, summary: summary) ?? false
        }
        nativeSession?.onCaptureToggled = { [weak self] captured in
            guard let self else { return }
            ad_toggle_set(self.captureButton, captured ? 1 : 0)
            ad_banner_show(self.captureBanner, "System shortcuts released to host Windows — Press Right Ctrl + Right Alt or Scroll Lock to recapture", captured ? 0 : 1)
        }
    }

    private func refreshNativeState() {
        guard let stats = nativeSession?.stats else { return }
        let cfg = nativeSession?.config ?? CaptureConfig()
        ad_label_set(statusLabel, stats.status)
        let busy = stats.status.hasPrefix("Connecting") || stats.status.hasPrefix("Starting") || stats.status.hasPrefix("Negotiating")
        ad_spinner_set(spinner, busy ? 1 : 0)

        let resolution = stats.videoWidth > 0 && stats.videoHeight > 0
            ? "\(stats.videoWidth)×\(stats.videoHeight)"
            : "no video"
        let fps = stats.fps > 0 ? String(format: "%.1f fps", stats.fps) : "0 fps"
        let br = stats.bitrateKbps > 0 ? String(format: " · %.0f kbps", stats.bitrateKbps) : ""
        let hid = stats.hidReady ? "HID ready" : "HID idle"
        let capture = (nativeSession?.keyboardCaptured ?? false) ? "keys captured" : "keys released"
        let mouse = cfg.mouseMode == .relative ? "relative mouse" : "absolute mouse"
        let rec = (nativeSession?.isRecording ?? false) ? " · ● REC" : ""
        ad_label_set(metricsLabel, "\(resolution) · \(fps)\(br) · \(hid) · \(mouse) · \(capture)\(rec)")
    }

    private func applyConfigToUI(_ cfg: CaptureConfig) {
        ad_visible(statusBar, cfg.showStatsOverlay ? 1 : 0)
        ad_toggle_set(mouseModeButton, cfg.mouseMode == .relative ? 1 : 0)
        refreshNativeState()
    }

    private func reloadDeviceList() {
        ad_list_clear(deviceList)
        if devices.isEmpty {
            ad_stack_set_visible(sidebarStack, "empty")
            return
        }

        ad_stack_set_visible(sidebarStack, "list")
        for device in devices {
            let row = ad_action_row(device.displayName, "\(device.username)@\(device.hostPort)")
            ad_list_append(deviceList, row)
        }
    }

    private func populateSelectedDevice() {
        guard let device = selectedDevice else {
            ad_editable_set(nameRow, "")
            ad_editable_set(addressRow, "")
            ad_editable_set(usernameRow, "admin")
            ad_editable_set(passwordRow, "")
            ad_action_set_subtitle(keyringRow, "Save a device to store its password in Windows Credential Manager")
            updateCertificateStatus(for: nil)
            gtk_window_set_title(window, "Overlook")
            return
        }

        ad_editable_set(nameRow, device.name)
        ad_editable_set(addressRow, device.address)
        ad_editable_set(usernameRow, device.username)
        gtk_window_set_title(window, "Overlook — \(device.displayName)")

        let (password, status) = passwords.load(for: device)
        ad_editable_set(passwordRow, password ?? "")
        switch status {
        case .ready:
            ad_action_set_subtitle(keyringRow, password == nil ? "No saved password for this device" : "Loaded from Windows Credential Manager")
        case .missing(let message), .error(let message):
            ad_action_set_subtitle(keyringRow, message)
        }
        updateCertificateStatus(for: device)
    }

    private func updateCertificateStatus(for device: Device?) {
        guard let device else {
            ad_action_set_subtitle(trustRow, "No device selected")
            ad_sensitive(forgetTrustButton, 0)
            return
        }

        if let record = certificates.record(for: device.hostPort) {
            ad_action_set_subtitle(trustRow, "Pinned SHA-256 \(record.fingerprint)")
            ad_sensitive(forgetTrustButton, 1)
        } else {
            ad_action_set_subtitle(trustRow, "No certificate pinned; first self-signed TLS connection will ask for confirmation")
            ad_sensitive(forgetTrustButton, 0)
        }
    }

    private func beginNewDevice() {
        selectedDevice = nil
        populateSelectedDevice()
        ad_stack_set_visible(stack, "connect")
    }

    private func saveDeviceFromForm() -> Device? {
        guard let draft = Device.normalized(
            id: selectedDevice?.id ?? UUID(),
            name: text(of: nameRow),
            address: text(of: addressRow),
            username: text(of: usernameRow),
            lastConnected: Date()
        ) else {
            ad_banner_show(banner, "Enter a valid GLKVM hostname or IP address.", 1)
            return nil
        }

        if let index = devices.firstIndex(where: { $0.id == draft.id || $0.hostPort == draft.hostPort }) {
            devices[index] = draft
        } else {
            devices.insert(draft, at: 0)
        }
        selectedDevice = draft

        do {
            try store.save(devices)
        } catch {
            ad_banner_show(banner, "Could not save device list: \(error.localizedDescription)", 1)
        }

        let password = text(of: passwordRow)
        let passwordStatus = passwords.save(password, for: draft)
        switch passwordStatus {
        case .ready:
            ad_action_set_subtitle(keyringRow, password.isEmpty ? "Password cleared from Windows Credential Manager" : "Saved in Windows Credential Manager")
        case .missing(let message), .error(let message):
            ad_action_set_subtitle(keyringRow, message)
        }

        reloadDeviceList()
        updateCertificateStatus(for: draft)
        return draft
    }

    private func saveAndConnectNative() {
        guard let device = saveDeviceFromForm() else { return }
        let username = text(of: usernameRow).isEmpty ? "admin" : text(of: usernameRow)
        let password = text(of: passwordRow)
        lastCredentials = (device, username, password)
        connectionLog.record(device: device.hostPort, event: "connect_start", detail: "user=\(username)")
        ad_stack_set_visible(stack, "native")
        nativeSession?.connect(device: device, username: username, password: password)
    }

    private func saveAndOpenWeb() {
        guard let device = saveDeviceFromForm(), let url = device.webURL else {
            ad_banner_show(banner, "Could not build HTTPS URL for device.", 1)
            return
        }
        let web = ensureWebView()
        if certificates.record(for: device.hostPort) != nil {
            ol_web_trust_host(web, device.host)
        }
        ol_web_load(web, url.absoluteString)
        ad_stack_set_visible(stack, "web")
        ad_label_set(statusLabel, "Web console: \(url.absoluteString)")
    }

    private func deleteSelectedDevice() {
        guard let selectedDevice else { return }
        _ = passwords.clear(for: selectedDevice)
        devices.removeAll { $0.id == selectedDevice.id }
        self.selectedDevice = devices.first
        try? store.save(devices)
        reloadDeviceList()
        populateSelectedDevice()
    }

    private func forgetSelectedCertificate() {
        guard let selectedDevice else { return }
        try? certificates.remove(host: selectedDevice.hostPort)
        updateCertificateStatus(for: selectedDevice)
    }

    private func evaluateCertificate(host: String, fingerprint: String, summary: String) -> Bool {
        let hostKey = selectedDevice?.hostPort ?? host
        switch certificates.evaluate(host: hostKey, fingerprint: fingerprint) {
        case .trusted:
            return true
        case .unknown(let fp):
            promptToTrustCertificate(
                host: hostKey,
                fingerprint: fp,
                heading: "Trust GLKVM TLS Certificate?",
                body: "\(hostKey) presented an untrusted or self-signed certificate.\n\nSHA-256 fingerprint:\n\(fp)\n\n\(summary)"
            )
            return false
        case .mismatch(let expected, let actual):
            promptToTrustCertificate(
                host: hostKey,
                fingerprint: actual,
                heading: "Certificate Fingerprint Changed",
                body: "The certificate for \(hostKey) does not match the pinned fingerprint.\n\nPinned: \(expected)\nPresented: \(actual)\n\nOnly replace the pin if you recently flashed or reconfigured this GLKVM device."
            )
            return false
        }
    }

    private func promptToTrustCertificate(host: String, fingerprint: String, heading: String, body: String) {
        pendingCertificateHost = host
        pendingCertificateFingerprint = fingerprint
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        ad_alert(
            window,
            heading,
            body,
            "cancel",
            "Reject",
            "trust",
            "Trust and Reconnect",
            1,
            { response, context in
                guard let context else { return }
                let me = Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue()
                let choice = response.map { String(cString: $0) } ?? "cancel"
                guard choice == "trust",
                      let host = me.pendingCertificateHost,
                      let fingerprint = me.pendingCertificateFingerprint else { return }
                try? me.certificates.trust(host: host, fingerprint: fingerprint)
                me.connectionLog.record(device: host, event: "tls_pinned", detail: fingerprint)
                if let device = me.selectedDevice, let web = me.web {
                    ol_web_trust_host(web, device.host)
                }
                me.updateCertificateStatus(for: me.selectedDevice)
                me.saveAndConnectNative()
            },
            selfPtr
        )
    }

    private func showSettingsDialog() {
        let dlg = SettingsDialog(
            session: nativeSession,
            device: selectedDevice,
            certificates: certificates,
            connectionLog: connectionLog,
            onConfigChanged: { [weak self] cfg in
                self?.applyConfigToUI(cfg)
            },
            onStatusToast: { [weak self] msg in
                guard let self else { return }
                ad_label_set(self.statusLabel, msg)
            }
        )
        activeSettingsDialog = dlg
        dlg.present(over: window)
    }

    private func showConnectionInfoDialog() {
        let dlg = ConnectionInfoDialog(
            session: nativeSession,
            device: selectedDevice,
            certificates: certificates
        )
        activeInfoDialog = dlg
        dlg.present(over: window)
    }

    private func captureScreenshot() {
        guard let session = nativeSession else { return }
        let userProfile = ProcessInfo.processInfo.environment["USERPROFILE"] ?? NSHomeDirectory()
        let picturesDir = URL(fileURLWithPath: userProfile, isDirectory: true)
            .appendingPathComponent("Pictures", isDirectory: true)
            .appendingPathComponent("Overlook", isDirectory: true)
        try? FileManager.default.createDirectory(at: picturesDir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "Overlook_\(selectedDevice?.host ?? "capture")_\(formatter.string(from: Date())).png"
        let fullPath = picturesDir.appendingPathComponent(filename).path

        switch session.takeScreenshot(to: fullPath) {
        case .success(let savedPath):
            ad_label_set(statusLabel, "Screenshot saved to \(savedPath)")
        case .failure(let err):
            ad_banner_show(banner, "Screenshot failed: \(err.localizedDescription)", 1)
        }
    }

    private func toggleRecording(active: Bool) {
        guard let session = nativeSession else { return }
        if active {
            guard !session.isRecording else { return }
            let userProfile = ProcessInfo.processInfo.environment["USERPROFILE"] ?? NSHomeDirectory()
            let videosDir = URL(fileURLWithPath: userProfile, isDirectory: true)
                .appendingPathComponent("Videos", isDirectory: true)
                .appendingPathComponent("Overlook", isDirectory: true)
            try? FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let filename = "Overlook_\(selectedDevice?.host ?? "stream")_\(formatter.string(from: Date())).mp4"
            let fullPath = videosDir.appendingPathComponent(filename).path
            let cfg = session.config

            switch session.startRecording(to: fullPath, hevc: cfg.preferHEVC, vaapiDevice: cfg.vaapiDevice) {
            case .success(let info):
                ad_label_set(statusLabel, "Recording (\(info.backend)) → \(info.path)")
                connectionLog.record(device: selectedDevice?.hostPort ?? "stream", event: "record_start", detail: "\(info.backend) \(info.path)")
                refreshNativeState()
            case .failure(let err):
                ad_toggle_set(recordButton, 0)
                ad_banner_show(banner, "Recording failed: \(err.localizedDescription)", 1)
            }
        } else {
            guard session.isRecording else { return }
            switch session.stopRecording() {
            case .success(let stats):
                ad_label_set(statusLabel, String(format: "Recording saved (%.1fs, %d frames)", stats.duration, stats.frames))
                connectionLog.record(device: selectedDevice?.hostPort ?? "stream", event: "record_stop", detail: "\(stats.frames) frames")
                refreshNativeState()
            case .failure(let err):
                ad_banner_show(banner, "Stop recording error: \(err.localizedDescription)", 1)
            }
        }
    }

    private func ocrCurrentFrameToClipboard() {
        guard let session = nativeSession else { return }
        let tmpPath = NSTemporaryDirectory() + "overlook-ocr-\(UUID().uuidString).png"
        switch session.takeScreenshot(to: tmpPath) {
        case .failure(let err):
            ad_banner_show(banner, "OCR capture failed: \(err.localizedDescription)", 1)
        case .success(let imgPath):
            defer { try? FileManager.default.removeItem(atPath: imgPath) }
            let proc = Process()
            #if os(Windows)
            let defaultTesseract = "C:\\Program Files\\Tesseract-OCR\\tesseract.exe"
            if FileManager.default.fileExists(atPath: defaultTesseract) {
                proc.executableURL = URL(fileURLWithPath: defaultTesseract)
                proc.arguments = [imgPath, "stdout", "-l", "eng"]
            } else {
                proc.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\where.exe")
                proc.arguments = ["tesseract"]
            }
            #else
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["tesseract", imgPath, "stdout", "-l", "eng"]
            #endif
            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let recognized = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if recognized.isEmpty {
                    ad_banner_show(banner, "OCR completed but no text was detected on screen (ensure tesseract is installed)", 1)
                } else {
                    ol_clipboard_set(window, recognized)
                    ad_label_set(statusLabel, "OCR copied \(recognized.count) characters to clipboard")
                }
            } catch {
                ad_banner_show(banner, "Install tesseract (e.g. winget install UB-Mannheim.TesseractOCR or scoop install tesseract) to enable screen OCR", 1)
            }
        }
    }

    private func pasteHostClipboard() {
        guard let ptr = ol_clipboard_get(window) else {
            ad_banner_show(banner, "Clipboard is empty or does not contain text", 1)
            return
        }
        defer { g_free(ptr) }
        let text = String(cString: ptr)
        guard !text.isEmpty else { return }
        nativeSession?.pasteText(text)
    }

    private func scheduleAutoReconnectIfNeeded(reason: String) {
        guard let cfg = nativeSession?.config, cfg.autoReconnect,
              let creds = lastCredentials,
              reconnectTimerId == 0 else { return }
        // Don't auto-reconnect on TLS certificate mismatch or bad credentials
        if reason.localizedCaseInsensitiveContains("certificate") || reason.localizedCaseInsensitiveContains("401") {
            return
        }
        ad_label_set(statusLabel, "Connection dropped — auto-reconnecting in 3s…")
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        reconnectTimerId = g_timeout_add_seconds(3, { ctx -> Int32 in
            guard let ctx else { return G_SOURCE_REMOVE }
            let me = Unmanaged<OverlookDesktopController>.fromOpaque(ctx).takeUnretainedValue()
            me.reconnectTimerId = 0
            if let creds = me.lastCredentials, !(me.nativeSession?.stats.connected ?? false) {
                me.connectionLog.record(device: creds.device.hostPort, event: "auto_reconnect", detail: "Retrying native stream")
                me.nativeSession?.connect(device: creds.device, username: creds.username, password: creds.password)
            }
            return G_SOURCE_REMOVE
        }, selfPtr)
    }

    private func toggleFullscreen() {
        if gtk_window_is_fullscreen(window) != 0 {
            gtk_window_unfullscreen(window)
            ad_split_set_show_sidebar(splitView, 1)
        } else {
            ad_split_set_show_sidebar(splitView, 0)
            gtk_window_fullscreen(window)
        }
    }

    private func text(of row: OLWidgetPtr) -> String {
        guard let raw = ad_editable_get(row) else { return "" }
        return String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

let smokeMode: SmokeMode = {
    if CommandLine.arguments.contains("--native-smoke-test") {
        return .nativeStream
    }
    if CommandLine.arguments.contains("--capture-smoke-test") {
        return .captureDialog
    }
    if CommandLine.arguments.contains("--smoke-test") {
        return .ui
    }
    return .none
}()

let app = ad_app_new("com.overlook.windows")
let controller = OverlookDesktopController(app: app, smokeMode: smokeMode)
let controllerPtr = Unmanaged.passRetained(controller).toOpaque()

ol_signal_connect(app, "startup", { _, context in
    guard let context else { return }
    Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().startup()
}, controllerPtr)

ol_signal_connect(app, "activate", { _, context in
    guard let context else { return }
    Unmanaged<OverlookDesktopController>.fromOpaque(context).takeUnretainedValue().activate()
}, controllerPtr)

let status = g_application_run(app, 0, nil)
g_object_unref(app)
Unmanaged<OverlookDesktopController>.fromOpaque(controllerPtr).release()
exit(status)
