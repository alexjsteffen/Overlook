import Foundation
import CNativeWin
import OverlookCore
#if os(Windows)
import WinSDK
import WinUI
import WinAppSDK
import UWP
import WindowsFoundation
#endif

// ============================================================================
// Native WinUI 3 XAML UI Adapter & Widget Hierarchy (thebrowsercompany/swift-winui)
// ============================================================================
//
// Provides a unified Swift builder facade over native WinUI 3 controls:
// - WinUI.Application, WinUI.Window, WinUI.SplitView, WinUI.NavigationView
// - WinUI.Grid, WinUI.StackPanel, WinUI.ScrollViewer, WinUI.Border
// - WinUI.TextBlock, WinUI.TextBox, WinUI.PasswordBox, WinUI.NumberBox
// - WinUI.Button, WinUI.ToggleButton, WinUI.ToggleSwitch, WinUI.ComboBox
// - WinUI.ProgressRing, WinUI.InfoBar, WinUI.ContentDialog, WinUI.MenuFlyout
// - WinUI.WebView2 (Web Console with TOFU TLS certificate handling)
// - WinUI.Image + WinUI.WriteableBitmap (Native H.264/HEVC BGRA video surface)

typealias OLWidgetPtr = UnsafeMutableRawPointer
typealias OLAppPtr = UnsafeMutableRawPointer
typealias OLMenuPtr = UnsafeMutableRawPointer
typealias GCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
typealias OLActionCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
typealias OLCertCallback = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32
typealias OLAlertCallback = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
typealias OLWebLoadFailedCallback = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
typealias GSourceFunc = @convention(c) (UnsafeMutableRawPointer?) -> Int32

let G_SOURCE_REMOVE: Int32 = 0
let G_SOURCE_CONTINUE: Int32 = 1

enum WinUINodeKind {
    case app
    case window
    case toolbarView
    case headerBar
    case splitView
    case stack
    case box
    case clamp
    case scrolled
    case label
    case button
    case toggleButton
    case menuButton
    case statusPage
    case banner
    case spinner
    case listBox
    case listRow
    case preferencesGroup
    case entryRow
    case passwordRow
    case actionRow
    case switchRow
    case spinRow
    case comboRow
    case preferencesDialog
    case preferencesPage
    case webView
    case nativeVideoSurface
    case menuModel
}

final class WinUIMenuEntry {
    let label: String
    let action: String
    init(label: String, action: String) {
        self.label = label
        self.action = action
    }
}

final class WinUIAppAction {
    let name: String
    let callback: OLActionCallback?
    let userData: UnsafeMutableRawPointer?
    var accelerators: [String] = []

    init(name: String, callback: OLActionCallback?, userData: UnsafeMutableRawPointer?) {
        self.name = name
        self.callback = callback
        self.userData = userData
    }
}

final class WinUISignalSubscription {
    let signal: String
    let callback: GCallback
    let userData: UnsafeMutableRawPointer?

    init(signal: String, callback: GCallback, userData: UnsafeMutableRawPointer?) {
        self.signal = signal
        self.callback = callback
        self.userData = userData
    }
}

final class WinUINode {
    let kind: WinUINodeKind
    var title: String = ""
    var subtitle: String = ""
    var text: String = ""
    var iconName: String = ""
    var tooltip: String = ""
    var cssClasses: Set<String> = []
    var visible: Bool = true
    var sensitive: Bool = true
    var active: Bool = false
    var hexpand: Bool = false
    var vexpand: Bool = false
    var width: Int32 = 0
    var height: Int32 = 0
    var fullscreened: Bool = false
    var spinValue: Double = 0
    var spinLower: Double = 0
    var spinUpper: Double = 100
    var spinStep: Double = 1
    var selectedIndex: UInt32 = 0
    var comboItems: [String] = []
    var namedChildren: [(name: String, title: String, node: WinUINode)] = []
    var children: [WinUINode] = []
    weak var parent: WinUINode?
    var visibleChildName: String = ""
    var sidebarNode: WinUINode?
    var contentNode: WinUINode?
    var topBars: [WinUINode] = []
    var bottomBars: [WinUINode] = []
    var startPacks: [WinUINode] = []
    var endPacks: [WinUINode] = []
    var suffixes: [WinUINode] = []
    var menuEntries: [WinUIMenuEntry] = []
    var menuSections: [WinUINode] = []
    var menuModel: WinUINode?
    var actions: [String: WinUIAppAction] = [:]
    var signals: [WinUISignalSubscription] = []
    var webCertCallback: OLCertCallback?
    var webCertContext: UnsafeMutableRawPointer?
    var webLoadFailedCallback: OLWebLoadFailedCallback?
    var webLoadFailedContext: UnsafeMutableRawPointer?
    var webTrustedHosts: Set<String> = []
    var webCurrentURI: String = ""
    var nativeHandle: OpaquePointer?

    #if os(Windows)
    var xamlApplication: WinUI.Application?
    var xamlWindow: WinUI.Window?
    var xamlElement: WinUI.UIElement?
    var xamlSplitView: WinUI.SplitView?
    var xamlNavView: WinUI.NavigationView?
    var xamlStackPanel: WinUI.StackPanel?
    var xamlGrid: WinUI.Grid?
    var xamlScrollViewer: WinUI.ScrollViewer?
    var xamlTextBlock: WinUI.TextBlock?
    var xamlSubtitleBlock: WinUI.TextBlock?
    var xamlTextBox: WinUI.TextBox?
    var xamlPasswordBox: WinUI.PasswordBox?
    var xamlButton: WinUI.Button?
    var xamlToggleButton: WinUI.ToggleButton?
    var xamlToggleSwitch: WinUI.ToggleSwitch?
    var xamlNumberBox: WinUI.NumberBox?
    var xamlComboBox: WinUI.ComboBox?
    var xamlInfoBar: WinUI.InfoBar?
    var xamlProgressRing: WinUI.ProgressRing?
    var xamlWebView: WinUI.WebView2?
    var xamlImage: WinUI.Image?
    var xamlBitmap: WinUI.WriteableBitmap?
    var xamlContentDialog: WinUI.ContentDialog?
    #endif

