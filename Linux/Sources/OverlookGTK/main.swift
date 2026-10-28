import Foundation
import CDesktop
import OverlookCore

/// Retained Swift closure for a GLib signal; released by GLib with the instance.
final class Handler {
    let run: (UnsafeMutableRawPointer?) -> Void
    init(_ run: @escaping (UnsafeMutableRawPointer?) -> Void) { self.run = run }
}
private let releaseHandler: OLRelease = { Unmanaged<Handler>.fromOpaque($0!).release() }
func on(_ object: UnsafeMutableRawPointer, _ signal: String, _ run: @escaping () -> Void) {
    ol_connect0(object, signal, { _, box in
        Unmanaged<Handler>.fromOpaque(ol_box_value(box)!).takeUnretainedValue().run(nil)
    }, Unmanaged.passRetained(Handler { _ in run() }).toOpaque(), releaseHandler)
}
func on(_ object: UnsafeMutableRawPointer, _ signal: String, _ run: @escaping (UnsafeMutableRawPointer?) -> Void) {
    ol_connect1(object, signal, { _, argument, box in
        Unmanaged<Handler>.fromOpaque(ol_box_value(box)!).takeUnretainedValue().run(argument)
    }, Unmanaged.passRetained(Handler(run)).toOpaque(), releaseHandler)
}

// GtkAlign / AdwResponseAppearance values.
let alignFill: Int32 = 0, alignCenter: Int32 = 3
let responseDefault: Int32 = 0, responseSuggested: Int32 = 1, responseDestructive: Int32 = 2

// GTK owns the UI thread. Every callback runs on GLib's main loop; no Dispatch
// main queue or Apple run loop is needed on Linux.
final class Desktop {
    enum Mode { case idle, native, web }
    let app = ad_app()!
    let store = DeviceStore()
    let passwordStore = PasswordStore()
    let preferencesStore = PreferencesStore()
    let certificates = CertificateStore()
    var preferences: AppPreferences!
    var vaapiStatus = VAAPIProbeStatus()
    var connectionInfo: ConnectionInfoController!
    var settingsDialog: SettingsDialogController!
    var devices: [Device] = []
    var deviceRows: [UnsafeMutableRawPointer: Device] = [:]
    var bookmarksWritable = true
    var window: UnsafeMutableRawPointer!
    var toasts: UnsafeMutableRawPointer!
    var split: UnsafeMutableRawPointer!
    var contentView: UnsafeMutableRawPointer!
    var sidebarView: UnsafeMutableRawPointer!
    var title: UnsafeMutableRawPointer!
    var stack: UnsafeMutableRawPointer!
    var session: UnsafeMutableRawPointer!
    var spinner: UnsafeMutableRawPointer!
    var recordingBadge: UnsafeMutableRawPointer!
    var deviceList: UnsafeMutableRawPointer!
    var keyboardButton: UnsafeMutableRawPointer!
    var screenshotButton: UnsafeMutableRawPointer!
    var recordButton: UnsafeMutableRawPointer!
    var ocrButton: UnsafeMutableRawPointer!
    var infoButton: UnsafeMutableRawPointer!
    var settingsButton: UnsafeMutableRawPointer!
    var address: UnsafeMutableRawPointer!
    var name: UnsafeMutableRawPointer!
    var username: UnsafeMutableRawPointer!
    var password: UnsafeMutableRawPointer!
    var savePassword: UnsafeMutableRawPointer!
    var otp: UnsafeMutableRawPointer!
    var actions: [String: UnsafeMutableRawPointer] = [:]
    var mode = Mode.idle
    var host = ""
    var native: NativeSession?
    var web: UnsafeMutableRawPointer?
    var webCertificate: UnsafeMutableRawPointer?
    var webCertificateURL: URL?
    var recordingStartedAt: Date?
    var recordingFileURL: URL?
    var recordingBackend = ""
    var recordingTimer: UInt32 = 0
    var failed = false
    var smokePassed = false
    var nativeSmokeCycles = 0
    let smoke = CommandLine.arguments.contains("--smoke-test")
    let nativeSmoke = CommandLine.arguments.contains("--native-smoke-test")
    let captureSmoke = CommandLine.arguments.contains("--capture-smoke-test")
    var webConsoleAvailable: Bool {
        ProcessInfo.processInfo.environment["OVERLOOK_DISABLE_WEB_CONSOLE"] != "1"
    }
    var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    static let accelerators: [(String, String)] = [
        ("app.new-connection", "<Control>n"), ("win.reload", "<Control>r"), ("win.fullscreen", "F11"),
        ("win.disconnect", "<Control>w"), ("win.connection-info", "<Control>i"), ("win.connection-log", "<Control>l"),
        ("win.settings", "<Control>comma"), ("win.screenshot", "<Control><Shift>s"), ("win.record", "<Control><Shift>r"),
        ("win.paste-remote", "<Control><Shift>v"), ("app.quit", "<Control>q")
    ]

    var isRecording: Bool { native?.isRecording == true }
    var recordingStatusText: String {
        guard isRecording, let started = recordingStartedAt else { return "Idle" }
        let elapsed = CaptureFileNaming.durationText(Date().timeIntervalSince(started))
        return "Recording \(elapsed) · \(recordingBackend)"
    }

    func start() -> Int32 {
        preferences = preferencesStore.load()
        refreshVAAPI()
        connectionInfo = ConnectionInfoController(desktop: self)
        settingsDialog = SettingsDialogController(desktop: self)
        on(app, "activate") { [unowned self] in activate() }
        let result = ol_run(app)
        if isRecording { stopRecording() }
        native?.stop()
        clearWebCertificate()
        ol_unref(app)
        return (smoke || nativeSmoke || captureSmoke) && !smokePassed ? 1 : result
    }

