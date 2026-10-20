import Foundation
import CDesktop
import OverlookCore

// GTK owns the UI thread. Every callback runs on GLib's main loop; no Dispatch
// main queue or Apple run loop is needed on Linux.
final class Desktop {
    let app = ol_app()!
    let store = DeviceStore()
    var devices: [Device] = []
    var bookmarksWritable = true
    var actions: [UnsafeMutableRawPointer: () -> Void] = [:]
    var window: UnsafeMutableRawPointer!
    var deviceList: UnsafeMutableRawPointer!
    var content: UnsafeMutableRawPointer!
    var address: UnsafeMutableRawPointer!
    var name: UnsafeMutableRawPointer!
    var status: UnsafeMutableRawPointer!
    var trustBar: UnsafeMutableRawPointer!
    var trustText: UnsafeMutableRawPointer!
    var native: NativeSession?
    var username: UnsafeMutableRawPointer!
    var password: UnsafeMutableRawPointer!
    var otp: UnsafeMutableRawPointer!
    var web: UnsafeMutableRawPointer?
    var certificate: UnsafeMutableRawPointer?
    var certificateURL: URL?
    var failed = false
    var fullscreen = false
    var smokePassed = false
    var nativeSmokeCycles = 0
    let smoke = CommandLine.arguments.contains("--smoke-test")
    let nativeSmoke = CommandLine.arguments.contains("--native-smoke-test")
    var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    func button(_ title: String, in box: UnsafeMutableRawPointer, action: @escaping () -> Void) {
        let widget = ol_button(title)!
        actions[widget] = action
        ol_signal(widget, "clicked", { widget, context in
            guard let widget, let context else { return }
            Unmanaged<Desktop>.fromOpaque(context).takeUnretainedValue().actions[widget]?()
        }, context)
        ol_append(box, widget)
    }

    func start() -> Int32 {
        ol_signal(app, "activate", { _, context in
            Unmanaged<Desktop>.fromOpaque(context!).takeUnretainedValue().activate()
        }, context)
        let result = ol_run(app)
        native?.stop()
        clearCertificate()
        ol_unref(app)
        return (smoke || nativeSmoke) && !smokePassed ? 1 : result
    }

    func activate() {
        if let window { ol_present(window); return }
        window = ol_window(app)
        ol_title(window, "Overlook — Linux Preview")
        ol_size(window, 1280, 800)
        let root = ol_box(1, 8)!
        ol_margin(root, 12)
        ol_child(window, root)
        let toolbar = ol_box(0, 8)!
        address = ol_entry("Device address · https://pikvm.local")
        ol_expand(address, 1, 0)
        ol_append(toolbar, address)
        ol_signal(address, "activate", { _, context in
            Unmanaged<Desktop>.fromOpaque(context!).takeUnretainedValue().connect()
        }, context)
        button("Connect native", in: toolbar) { [unowned self] in connect() }
        button("Web console", in: toolbar) { [unowned self] in connectWeb() }
        button("Disconnect", in: toolbar) { [unowned self] in disconnect() }
        button("Reload", in: toolbar) { [unowned self] in
            if let web { failed = false; ol_reload(web) } else { show("For native video, reconnect using Connect native.") }
        }
        button("Fullscreen", in: toolbar) { [unowned self] in
            fullscreen.toggle(); ol_fullscreen(window, fullscreen ? 1 : 0)
        }
        ol_append(root, toolbar)
        let credentials = ol_box(0, 8)!
        username = ol_entry("Username")
        ol_set_value(username, "admin")
        password = ol_password("Password")
        otp = ol_password("OTP code (optional)")
        ol_append(credentials, username)
        ol_append(credentials, password)
        ol_append(credentials, otp)
        ol_append(credentials, ol_label("Native video is view-only. Use Web console for remote input and settings."))
        ol_append(root, credentials)
        let body = ol_box(0, 12)!
        let sidebar = ol_box(1, 8)!
        ol_append(sidebar, ol_label("SAVED DEVICES"))
        name = ol_entry("Device name (optional)")
        ol_append(sidebar, name)
        button("Save address", in: sidebar) { [unowned self] in saveDevice() }
        deviceList = ol_box(1, 6)
        let scroll = ol_scroll(deviceList)!
        ol_expand(scroll, 0, 1)
        ol_append(sidebar, scroll)
        ol_append(body, sidebar)
        content = ol_box(1, 0)
        ol_expand(content, 1, 1)
        ol_append(body, content)
        ol_expand(body, 1, 1)
        ol_append(root, body)
        trustBar = ol_box(1, 6)
        trustText = ol_label("")
        ol_append(trustBar, trustText)
        let trustActions = ol_box(0, 8)!
        button("Trust certificate for this session", in: trustActions) { [unowned self] in
            guard let web, let certificate, let url = certificateURL, let host = url.host else { return }
            ol_trust(web, certificate, host)
            clearCertificate()
            failed = false
            ol_load(web, url.absoluteString)
        }
        button("Cancel", in: trustActions) { [unowned self] in disconnect() }
        ol_append(trustBar, trustActions)
        ol_append(root, trustBar)
        ol_visible(trustBar, 0)
        status = ol_label("Connect to a GLKVM / Comet or PiKVM. Sign in using its console.")
        ol_append(root, status)
        do { devices = try store.load(); rebuildDevices() }
        catch { bookmarksWritable = false; show("Cannot read saved devices: \(error.localizedDescription). Repair the file before saving.") }
        welcome()
        ol_present(window)
        if nativeSmoke {
            clearContent()
            startNative()
            native?.test()
        } else if smoke {
            replaceWeb()
            ol_html(web, "<html><body><h1>Overlook GTK4 smoke test</h1></body></html>")
        }
    }

