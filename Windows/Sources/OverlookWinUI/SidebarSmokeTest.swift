import Foundation
import CNativeWin
import OverlookCore

/// Exercises the Windows collapsible sidebar state, Win32 bridge synchronization,
/// fullscreen preservation, and preferences persistence without modifying user data.
func runSidebarSmokeTest() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("overlook-sidebar-smoke-\(UUID().uuidString)")
    var activeApp: UnsafeMutableRawPointer?
    defer {
        ol_win_gui_close()
        if let activeApp {
            ol_unref(activeApp)
        }
        try? FileManager.default.removeItem(at: tempDir)
    }

    let prefsURL = tempDir.appendingPathComponent("preferences.json")
    let store = PreferencesStore(file: prefsURL)
    let registry = WinUIAdapterRegistry.shared

    let commandHandler: OLWinUICommandCallback = { cmdPtr, idx, _ in
        guard let cmdPtr else { return }
        WinUIAdapterRegistry.shared.handleNativeCommand(String(cString: cmdPtr), index: idx)
    }

    func require(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw NSError(domain: "SidebarSmokeTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    func makeActivatedDesktop() -> Desktop {
        ol_win_gui_init(commandHandler, nil)
        let desktop = Desktop(preferencesStore: store)
        desktop.presentWindow = false
        desktop.preferences = store.load()
        desktop.connectionInfo = ConnectionInfoController(desktop: desktop)
        desktop.settingsDialog = SettingsDialogController(desktop: desktop)
        activeApp = desktop.app
        desktop.activate()
        return desktop
    }

    do {
        let desktop = makeActivatedDesktop()

        // 1. Default startup state is expanded.
        try require(ol_win_gui_is_sidebar_visible() == 1, "Initial sidebar should be visible")
        try require(registry.splitView?.showSidebar == true, "Initial splitView.showSidebar should be true")
        try require(registry.sidebarToggle?.checked == true, "Initial sidebarToggle.checked should be true")
        try require(!desktop.preferences.sidebarCollapsed, "Initial sidebarCollapsed preference should be false")

        // 2. Toggle collapses sidebar and persists preference.
        registry.handleNativeCommand("toggle-sidebar", index: 0)
        try require(ol_win_gui_is_sidebar_visible() == 0, "Sidebar should collapse after toggle-sidebar")
        try require(registry.splitView?.showSidebar == false, "splitView.showSidebar should become false after collapse")
        try require(registry.sidebarToggle?.checked == false, "sidebarToggle.checked should become false after collapse")
        try require(desktop.preferences.sidebarCollapsed, "preferences.sidebarCollapsed should become true after collapse")
        try require(store.load().sidebarCollapsed, "Persisted preferences should record sidebarCollapsed = true")

        // 3. Fullscreen enter and exit preserve collapsed state.
        registry.handleNativeCommand("fullscreen", index: 0)
        try require(ol_win_gui_is_fullscreen() == 1, "Window should enter fullscreen")
        try require(ol_win_gui_is_sidebar_visible() == 0, "Sidebar state should remain collapsed during fullscreen")
        registry.handleNativeCommand("fullscreen", index: 0)
        try require(ol_win_gui_is_fullscreen() == 0, "Window should exit fullscreen")
        try require(ol_win_gui_is_sidebar_visible() == 0, "Collapsed sidebar should stay collapsed after exiting fullscreen")

        // 4. Toggle expands sidebar again and updates persisted preference.
        registry.handleNativeCommand("toggle-sidebar", index: 0)
        try require(ol_win_gui_is_sidebar_visible() == 1, "Sidebar should expand after second toggle-sidebar")
        try require(registry.splitView?.showSidebar == true, "splitView.showSidebar should become true after expand")
        try require(registry.sidebarToggle?.checked == true, "sidebarToggle.checked should become true after expand")
        try require(!desktop.preferences.sidebarCollapsed, "preferences.sidebarCollapsed should become false after expand")
        try require(!store.load().sidebarCollapsed, "Persisted preferences should record sidebarCollapsed = false")

        // 5. Fullscreen enter and exit preserve expanded state.
        registry.handleNativeCommand("fullscreen", index: 0)
        try require(ol_win_gui_is_fullscreen() == 1, "Window should enter fullscreen while expanded")
        try require(ol_win_gui_is_sidebar_visible() == 1, "Expanded sidebar preference should be preserved during fullscreen")
        registry.handleNativeCommand("fullscreen", index: 0)
        try require(ol_win_gui_is_fullscreen() == 0, "Window should exit fullscreen while expanded")
        try require(ol_win_gui_is_sidebar_visible() == 1, "Expanded sidebar should remain visible after exiting fullscreen")

        // 6. Persist collapsed state before restarting into a fresh Desktop instance.
        registry.handleNativeCommand("toggle-sidebar", index: 0)
        try require(store.load().sidebarCollapsed, "Sidebar should be persisted as collapsed before restart")

        ol_win_gui_close()
        ol_unref(desktop.app)
        activeApp = nil
    }

    // Re-launch a fresh Desktop instance with the same PreferencesStore.
    let restarted = makeActivatedDesktop()
    try require(restarted.preferences.sidebarCollapsed, "Restarted desktop should load sidebarCollapsed = true")
    try require(ol_win_gui_is_sidebar_visible() == 0, "Restarted window should restore collapsed sidebar")
    try require(registry.splitView?.showSidebar == false, "Restarted splitView.showSidebar should be false")
    try require(registry.sidebarToggle?.checked == false, "Restarted sidebarToggle.checked should be false")

    print("Sidebar smoke test passed: toggle, fullscreen preservation, and restart persistence.")
}