    func action(_ map: UnsafeMutableRawPointer, _ name: String, _ run: @escaping () -> Void) {
        let action = ad_action(map, name)!
        actions[name] = action
        on(action, "activate") { (_: UnsafeMutableRawPointer?) in run() }
    }

    func activate() {
        if let window { ol_present(window); return }
        applyAppearance()
        window = ad_window(app)
        ol_title(window, "Overlook")
        ol_size(window, 1280, 800)
        ad_min_size(window, 360, 400)

        action(app, "new-connection") { [unowned self] in
            disconnect()
            ol_set_value(address, ""); ol_set_value(name, "")
            ol_set_value(username, "admin"); ol_set_value(password, ""); ol_set_value(otp, "")
            ad_set_checked(savePassword, 0)
            ad_focus(address)
        }
        action(app, "forget-certificates") { [unowned self] in
            do { try certificates.forgetAll(); toast("Trusted certificates forgotten.") }
            catch { toast("Could not forget certificates: \(error.localizedDescription)") }
        }
        action(app, "about") { [unowned self] in ad_about(window, "0.3 Preview") }
        action(app, "quit") { [unowned self] in ad_close(window) }
        action(window, "reload") { [unowned self] in reload() }
        action(window, "fit-window") { [unowned self] in fitWindowToGuest() }
        action(window, "fullscreen") { [unowned self] in
            ol_fullscreen(window, ad_is_fullscreen(window) != 0 ? 0 : 1)
        }
        action(window, "connection-info") { [unowned self] in
            native?.releaseCapture()
            connectionInfo.present()
        }
        action(window, "connection-log") { [unowned self] in
            native?.releaseCapture()
            connectionInfo.presentConnectionLog()
        }
        action(window, "settings") { [unowned self] in
            native?.releaseCapture()
            settingsDialog.present()
        }
        action(window, "screenshot") { [unowned self] in takeScreenshot() }
        action(window, "streamer-snapshot") { [unowned self] in saveStreamerSnapshot() }
        action(window, "record") { [unowned self] in toggleRecording() }
        action(window, "ocr") { [unowned self] in
            native?.releaseCapture()
            performServerOCR()
        }
        action(window, "paste-remote") { [unowned self] in pasteClipboardToRemote() }
        action(window, "logout-disconnect") { [unowned self] in logoutAndDisconnect() }
        action(window, "disconnect") { [unowned self] in disconnect(); show("Disconnected", notice: "Disconnected. Session data discarded.") }
        action(window, "capture") { [unowned self] in native?.capture() }
        action(window, "send-ctrl-alt-delete") { [unowned self] in native?.sendShortcut(["ControlLeft", "AltLeft", "Delete"]) }
        action(window, "send-ctrl-alt-backspace") { [unowned self] in native?.sendShortcut(["ControlLeft", "AltLeft", "Backspace"]) }
        action(window, "send-ctrl-shift-esc") { [unowned self] in native?.sendShortcut(["ControlLeft", "ShiftLeft", "Escape"]) }
        action(window, "send-alt-tab") { [unowned self] in native?.sendShortcut(["AltLeft", "Tab"]) }
        action(window, "send-alt-f4") { [unowned self] in native?.sendShortcut(["AltLeft", "F4"]) }
        action(window, "send-super") { [unowned self] in native?.sendShortcut(["MetaLeft"]) }
        action(window, "send-print-screen") { [unowned self] in native?.sendShortcut(["PrintScreen"]) }
        action(window, "send-ctrl-alt-f1") { [unowned self] in native?.sendShortcut(["ControlLeft", "AltLeft", "F1"]) }
        action(window, "send-ctrl-alt-f2") { [unowned self] in native?.sendShortcut(["ControlLeft", "AltLeft", "F2"]) }
        action(window, "release-keys") { [unowned self] in native?.releaseInputs() }
        setAccelerators(true)
        on(window, "notify::fullscreened") { (_: UnsafeMutableRawPointer?) in
            let full = ad_is_fullscreen(self.window) != 0
            ad_toolbar_reveal(self.contentView, full ? 0 : 1)
            if full { ad_split_show(self.split, 0) }
        }

        sidebarView = ad_toolbar_view()
        let sideHeader = ad_header()!
        ad_header_title(sideHeader, ad_title("Devices", ""))
        let add = ad_icon_button("list-add-symbolic", "New Connection")!
        ad_action_name(add, "app.new-connection")
        ad_header_start(sideHeader, add)
        ad_toolbar_top(sidebarView, sideHeader)
        deviceList = ad_list()
        let empty = ad_wrap_label("No saved devices", "dim-label")!
        ol_margin(empty, 24)
        ad_list_placeholder(deviceList, empty)
        on(deviceList, "row-activated") { [unowned self] (row: UnsafeMutableRawPointer?) in
            if let row, let device = deviceRows[row] { select(device) }
        }
        let scroll = ol_scroll(deviceList)!
        ol_expand(scroll, 0, 1)
        ad_toolbar_content(sidebarView, scroll)

        contentView = ad_toolbar_view()
        let header = ad_header()!
        title = ad_title("Overlook", "")
        ad_header_title(header, title)
        let toggle = ad_toggle_button("sidebar-show-symbolic", "Toggle Sidebar")!
        ad_header_start(header, toggle)
        infoButton = ad_icon_button("dialog-information-symbolic", "Connection Information (Ctrl+I)")!
        ad_action_name(infoButton, "win.connection-info")
        ad_header_start(header, infoButton)

        ad_header_end(header, mainMenuButton())
        settingsButton = ad_icon_button("emblem-system-symbolic", "Settings (Ctrl+,)")!
        ad_action_name(settingsButton, "win.settings")
        ad_header_end(header, settingsButton)
        keyboardButton = keyboardMenuButton()
        ad_header_end(header, keyboardButton)
        ocrButton = ad_icon_button("edit-find-symbolic", "Extract Text with OCR")!
        ad_action_name(ocrButton, "win.ocr")
        ad_header_end(header, ocrButton)
        recordButton = ad_icon_button("media-record-symbolic", "Start Recording (Ctrl+Shift+R)")!
        ad_action_name(recordButton, "win.record")
        ad_header_end(header, recordButton)
        screenshotButton = ad_icon_button("camera-photo-symbolic", "Save Screenshot (Ctrl+Shift+S)")!
        ad_action_name(screenshotButton, "win.screenshot")
        ad_header_end(header, screenshotButton)
        ad_toolbar_top(contentView, header)

        stack = ad_stack()
        ad_stack_add(stack, connectPage(), "connect")
        session = ol_box(1, 0)
        ol_expand(session, 1, 1)
        let overlay = ad_overlay(session)!
        spinner = ad_spinner()
        ad_overlay_add(overlay, spinner)
        recordingBadge = ad_label("", "osd")!
        ad_css(recordingBadge, "caption")
        ad_align(recordingBadge, 2, 1) // GTK_ALIGN_END = 2, GTK_ALIGN_START = 1
        ol_margin(recordingBadge, 12)
        ol_visible(recordingBadge, 0)
        ad_overlay_add(overlay, recordingBadge)
        ad_stack_add(stack, overlay, "session")
        ad_toolbar_content(contentView, stack)

        split = ad_split(sidebarView, contentView)
        ad_bind(split, "show-sidebar", toggle, "active")
        toasts = ad_toasts(split)
        ad_window_content(window, toasts)
        ad_add_breakpoint(window, "max-width: 720sp", split, "collapsed")

        do { devices = try store.load(); rebuildDevices() }
        catch { bookmarksWritable = false; toast("Cannot read saved devices: \(error.localizedDescription). Repair the file before saving.") }
        showConnect()
        ol_present(window)
        if nativeSmoke || captureSmoke {
            startNative(host: "Local test")
            native?.test(h264: captureSmoke)
        } else if smoke {
            if webConsoleAvailable {
                replaceWeb()
                ol_html(web, "<html><body><h1>Overlook GTK4 smoke test</h1></body></html>")
            } else {
                print("Web Console smoke test is unavailable in the AppImage.")
                ol_quit(app)
            }
        }
    }