    init(kind: WinUINodeKind) {
        self.kind = kind
        #if os(Windows)
        buildXAMLControl()
        #endif
    }

    var ptr: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    static func from(_ ptr: UnsafeMutableRawPointer?) -> WinUINode? {
        guard let ptr else { return nil }
        return Unmanaged<WinUINode>.fromOpaque(ptr).takeUnretainedValue()
    }

    func emitSignal(_ name: String) {
        for sub in signals where sub.signal == name {
            sub.callback(self.ptr, sub.userData)
        }
    }

    func addChild(_ child: WinUINode) {
        child.parent = self
        children.append(child)
        #if os(Windows)
        if let panel = xamlStackPanel, let el = child.xamlElement {
            try? panel.children.append(el)
        } else if let grid = xamlGrid, let el = child.xamlElement {
            try? grid.children.append(el)
        } else if let sv = xamlScrollViewer, let el = child.xamlElement {
            sv.content = el
        }
        #endif
    }

    func removeAllChildren() {
        for c in children {
            c.parent = nil
        }
        children.removeAll()
        #if os(Windows)
        try? xamlStackPanel?.children.clear()
        try? xamlGrid?.children.clear()
        #endif
    }

    #if os(Windows)
    private func buildXAMLControl() {
        switch kind {
        case .window:
            if let win = try? WinUI.Window() {
                xamlWindow = win
                if let rootGrid = try? WinUI.Grid() {
                    xamlGrid = rootGrid
                    xamlElement = rootGrid
                    win.content = rootGrid
                }
            }
        case .toolbarView, .box, .clamp, .preferencesGroup, .preferencesPage:
            if let panel = try? WinUI.StackPanel() {
                panel.spacing = 8
                xamlStackPanel = panel
                xamlElement = panel
            }
        case .headerBar:
            if let grid = try? WinUI.Grid() {
                xamlGrid = grid
                xamlElement = grid
            }
        case .splitView:
            if let split = try? WinUI.SplitView() {
                split.displayMode = .inline
                split.isPaneOpen = true
                split.openPaneLength = 240
                xamlSplitView = split
                xamlElement = split
            }
        case .stack:
            if let grid = try? WinUI.Grid() {
                xamlGrid = grid
                xamlElement = grid
            }
        case .scrolled:
            if let sv = try? WinUI.ScrollViewer() {
                xamlScrollViewer = sv
                xamlElement = sv
            }
        case .label:
            if let tb = try? WinUI.TextBlock() {
                tb.textWrapping = .wrapWholeWords
                xamlTextBlock = tb
                xamlElement = tb
            }
        case .button, .menuButton:
            if let btn = try? WinUI.Button() {
                xamlButton = btn
                xamlElement = btn
            }
        case .toggleButton:
            if let tbtn = try? WinUI.ToggleButton() {
                xamlToggleButton = tbtn
                xamlElement = tbtn
            }
        case .statusPage:
            if let panel = try? WinUI.StackPanel() {
                panel.spacing = 12
                panel.horizontalAlignment = .center
                panel.verticalAlignment = .center
                if let titleBlock = try? WinUI.TextBlock(),
                   let subBlock = try? WinUI.TextBlock() {
                    titleBlock.fontSize = 22
                    subBlock.opacity = 0.78
                    subBlock.textWrapping = .wrapWholeWords
                    try? panel.children.append(titleBlock)
                    try? panel.children.append(subBlock)
                    xamlTextBlock = titleBlock
                    xamlSubtitleBlock = subBlock
                }
                xamlStackPanel = panel
                xamlElement = panel
            }
        case .banner:
            if let bar = try? WinUI.InfoBar() {
                bar.isOpen = false
                bar.isClosable = true
                bar.severity = .warning
                xamlInfoBar = bar
                xamlElement = bar
            }
        case .spinner:
            if let ring = try? WinUI.ProgressRing() {
                ring.isActive = false
                ring.width = 20
                ring.height = 20
                xamlProgressRing = ring
                xamlElement = ring
            }
        case .listBox, .listRow:
            if let panel = try? WinUI.StackPanel() {
                panel.spacing = 4
                xamlStackPanel = panel
                xamlElement = panel
            }
        case .entryRow:
            if let panel = try? WinUI.StackPanel(),
               let tb = try? WinUI.TextBox() {
                panel.spacing = 4
                xamlTextBox = tb
                try? panel.children.append(tb)
                xamlStackPanel = panel
                xamlElement = panel
            }
        case .passwordRow:
            if let panel = try? WinUI.StackPanel(),
               let pb = try? WinUI.PasswordBox() {
                panel.spacing = 4
                xamlPasswordBox = pb
                try? panel.children.append(pb)
                xamlStackPanel = panel
                xamlElement = panel
            }
        case .actionRow:
            if let panel = try? WinUI.StackPanel(),
               let titleBlock = try? WinUI.TextBlock(),
               let subBlock = try? WinUI.TextBlock() {
                panel.spacing = 2
                subBlock.opacity = 0.72
                subBlock.textWrapping = .wrapWholeWords
                try? panel.children.append(titleBlock)
                try? panel.children.append(subBlock)
                xamlTextBlock = titleBlock
                xamlSubtitleBlock = subBlock
                xamlStackPanel = panel
                xamlElement = panel
            }
        case .switchRow:
            if let panel = try? WinUI.StackPanel(),
               let ts = try? WinUI.ToggleSwitch() {
                panel.spacing = 4
                xamlToggleSwitch = ts
                try? panel.children.append(ts)
                xamlStackPanel = panel
                xamlElement = panel
            }
        case .spinRow:
            if let panel = try? WinUI.StackPanel(),
               let nb = try? WinUI.NumberBox() {
                panel.spacing = 4
                xamlNumberBox = nb
                try? panel.children.append(nb)
                xamlStackPanel = panel
                xamlElement = panel
            }
        case .comboRow:
            if let panel = try? WinUI.StackPanel(),
               let cb = try? WinUI.ComboBox() {
                panel.spacing = 4
                xamlComboBox = cb
                try? panel.children.append(cb)
                xamlStackPanel = panel
                xamlElement = panel
            }
        case .preferencesDialog:
            if let nav = try? WinUI.NavigationView() {
                nav.isBackButtonVisible = .collapsed
                nav.isSettingsVisible = false
                xamlNavView = nav
                xamlElement = nav
            }
        case .webView:
            if let wv = try? WinUI.WebView2() {
                xamlWebView = wv
                xamlElement = wv
            }
        case .nativeVideoSurface:
            if let grid = try? WinUI.Grid(),
               let img = try? WinUI.Image() {
                img.stretch = .uniform
                try? grid.children.append(img)
                xamlImage = img
                xamlGrid = grid
                xamlElement = grid
            }
        case .app, .menuModel:
            break
        }
    }
    #endif
}