    func show(_ message: String) {
        ol_text(status, message)
        if smoke || nativeSmoke { print(message) }
    }

    func welcome() {
        let label = ol_label("Overlook for Linux\n\nConnect using the address above, or select a saved device.\n\nConnect native uses GStreamer WebRTC for view-only video.\nWeb console provides keyboard, mouse, and device settings.\nDisconnect discards this session’s cookies and certificate exceptions.")!
        ol_margin(label, 24)
        ol_expand(label, 1, 1)
        ol_append(content, label)
    }

    func clearCertificate() {
        if let certificate { ol_unref(certificate) }
        certificate = nil
        certificateURL = nil
        if let trustBar { ol_visible(trustBar, 0) }
    }

    func clearContent() {
        native?.stop()
        native = nil
        clearCertificate()
        // Removing the widget destroys its ephemeral session and stops its media.
        web = nil
        while let child = ol_first(content) { ol_remove(content, child) }
    }

    func disconnect() {
        clearContent()
        welcome()
        ol_title(window, "Overlook — Linux Preview")
        show("Disconnected. Session data discarded.")
    }

    func startNative() {
        native = NativeSession(onStatus: { [weak self] in self?.show($0) }, onFrame: { [weak self] in
            guard let self, self.nativeSmoke else { return }
            self.nativeSmokeCycles += 1
            if self.nativeSmokeCycles < 3 {
                self.clearContent()
                self.startNative()
                self.native?.test(h264: self.nativeSmokeCycles == 1)
            } else {
                self.smokePassed = true
                ol_quit(self.app)
            }
        }, onFailure: { [weak self] in
            if let self, self.nativeSmoke { ol_quit(self.app) }
        })
        ol_expand(native!.picture, 1, 1)
        ol_append(content, native!.picture)
    }

    func connect() {
        do {
            let url = try DeviceAddress.parse(String(cString: ol_value(address)))
            let code = String(cString: ol_value(otp))
            guard code.isEmpty || (code.count == 6 && code.allSatisfy({ $0.isASCII && $0.isNumber })) else {
                show("OTP must be a six-digit code, not a TOTP secret."); return
            }
            clearContent()
            startNative()
            ol_title(window, "\(url.host ?? "KVM") — Native WebRTC — Overlook")
            native?.connect(base: url, username: String(cString: ol_value(username)),
                            password: String(cString: ol_value(password)), otp: code)
            ol_set_value(password, "")
            ol_set_value(otp, "")
        } catch { show(error.localizedDescription) }
    }

    func connectWeb() {
        do {
            let url = try DeviceAddress.parse(String(cString: ol_value(address)))
            replaceWeb()
            ol_set_value(address, url.absoluteString)
            ol_title(window, "\(url.host ?? "KVM") — Overlook")
            ol_load(web, url.absoluteString)
        } catch { show(error.localizedDescription) }
    }