    func mainMenuButton() -> UnsafeMutableRawPointer {
        let menu = ad_menu()!
        let session = ad_menu()!
        ad_menu_item(session, "Connection _Information…", "win.connection-info")
        ad_menu_item(session, "Connection _Log…", "win.connection-log")
        ad_menu_item(session, "_Settings…", "win.settings")
        ad_menu_item(session, "_Reload", "win.reload")
        ad_menu_item(session, "Fit _Window to Video", "win.fit-window")
        ad_menu_item(session, "_Fullscreen", "win.fullscreen")
        ad_menu_item(session, "Log _Out and Disconnect", "win.logout-disconnect")
        ad_menu_item(session, "_Disconnect", "win.disconnect")
        ad_menu_section(menu, session)
        let captureSec = ad_menu()!
        ad_menu_item(captureSec, "Save _Screenshot", "win.screenshot")
        ad_menu_item(captureSec, "Save Streamer S_napshot", "win.streamer-snapshot")
        ad_menu_item(captureSec, "Start / Stop _Recording (VAAPI)", "win.record")
        ad_menu_item(captureSec, "Extract Text (_OCR)…", "win.ocr")
        ad_menu_section(menu, captureSec)
        let app = ad_menu()!
        ad_menu_item(app, "Forget Trusted _Certificates", "app.forget-certificates")
        ad_menu_item(app, "_About Overlook", "app.about")
        ad_menu_section(menu, app)
        return ad_menu_button("open-menu-symbolic", "Main Menu", menu, 1)
    }

    func keyboardMenuButton() -> UnsafeMutableRawPointer {
        let menu = ad_menu()!
        let capture = ad_menu()!
        ad_menu_item(capture, "_Capture Keyboard", "win.capture")
        ad_menu_item(capture, "_Release All Keys", "win.release-keys")
        ad_menu_item(capture, "_Paste Clipboard to Remote", "win.paste-remote")
        ad_menu_section(menu, capture)
        let keys = ad_menu()!
        ad_menu_item(keys, "Send Ctrl+Alt+_Delete", "win.send-ctrl-alt-delete")
        ad_menu_item(keys, "Send Ctrl+Alt+_Backspace", "win.send-ctrl-alt-backspace")
        ad_menu_item(keys, "Send Ctrl+Shift+_Esc", "win.send-ctrl-shift-esc")
        ad_menu_item(keys, "Send Alt+_Tab", "win.send-alt-tab")
        ad_menu_item(keys, "Send Alt+_F4", "win.send-alt-f4")
        ad_menu_item(keys, "Send _Super / Meta", "win.send-super")
        ad_menu_item(keys, "Send _Print Screen", "win.send-print-screen")
        ad_menu_item(keys, "Send Ctrl+Alt+F_1", "win.send-ctrl-alt-f1")
        ad_menu_item(keys, "Send Ctrl+Alt+F_2", "win.send-ctrl-alt-f2")
        ad_menu_section(menu, keys)
        return ad_menu_button("input-keyboard-symbolic", "Keyboard", menu, 0)
    }