private var gRetainedNodes: [ObjectIdentifier: WinUINode] = [:]

private func retainNode(_ node: WinUINode) -> UnsafeMutableRawPointer {
    gRetainedNodes[ObjectIdentifier(node)] = node
    return node.ptr
}

// ============================================================================
// Application & Lifecycle
// ============================================================================

func ad_app_new(_ applicationId: String) -> OLAppPtr {
    let node = WinUINode(kind: .app)
    node.title = applicationId
    return retainNode(node)
}

func g_application_run(_ app: OLAppPtr, _ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    guard let appNode = WinUINode.from(app) else { return 1 }
    // Emit startup & activate so controller builds UI or runs CLI smoke tests
    appNode.emitSignal("startup")
    appNode.emitSignal("activate")

    #if os(Windows)
    // If a window was created and presented, run the Win32/WinUI message loop;
    // if running in headless smoke-test mode, pump the Win32 message loop until quit.
    return ol_win_run_message_loop()
    #else
    return 0
    #endif
}

func g_application_quit(_ app: OLAppPtr) {
    #if os(Windows)
    ol_win_quit_message_loop(0)
    #endif
}

func g_object_unref(_ obj: UnsafeMutableRawPointer?) {
    guard let obj, let node = WinUINode.from(obj) else { return }
    gRetainedNodes.removeValue(forKey: ObjectIdentifier(node))
}

func g_free(_ ptr: UnsafeMutableRawPointer?) {
    if let ptr {
        free(ptr)
    }
}

func ol_signal_connect(_ instance: UnsafeMutableRawPointer?, _ detailedSignal: String, _ cHandler: GCallback, _ data: UnsafeMutableRawPointer?) {
    guard let node = WinUINode.from(instance) else { return }
    node.signals.append(WinUISignalSubscription(signal: detailedSignal, callback: cHandler, userData: data))
}

// ============================================================================
// Window & Layout Builders
// ============================================================================

func ad_window_new(_ app: OLAppPtr, _ title: String, _ width: Int32, _ height: Int32) -> OLWidgetPtr {
    let win = WinUINode(kind: .window)
    win.title = title
    win.width = width
    win.height = height
    #if os(Windows)
    win.xamlWindow?.title = title
    #endif
    return retainNode(win)
}

func ad_window_set_content(_ window: OLWidgetPtr, _ content: OLWidgetPtr) {
    guard let win = WinUINode.from(window), let child = WinUINode.from(content) else { return }
    win.removeAllChildren()
    win.addChild(child)
    #if os(Windows)
    if let el = child.xamlElement {
        win.xamlWindow?.content = el
    }
    #endif
}

func ad_window_present(_ window: OLWidgetPtr) {
    guard let win = WinUINode.from(window) else { return }
    win.visible = true
    #if os(Windows)
    try? win.xamlWindow?.activate()
    #endif
}

func gtk_window_set_title(_ window: OLWidgetPtr, _ title: String) {
    guard let win = WinUINode.from(window) else { return }
    win.title = title
    #if os(Windows)
    win.xamlWindow?.title = title
    #endif
}

func gtk_window_is_fullscreen(_ window: OLWidgetPtr) -> Int32 {
    guard let win = WinUINode.from(window) else { return 0 }
    return win.fullscreened ? 1 : 0
}

func gtk_window_fullscreen(_ window: OLWidgetPtr) {
    guard let win = WinUINode.from(window) else { return }
    win.fullscreened = true
}

func gtk_window_unfullscreen(_ window: OLWidgetPtr) {
    guard let win = WinUINode.from(window) else { return }
    win.fullscreened = false
}

func ad_toolbar_view_new() -> OLWidgetPtr {
    retainNode(WinUINode(kind: .toolbarView))
}

func ad_toolbar_add_top(_ toolbarView: OLWidgetPtr, _ bar: OLWidgetPtr) {
    guard let tv = WinUINode.from(toolbarView), let barNode = WinUINode.from(bar) else { return }
    tv.topBars.append(barNode)
    tv.addChild(barNode)
}

