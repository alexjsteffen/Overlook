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
    let certificates = CertificateStore()
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
    var deviceList: UnsafeMutableRawPointer!
    var keyboardButton: UnsafeMutableRawPointer!
    var address: UnsafeMutableRawPointer!
    var name: UnsafeMutableRawPointer!
    var username: UnsafeMutableRawPointer!
    var password: UnsafeMutableRawPointer!
    var otp: UnsafeMutableRawPointer!
    var actions: [String: UnsafeMutableRawPointer] = [:]
    var mode = Mode.idle
    var host = ""
    var native: NativeSession?
    var web: UnsafeMutableRawPointer?
    var webCertificate: UnsafeMutableRawPointer?
    var webCertificateURL: URL?
    var failed = false
    var smokePassed = false
    var nativeSmokeCycles = 0
    let smoke = CommandLine.arguments.contains("--smoke-test")
    let nativeSmoke = CommandLine.arguments.contains("--native-smoke-test")
    var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    static let accelerators: [(String, String)] = [
        ("app.new-connection", "<Control>n"), ("win.reload", "<Control>r"), ("win.fullscreen", "F11"),
        ("win.disconnect", "<Control>w"), ("app.quit", "<Control>q")
    ]

    func start() -> Int32 {
        on(app, "activate") { [unowned self] in activate() }
        let result = ol_run(app)
        native?.stop()
        clearWebCertificate()
        ol_unref(app)
        return (smoke || nativeSmoke) && !smokePassed ? 1 : result
    }

    func action(_ map: UnsafeMutableRawPointer, _ name: String, _ run: @escaping () -> Void) {
        let action = ad_action(map, name)!
        actions[name] = action
        on(action, "activate") { (_: UnsafeMutableRawPointer?) in run() }
    }

    func activate() {
        if let window { ol_present(window); return }
        window = ad_window(app)
        ol_title(window, "Overlook")
        ol_size(window, 1280, 800)
        ad_min_size(window, 360, 400)

        action(app, "new-connection") { [unowned self] in disconnect(); ad_focus(address) }
        action(app, "forget-certificates") { [unowned self] in
            do { try certificates.forgetAll(); toast("Trusted certificates forgotten.") }
            catch { toast("Could not forget certificates: \(error.localizedDescription)") }
        }
        action(app, "about") { [unowned self] in ad_about(window, "0.2 Preview") }
        action(app, "quit") { [unowned self] in ad_close(window) }
        action(window, "reload") { [unowned self] in reload() }
        action(window, "fullscreen") { [unowned self] in
            ol_fullscreen(window, ad_is_fullscreen(window) != 0 ? 0 : 1)
        }
        action(window, "disconnect") { [unowned self] in disconnect(); show("Disconnected", notice: "Disconnected. Session data discarded.") }
        action(window, "capture") { [unowned self] in native?.capture() }
        action(window, "send-ctrl-alt-delete") { [unowned self] in native?.sendShortcut(["ControlLeft", "AltLeft", "Delete"]) }
        action(window, "send-ctrl-alt-backspace") { [unowned self] in native?.sendShortcut(["ControlLeft", "AltLeft", "Backspace"]) }
        action(window, "send-print-screen") { [unowned self] in native?.sendShortcut(["PrintScreen"]) }
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
        ad_header_end(header, mainMenuButton())
        keyboardButton = keyboardMenuButton()
        ad_header_end(header, keyboardButton)
        ad_toolbar_top(contentView, header)

        stack = ad_stack()
        ad_stack_add(stack, connectPage(), "connect")
        session = ol_box(1, 0)
        ol_expand(session, 1, 1)
        let overlay = ad_overlay(session)!
        spinner = ad_spinner()
        ad_overlay_add(overlay, spinner)
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
        if nativeSmoke {
            startNative(host: "Local test")
            native?.test()
        } else if smoke {
            replaceWeb()
            ol_html(web, "<html><body><h1>Overlook GTK4 smoke test</h1></body></html>")
        }
    }

    func mainMenuButton() -> UnsafeMutableRawPointer {
        let menu = ad_menu()!
        let session = ad_menu()!
        ad_menu_item(session, "_Reload", "win.reload")
        ad_menu_item(session, "_Fullscreen", "win.fullscreen")
        ad_menu_item(session, "_Disconnect", "win.disconnect")
        ad_menu_section(menu, session)
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
        ad_menu_section(menu, capture)
        let keys = ad_menu()!
        ad_menu_item(keys, "Send Ctrl+Alt+_Delete", "win.send-ctrl-alt-delete")
        ad_menu_item(keys, "Send Ctrl+Alt+_Backspace", "win.send-ctrl-alt-backspace")
        ad_menu_item(keys, "Send _Print Screen", "win.send-print-screen")
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
        otp = ad_entry_row("One-Time Code (Optional)")
        ad_entry_purpose(otp, 1)
        for row in [username!, password!, otp!] { ad_group_add(credentials, row) }
        ol_append(box, credentials)
        for row in [address!, password!, otp!] { on(row, "entry-activated") { [unowned self] in connect() } }

        let buttons = ol_box(0, 12)!
        ad_align(buttons, alignCenter, alignFill)
        let connect = ad_mnemonic_button("_Connect")!
        ad_css(connect, "pill"); ad_css(connect, "suggested-action")
        on(connect, "clicked") { [unowned self] in self.connect() }
        let console = ad_mnemonic_button("_Web Console")!
        ad_css(console, "pill")
        on(console, "clicked") { [unowned self] in connectWeb() }
        ol_append(buttons, connect)
        ol_append(buttons, console)
        ol_append(box, buttons)
        ol_append(box, ad_wrap_label("Passwords are kept in memory only. Click the video to capture the keyboard; press Left Ctrl+Alt to release it.", "dim-label")!)
        ad_status_child(page, ad_clamp(box, 440))
        return page
    }

    func setAccelerators(_ enabled: Bool) {
        for (action, accel) in Self.accelerators { ad_accel(app, action, enabled ? accel : nil) }
    }

    func toast(_ message: String) {
        ad_toast(toasts, message, 4)
        if smoke || nativeSmoke { print(message) }
    }

    func show(_ subtitle: String, notice: String? = nil) {
        ad_set_title(title, mode == .idle ? "Overlook" : host, subtitle)
        if let notice { toast(notice) } else if smoke || nativeSmoke { print(subtitle) }
    }

    func updateSessionControls() {
        let input = mode == .native && native?.inputAvailable == true
        ol_visible(keyboardButton, input ? 1 : 0)
        for name in ["capture", "release-keys", "send-ctrl-alt-delete", "send-ctrl-alt-backspace", "send-print-screen"] {
            ad_action_enabled(actions[name], input ? 1 : 0)
        }
        ad_action_enabled(actions["reload"], mode == .idle ? 0 : 1)
        ad_action_enabled(actions["disconnect"], mode == .idle ? 0 : 1)
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
        native = session
        session.onStatus = { [unowned self] in show($0) }
        session.onNotice = { [unowned self] in toast($0) }
        session.onFailure = { [unowned self] message in
            if nativeSmoke { print(message); ol_quit(app); return }
            fail(message)
        }
        session.onFrame = { [unowned self] in
            ad_spin(spinner, 0)
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
                show(session.mouseAbsolute ? "Connected" : "Connected · Relative mouse")
            }
        }
        let picture = session.picture
        ol_expand(picture, 1, 1)
        ol_append(self.session, picture)
        showSession(.native, host: host)
    }

    func connect() {
        do {
            let url = try DeviceAddress.parse(String(cString: ol_value(address)))
            let code = String(cString: ol_value(otp))
            guard code.isEmpty || (code.count == 6 && code.allSatisfy({ $0.isASCII && $0.isNumber })) else {
                ad_focus(otp); toast("The one-time code must have six digits."); return
            }
            startNative(host: url.host ?? "KVM")
            native?.connect(base: url, username: String(cString: ol_value(username)),
                            password: String(cString: ol_value(password)), otp: code)
            ol_set_value(password, "")
            ol_set_value(otp, "")
        } catch { toast(error.localizedDescription) }
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
        ol_set_value(address, device.address.absoluteString)
        ol_set_value(name, device.name)
        if String(cString: ol_value(password)).isEmpty {
            disconnect()
            ol_set_value(address, device.address.absoluteString)
            ol_set_value(name, device.name)
            ad_focus(password)
            show("", notice: "Enter the password for \(device.name).")
        } else { connect() }
    }

    func saveDevice() {
        guard bookmarksWritable else { toast("Repair the saved devices file and restart before saving."); return }
        do {
            let device = try Device(name: String(cString: ol_value(name)), address: String(cString: ol_value(address)))
            var updated = devices.filter { $0.address != device.address }
            updated.append(device)
            try store.save(updated)
            devices = updated
            rebuildDevices()
            toast("Saved \(device.name). Passwords are not stored.")
        } catch { toast("Could not save device: \(error.localizedDescription)") }
    }

    func remove(_ device: Device) {
        do {
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
}

if CommandLine.arguments.contains("--help") {
    print("Overlook for Linux\nUsage: overlook [--smoke-test | --native-smoke-test]\nConnect to a PiKVM or GL.iNet Comet / GLKVM device. --smoke-test loads a local page; --native-smoke-test receives video from a local WebRTC peer.")
} else {
    exit(Desktop().start())
}