    func connectPage() -> UnsafeMutableRawPointer {
        let page = ad_status("video-display-symbolic", "Connect to a KVM",
                             "Control a GL.iNet Comet, GLKVM, or PiKVM device over the network.")!
        let box = ol_box(1, 24)!
        let device = ad_group(nil)!
        address = ad_entry_row("Address")
        ad_entry_purpose(address, 0)
        name = ad_entry_row("Name (Optional)")
        let save = ad_icon_button("bookmark-new-symbolic", "Save Device")!
        ad_css(save, "flat"); ad_align(save, alignFill, alignCenter)
        on(save, "clicked") { [unowned self] in saveDevice() }
        ad_entry_suffix(name, save)
        ad_group_add(device, address)
        ad_group_add(device, name)
        ol_append(box, device)

        let credentials = ad_group("Sign In")!
        username = ad_entry_row("Username")
        ol_set_value(username, "admin")
        password = ad_password_row("Password")
        otp = ad_entry_row("One-Time Code or Base32 TOTP Secret (Optional)")
        for row in [username!, password!, otp!] { ad_group_add(credentials, row) }
        ol_append(box, credentials)
        savePassword = ad_check("Save password in system keyring when bookmarking")
        ol_append(box, savePassword)
        for row in [address!, password!, otp!] { on(row, "entry-activated") { [unowned self] in self.connect() } }

        let buttons = ol_box(0, 12)!
        ad_align(buttons, alignCenter, alignFill)
        let connectButton = ad_mnemonic_button("_Connect")!
        ad_css(connectButton, "pill"); ad_css(connectButton, "suggested-action")
        on(connectButton, "clicked") { [unowned self] in self.connect() }
        let console = ad_mnemonic_button("_Web Console")!
        ad_css(console, "pill")
        if !webConsoleAvailable {
            ad_sensitive(console, 0)
            ad_tooltip(console, "Web Console is unavailable in the AppImage. Use a native Linux package for this feature.")
        }
        on(console, "clicked") { [unowned self] in connectWeb() }
        ol_append(buttons, connectButton)
        ol_append(buttons, console)
        ol_append(box, buttons)
        ol_append(box, ad_wrap_label("Passwords are saved only when you opt in and bookmark a device. One-time codes are never saved. Click the video to capture the keyboard; press Left Ctrl+Alt to release it.", "dim-label")!)
        ad_status_child(page, ad_clamp(box, 440))
        return page
    }

    func setAccelerators(_ enabled: Bool) {
        for (action, accel) in Self.accelerators { ad_accel(app, action, enabled ? accel : nil) }
    }

    func toast(_ message: String) {
        ad_toast(toasts, message, 4)
        if smoke || nativeSmoke || captureSmoke { print(message) }
    }

    func show(_ subtitle: String, notice: String? = nil) {
        ad_set_title(title, mode == .idle ? "Overlook" : host, subtitle)
        if let notice { toast(notice) } else if smoke || nativeSmoke || captureSmoke { print(subtitle) }
    }

    func updateSessionControls() {
        let isNative = mode == .native
        let input = isNative && native?.inputAvailable == true
        ol_visible(keyboardButton, input ? 1 : 0)
        ol_visible(screenshotButton, isNative ? 1 : 0)
        ol_visible(recordButton, (isNative || isRecording) ? 1 : 0)
        ol_visible(ocrButton, isNative ? 1 : 0)
        for name in [
            "capture", "release-keys", "paste-remote",
            "send-ctrl-alt-delete", "send-ctrl-alt-backspace", "send-ctrl-shift-esc",
            "send-alt-tab", "send-alt-f4", "send-super", "send-print-screen",
            "send-ctrl-alt-f1", "send-ctrl-alt-f2"
        ] {
            ad_action_enabled(actions[name], input ? 1 : 0)
        }
        for name in ["screenshot", "streamer-snapshot", "ocr", "fit-window", "logout-disconnect"] {
            ad_action_enabled(actions[name], isNative ? 1 : 0)
        }
        ad_action_enabled(actions["record"], (isNative || isRecording) ? 1 : 0)
        ad_action_enabled(actions["reload"], mode == .idle ? 0 : 1)
        ad_action_enabled(actions["disconnect"], mode == .idle ? 0 : 1)
        updateRecordButtonUI()
    }

    func showConnect() {
        ad_stack_show(stack, "connect")
        ad_spin(spinner, 0)
        ad_set_title(title, "Overlook", "")
        ol_title(window, "Overlook")
        updateSessionControls()
    }

    func showSession(_ mode: Mode, host: String) {
        self.mode = mode
        self.host = host
        ad_stack_show(stack, "session")
        ad_spin(spinner, 1)
        ol_title(window, "\(host) — Overlook")
        if ad_split_collapsed(split) != 0 { ad_split_show(split, 0) }
        updateSessionControls()
    }

    func clearWebCertificate() {
        if let webCertificate { ol_unref(webCertificate) }
        webCertificate = nil
        webCertificateURL = nil
    }