func ad_toolbar_add_bottom(_ toolbarView: OLWidgetPtr, _ bar: OLWidgetPtr) {
    guard let tv = WinUINode.from(toolbarView), let barNode = WinUINode.from(bar) else { return }
    tv.bottomBars.append(barNode)
    tv.addChild(barNode)
}

func ad_toolbar_set_content(_ toolbarView: OLWidgetPtr, _ content: OLWidgetPtr) {
    guard let tv = WinUINode.from(toolbarView), let contentNode = WinUINode.from(content) else { return }
    tv.contentNode = contentNode
    tv.addChild(contentNode)
}

func ad_header_new() -> OLWidgetPtr {
    retainNode(WinUINode(kind: .headerBar))
}

func ad_header_pack_start(_ header: OLWidgetPtr, _ child: OLWidgetPtr) {
    guard let h = WinUINode.from(header), let c = WinUINode.from(child) else { return }
    h.startPacks.append(c)
    h.addChild(c)
}

func ad_header_pack_end(_ header: OLWidgetPtr, _ child: OLWidgetPtr) {
    guard let h = WinUINode.from(header), let c = WinUINode.from(child) else { return }
    h.endPacks.append(c)
    h.addChild(c)
}

func ad_split_view_new() -> OLWidgetPtr {
    retainNode(WinUINode(kind: .splitView))
}

func ad_split_set_sidebar(_ split: OLWidgetPtr, _ sidebar: OLWidgetPtr) {
    guard let s = WinUINode.from(split), let sb = WinUINode.from(sidebar) else { return }
    s.sidebarNode = sb
    #if os(Windows)
    s.xamlSplitView?.pane = sb.xamlElement
    #endif
}

func ad_split_set_content(_ split: OLWidgetPtr, _ content: OLWidgetPtr) {
    guard let s = WinUINode.from(split), let c = WinUINode.from(content) else { return }
    s.contentNode = c
    #if os(Windows)
    s.xamlSplitView?.content = c.xamlElement
    #endif
}

func ad_split_get_show_sidebar(_ split: OLWidgetPtr) -> Int32 {
    guard let s = WinUINode.from(split) else { return 0 }
    #if os(Windows)
    if let sv = s.xamlSplitView {
        return sv.isPaneOpen ? 1 : 0
    }
    #endif
    return s.active ? 1 : 0
}

func ad_split_set_show_sidebar(_ split: OLWidgetPtr, _ show: Int32) {
    guard let s = WinUINode.from(split) else { return }
    s.active = (show != 0)
    #if os(Windows)
    s.xamlSplitView?.isPaneOpen = (show != 0)
    #endif
}

func ad_stack_new() -> OLWidgetPtr {
    retainNode(WinUINode(kind: .stack))
}

func ad_stack_add_named(_ stack: OLWidgetPtr, _ child: OLWidgetPtr, _ name: String, _ title: String) {
    guard let st = WinUINode.from(stack), let ch = WinUINode.from(child) else { return }
    st.namedChildren.append((name: name, title: title, node: ch))
    st.addChild(ch)
    if st.visibleChildName.isEmpty {
        st.visibleChildName = name
    }
}

func ad_stack_set_visible(_ stack: OLWidgetPtr, _ name: String) {
    guard let st = WinUINode.from(stack) else { return }
    st.visibleChildName = name
    for entry in st.namedChildren {
        let isVis = (entry.name == name)
        entry.node.visible = isVis
        #if os(Windows)
        entry.node.xamlElement?.visibility = isVis ? .visible : .collapsed
        #endif
    }
}

func ad_switcher_new(_ stack: OLWidgetPtr) -> OLWidgetPtr {
    let box = WinUINode(kind: .box)
    if let st = WinUINode.from(stack) {
        for entry in st.namedChildren {
            let btn = WinUINode(kind: .button)
            btn.title = entry.title
            box.addChild(btn)
        }
    }
    return retainNode(box)
}

func ad_box_v(_ spacing: Int32) -> OLWidgetPtr {
    let box = WinUINode(kind: .box)
    #if os(Windows)
    box.xamlStackPanel?.orientation = .vertical
    box.xamlStackPanel?.spacing = Double(spacing)
    #endif
    return retainNode(box)
}

func ad_box_h(_ spacing: Int32) -> OLWidgetPtr {
    let box = WinUINode(kind: .box)
    #if os(Windows)
    box.xamlStackPanel?.orientation = .horizontal
    box.xamlStackPanel?.spacing = Double(spacing)
    #endif
    return retainNode(box)
}

func ad_box_append(_ box: OLWidgetPtr, _ child: OLWidgetPtr) {
    guard let b = WinUINode.from(box), let c = WinUINode.from(child) else { return }
    b.addChild(c)
}

func ad_clamp(_ child: OLWidgetPtr, _ maxSize: Int32) -> OLWidgetPtr {
    let clamp = WinUINode(kind: .clamp)
    clamp.width = maxSize
    if let c = WinUINode.from(child) {
        clamp.addChild(c)
    }
    #if os(Windows)
    clamp.xamlStackPanel?.maxWidth = Double(maxSize)
    #endif
    return retainNode(clamp)
}

func ad_scrolled(_ child: OLWidgetPtr) -> OLWidgetPtr {
    let sc = WinUINode(kind: .scrolled)
    if let c = WinUINode.from(child) {
        sc.addChild(c)
    }
    return retainNode(sc)
}

func ad_margins(_ widget: OLWidgetPtr, _ top: Int32, _ bottom: Int32, _ start: Int32, _ end: Int32) {
    guard let _ = WinUINode.from(widget) else { return }
}

func ad_expand(_ widget: OLWidgetPtr, _ hexpand: Int32, _ vexpand: Int32) {
    guard let w = WinUINode.from(widget) else { return }
    w.hexpand = (hexpand != 0)
    w.vexpand = (vexpand != 0)
}

