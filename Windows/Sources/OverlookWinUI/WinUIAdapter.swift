import Foundation
import CNativeWin
import OverlookCore

// MARK: - WinUI 3 / Windows 11 Fluent Desktop Widget Tree & Signal Adapter
// Provides the exact CDesktop (ad_* / ol_* / g_*) API surface used by OverlookWinUI
// (`main.swift`, `NativeSession.swift`, `ConnectionInfoDialog.swift`, `SettingsDialog*.swift`),
// backed by the native Windows 11 DWM Mica / Fluent Dark Mode desktop window and
// interactive video viewport in `CNativeWin` (`ol_win_gui_*`).

public typealias OLHandler0 = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
public typealias OLHandler1 = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
public typealias OLRelease = @convention(c) (UnsafeMutableRawPointer?) -> Void
public typealias OLAction = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
public typealias OLLoad = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutableRawPointer?) -> Void
public typealias OLFailure = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
public typealias OLTLS = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?) -> Int32
public typealias OLPolicy = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, UnsafeMutableRawPointer?) -> Int32
public typealias OLClipboardText = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
public typealias GSourceFunc = @convention(c) (UnsafeMutableRawPointer?) -> Int32

final class OLSignalSlot {
    let name: String
    let handler0: OLHandler0?
    let handler1: OLHandler1?
    let action: OLAction?
    let boxPtr: UnsafeMutableRawPointer?
    let release: OLRelease?
    let rawCtx: UnsafeMutableRawPointer?

    init(name: String, handler0: OLHandler0? = nil, handler1: OLHandler1? = nil, action: OLAction? = nil,
         boxPtr: UnsafeMutableRawPointer? = nil, release: OLRelease? = nil, rawCtx: UnsafeMutableRawPointer? = nil) {
        self.name = name
        self.handler0 = handler0
        self.handler1 = handler1
        self.action = action
        self.boxPtr = boxPtr
        self.release = release
        self.rawCtx = rawCtx
    }

    deinit {
        if let release, let boxPtr {
            release(boxPtr)
        }
    }
}

final class WinUIWidgetNode {
    let kind: String
    var title: String = ""
    var subtitle: String = ""
    var textValue: String = ""
    var actionName: String = ""
    var iconName: String = ""
    var tooltip: String = ""
    var checked: Bool = false
    var sensitive: Bool = true
    var visible: Bool = true
    var spinning: Bool = false
    var fullscreen: Bool = false
    var showSidebar: Bool = true
    var collapsed: Bool = false
    var width: Int32 = 0
    var height: Int32 = 0
    var spinValue: Double = 0
    var spinMin: Double = 0
    var spinMax: Double = 100
    var spinStep: Double = 1
    var comboItems: [String] = []
    var comboSelected: Int32 = -1
    var alertResponses: [(id: String, label: String, appearance: Int32)] = []
    var alertDefaultResponse: String = ""
    var alertCloseResponse: String = ""
    var uri: String = ""
    var certSha256: String = ""
    var nativePtr: OpaquePointer?
    var children: [WinUIWidgetNode] = []
    var namedChildren: [String: WinUIWidgetNode] = [:]
    var visibleStackName: String = ""
    weak var parent: WinUIWidgetNode?
    var signals: [OLSignalSlot] = []
    var loadCallback: (OLLoad, UnsafeMutableRawPointer?)?
    var failureCallback: (OLFailure, UnsafeMutableRawPointer?)?
    var tlsCallback: (OLTLS, UnsafeMutableRawPointer?)?
    var policyCallback: (OLPolicy, UnsafeMutableRawPointer?)?
    var cStringCache: UnsafeMutablePointer<CChar>?

    init(kind: String, title: String = "", subtitle: String = "") {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
    }

    deinit {
        if let cStringCache {
            ol_native_free_string(cStringCache)
        }
    }

    var opaquePtr: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    func cachedCString(_ str: String) -> UnsafePointer<CChar>! {
        if let cStringCache {
            ol_native_free_string(cStringCache)
            cStringCache = nil
        }
        cStringCache = ol_native_strdup(str)
        return UnsafePointer(cStringCache)
    }

    func emit0(_ signalName: String) {
        let ptr = opaquePtr
        for slot in signals where slot.name == signalName {
            if let h0 = slot.handler0 {
                h0(ptr, slot.boxPtr)
            } else if let act = slot.action {
                act(ptr, slot.rawCtx)
            }
        }
    }

    func emit1(_ signalName: String, arg: UnsafeMutableRawPointer?) {
        let ptr = opaquePtr
        for slot in signals where slot.name == signalName {
            if let h1 = slot.handler1 {
                h1(ptr, arg, slot.boxPtr)
            }
        }
    }

    func emit1String(_ signalName: String, value: String) {
        value.withCString { cstr in
            let mutPtr = UnsafeMutableRawPointer(mutating: cstr)
            emit1(signalName, arg: mutPtr)
        }
    }
}

final class WinUIAdapterRegistry {
    static let shared = WinUIAdapterRegistry()

    var nodes: [UnsafeMutableRawPointer: WinUIWidgetNode] = [:]
    var actions: [String: WinUIWidgetNode] = [:]
    var mainApp: WinUIWidgetNode?
    var mainWindow: WinUIWidgetNode?
    var deviceList: WinUIWidgetNode?
    var addressEntry: WinUIWidgetNode?
    var nameEntry: WinUIWidgetNode?
    var usernameEntry: WinUIWidgetNode?
    var passwordEntry: WinUIWidgetNode?
    var otpEntry: WinUIWidgetNode?
    var saveCheck: WinUIWidgetNode?
    var activeNative: OpaquePointer?

    func register(_ node: WinUIWidgetNode) -> UnsafeMutableRawPointer! {
        let ptr = Unmanaged.passRetained(node).toOpaque()
        nodes[ptr] = node
        return ptr
    }

    func node(_ ptr: UnsafeMutableRawPointer?) -> WinUIWidgetNode? {
        guard let ptr else { return nil }
        if let existing = nodes[ptr] {
            return existing
        }
        return Unmanaged<WinUIWidgetNode>.fromOpaque(ptr).takeUnretainedValue()
    }