    func clearContent() {
        if isRecording { stopRecording() }
        if native?.captured == true { setAccelerators(true) }
        native?.stop()
        native = nil
        clearWebCertificate()
        // Removing the widget destroys its ephemeral session and stops its media.
        web = nil
        while let child = ol_first(session) { ol_remove(session, child) }
        mode = .idle
    }

    func disconnect() {
        clearContent()
        showConnect()
    }

    func logoutAndDisconnect() {
        guard let session = native else { disconnect(); return }
        session.requestEmpty(path: "api/auth/logout") { [unowned self] _ in
            disconnect()
            show("Disconnected", notice: "Logged out and disconnected.")
        }
    }

    func reload() {
        if let web { failed = false; ol_reload(web) }
        else if mode == .native { connect() }
    }

    func fail(_ message: String) {
        clearContent()
        showConnect()
        toast(message)
    }

    // MARK: Native session

    func startNative(host: String) {
        clearContent()
        let session = NativeSession(trusted: (try? certificates.load()) ?? [:])
        session.relativeSensitivity = preferences.relativeSensitivity
        native = session
        session.onStatus = { [unowned self] in show($0) }
        session.onNotice = { [unowned self] in toast($0) }
        session.onFailure = { [unowned self] message in
            if nativeSmoke || captureSmoke { print(message); ol_quit(app); return }
            fail(message)
        }
        session.onFrame = { [unowned self] in
            ad_spin(spinner, 0)
            if captureSmoke {
                runCaptureSmokeVerification()
                return
            }
            guard nativeSmoke else { return }
            nativeSmokeCycles += 1
            if nativeSmokeCycles < 3 {
                startNative(host: "Local test")
                native?.test(h264: nativeSmokeCycles == 1)
            } else {
                smokePassed = true
                ol_quit(app)
            }
        }
        session.onCertificate = { [unowned self, unowned session] certificate in
            askTrust(host: certificate.key, sha256: certificate.sha256, reason: certificate.reason) { decision in
                guard self.native === session else { return }
                switch decision {
                case .cancel: session.rejectCertificate()
                case .once: session.trust(certificate)
                case .always:
                    do { try self.certificates.trust(certificate.key, sha256: certificate.sha256) }
                    catch { self.toast("Could not save the certificate: \(error.localizedDescription)") }
                    session.trust(certificate)
                }
            }
        }
        session.onInputChanged = { [unowned self, unowned session] in
            setAccelerators(!session.captured)
            updateSessionControls()
            guard session.inputAvailable else { return }
            if session.captured {
                show("Keyboard captured", notice: "Keyboard captured. Press Left Ctrl+Alt to release.")
            } else {
                updateLiveHeaderStatus()
            }
        }
        session.onTelemetryChanged = { [unowned self] in
            updateLiveHeaderStatus()
            connectionInfo.refresh()
        }
        let picture = session.picture
        ol_expand(picture, 1, 1)
        ol_append(self.session, picture)
        showSession(.native, host: host)
    }

    func updateLiveHeaderStatus() {
        guard mode == .native, let session = native, session.receivedFrame else { return }
        if session.captured {
            ad_set_title(title, host, "Keyboard captured")
            return
        }
        var parts: [String] = []
        let compact = session.telemetry.compactHeaderSubtitle
        if !compact.isEmpty {
            parts.append(compact)
        } else {
            parts.append("Connected")
        }
        if session.inputAvailable && !session.mouseAbsolute {
            parts.append("Relative mouse")
        } else if !session.inputAvailable {
            parts.append("View only")
        }
        let subtitle = parts.joined(separator: " · ")
        ad_set_title(title, host, subtitle)
        ol_title(window, "\(host) — \(subtitle) — Overlook")
    }