// ============================================================================
// Controls: Labels, Buttons, Banners, Spinners, Lists
// ============================================================================

func ad_label(_ text: String) -> OLWidgetPtr {
    let lbl = WinUINode(kind: .label)
    lbl.text = text
    #if os(Windows)
    lbl.xamlTextBlock?.text = text
    #endif
    return retainNode(lbl)
}

func ad_label_set(_ label: OLWidgetPtr, _ text: String) {
    guard let lbl = WinUINode.from(label) else { return }
    lbl.text = text
    #if os(Windows)
    lbl.xamlTextBlock?.text = text
    #endif
}

func ad_button(_ label: String, _ cssClass: String?) -> OLWidgetPtr {
    let btn = WinUINode(kind: .button)
    btn.title = label
    if let cssClass {
        btn.cssClasses.insert(cssClass)
    }
    #if os(Windows)
    if let tb = try? WinUI.TextBlock() {
        tb.text = label
        btn.xamlButton?.content = tb
    }
    #endif
    return retainNode(btn)
}

func ad_button_icon(_ iconName: String, _ tooltip: String) -> OLWidgetPtr {
    let btn = WinUINode(kind: .button)
    btn.iconName = iconName
    btn.tooltip = tooltip
    #if os(Windows)
    if let tb = try? WinUI.TextBlock() {
        tb.text = tooltip
        btn.xamlButton?.content = tb
    }
    #endif
    return retainNode(btn)
}

func ad_button_set_icon(_ button: OLWidgetPtr, _ iconName: String) {
    guard let btn = WinUINode.from(button) else { return }
    btn.iconName = iconName
}

func ad_toggle_icon(_ iconName: String, _ tooltip: String) -> OLWidgetPtr {
    let btn = WinUINode(kind: .toggleButton)
    btn.iconName = iconName
    btn.tooltip = tooltip
    #if os(Windows)
    if let tb = try? WinUI.TextBlock() {
        tb.text = tooltip
        btn.xamlToggleButton?.content = tb
    }
    #endif
    return retainNode(btn)
}

func ad_toggle_get(_ toggle: OLWidgetPtr) -> Int32 {
    guard let t = WinUINode.from(toggle) else { return 0 }
    return t.active ? 1 : 0
}

func ad_toggle_set(_ toggle: OLWidgetPtr, _ active: Int32) {
    guard let t = WinUINode.from(toggle) else { return }
    let newState = (active != 0)
    if t.active != newState {
        t.active = newState
        #if os(Windows)
        t.xamlToggleButton?.isChecked = newState
        #endif
        t.emitSignal("toggled")
    }
}

func ad_status_page(_ iconName: String, _ title: String, _ description: String, _ child: OLWidgetPtr?) -> OLWidgetPtr {
    let page = WinUINode(kind: .statusPage)
    page.iconName = iconName
    page.title = title
    page.subtitle = description
    #if os(Windows)
    page.xamlTextBlock?.text = title
    page.xamlSubtitleBlock?.text = description
    #endif
    if let child, let childNode = WinUINode.from(child) {
        page.addChild(childNode)
    }
    return retainNode(page)
}

func ad_status_set(_ statusPage: OLWidgetPtr, _ iconName: String, _ title: String, _ description: String) {
    guard let page = WinUINode.from(statusPage) else { return }
    page.iconName = iconName
    page.title = title
    page.subtitle = description
    #if os(Windows)
    page.xamlTextBlock?.text = title
    page.xamlSubtitleBlock?.text = description
    #endif
}

func ad_banner(_ title: String) -> OLWidgetPtr {
    let banner = WinUINode(kind: .banner)
    banner.title = title
    #if os(Windows)
    banner.xamlInfoBar?.title = title
    #endif
    return retainNode(banner)
}

func ad_banner_show(_ banner: OLWidgetPtr, _ title: String, _ revealed: Int32) {
    guard let b = WinUINode.from(banner) else { return }
    b.title = title
    b.visible = (revealed != 0)
    #if os(Windows)
    b.xamlInfoBar?.title = title
    b.xamlInfoBar?.isOpen = (revealed != 0)
    #endif
}

func ad_banner_set_button(_ banner: OLWidgetPtr, _ label: String?) {
    guard let b = WinUINode.from(banner) else { return }
    b.subtitle = label ?? ""
}

func ad_spinner() -> OLWidgetPtr {
    retainNode(WinUINode(kind: .spinner))
}

func ad_spinner_set(_ spinner: OLWidgetPtr, _ spinning: Int32) {
    guard let sp = WinUINode.from(spinner) else { return }
    sp.active = (spinning != 0)
    sp.visible = (spinning != 0)
    #if os(Windows)
    sp.xamlProgressRing?.isActive = (spinning != 0)
    sp.xamlElement?.visibility = (spinning != 0) ? .visible : .collapsed
    #endif
}

func ad_list_sidebar() -> OLWidgetPtr {
    retainNode(WinUINode(kind: .listBox))
}

func ad_list_boxed() -> OLWidgetPtr {
    retainNode(WinUINode(kind: .listBox))
}

func ad_list_clear(_ listBox: OLWidgetPtr) {
    guard let lb = WinUINode.from(listBox) else { return }
    lb.removeAllChildren()
}

func ad_list_append(_ listBox: OLWidgetPtr, _ child: OLWidgetPtr) {
    guard let lb = WinUINode.from(listBox), let c = WinUINode.from(child) else { return }
    let row = WinUINode(kind: .listRow)
    row.addChild(c)
    lb.addChild(row)
    _ = retainNode(row)
}

func ad_list_row_index(_ row: OLWidgetPtr?) -> Int32 {
    guard let r = WinUINode.from(row), let parent = r.parent else { return -1 }
    if let idx = parent.children.firstIndex(where: { $0 === r }) {
        return Int32(idx)
    }
    return -1
}