    func syncFormFromNativeGUI() {
        var addr = [CChar](repeating: 0, count: 512)
        var name = [CChar](repeating: 0, count: 256)
        var user = [CChar](repeating: 0, count: 256)
        var pass = [CChar](repeating: 0, count: 256)
        var otp  = [CChar](repeating: 0, count: 128)
        var save: Int32 = 1
        ol_win_gui_get_form(&addr, 512, &name, 256, &user, 256, &pass, 256, &otp, 128, &save)
        addressEntry?.textValue = String(cString: addr)
        nameEntry?.textValue = String(cString: name)
        usernameEntry?.textValue = String(cString: user)
        passwordEntry?.textValue = String(cString: pass)
        otpEntry?.textValue = String(cString: otp)
        saveCheck?.checked = (save != 0)
    }

    func pushFormToNativeGUI() {
        let addr = addressEntry?.textValue ?? ""
        let name = nameEntry?.textValue ?? ""
        let user = usernameEntry?.textValue ?? "admin"
        let pass = passwordEntry?.textValue ?? ""
        let otp  = otpEntry?.textValue ?? ""
        let save: Int32 = (saveCheck?.checked ?? true) ? 1 : 0
        ol_win_gui_set_form(addr, name, user, pass, otp, save)
    }

    func handleNativeCommand(_ cmd: String, index: Int32) {
        switch cmd {
        case "connect":
            syncFormFromNativeGUI()
            actions["connect"]?.emit0("activate")
        case "save-device":
            syncFormFromNativeGUI()
            for (_, node) in nodes where node.kind == "button" && node.title == "Save Device" {
                node.emit0("clicked")
                break
            }
        case "device-activated":
            if let list = deviceList, index >= 0, Int(index) < list.children.count {
                let row = list.children[Int(index)]
                list.emit1("row-activated", arg: row.opaquePtr)
            }
        case "device-delete":
            if let list = deviceList, index >= 0, Int(index) < list.children.count {
                let row = list.children[Int(index)]
                func triggerDelete(_ n: WinUIWidgetNode) {
                    if n.kind == "icon_button" && n.iconName.contains("trash") {
                        n.emit0("clicked")
                        return
                    }
                    for child in n.children {
                        triggerDelete(child)
                    }
                }
                triggerDelete(row)
            }
        default:
            if let actionNode = actions[cmd] {
                actionNode.emit0("activate")
            }
        }
    }
}

// MARK: - Box & Signal Connection Helpers (adw.h)