    func connect(saved credentials: SavedCredentials? = nil) {
        do {
            let url = try DeviceAddress.parse(String(cString: ol_value(address)))
            let rawOtp = String(cString: ol_value(otp)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let resolvedOtp = TOTPGenerator.resolveTwoFactorCode(rawOtp) else {
                ad_focus(otp); toast("Enter a 6-digit one-time code or a valid Base32 TOTP secret."); return
            }
            var user = String(cString: ol_value(username))
            var pass = String(cString: ol_value(password))
            if pass.isEmpty && ad_checked(savePassword) != 0 {
                if let saved = try credentials ?? passwordStore.load(for: url) {
                    user = saved.username
                    pass = saved.password
                } else {
                    ad_focus(password); toast("Enter a password before connecting with saved credentials."); return
                }
            }
            startNative(host: url.host ?? "KVM")
            native?.connect(base: url, username: user, password: pass, otp: resolvedOtp)
            ol_set_value(password, "")
            ol_set_value(otp, "")
        } catch { toast("Could not connect: \(error.localizedDescription)") }
    }

    // MARK: Certificates

    enum TrustDecision { case cancel, once, always }

    /// Ask before accepting a certificate the system does not trust. A pinned
    /// certificate that changed is reported as such and cannot be silently replaced.
    func askTrust(host key: String, sha256: String, reason: String, completion: @escaping (TrustDecision) -> Void) {
        let changed = certificates.pinned(key).map { $0 != sha256.lowercased() } ?? false
        let host = key.hasSuffix(":443") ? String(key.dropLast(4)) : key
        let body = changed
            ? "The certificate for \(host) is different from the one you trusted before. Someone could be impersonating the device. Only continue if you replaced its certificate."
            : "The identity of \(host) could not be verified. \(reason) Only continue if you trust this device and the network you are on."
        let dialog = ad_alert(changed ? "Certificate Changed" : "Unverified Certificate", body)!
        ad_alert_response(dialog, "cancel", "_Cancel", responseDefault)
        ad_alert_response(dialog, "once", "Trust _Once", responseDefault)
        ad_alert_response(dialog, "always", changed ? "_Replace and Trust" : "_Always Trust", responseDestructive)
        ad_alert_defaults(dialog, "cancel", "cancel")
        let details = ol_box(1, 6)!
        ol_append(details, ad_label("SHA-256 Fingerprint", "heading")!)
        ol_append(details, ad_fingerprint(CertificateFingerprint.display(sha256))!)
        ad_alert_extra(dialog, details)
        on(dialog, "response") { (response: UnsafeMutableRawPointer?) in
            let id = response.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? "cancel"
            completion(id == "always" ? .always : id == "once" ? .once : .cancel)
        }
        show("Waiting for certificate approval")
        ad_present(dialog, window)
    }

    // MARK: Web console

    func connectWeb() {
        guard webConsoleAvailable else {
            toast("Web Console is unavailable in the AppImage. Use a native Linux package for this feature.")
            return
        }
        do {
            let url = try DeviceAddress.parse(String(cString: ol_value(address)))
            replaceWeb()
            showSession(.web, host: url.host ?? "KVM")
            show("Web Console")
            ol_load(web, url.absoluteString)
        } catch { toast(error.localizedDescription) }
    }

    func replaceWeb() {
        clearContent()
        failed = false
        let view = ol_web()!
        web = view
        ol_expand(view, 1, 1)
        ol_append(session, view)
        ol_on_load(view, { view, event, context in
            let owner = Unmanaged<Desktop>.fromOpaque(context!).takeUnretainedValue()
            guard view == owner.web else { return }
            if event == 0 { owner.show("Loading…") }
            if event == 3 && !owner.failed {
                ad_spin(owner.spinner, 0)
                owner.show("Web Console")
                if owner.smoke { owner.smokePassed = true; ol_quit(owner.app) }
            }
        }, context)
        ol_on_failure(view, { view, _, _, error, context in
            let owner = Unmanaged<Desktop>.fromOpaque(context!).takeUnretainedValue()
            guard view == owner.web else { return 1 }
            if let error, g_error_matches(error, webkit_network_error_quark(), Int32(WEBKIT_NETWORK_ERROR_CANCELLED.rawValue)) != 0 { return 1 }
            owner.failed = true
            if owner.webCertificate == nil {
                let message = "Connection failed: \(error.map { String(cString: $0.pointee.message) } ?? "Unknown network error")"
                if owner.smoke { print(message); ol_quit(owner.app) } else { owner.fail(message) }
            }
            return 1
        }, context)
        ol_on_tls(view, { view, uri, cert, errors, context in
            let owner = Unmanaged<Desktop>.fromOpaque(context!).takeUnretainedValue()
            guard view == owner.web, let cert, let uri, let url = URL(string: String(cString: uri)) else { return 0 }
            owner.webCertificateFailed(url: url, certificate: cert, errors: errors)
            return 1
        }, context)
        ol_on_policy(view, { _, decision, type, context in
            // Keep file:, custom schemes, and popup windows out of the console.
            guard type == 0 || type == 1, let decision else { return 0 }
            let uri = ol_policy_uri(decision).map { String(cString: $0) } ?? ""
            let scheme = URL(string: uri)?.scheme?.lowercased()
            if type == 1 || !(scheme == "https" || scheme == "http" || uri == "about:blank") {
                ol_ignore(decision)
                Unmanaged<Desktop>.fromOpaque(context!).takeUnretainedValue()
                    .toast("Links to other windows or non-web addresses are blocked.")
                return 1
            }
            return 0
        }, context)
    }

    func webCertificateFailed(url: URL, certificate: UnsafeMutableRawPointer, errors: UInt32) {
        guard let host = url.host, let key = CertificateStore.key(for: url),
              let raw = ad_certificate_sha256(certificate) else { return }
        let sha256 = String(cString: raw)
        g_free(raw)
        clearWebCertificate()
        failed = true
        webCertificate = ol_ref(certificate)
        webCertificateURL = url
        let allow = { [unowned self] in
            guard let web, let webCertificate, let target = webCertificateURL else { return }
            ol_trust(web, webCertificate, host)
            clearWebCertificate()
            failed = false
            ol_load(web, target.absoluteString)
        }
        if certificates.pinned(key) == sha256 { allow(); return }
        askTrust(host: key, sha256: sha256, reason: describe(errors)) { [unowned self] decision in
            guard webCertificate == certificate else { return }
            switch decision {
            case .cancel: fail("The device certificate was not trusted.")
            case .once: allow()
            case .always:
                do { try certificates.trust(key, sha256: sha256) }
                catch { toast("Could not save the certificate: \(error.localizedDescription)") }
                allow()
            }
        }
    }

    func describe(_ errors: UInt32) -> String {
        let reasons: [(UInt32, String)] = [
            (1 << 0, "It is not issued by a trusted certificate authority."), (1 << 1, "It does not match the device address."),
            (1 << 2, "It is not valid yet."), (1 << 3, "It has expired."), (1 << 4, "It has been revoked."),
            (1 << 5, "It uses an insecure algorithm."), (1 << 6, "It could not be validated.")
        ]
        return reasons.filter { errors & $0.0 != 0 }.map(\.1).joined(separator: " ")
    }

    // MARK: Saved devices

    func select(_ device: Device) {
        disconnect()
        ol_set_value(address, device.address.absoluteString)
        ol_set_value(name, device.name)
        ol_set_value(password, "")
        ol_set_value(otp, "")
        ad_set_checked(savePassword, 0)
        do {
            if let saved = try passwordStore.load(for: device.address) {
                ol_set_value(username, saved.username)
                ad_set_checked(savePassword, 1)
                connect(saved: saved)
                return
            }
            ol_set_value(username, "admin")
            ad_focus(password)
            show("", notice: "Enter the password for \(device.name).")
        } catch {
            ad_focus(password)
            toast("Could not read saved password: \(error.localizedDescription)")
        }
    }

    func saveDevice() {
        guard bookmarksWritable else { toast("Repair the saved devices file and restart before saving."); return }
        do {
            let device = try Device(name: String(cString: ol_value(name)), address: String(cString: ol_value(address)))
            if ad_checked(savePassword) != 0 {
                let pass = String(cString: ol_value(password))
                if !pass.isEmpty {
                    try passwordStore.save(SavedCredentials(username: String(cString: ol_value(username)), password: pass), for: device.address)
                } else if try passwordStore.load(for: device.address) == nil {
                    ad_focus(password)
                    toast("Enter a password before saving it in the keyring.")
                    return
                }
            } else if devices.contains(where: { $0.address == device.address }) {
                try passwordStore.delete(for: device.address)
            }
            var updated = devices.filter { $0.address != device.address }
            updated.append(device)
            try store.save(updated)
            devices = updated
            rebuildDevices()
            if ad_checked(savePassword) != 0 { ol_set_value(password, "") }
            toast(ad_checked(savePassword) != 0 ? "Saved \(device.name) with password in system keyring." : "Saved \(device.name) without password.")
        } catch { toast("Could not save device: \(error.localizedDescription)") }
    }

    func remove(_ device: Device) {
        do {
            try passwordStore.delete(for: device.address)
            let updated = devices.filter { $0.id != device.id }
            try store.save(updated)
            devices = updated
            rebuildDevices()
            toast("Removed \(device.name).")
        } catch { toast("Could not remove device: \(error.localizedDescription)") }
    }

    func rebuildDevices() {
        ad_list_clear(deviceList)
        deviceRows.removeAll()
        for device in devices.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            let box = ol_box(0, 6)!
            let labels = ol_box(1, 2)!
            ol_expand(labels, 1, 0)
            ad_align(labels, alignFill, alignCenter)
            ol_append(labels, ad_label(device.name, nil)!)
            ol_append(labels, ad_label(device.address.host ?? device.address.absoluteString, "caption")!)
            ad_css(ol_next(ol_first(labels))!, "dim-label")
            ol_append(box, labels)
            let delete = ad_icon_button("user-trash-symbolic", "Remove \(device.name)")!
            ad_css(delete, "flat"); ad_align(delete, alignFill, alignCenter)
            on(delete, "clicked") { [unowned self] in remove(device) }
            ol_append(box, delete)
            let row = ad_list_row(box)!
            deviceRows[row] = device
            ad_list_append(deviceList, row)
        }
    }