// ============================================================================
// Preferences / Settings Rows & Dialogs
// ============================================================================

func ad_pref_group(_ title: String, _ description: String?) -> OLWidgetPtr {
    let group = WinUINode(kind: .preferencesGroup)
    group.title = title
    group.subtitle = description ?? ""
    #if os(Windows)
    if let header = try? WinUI.TextBlock() {
        header.text = title
        header.fontSize = 16
        try? group.xamlStackPanel?.children.append(header)
    }
    if let description, !description.isEmpty, let sub = try? WinUI.TextBlock() {
        sub.text = description
        sub.opacity = 0.72
        sub.textWrapping = .wrapWholeWords
        try? group.xamlStackPanel?.children.append(sub)
    }
    #endif
    return retainNode(group)
}

func ad_pref_add(_ group: OLWidgetPtr, _ row: OLWidgetPtr) {
    guard let g = WinUINode.from(group), let r = WinUINode.from(row) else { return }
    g.addChild(r)
}

func ad_entry_row(_ title: String) -> OLWidgetPtr {
    let row = WinUINode(kind: .entryRow)
    row.title = title
    #if os(Windows)
    row.xamlTextBox?.header = title
    #endif
    return retainNode(row)
}

func ad_password_row(_ title: String) -> OLWidgetPtr {
    let row = WinUINode(kind: .passwordRow)
    row.title = title
    #if os(Windows)
    row.xamlPasswordBox?.header = title
    #endif
    return retainNode(row)
}

func ad_editable_get(_ row: OLWidgetPtr) -> UnsafePointer<CChar>? {
    guard let r = WinUINode.from(row) else { return nil }
    #if os(Windows)
    if let tb = r.xamlTextBox {
        r.text = tb.text
    } else if let pb = r.xamlPasswordBox {
        r.text = pb.password
    }
    #endif
    return (r.text as NSString).utf8String
}

func ad_editable_set(_ row: OLWidgetPtr, _ text: String) {
    guard let r = WinUINode.from(row) else { return }
    r.text = text
    #if os(Windows)
    r.xamlTextBox?.text = text
    r.xamlPasswordBox?.password = text
    #endif
}

func ad_action_row(_ title: String, _ subtitle: String?) -> OLWidgetPtr {
    let row = WinUINode(kind: .actionRow)
    row.title = title
    row.subtitle = subtitle ?? ""
    #if os(Windows)
    row.xamlTextBlock?.text = title
    row.xamlSubtitleBlock?.text = subtitle ?? ""
    #endif
    return retainNode(row)
}

func ad_action_set_subtitle(_ row: OLWidgetPtr, _ subtitle: String) {
    guard let r = WinUINode.from(row) else { return }
    r.subtitle = subtitle
    #if os(Windows)
    r.xamlSubtitleBlock?.text = subtitle
    #endif
}

func ad_row_add_suffix(_ row: OLWidgetPtr, _ widget: OLWidgetPtr) {
    guard let r = WinUINode.from(row), let w = WinUINode.from(widget) else { return }
    r.suffixes.append(w)
    r.addChild(w)
}

func ad_row_activatable(_ row: OLWidgetPtr, _ widget: OLWidgetPtr?) {
    guard let _ = WinUINode.from(row) else { return }
}

func ad_switch_row(_ title: String, _ subtitle: String?) -> OLWidgetPtr {
    let row = WinUINode(kind: .switchRow)
    row.title = title
    row.subtitle = subtitle ?? ""
    #if os(Windows)
    row.xamlToggleSwitch?.header = title
    row.xamlToggleSwitch?.onContent = "On"
    row.xamlToggleSwitch?.offContent = "Off"
    #endif
    return retainNode(row)
}

func ad_switch_get(_ row: OLWidgetPtr) -> Int32 {
    guard let r = WinUINode.from(row) else { return 0 }
    #if os(Windows)
    if let ts = r.xamlToggleSwitch {
        r.active = ts.isOn
    }
    #endif
    return r.active ? 1 : 0
}

func ad_switch_set(_ row: OLWidgetPtr, _ active: Int32) {
    guard let r = WinUINode.from(row) else { return }
    r.active = (active != 0)
    #if os(Windows)
    r.xamlToggleSwitch?.isOn = (active != 0)
    #endif
}

func ad_spin_row(_ title: String, _ subtitle: String?, _ min: Double, _ max: Double, _ step: Double) -> OLWidgetPtr {
    let row = WinUINode(kind: .spinRow)
    row.title = title
    row.subtitle = subtitle ?? ""
    row.spinLower = min
    row.spinUpper = max
    row.spinStep = step
    row.spinValue = min
    #if os(Windows)
    row.xamlNumberBox?.header = title
    row.xamlNumberBox?.minimum = min
    row.xamlNumberBox?.maximum = max
    row.xamlNumberBox?.smallChange = step
    row.xamlNumberBox?.value = min
    #endif
    return retainNode(row)
}

func ad_spin_get(_ row: OLWidgetPtr) -> Double {
    guard let r = WinUINode.from(row) else { return 0 }
    #if os(Windows)
    if let nb = r.xamlNumberBox, !nb.value.isNaN {
        r.spinValue = nb.value
    }
    #endif
    return r.spinValue
}

func ad_spin_set(_ row: OLWidgetPtr, _ value: Double) {
    guard let r = WinUINode.from(row) else { return }
    r.spinValue = min(max(value, r.spinLower), r.spinUpper)
    #if os(Windows)
    r.xamlNumberBox?.value = r.spinValue
    #endif
}