func ol_box_value(_ data: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer! {
    return data
}

func ol_connect0(_ o: UnsafeMutableRawPointer?, _ name: String?, _ cb: OLHandler0?, _ box: UnsafeMutableRawPointer?, _ release: OLRelease?) {
    guard let node = WinUIAdapterRegistry.shared.node(o), let cb else { return }
    node.signals.append(OLSignalSlot(name: name ?? "", handler0: cb, boxPtr: box, release: release))
}

func ol_connect1(_ o: UnsafeMutableRawPointer?, _ name: String?, _ cb: OLHandler1?, _ box: UnsafeMutableRawPointer?, _ release: OLRelease?) {
    guard let node = WinUIAdapterRegistry.shared.node(o), let cb else { return }
    node.signals.append(OLSignalSlot(name: name ?? "", handler1: cb, boxPtr: box, release: release))
}

// MARK: - Application & Window Lifecycle

func ad_app() -> UnsafeMutableRawPointer! {
    let node = WinUIWidgetNode(kind: "app", title: "Overlook")
    WinUIAdapterRegistry.shared.mainApp = node
    return WinUIAdapterRegistry.shared.register(node)
}

func ol_app() -> UnsafeMutableRawPointer! {
    return ad_app()
}

func ol_signal(_ o: UnsafeMutableRawPointer?, _ name: String?, _ cb: OLAction?, _ ctx: UnsafeMutableRawPointer?) {
    guard let node = WinUIAdapterRegistry.shared.node(o), let cb else { return }
    node.signals.append(OLSignalSlot(name: name ?? "", action: cb, rawCtx: ctx))
}

func ol_run(_ app: UnsafeMutableRawPointer?) -> Int32 {
    ol_win_gui_init({ cmdPtr, idx, _ in
        guard let cmdPtr else { return }
        WinUIAdapterRegistry.shared.handleNativeCommand(String(cString: cmdPtr), index: idx)
    }, nil)
    if let appNode = WinUIAdapterRegistry.shared.node(app) {
        appNode.emit0("activate")
    }
    return ol_win_run_message_loop()
}

func ol_quit(_ app: UnsafeMutableRawPointer?) {
    _ = app
    ol_win_quit_message_loop(0)
}

func ol_unref(_ o: UnsafeMutableRawPointer?) {
    _ = o
}

func ol_ref(_ o: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer! {
    return o
}

func ad_window(_ app: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer! {
    _ = app
    let node = WinUIWidgetNode(kind: "window", title: "Overlook")
    WinUIAdapterRegistry.shared.mainWindow = node
    return WinUIAdapterRegistry.shared.register(node)
}

func ol_window(_ app: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer! {
    return ad_window(app)
}

func ad_window_content(_ w: UnsafeMutableRawPointer?, _ c: UnsafeMutableRawPointer?) {
    guard let win = WinUIAdapterRegistry.shared.node(w),
          let child = WinUIAdapterRegistry.shared.node(c) else { return }
    win.children = [child]
    child.parent = win
}

func ad_add_breakpoint(_ window: UnsafeMutableRawPointer?, _ condition: String?, _ object: UnsafeMutableRawPointer?, _ property: String?) {
    _ = window; _ = condition; _ = object; _ = property
}

func ad_is_fullscreen(_ w: UnsafeMutableRawPointer?) -> Int32 {
    _ = w
    return ol_win_gui_is_fullscreen()
}

func ad_close(_ w: UnsafeMutableRawPointer?) {
    guard let node = WinUIAdapterRegistry.shared.node(w) else { return }
    for slot in node.signals where slot.name == "close-request" {
        slot.handler0?(node.opaquePtr, slot.boxPtr)
    }
    ol_win_gui_close()
}

func ol_title(_ w: UnsafeMutableRawPointer?, _ title: String?) {
    guard let node = WinUIAdapterRegistry.shared.node(w) else { return }
    node.title = title ?? ""
    ol_win_gui_set_title(node.title, node.subtitle)
}

func ol_size(_ w: UnsafeMutableRawPointer?, _ x: Int32, _ y: Int32) {
    guard let node = WinUIAdapterRegistry.shared.node(w) else { return }
    node.width = x
    node.height = y
    ol_win_gui_set_size(x, y)
}

func ol_child(_ w: UnsafeMutableRawPointer?, _ c: UnsafeMutableRawPointer?) {
    ad_window_content(w, c)
}

func ol_present(_ w: UnsafeMutableRawPointer?) {
    _ = w
    ol_win_gui_present()
}

func ol_fullscreen(_ w: UnsafeMutableRawPointer?, _ enabled: Int32) {
    guard let node = WinUIAdapterRegistry.shared.node(w) else { return }
    node.fullscreen = (enabled != 0)
    ol_win_gui_set_fullscreen(enabled)
    node.emit0("notify::fullscreened")
}

// MARK: - Toolbar, Header & Split View

func ad_toolbar_view() -> UnsafeMutableRawPointer! {
    WinUIAdapterRegistry.shared.register(WinUIWidgetNode(kind: "toolbar_view"))
}

func ad_toolbar_top(_ v: UnsafeMutableRawPointer?, _ w: UnsafeMutableRawPointer?) {
    ol_append(v, w)
}

func ad_toolbar_content(_ v: UnsafeMutableRawPointer?, _ w: UnsafeMutableRawPointer?) {
    ol_append(v, w)
}

func ad_toolbar_reveal(_ v: UnsafeMutableRawPointer?, _ reveal: Int32) {
    _ = v; _ = reveal
}

func ad_header() -> UnsafeMutableRawPointer! {
    WinUIAdapterRegistry.shared.register(WinUIWidgetNode(kind: "header"))
}

func ad_header_start(_ h: UnsafeMutableRawPointer?, _ w: UnsafeMutableRawPointer?) {
    ol_append(h, w)
}

func ad_header_end(_ h: UnsafeMutableRawPointer?, _ w: UnsafeMutableRawPointer?) {
    ol_append(h, w)
}

func ad_header_title(_ h: UnsafeMutableRawPointer?, _ w: UnsafeMutableRawPointer?) {
    ol_append(h, w)
}

func ad_title(_ title: String?, _ subtitle: String?) -> UnsafeMutableRawPointer! {
    let node = WinUIWidgetNode(kind: "window_title", title: title ?? "", subtitle: subtitle ?? "")
    ol_win_gui_set_title(node.title, node.subtitle)
    return WinUIAdapterRegistry.shared.register(node)
}

func ad_set_title(_ w: UnsafeMutableRawPointer?, _ title: String?, _ subtitle: String?) {
    guard let node = WinUIAdapterRegistry.shared.node(w) else { return }
    node.title = title ?? ""
    node.subtitle = subtitle ?? ""
    ol_win_gui_set_title(node.title, node.subtitle)
}

func ad_split(_ sidebar: UnsafeMutableRawPointer?, _ content: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer! {
    let node = WinUIWidgetNode(kind: "split")
    if let sNode = WinUIAdapterRegistry.shared.node(sidebar) { node.children.append(sNode) }
    if let cNode = WinUIAdapterRegistry.shared.node(content) { node.children.append(cNode) }
    return WinUIAdapterRegistry.shared.register(node)
}

func ad_split_show(_ s: UnsafeMutableRawPointer?, _ show: Int32) {
    guard let node = WinUIAdapterRegistry.shared.node(s) else { return }
    node.showSidebar = (show != 0)
}

func ad_split_collapsed(_ s: UnsafeMutableRawPointer?) -> Int32 {
    guard let node = WinUIAdapterRegistry.shared.node(s) else { return 0 }
    return node.collapsed ? 1 : 0
}

func ad_bind(_ source: UnsafeMutableRawPointer?, _ sp: String?, _ target: UnsafeMutableRawPointer?, _ tp: String?) {
    _ = source; _ = sp; _ = target; _ = tp
}

// MARK: - Toasts, Status Page & Clamp

func ad_toasts(_ child: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer! {
    let node = WinUIWidgetNode(kind: "toast_overlay")
    if let c = WinUIAdapterRegistry.shared.node(child) { node.children.append(c) }
    return WinUIAdapterRegistry.shared.register(node)
}

func ad_toast(_ overlay: UnsafeMutableRawPointer?, _ text: String?, _ timeout: Int32) {
    _ = overlay; _ = timeout
    ol_win_gui_toast(text ?? "")
}

func ad_status(_ icon: String?, _ title: String?, _ description: String?) -> UnsafeMutableRawPointer! {
    let node = WinUIWidgetNode(kind: "status_page", title: title ?? "", subtitle: description ?? "")
    node.iconName = icon ?? ""
    return WinUIAdapterRegistry.shared.register(node)
}

func ad_status_child(_ s: UnsafeMutableRawPointer?, _ c: UnsafeMutableRawPointer?) {
    ol_append(s, c)
}

func ad_clamp(_ child: UnsafeMutableRawPointer?, _ size: Int32) -> UnsafeMutableRawPointer! {
    let node = WinUIWidgetNode(kind: "clamp")
    node.width = size
    if let c = WinUIAdapterRegistry.shared.node(child) { node.children.append(c) }
    return WinUIAdapterRegistry.shared.register(node)
}

// MARK: - Preferences Groups & Rows

func ad_group(_ title: String?) -> UnsafeMutableRawPointer! {
    WinUIAdapterRegistry.shared.register(WinUIWidgetNode(kind: "group", title: title ?? ""))
}

func ad_group_desc(_ title: String?, _ description: String?) -> UnsafeMutableRawPointer! {
    WinUIAdapterRegistry.shared.register(WinUIWidgetNode(kind: "group", title: title ?? "", subtitle: description ?? ""))
}

func ad_group_add(_ g: UnsafeMutableRawPointer?, _ w: UnsafeMutableRawPointer?) {
    ol_append(g, w)
}

func ad_entry_row(_ title: String?) -> UnsafeMutableRawPointer! {
    let t = title ?? ""
    let node = WinUIWidgetNode(kind: "entry_row", title: t)
    if t.contains("Address") { WinUIAdapterRegistry.shared.addressEntry = node }
    else if t.contains("Device Name") { WinUIAdapterRegistry.shared.nameEntry = node }
    else if t.contains("Username") { WinUIAdapterRegistry.shared.usernameEntry = node }
    else if t.contains("Two-Factor") || t.contains("OTP") { WinUIAdapterRegistry.shared.otpEntry = node }
    return WinUIAdapterRegistry.shared.register(node)
}

func ad_password_row(_ title: String?) -> UnsafeMutableRawPointer! {
    let t = title ?? ""
    let node = WinUIWidgetNode(kind: "password_row", title: t)
    if t == "Password" { WinUIAdapterRegistry.shared.passwordEntry = node }
    return WinUIAdapterRegistry.shared.register(node)
}

func ad_entry_suffix(_ r: UnsafeMutableRawPointer?, _ w: UnsafeMutableRawPointer?) {
    ol_append(r, w)
}

func ad_entry_purpose(_ r: UnsafeMutableRawPointer?, _ digits: Int32) {
    _ = r; _ = digits
}

// MARK: - Buttons, Menus & Actions

func ad_icon_button(_ icon: String?, _ tooltip: String?) -> UnsafeMutableRawPointer! {
    let node = WinUIWidgetNode(kind: "icon_button")
    node.iconName = icon ?? ""
    node.tooltip = tooltip ?? ""
    return WinUIAdapterRegistry.shared.register(node)
}

func ad_toggle_button(_ icon: String?, _ tooltip: String?) -> UnsafeMutableRawPointer! {
    let node = WinUIWidgetNode(kind: "toggle_button")
    node.iconName = icon ?? ""
    node.tooltip = tooltip ?? ""
    return WinUIAdapterRegistry.shared.register(node)
}

func ad_action_name(_ w: UnsafeMutableRawPointer?, _ action: String?) {
    guard let node = WinUIAdapterRegistry.shared.node(w) else { return }
    node.actionName = action ?? ""
}

func ad_menu_button(_ icon: String?, _ tooltip: String?, _ menu: UnsafeMutableRawPointer?, _ primary: Int32) -> UnsafeMutableRawPointer! {
    _ = primary
    let node = WinUIWidgetNode(kind: "menu_button")
    node.iconName = icon ?? ""
    node.tooltip = tooltip ?? ""
    if let m = WinUIAdapterRegistry.shared.node(menu) { node.children.append(m) }
    return WinUIAdapterRegistry.shared.register(node)
}

func ad_menu() -> UnsafeMutableRawPointer! {
    WinUIAdapterRegistry.shared.register(WinUIWidgetNode(kind: "menu"))
}

func ad_menu_item(_ m: UnsafeMutableRawPointer?, _ label: String?, _ action: String?) {
    let item = WinUIWidgetNode(kind: "menu_item", title: label ?? "")
    item.actionName = action ?? ""
    let ptr = WinUIAdapterRegistry.shared.register(item)
    ol_append(m, ptr)
}

func ad_menu_section(_ m: UnsafeMutableRawPointer?, _ section: UnsafeMutableRawPointer?) {
    ol_append(m, section)
}

func ad_action(_ map: UnsafeMutableRawPointer?, _ name: String?) -> UnsafeMutableRawPointer! {
    _ = map
    let actName = name ?? ""
    let node = WinUIWidgetNode(kind: "action", title: actName)
    WinUIAdapterRegistry.shared.actions[actName] = node
    return WinUIAdapterRegistry.shared.register(node)
}

func ad_action_enabled(_ a: UnsafeMutableRawPointer?, _ enabled: Int32) {
    guard let node = WinUIAdapterRegistry.shared.node(a) else { return }
    node.sensitive = (enabled != 0)
}

func ad_accel(_ app: UnsafeMutableRawPointer?, _ action: String?, _ accel: String?) {
    _ = app; _ = action; _ = accel
}

// MARK: - Sidebar List & Rows

func ad_list() -> UnsafeMutableRawPointer! {
    let node = WinUIWidgetNode(kind: "list")
    WinUIAdapterRegistry.shared.deviceList = node
    return WinUIAdapterRegistry.shared.register(node)
}

func ad_list_placeholder(_ l: UnsafeMutableRawPointer?, _ w: UnsafeMutableRawPointer?) {
    _ = l; _ = w
}

func ad_list_append(_ l: UnsafeMutableRawPointer?, _ row: UnsafeMutableRawPointer?) {
    guard let list = WinUIAdapterRegistry.shared.node(l),
          let rowNode = WinUIAdapterRegistry.shared.node(row) else { return }
    list.children.append(rowNode)
    rowNode.parent = list

    var texts: [String] = []
    func collectLabels(_ n: WinUIWidgetNode) {
        if n.kind == "label" && !n.title.isEmpty {
            texts.append(n.title)
        }
        for c in n.children {
            collectLabels(c)
        }
    }
    collectLabels(rowNode)
    let devName = texts.first ?? "KVM Device"
    let devHost = texts.count > 1 ? texts[1] : devName
    ol_win_gui_add_device(devName, devHost)
}

func ad_list_clear(_ l: UnsafeMutableRawPointer?) {
    guard let list = WinUIAdapterRegistry.shared.node(l) else { return }
    list.children.removeAll()
    ol_win_gui_clear_devices()
}

func ad_list_select(_ l: UnsafeMutableRawPointer?, _ row: UnsafeMutableRawPointer?) {
    _ = l; _ = row
}

func ad_list_row(_ child: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer! {
    let node = WinUIWidgetNode(kind: "list_row")
    if let c = WinUIAdapterRegistry.shared.node(child) {
        node.children.append(c)
        c.parent = node
    }
    return WinUIAdapterRegistry.shared.register(node)
}

// MARK: - Labels, Checkboxes, Stack, Overlay & Spinner

func ad_label(_ text: String?, _ css: String?) -> UnsafeMutableRawPointer! {
    _ = css
    return WinUIAdapterRegistry.shared.register(WinUIWidgetNode(kind: "label", title: text ?? ""))
}

func ad_wrap_label(_ text: String?, _ css: String?) -> UnsafeMutableRawPointer! {
    _ = css
    return WinUIAdapterRegistry.shared.register(WinUIWidgetNode(kind: "label", title: text ?? ""))
}

func ad_fingerprint(_ text: String?) -> UnsafeMutableRawPointer! {
    return WinUIAdapterRegistry.shared.register(WinUIWidgetNode(kind: "fingerprint", title: text ?? ""))
}

func ad_min_size(_ w: UnsafeMutableRawPointer?, _ width: Int32, _ height: Int32) {
    guard let node = WinUIAdapterRegistry.shared.node(w) else { return }
    node.width = width
    node.height = height
}

func ad_mnemonic_button(_ label: String?) -> UnsafeMutableRawPointer! {
    let clean = (label ?? "").replacingOccurrences(of: "_", with: "")
    return WinUIAdapterRegistry.shared.register(WinUIWidgetNode(kind: "button", title: clean))
}

func ad_css(_ w: UnsafeMutableRawPointer?, _ css: String?) {
    _ = w; _ = css
}

func ad_remove_css(_ w: UnsafeMutableRawPointer?, _ css: String?) {
    _ = w; _ = css
}

func ad_button_icon(_ b: UnsafeMutableRawPointer?, _ icon: String?) {
    guard let node = WinUIAdapterRegistry.shared.node(b) else { return }
    node.iconName = icon ?? ""
}

func ad_tooltip(_ w: UnsafeMutableRawPointer?, _ tooltip: String?) {
    guard let node = WinUIAdapterRegistry.shared.node(w) else { return }
    node.tooltip = tooltip ?? ""
}

func ad_align(_ w: UnsafeMutableRawPointer?, _ halign: Int32, _ valign: Int32) {
    _ = w; _ = halign; _ = valign
}

func ad_focus(_ w: UnsafeMutableRawPointer?) {
    _ = w
}

func ad_check(_ label: String?) -> UnsafeMutableRawPointer! {
    let node = WinUIWidgetNode(kind: "check", title: label ?? "")
    if node.title.contains("Save password") {
        WinUIAdapterRegistry.shared.saveCheck = node
    }
    return WinUIAdapterRegistry.shared.register(node)
}

func ad_checked(_ w: UnsafeMutableRawPointer?) -> Int32 {
    WinUIAdapterRegistry.shared.syncFormFromNativeGUI()
    guard let node = WinUIAdapterRegistry.shared.node(w) else { return 0 }
    return node.checked ? 1 : 0
}

func ad_set_checked(_ w: UnsafeMutableRawPointer?, _ checked: Int32) {
    guard let node = WinUIAdapterRegistry.shared.node(w) else { return }
    node.checked = (checked != 0)
    WinUIAdapterRegistry.shared.pushFormToNativeGUI()
}

func ad_sensitive(_ w: UnsafeMutableRawPointer?, _ enabled: Int32) {
    guard let node = WinUIAdapterRegistry.shared.node(w) else { return }
    node.sensitive = (enabled != 0)
}

func ad_stack() -> UnsafeMutableRawPointer! {
    WinUIAdapterRegistry.shared.register(WinUIWidgetNode(kind: "stack"))
}

func ad_stack_add(_ st: UnsafeMutableRawPointer?, _ w: UnsafeMutableRawPointer?, _ name: String?) {
    guard let stack = WinUIAdapterRegistry.shared.node(st),
          let child = WinUIAdapterRegistry.shared.node(w) else { return }
    let key = name ?? ""
    stack.namedChildren[key] = child
    stack.children.append(child)
    child.parent = stack
}

func ad_stack_show(_ st: UnsafeMutableRawPointer?, _ name: String?) {
    guard let stack = WinUIAdapterRegistry.shared.node(st) else { return }
    let key = name ?? ""
    stack.visibleStackName = key
    if key == "session" {
        ol_win_gui_set_mode(1, WinUIAdapterRegistry.shared.activeNative)
    } else if key == "connect" {
        ol_win_gui_set_mode(0, nil)
    }
}

func ad_overlay(_ child: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer! {
    let node = WinUIWidgetNode(kind: "overlay")
    if let c = WinUIAdapterRegistry.shared.node(child) { node.children.append(c) }
    return WinUIAdapterRegistry.shared.register(node)
}

func ad_overlay_add(_ o: UnsafeMutableRawPointer?, _ w: UnsafeMutableRawPointer?) {
    ol_append(o, w)
}

func ad_spinner() -> UnsafeMutableRawPointer! {
    WinUIAdapterRegistry.shared.register(WinUIWidgetNode(kind: "spinner"))
}

func ad_spin(_ s: UnsafeMutableRawPointer?, _ spinning: Int32) {
    guard let node = WinUIAdapterRegistry.shared.node(s) else { return }
    node.spinning = (spinning != 0)
}

// MARK: - Alerts, Dialogs, Preferences & About

func ad_alert(_ heading: String?, _ body: String?) -> UnsafeMutableRawPointer! {
    WinUIAdapterRegistry.shared.register(WinUIWidgetNode(kind: "alert", title: heading ?? "", subtitle: body ?? ""))
}

func ad_alert_response(_ d: UnsafeMutableRawPointer?, _ id: String?, _ label: String?, _ appearance: Int32) {
    guard let node = WinUIAdapterRegistry.shared.node(d) else { return }
    node.alertResponses.append((id: id ?? "", label: label ?? "", appearance: appearance))
}

func ad_alert_defaults(_ d: UnsafeMutableRawPointer?, _ defaultResponse: String?, _ closeResponse: String?) {
    guard let node = WinUIAdapterRegistry.shared.node(d) else { return }
    node.alertDefaultResponse = defaultResponse ?? ""
    node.alertCloseResponse = closeResponse ?? ""
}

func ad_alert_extra(_ d: UnsafeMutableRawPointer?, _ w: UnsafeMutableRawPointer?) {
    ol_append(d, w)
}

private func summarizeDialogTree(_ root: WinUIWidgetNode) -> String {
    var lines: [String] = []
    func walk(_ n: WinUIWidgetNode, indent: String = "") {
        switch n.kind {
        case "prefs_page":
            lines.append("\n=== \(n.title) ===")
        case "group":
            if !n.title.isEmpty { lines.append("\n[\(n.title)]") }
            if !n.subtitle.isEmpty { lines.append("  \(n.subtitle)") }
        case "action_row":
            lines.append("• \(n.title): \(n.subtitle)")
        case "switch_row":
            lines.append("• \(n.title): \(n.checked ? "On" : "Off")")
        case "spin_row":
            lines.append("• \(n.title): \(n.spinValue)")
        case "combo_row":
            let sel = (n.comboSelected >= 0 && Int(n.comboSelected) < n.comboItems.count) ? n.comboItems[Int(n.comboSelected)] : "—"
            lines.append("• \(n.title): \(sel)")
        case "entry_row", "password_row":
            if !n.textValue.isEmpty {
                lines.append("• \(n.title): \(n.textValue)")
            }
        case "text_view":
            if !n.textValue.isEmpty {
                lines.append(n.textValue)
            }
        default:
            break
        }
        for c in n.children {
            walk(c, indent: indent + "  ")
        }
    }
    walk(root)
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

func ad_present(_ d: UnsafeMutableRawPointer?, _ parent: UnsafeMutableRawPointer?) {
    _ = parent
    guard let node = WinUIAdapterRegistry.shared.node(d) else { return }
    if node.kind == "alert" {
        var fp = ""
        for c in node.children where c.kind == "fingerprint" {
            fp = c.title
        }
        let trusted = ol_win_gui_cert_prompt(node.title, node.subtitle, fp)
        let responseId = (trusted != 0) ? "trust" : (node.alertCloseResponse.isEmpty ? "cancel" : node.alertCloseResponse)
        node.emit1String("response", value: responseId)
    } else if node.kind == "dialog" || node.kind == "prefs_dialog" {
        let summary = summarizeDialogTree(node)
        ol_win_gui_show_dialog(node.title.isEmpty ? "Overlook" : node.title, summary.isEmpty ? node.subtitle : summary)
        node.emit0("closed")
    }
}

func ad_about(_ parent: UnsafeMutableRawPointer?, _ version: String?) {
    _ = parent
    let ver = version ?? "0.1.0"
    let text = "Overlook for Windows v\(ver)\n\nNative Windows 11 (WinUI 3 / Fluent DWM Mica) Remote Console for PiKVM, GL.iNet Comet / GLKVM, and NanoKVM Cube devices.\n\nAuthor: Ross Cawston / Overlook Contributors\nLicense: GPL-3.0"
    ol_win_gui_show_dialog("About Overlook", text)
}

func ad_certificate_sha256(_ certificate: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>! {
    guard let node = WinUIAdapterRegistry.shared.node(certificate), !node.certSha256.isEmpty else {
        return nil
    }
    return ol_native_strdup(node.certSha256)
}

func ad_style_color_scheme(_ scheme: Int32) {
    _ = scheme
}

func ad_prefs_dialog(_ title: String?, _ width: Int32, _ height: Int32) -> UnsafeMutableRawPointer! {
    let node = WinUIWidgetNode(kind: "prefs_dialog", title: title ?? "")
    node.width = width
    node.height = height
    return WinUIAdapterRegistry.shared.register(node)
}

func ad_prefs_dialog_add(_ d: UnsafeMutableRawPointer?, _ page: UnsafeMutableRawPointer?) {
    ol_append(d, page)
}

func ad_prefs_dialog_toast(_ d: UnsafeMutableRawPointer?, _ text: String?) {
    _ = d
    ol_win_gui_toast(text ?? "")
}

func ad_prefs_page(_ title: String?, _ icon: String?) -> UnsafeMutableRawPointer! {
    let node = WinUIWidgetNode(kind: "prefs_page", title: title ?? "")
    node.iconName = icon ?? ""
    return WinUIAdapterRegistry.shared.register(node)
}

func ad_prefs_page_add(_ page: UnsafeMutableRawPointer?, _ group: UnsafeMutableRawPointer?) {
    ol_append(page, group)
}

func ad_action_row(_ title: String?, _ subtitle: String?) -> UnsafeMutableRawPointer! {
    WinUIAdapterRegistry.shared.register(WinUIWidgetNode(kind: "action_row", title: title ?? "", subtitle: subtitle ?? ""))
}

func ad_action_row_subtitle(_ r: UnsafeMutableRawPointer?, _ subtitle: String?) {
    guard let node = WinUIAdapterRegistry.shared.node(r) else { return }
    node.subtitle = subtitle ?? ""
}

func ad_action_row_suffix(_ r: UnsafeMutableRawPointer?, _ w: UnsafeMutableRawPointer?) {
    ol_append(r, w)
}

func ad_action_row_prefix(_ r: UnsafeMutableRawPointer?, _ w: UnsafeMutableRawPointer?) {
    ol_append(r, w)
}

func ad_switch_row(_ title: String?, _ subtitle: String?, _ active: Int32) -> UnsafeMutableRawPointer! {
    let node = WinUIWidgetNode(kind: "switch_row", title: title ?? "", subtitle: subtitle ?? "")
    node.checked = (active != 0)
    return WinUIAdapterRegistry.shared.register(node)
}

func ad_switch_get(_ r: UnsafeMutableRawPointer?) -> Int32 {
    guard let node = WinUIAdapterRegistry.shared.node(r) else { return 0 }
    return node.checked ? 1 : 0
}

func ad_switch_set(_ r: UnsafeMutableRawPointer?, _ active: Int32) {
    guard let node = WinUIAdapterRegistry.shared.node(r) else { return }
    node.checked = (active != 0)
}

func ad_spin_row(_ title: String?, _ subtitle: String?, _ min: Double, _ max: Double, _ step: Double, _ digits: Int32, _ value: Double) -> UnsafeMutableRawPointer! {
    _ = digits
    let node = WinUIWidgetNode(kind: "spin_row", title: title ?? "", subtitle: subtitle ?? "")
    node.spinMin = min
    node.spinMax = max
    node.spinStep = step
    node.spinValue = value
    return WinUIAdapterRegistry.shared.register(node)
}

func ad_spin_get(_ r: UnsafeMutableRawPointer?) -> Double {
    guard let node = WinUIAdapterRegistry.shared.node(r) else { return 0 }
    return node.spinValue
}

func ad_spin_set(_ r: UnsafeMutableRawPointer?, _ value: Double) {
    guard let node = WinUIAdapterRegistry.shared.node(r) else { return }
    node.spinValue = value
}

func ad_spin_range(_ r: UnsafeMutableRawPointer?, _ min: Double, _ max: Double) {
    guard let node = WinUIAdapterRegistry.shared.node(r) else { return }
    node.spinMin = min
    node.spinMax = max
}

func ad_combo_row(_ title: String?, _ subtitle: String?) -> UnsafeMutableRawPointer! {
    WinUIAdapterRegistry.shared.register(WinUIWidgetNode(kind: "combo_row", title: title ?? "", subtitle: subtitle ?? ""))
}

func ad_combo_clear(_ r: UnsafeMutableRawPointer?) {
    guard let node = WinUIAdapterRegistry.shared.node(r) else { return }
    node.comboItems.removeAll()
    node.comboSelected = -1
}

func ad_combo_append(_ r: UnsafeMutableRawPointer?, _ item: String?) {
    guard let node = WinUIAdapterRegistry.shared.node(r) else { return }
    node.comboItems.append(item ?? "")
    if node.comboSelected < 0 { node.comboSelected = 0 }
}

func ad_combo_get(_ r: UnsafeMutableRawPointer?) -> Int32 {
    guard let node = WinUIAdapterRegistry.shared.node(r) else { return -1 }
    return node.comboSelected
}

func ad_combo_set(_ r: UnsafeMutableRawPointer?, _ index: Int32) {
    guard let node = WinUIAdapterRegistry.shared.node(r) else { return }
    node.comboSelected = index
}

func ad_dialog(_ title: String?, _ content: UnsafeMutableRawPointer?, _ width: Int32, _ height: Int32) -> UnsafeMutableRawPointer! {
    let node = WinUIWidgetNode(kind: "dialog", title: title ?? "")
    node.width = width
    node.height = height
    if let c = WinUIAdapterRegistry.shared.node(content) {
        node.children.append(c)
        c.parent = node
    }
    return WinUIAdapterRegistry.shared.register(node)
}

func ad_dialog_close(_ d: UnsafeMutableRawPointer?) {
    guard let node = WinUIAdapterRegistry.shared.node(d) else { return }
    node.emit0("closed")
}

// MARK: - Box, Entry, Scroll, Web & Text View Helpers (shim.h)

func ol_box(_ vertical: Int32, _ spacing: Int32) -> UnsafeMutableRawPointer! {
    _ = vertical; _ = spacing
    return WinUIAdapterRegistry.shared.register(WinUIWidgetNode(kind: "box"))
}

func ol_append(_ b: UnsafeMutableRawPointer?, _ w: UnsafeMutableRawPointer?) {
    guard let parent = WinUIAdapterRegistry.shared.node(b),
          let child = WinUIAdapterRegistry.shared.node(w) else { return }
    if !parent.children.contains(where: { $0 === child }) {
        parent.children.append(child)
        child.parent = parent
    }
}

func ol_remove(_ b: UnsafeMutableRawPointer?, _ w: UnsafeMutableRawPointer?) {
    guard let parent = WinUIAdapterRegistry.shared.node(b),
          let child = WinUIAdapterRegistry.shared.node(w) else { return }
    parent.children.removeAll { $0 === child }
    child.parent = nil
}

func ol_first(_ w: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer! {
    guard let node = WinUIAdapterRegistry.shared.node(w),
          let first = node.children.first else { return nil }
    return first.opaquePtr
}

func ol_next(_ w: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer! {
    guard let node = WinUIAdapterRegistry.shared.node(w),
          let parent = node.parent,
          let idx = parent.children.firstIndex(where: { $0 === node }),
          idx + 1 < parent.children.count else { return nil }
    return parent.children[idx + 1].opaquePtr
}

func ol_expand(_ w: UnsafeMutableRawPointer?, _ horizontal: Int32, _ vertical: Int32) {
    _ = w; _ = horizontal; _ = vertical
}

func ol_visible(_ w: UnsafeMutableRawPointer?, _ show: Int32) {
    guard let node = WinUIAdapterRegistry.shared.node(w) else { return }
    node.visible = (show != 0)
}

func ol_margin(_ w: UnsafeMutableRawPointer?, _ n: Int32) {
    _ = w; _ = n
}

func ol_label(_ text: String?) -> UnsafeMutableRawPointer! {
    WinUIAdapterRegistry.shared.register(WinUIWidgetNode(kind: "label", title: text ?? ""))
}

func ol_text(_ w: UnsafeMutableRawPointer?, _ text: String?) {
    guard let node = WinUIAdapterRegistry.shared.node(w) else { return }
    node.title = text ?? ""
}

func ol_button(_ label: String?) -> UnsafeMutableRawPointer! {
    WinUIAdapterRegistry.shared.register(WinUIWidgetNode(kind: "button", title: label ?? ""))
}

func ol_entry(_ placeholder: String?) -> UnsafeMutableRawPointer! {
    WinUIAdapterRegistry.shared.register(WinUIWidgetNode(kind: "entry", subtitle: placeholder ?? ""))
}

func ol_password(_ placeholder: String?) -> UnsafeMutableRawPointer! {
    WinUIAdapterRegistry.shared.register(WinUIWidgetNode(kind: "password", subtitle: placeholder ?? ""))
}

func ol_value(_ e: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>! {
    WinUIAdapterRegistry.shared.syncFormFromNativeGUI()
    guard let node = WinUIAdapterRegistry.shared.node(e) else {
        return nil
    }
    return node.cachedCString(node.textValue)
}

func ol_set_value(_ e: UnsafeMutableRawPointer?, _ val: String?) {
    guard let node = WinUIAdapterRegistry.shared.node(e) else { return }
    node.textValue = val ?? ""
    WinUIAdapterRegistry.shared.pushFormToNativeGUI()
}

func ol_scroll(_ child: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer! {
    let node = WinUIWidgetNode(kind: "scroll")
    if let c = WinUIAdapterRegistry.shared.node(child) {
        node.children.append(c)
        c.parent = node
    }
    return WinUIAdapterRegistry.shared.register(node)
}

func ol_web() -> UnsafeMutableRawPointer! {
    WinUIAdapterRegistry.shared.register(WinUIWidgetNode(kind: "web"))
}

func ol_load(_ w: UnsafeMutableRawPointer?, _ uri: String?) {
    guard let node = WinUIAdapterRegistry.shared.node(w) else { return }
    let target = uri ?? ""
    node.uri = target
    if let (cb, ctx) = node.loadCallback {
        cb(w, 0, ctx)
        if !target.isEmpty && target != "about:blank" {
            ol_win_gui_open_web(target)
        }
        cb(w, 3, ctx)
    }
}

func ol_html(_ w: UnsafeMutableRawPointer?, _ html: String?) {
    _ = html
    guard let node = WinUIAdapterRegistry.shared.node(w) else { return }
    node.uri = "about:blank"
    if let (cb, ctx) = node.loadCallback {
        cb(w, 0, ctx)
        cb(w, 3, ctx)
    }
}

func ol_reload(_ w: UnsafeMutableRawPointer?) {
    guard let node = WinUIAdapterRegistry.shared.node(w) else { return }
    if !node.uri.isEmpty {
        ol_load(w, node.uri)
    }
}

func ol_uri(_ w: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>! {
    guard let node = WinUIAdapterRegistry.shared.node(w) else { return nil }
    return node.cachedCString(node.uri)
}

func ol_on_load(_ w: UnsafeMutableRawPointer?, _ cb: OLLoad?, _ c: UnsafeMutableRawPointer?) {
    guard let node = WinUIAdapterRegistry.shared.node(w), let cb else { return }
    node.loadCallback = (cb, c)
}

func ol_on_failure(_ w: UnsafeMutableRawPointer?, _ cb: OLFailure?, _ c: UnsafeMutableRawPointer?) {
    guard let node = WinUIAdapterRegistry.shared.node(w), let cb else { return }
    node.failureCallback = (cb, c)
}

func ol_on_tls(_ w: UnsafeMutableRawPointer?, _ cb: OLTLS?, _ c: UnsafeMutableRawPointer?) {
    guard let node = WinUIAdapterRegistry.shared.node(w), let cb else { return }
    node.tlsCallback = (cb, c)
}

func ol_on_policy(_ w: UnsafeMutableRawPointer?, _ cb: OLPolicy?, _ c: UnsafeMutableRawPointer?) {
    guard let node = WinUIAdapterRegistry.shared.node(w), let cb else { return }
    node.policyCallback = (cb, c)
}

func ol_policy_uri(_ decision: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>! {
    guard let node = WinUIAdapterRegistry.shared.node(decision) else { return nil }
    return node.cachedCString(node.uri)
}

func ol_ignore(_ decision: UnsafeMutableRawPointer?) {
    _ = decision
}

func ol_trust(_ w: UnsafeMutableRawPointer?, _ cert: UnsafeMutableRawPointer?, _ host: String?) {
    _ = w; _ = cert; _ = host
}

func ol_error_is_cancelled(_ error: UnsafeMutableRawPointer?) -> Int32 {
    _ = error
    return 0
}

func ol_error_message(_ error: UnsafeMutableRawPointer?) -> String {
    guard let error else { return "Unknown network error" }
    return String(cString: error.assumingMemoryBound(to: CChar.self))
}

func ol_native_picture_widget(_ native: OpaquePointer?) -> UnsafeMutableRawPointer {
    WinUIAdapterRegistry.shared.activeNative = native
    if let rawPic = ol_native_picture(native) {
        if let existing = WinUIAdapterRegistry.shared.nodes[rawPic] {
            existing.nativePtr = native
            return rawPic
        }
    }
    let node = WinUIWidgetNode(kind: "native_picture")
    node.nativePtr = native
    return WinUIAdapterRegistry.shared.register(node)
}

// MARK: - Clipboard, TextView & Timers

func ol_clipboard_get(_ widget: UnsafeMutableRawPointer?, _ cb: OLClipboardText?, _ ctx: UnsafeMutableRawPointer?) {
    _ = widget
    let raw = ol_win_clipboard_get()
    if let raw {
        cb?(raw, ctx)
        ol_native_free_string(raw)
    } else {
        "".withCString { empty in
            cb?(empty, ctx)
        }
    }
}

func ol_clipboard_set(_ widget: UnsafeMutableRawPointer?, _ text: String?) {
    _ = widget
    ol_win_clipboard_set(text ?? "")
}

func ol_text_view(_ text: String?, _ editable: Int32, _ monospace: Int32) -> UnsafeMutableRawPointer! {
    _ = editable; _ = monospace
    let node = WinUIWidgetNode(kind: "text_view")
    node.textValue = text ?? ""
    return WinUIAdapterRegistry.shared.register(node)
}

func ol_text_view_set(_ tv: UnsafeMutableRawPointer?, _ text: String?) {
    guard let node = WinUIAdapterRegistry.shared.node(tv) else { return }
    node.textValue = text ?? ""
}

func ol_text_view_get(_ tv: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>! {
    guard let node = WinUIAdapterRegistry.shared.node(tv) else { return ol_native_strdup("") }
    return ol_native_strdup(node.textValue)
}

func g_free(_ ptr: UnsafeMutableRawPointer?) {
    guard let ptr else { return }
    ol_native_free_string(ptr.assumingMemoryBound(to: CChar.self))
}

func g_timeout_add(_ intervalMs: UInt32, _ function: @escaping GSourceFunc, _ data: UnsafeMutableRawPointer?) -> UInt32 {
    return ol_win_timer_add(intervalMs, function, data)
}

func g_timeout_add_seconds(_ intervalSec: UInt32, _ function: @escaping GSourceFunc, _ data: UnsafeMutableRawPointer?) -> UInt32 {
    return ol_win_timer_add(intervalSec * 1000, function, data)
}

func g_source_remove(_ tag: UInt32) {
    ol_win_timer_remove(tag)
}