    // MARK: Preferences, Appearance & VAAPI

    func savePreferences() {
        try? preferencesStore.save(preferences)
    }

    func applyAppearance() {
        let scheme: Int32 = preferences.appAppearance == "light" ? 1 : (preferences.appAppearance == "dark" ? 2 : 0)
        ad_style_color_scheme(scheme)
    }

    func refreshVAAPI() {
        vaapiStatus = NativeSession.probeVAAPI(preferredDevice: preferences.vaapiDevice)
    }

    func fitWindowToGuest() {
        guard let session = native,
              let w = session.telemetry.videoWidth,
              let h = session.telemetry.videoHeight,
              w > 0, h > 0 else {
            toast("Wait for video stream before fitting window.")
            return
        }
        ol_size(window, Int32(min(1920, max(640, w))), Int32(min(1080, max(480, h + 48))))
    }

    // MARK: Screenshot & VAAPI Recording

    func takeScreenshot() {
        guard let session = native else {
            toast("Connect to a device before taking a screenshot.")
            return
        }
        if !session.receivedFrame {
            saveStreamerSnapshot()
            return
        }
        let folder = URL(fileURLWithPath: (preferences.screenshotsFolder as NSString).expandingTildeInPath, isDirectory: true)
        let url = CaptureFileNaming.makeFileURL(in: folder, deviceName: host, extension: "png")
        do {
            try session.saveScreenshot(to: url)
            toast("Screenshot saved: \(url.lastPathComponent)")
        } catch {
            toast("Screenshot failed: \(error.localizedDescription)")
        }
    }