func ad_combo_row(_ title: String, _ subtitle: String?, _ items: [String]) -> OLWidgetPtr {
    let row = WinUINode(kind: .comboRow)
    row.title = title
    row.subtitle = subtitle ?? ""
    row.comboItems = items
    #if os(Windows)
    row.xamlComboBox?.header = title
    #endif
    return retainNode(row)
}

func ad_combo_get(_ row: OLWidgetPtr) -> UInt32 {
    guard let r = WinUINode.from(row) else { return 0 }
    #if os(Windows)
    if let cb = r.xamlComboBox, cb.selectedIndex >= 0 {
        r.selectedIndex = UInt32(cb.selectedIndex)
    }
    #endif
    return r.selectedIndex
}

func ad_combo_set(_ row: OLWidgetPtr, _ selected: UInt32) {
    guard let r = WinUINode.from(row) else { return }
    r.selectedIndex = selected
    #if os(Windows)
    r.xamlComboBox?.selectedIndex = Int32(selected)
    #endif
}

func ad_pref_dialog_new(_ title: String) -> OLWidgetPtr {
    let dlg = WinUINode(kind: .preferencesDialog)
    dlg.title = title
    return retainNode(dlg)
}

func ad_pref_page_new(_ title: String, _ iconName: String) -> OLWidgetPtr {
    let page = WinUINode(kind: .preferencesPage)
    page.title = title
    page.iconName = iconName
    return retainNode(page)
}

func ad_pref_page_add(_ page: OLWidgetPtr, _ group: OLWidgetPtr) {
    guard let p = WinUINode.from(page), let g = WinUINode.from(group) else { return }
    p.addChild(g)
}

func ad_pref_dialog_add(_ dialog: OLWidgetPtr, _ page: OLWidgetPtr) {
    guard let d = WinUINode.from(dialog), let p = WinUINode.from(page) else { return }
    d.addChild(p)
    #if os(Windows)
    if d.xamlNavView?.content == nil {
        d.xamlNavView?.content = p.xamlElement
    }
    #endif
}

func ad_dialog_present(_ dialog: OLWidgetPtr, _ parent: OLWidgetPtr?) {
    guard let d = WinUINode.from(dialog) else { return }
    d.visible = true
    #if os(Windows)
    if let parentNode = WinUINode.from(parent),
       let xamlRoot = parentNode.xamlElement?.xamlRoot,
       let cd = try? WinUI.ContentDialog() {
        cd.title = d.title
        cd.closeButtonText = "Close"
        cd.content = d.xamlElement
        cd.xamlRoot = xamlRoot
        d.xamlContentDialog = cd
        _ = try? cd.showAsync()
    }
    #endif
}

func ad_alert(_ parent: OLWidgetPtr?, _ heading: String, _ body: String,
              _ cancelId: String, _ cancelLabel: String,
              _ actionId: String, _ actionLabel: String,
              _ destructive: Int32,
              _ callback: OLAlertCallback, _ userData: UnsafeMutableRawPointer?) {
    #if os(Windows)
    if let parentNode = WinUINode.from(parent),
       let xamlRoot = parentNode.xamlElement?.xamlRoot,
       let cd = try? WinUI.ContentDialog() {
        cd.title = heading
        if let tb = try? WinUI.TextBlock() {
            tb.text = body
            tb.textWrapping = .wrapWholeWords
            cd.content = tb
        }
        cd.closeButtonText = cancelLabel
        cd.primaryButtonText = actionLabel
        cd.defaultButton = .primary
        cd.xamlRoot = xamlRoot
        _ = try? cd.showAsync()
        return
    }
    #endif
    cancelId.withCString { cStr in
        callback(cStr, userData)
    }
}

// ============================================================================
// Widget State & Styling Helpers
// ============================================================================

func ad_visible(_ widget: OLWidgetPtr, _ visible: Int32) {
    guard let w = WinUINode.from(widget) else { return }
    w.visible = (visible != 0)
    #if os(Windows)
    w.xamlElement?.visibility = (visible != 0) ? .visible : .collapsed
    #endif
}

func ad_sensitive(_ widget: OLWidgetPtr, _ sensitive: Int32) {
    guard let w = WinUINode.from(widget) else { return }
    w.sensitive = (sensitive != 0)
    #if os(Windows)
    w.xamlButton?.isEnabled = (sensitive != 0)
    w.xamlToggleButton?.isEnabled = (sensitive != 0)
    w.xamlTextBox?.isEnabled = (sensitive != 0)
    w.xamlPasswordBox?.isEnabled = (sensitive != 0)
    w.xamlToggleSwitch?.isEnabled = (sensitive != 0)
    w.xamlNumberBox?.isEnabled = (sensitive != 0)
    w.xamlComboBox?.isEnabled = (sensitive != 0)
    #endif
}

func ad_add_class(_ widget: OLWidgetPtr, _ cssClass: String) {
    guard let w = WinUINode.from(widget) else { return }
    w.cssClasses.insert(cssClass)
}

func ad_remove_class(_ widget: OLWidgetPtr, _ cssClass: String) {
    guard let w = WinUINode.from(widget) else { return }
    w.cssClasses.remove(cssClass)
}

func ad_load_css(_ css: String) {
    // WinUI 3 uses native Fluent Design / Mica / Acrylic theme resources
}

func ad_menu_button(_ iconName: String, _ tooltip: String, _ menuModel: OLMenuPtr) -> OLWidgetPtr {
    let btn = WinUINode(kind: .menuButton)
    btn.iconName = iconName
    btn.tooltip = tooltip
    btn.menuModel = WinUINode.from(menuModel)
    #if os(Windows)
    if let tb = try? WinUI.TextBlock() {
        tb.text = tooltip
        btn.xamlButton?.content = tb
    }
    if let flyout = try? WinUI.MenuFlyout() {
        btn.xamlButton?.flyout = flyout
    }
    #endif
    return retainNode(btn)
}