    func replaceWeb() {
        clearContent()
        failed = false
        let view = ol_web()!
        web = view
        ol_expand(view, 1, 1)
        ol_append(content, view)
        ol_on_load(view, { view, event, context in
            let owner = Unmanaged<Desktop>.fromOpaque(context!).takeUnretainedValue()
            guard view == owner.web else { return }
            if event == 0 { owner.show("Loading device console…") }
            if event == 3 && !owner.failed {
                owner.show("Console loaded. Sign in on the device. Disconnect to end the session.")
                if owner.smoke { owner.smokePassed = true; ol_quit(owner.app) }
            }
        }, context)
        ol_on_failure(view, { view, _, _, error, context in
            let owner = Unmanaged<Desktop>.fromOpaque(context!).takeUnretainedValue()
            guard view == owner.web else { return 1 }
            if let error, g_error_matches(error, webkit_network_error_quark(), Int32(WEBKIT_NETWORK_ERROR_CANCELLED.rawValue)) != 0 { return 1 }
            owner.failed = true
            if owner.certificate == nil {
                owner.show("Connection failed: \(error.map { String(cString: $0.pointee.message) } ?? "Unknown network error")")
            }
            if owner.smoke { ol_quit(owner.app) }
            return 1
        }, context)
        ol_on_tls(view, { view, uri, cert, _, context in
            let owner = Unmanaged<Desktop>.fromOpaque(context!).takeUnretainedValue()
            guard view == owner.web, let cert, let uri, let url = URL(string: String(cString: uri)) else { return 0 }
            owner.clearCertificate()
            owner.failed = true
            owner.certificate = ol_ref(cert)
            owner.certificateURL = url
            ol_text(owner.trustText, "The certificate for \(url.host ?? "this device") could not be verified. Only continue if you trust this device and network. This exception applies to the presented certificate for this host until Disconnect.")
            ol_visible(owner.trustBar, 1)
            owner.show("Connection stopped: certificate verification failed.")
            return 1
        }, context)
        ol_on_policy(view, { _, decision, type, context in
            // Keep file:, custom schemes, and popup windows out of the console.
            guard type == 0 || type == 1, let decision else { return 0 }
            let uri = ol_policy_uri(decision).map { String(cString: $0) } ?? ""
            let scheme = URL(string: uri)?.scheme?.lowercased()
            if type == 1 || !(scheme == "https" || scheme == "http" || uri == "about:blank") {
                ol_ignore(decision)
                let owner = Unmanaged<Desktop>.fromOpaque(context!).takeUnretainedValue()
                owner.show("This preview supports HTTP(S) console navigation in the current window only.")
                return 1
            }
            return 0
        }, context)
    }

    func saveDevice() {
        guard bookmarksWritable else { show("Repair the saved devices file and restart before saving."); return }
        do {
            let device = try Device(name: String(cString: ol_value(name)), address: String(cString: ol_value(address)))
            var updated = devices.filter { $0.address != device.address }
            updated.append(device)
            try store.save(updated)
            devices = updated
            rebuildDevices()
            show("Saved \(device.name). Passwords are not stored.")
        } catch { show("Could not save device: \(error.localizedDescription)") }
    }

    func rebuildDevices() {
        while let row = ol_first(deviceList) {
            var child = ol_first(row)
            while let item = child {
                child = ol_next(item)
                actions.removeValue(forKey: item)
            }
            ol_remove(deviceList, row)
        }
        for device in devices {
            let row = ol_box(0, 4)!
            button(device.name, in: row) { [unowned self] in
                ol_set_value(address, device.address.absoluteString)
                ol_set_value(name, device.name)
                connect()
            }
            button("Remove", in: row) { [unowned self] in
                do {
                    let updated = devices.filter { $0.id != device.id }
                    try store.save(updated)
                    devices = updated
                    rebuildDevices()
                } catch { show("Could not remove device: \(error.localizedDescription)") }
            }
            ol_append(deviceList, row)
        }
    }
}

if CommandLine.arguments.contains("--help") {
    print("Overlook Linux Preview\nUsage: overlook [--smoke-test | --native-smoke-test]\nConnect to a device using the GTK address bar. --smoke-test loads a local page; --native-smoke-test receives video from a local WebRTC peer.")
} else {
    exit(Desktop().start())
}