    func saveStreamerSnapshot() {
        guard let session = native else {
            toast("Connect to a device before capturing a streamer snapshot.")
            return
        }
        let folder = URL(fileURLWithPath: (preferences.screenshotsFolder as NSString).expandingTildeInPath, isDirectory: true)
        let url = CaptureFileNaming.makeFileURL(in: folder, deviceName: host, extension: "jpg")
        session.requestData(path: "api/streamer/snapshot", query: [("allow_offline", "1"), ("preview_quality", "95")]) { [unowned self] res in
            switch res {
            case .success(let data):
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                    toast("Streamer snapshot saved: \(url.lastPathComponent)")
                } catch {
                    toast("Could not save snapshot: \(error.localizedDescription)")
                }
            case .failure(let err):
                toast("Streamer snapshot failed: \(err.localizedDescription)")
            }
        }
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard let session = native else {
            toast("Connect to a device before recording.")
            return
        }
        let folder = URL(fileURLWithPath: (preferences.recordingsFolder as NSString).expandingTildeInPath, isDirectory: true)
        let url = CaptureFileNaming.makeFileURL(in: folder, deviceName: host, extension: "mp4")
        do {
            let backend = try session.startRecording(to: url, codec: preferences.videoCodec, vaapiDevice: preferences.vaapiDevice)
            recordingStartedAt = Date()
            recordingFileURL = url
            recordingBackend = backend
            updateRecordButtonUI()
            if recordingTimer == 0 {
                recordingTimer = g_timeout_add_seconds(1, { ctx in
                    let owner = Unmanaged<Desktop>.fromOpaque(ctx!).takeUnretainedValue()
                    guard owner.isRecording else { owner.recordingTimer = 0; return 0 }
                    owner.updateRecordButtonUI()
                    return 1
                }, context)
            }
            toast("Recording started (\(backend)).")
        } catch {
            toast("Recording failed: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        if recordingTimer != 0 {
            g_source_remove(recordingTimer)
            recordingTimer = 0
        }
        let savedURL = recordingFileURL
        recordingStartedAt = nil
        recordingFileURL = nil
        recordingBackend = ""
        guard let session = native, session.isRecording else {
            updateRecordButtonUI()
            return
        }
        do {
            let res = try session.stopRecording()
            updateRecordButtonUI()
            let dur = CaptureFileNaming.durationText(res.duration)
            toast("Recording saved (\(dur)): \(savedURL?.lastPathComponent ?? "recording.mp4")")
        } catch {
            updateRecordButtonUI()
            toast("Recording not saved: \(error.localizedDescription)")
        }
    }

    func updateRecordButtonUI() {
        guard let recordButton, let recordingBadge else { return }
        if isRecording, let started = recordingStartedAt {
            ad_button_icon(recordButton, "media-playback-stop-symbolic")
            ad_css(recordButton, "destructive-action")
            ad_tooltip(recordButton, "Stop Recording (Ctrl+Shift+R)")
            let elapsed = CaptureFileNaming.durationText(Date().timeIntervalSince(started))
            ol_text(recordingBadge, "  ● REC \(elapsed) · \(recordingBackend)  ")
            ol_visible(recordingBadge, 1)
        } else {
            ad_button_icon(recordButton, "media-record-symbolic")
            ad_remove_css(recordButton, "destructive-action")
            ad_tooltip(recordButton, "Start Recording (Ctrl+Shift+R)")
            ol_visible(recordingBadge, 0)
        }
    }

    // MARK: OCR & Clipboard Paste

    func performServerOCR() {
        guard let session = native else {
            toast("Connect to a device before running OCR.")
            return
        }
        let lang = preferences.serverOCRLanguage.isEmpty ? "eng" : preferences.serverOCRLanguage
        toast("Running OCR (\(lang))…")
        session.requestData(path: "api/streamer/snapshot", query: [("ocr", "true"), ("ocr_langs", lang)]) { [unowned self] res in
            switch res {
            case .success(let data):
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                settingsDialog.presentTextReport(title: "OCR Result (\(lang))", text: text.isEmpty ? "(No text recognized)" : text)
            case .failure(let err):
                toast("Server OCR failed: \(err.localizedDescription)")
            }
        }
    }

    func pasteClipboardToRemote() {
        ol_clipboard_get(window, { textPtr, ctx in
            let owner = Unmanaged<Desktop>.fromOpaque(ctx!).takeUnretainedValue()
            guard let session = owner.native, let textPtr else { return }
            let text = String(cString: textPtr)
            guard !text.isEmpty else { owner.toast("Clipboard is empty."); return }
            let km = owner.settingsDialog.config?.keymap ?? "en-us"
            session.requestEmpty(path: "api/hid/print", query: [("keymap", km)], contentType: "text/plain; charset=utf-8", body: Data(text.utf8)) { res in
                switch res {
                case .success: owner.toast("Pasted clipboard to remote host.")
                case .failure(let err): owner.toast("Paste failed: \(err.localizedDescription)")
                }
            }
        }, context)
    }

    // MARK: Capture Smoke Test

    func runCaptureSmokeVerification() {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("overlook-capture-smoke-\(UUID().uuidString)")
        preferences.screenshotsFolder = tmpDir.path
        preferences.recordingsFolder = tmpDir.path
        connectionInfo.present()
        settingsDialog.present()
        takeScreenshot()
        startRecording()
        _ = g_timeout_add(650, { ctx in
            let owner = Unmanaged<Desktop>.fromOpaque(ctx!).takeUnretainedValue()
            let dirPath = owner.preferences.screenshotsFolder
            owner.stopRecording()
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dirPath)) ?? []
            let hasPng = files.contains { $0.hasSuffix(".png") }
            let hasMp4 = files.contains { $0.hasSuffix(".mp4") }
            try? FileManager.default.removeItem(atPath: dirPath)
            if hasPng && hasMp4 {
                owner.smokePassed = true
            }
            ol_quit(owner.app)
            return 0
        }, context)
    }
}

if CommandLine.arguments.contains("--help") {
    print("Overlook for Linux\nUsage: overlook [--smoke-test | --native-smoke-test | --capture-smoke-test]\nConnect to a PiKVM or GL.iNet Comet / GLKVM device. --smoke-test loads a local page; --native-smoke-test receives video from a local WebRTC peer; --capture-smoke-test verifies PNG screenshots and VAAPI MP4 recording.")
} else {
    exit(Desktop().start())
}