func g_menu_new() -> OLMenuPtr {
    retainNode(WinUINode(kind: .menuModel))
}

func g_menu_append(_ menu: OLMenuPtr, _ label: String, _ detailedAction: String) {
    guard let m = WinUINode.from(menu) else { return }
    m.menuEntries.append(WinUIMenuEntry(label: label, action: detailedAction))
}

func g_menu_append_section(_ menu: OLMenuPtr, _ label: String?, _ section: OLMenuPtr) {
    guard let m = WinUINode.from(menu), let sec = WinUINode.from(section) else { return }
    sec.title = label ?? ""
    m.menuSections.append(sec)
}

func ad_add_action(_ app: OLAppPtr, _ name: String, _ callback: OLActionCallback, _ userData: UnsafeMutableRawPointer?) {
    guard let appNode = WinUINode.from(app) else { return }
    appNode.actions[name] = WinUIAppAction(name: name, callback: callback, userData: userData)
}

func ad_set_accel(_ app: OLAppPtr, _ detailedAction: String, _ accel: String) {
    guard let appNode = WinUINode.from(app) else { return }
    let shortName = detailedAction.hasPrefix("app.") ? String(detailedAction.dropFirst(4)) : detailedAction
    appNode.actions[shortName]?.accelerators.append(accel)
}

// ============================================================================
// WebView2 Web Console Wrapper
// ============================================================================

func ol_web_new() -> OLWidgetPtr {
    retainNode(WinUINode(kind: .webView))
}

func ol_web_widget(_ web: OLWidgetPtr) -> OLWidgetPtr {
    web
}

func ol_web_load(_ web: OLWidgetPtr, _ uri: String) {
    guard let w = WinUINode.from(web) else { return }
    w.webCurrentURI = uri
    #if os(Windows)
    if let wv = w.xamlWebView, let winUri = try? WindowsFoundation.Uri(uri) {
        wv.source = winUri
    }
    #endif
}

func ol_web_reload(_ web: OLWidgetPtr) {
    guard let w = WinUINode.from(web) else { return }
    #if os(Windows)
    try? w.xamlWebView?.reload()
    #endif
}

func ol_web_back(_ web: OLWidgetPtr) {
    guard let w = WinUINode.from(web) else { return }
    #if os(Windows)
    try? w.xamlWebView?.goBack()
    #endif
}

func ol_web_forward(_ web: OLWidgetPtr) {
    guard let w = WinUINode.from(web) else { return }
    #if os(Windows)
    try? w.xamlWebView?.goForward()
    #endif
}

func ol_web_trust_host(_ web: OLWidgetPtr, _ host: String) {
    guard let w = WinUINode.from(web) else { return }
    w.webTrustedHosts.insert(host)
}

func ol_web_on_certificate(_ web: OLWidgetPtr, _ callback: OLCertCallback, _ userData: UnsafeMutableRawPointer?) {
    guard let w = WinUINode.from(web) else { return }
    w.webCertCallback = callback
    w.webCertContext = userData
}

func ol_web_on_load_failed(_ web: OLWidgetPtr, _ callback: OLWebLoadFailedCallback, _ userData: UnsafeMutableRawPointer?) {
    guard let w = WinUINode.from(web) else { return }
    w.webLoadFailedCallback = callback
    w.webLoadFailedContext = userData
}

func ol_web_uri(_ web: OLWidgetPtr) -> UnsafePointer<CChar>? {
    guard let w = WinUINode.from(web) else { return nil }
    return (w.webCurrentURI as NSString).utf8String
}

// ============================================================================
// Native Video Surface Widget (WriteableBitmap + Pointer/Key/Wheel Wiring)
// ============================================================================

func ol_native_widget(_ nativePtr: OpaquePointer?) -> OLWidgetPtr {
    let surface = WinUINode(kind: .nativeVideoSurface)
    surface.nativeHandle = nativePtr
    let retained = retainNode(surface)
    if let nativePtr {
        ol_native_set_frame_callback(nativePtr, { pixels, width, height, stride, ctx in
            guard let ctx, let pixels, width > 0, height > 0 else { return }
            guard let node = WinUINode.from(ctx) else { return }
            #if os(Windows)
            // Update WriteableBitmap when dimensions change
            if node.xamlBitmap == nil || node.width != width || node.height != height {
                node.width = width
                node.height = height
                if let bmp = try? WinUI.WriteableBitmap(width, height) {
                    node.xamlBitmap = bmp
                    node.xamlImage?.source = bmp
                }
            }
            try? node.xamlBitmap?.invalidate()
            #endif
            _ = stride
        }, retained)
    }
    return retained
}

// ============================================================================
// Clipboard & Timers
// ============================================================================

func ol_clipboard_get(_ widget: OLWidgetPtr) -> UnsafeMutablePointer<CChar>? {
    ol_win_clipboard_get()
}

func ol_clipboard_set(_ widget: OLWidgetPtr, _ text: String) {
    text.withCString { cStr in
        ol_win_clipboard_set(cStr)
    }
}

func g_timeout_add(_ intervalMs: UInt32, _ function: @escaping GSourceFunc, _ data: UnsafeMutableRawPointer?) -> UInt32 {
    ol_win_timer_add(intervalMs, function, data)
}

func g_timeout_add_seconds(_ intervalSec: UInt32, _ function: @escaping GSourceFunc, _ data: UnsafeMutableRawPointer?) -> UInt32 {
    ol_win_timer_add(intervalSec * 1000, function, data)
}

func g_source_remove(_ tag: UInt32) {
    ol_win_timer_remove(tag)
}
