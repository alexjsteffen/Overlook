import SwiftUI
#if canImport(WebRTC)
import WebRTC
#endif
import Vision
import Network
import Combine

@main
struct OverlookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.webRTCManager)
                // Telemetry is a separate observable so only the views that render stats
                // re-evaluate when it ticks.
                .environmentObject(appDelegate.webRTCManager.telemetry)
                .environmentObject(appDelegate.inputManager)
                .environmentObject(appDelegate.ocrManager)
                .environmentObject(appDelegate.kvmDeviceManager)
                .environmentObject(appDelegate.captureManager)
                .environmentObject(appDelegate.hardwareControlManager)
                .environmentObject(ConnectionLog.shared.store)
                .environmentObject(appDelegate.panels)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.automatic)
        .commands {
            // The View menu's Show/Hide Toolbar pair. Useful in its own right on a console
            // window, and `PanelCommands` anchors to the group it contributes.
            ToolbarCommands()

            PanelCommands(panels: appDelegate.panels)

            // One window: the panel state, `showMainWindow()` and `MenuBarAgent` all assume a
            // single console, and a second window would fight the first over which panel is open.
            CommandGroup(replacing: .newItem) { }

            CaptureCommands(captureManager: appDelegate.captureManager)
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarAgent: MenuBarAgent?

    let webRTCManager: WebRTCManager
    let inputManager = InputManager()
    let ocrManager = OCRManager()
    let kvmDeviceManager: KVMDeviceManager
    let captureManager: CaptureManager
    let hardwareControlManager = HardwareControlManager()
    /// Owned here rather than by `ContentView`: the View menu is built in the `App` scope, where
    /// a view's `@State` is out of reach, and the menu stays live with no window open.
    let panels = PanelPresentation()
    private var cancellables = Set<AnyCancellable>()

    override init() {
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 500])

        let webRTCManager = WebRTCManager()
        let kvmDeviceManager = KVMDeviceManager()
        self.webRTCManager = webRTCManager
        self.kvmDeviceManager = kvmDeviceManager
        captureManager = CaptureManager(webRTCManager: webRTCManager, kvmDeviceManager: kvmDeviceManager)
        super.init()

        kvmDeviceManager.$connectedDevice
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak panels] active in
                panels?.isSessionActive = active
            }
            .store(in: &cancellables)

        kvmDeviceManager.$glkvmClient
            .sink { [weak hardwareControlManager] client in
                hardwareControlManager?.setClient(client)
            }
            .store(in: &cancellables)
    }

    private var isTerminating = false
    private var hasRepliedToTermination = false
    /// Longest the app waits for the HID release and socket close before quitting anyway.
    private static let terminationGraceNanoseconds: UInt64 = 3_000_000_000

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarAgent = MenuBarAgent(
            kvmDeviceManager: kvmDeviceManager,
            webRTCManager: webRTCManager,
            inputManager: inputManager,
            captureManager: captureManager,
            showMainWindow: { [weak self] in
                self?.showMainWindow()
            }
        )
        menuBarAgent?.setup()

        // Configure app for KVM control
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let windows = NSApp.windows
        let candidate = windows.first(where: { $0.canBecomeKey && $0.isVisible }) ?? windows.first(where: { $0.canBecomeKey })
        candidate?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateCancel }
        isTerminating = true
        menuBarAgent?.cleanup()
        kvmDeviceManager.cancelScan()

        Task { @MainActor [self] in
            await captureManager.finishRecordingForTermination()
            await inputManager.shutdown()
            webRTCManager.disconnect()
            finishTermination(sender)
        }
        // Don't let a wedged HID socket hold the process open.
        Task { @MainActor [self] in
            try? await Task.sleep(nanoseconds: Self.terminationGraceNanoseconds)
            finishTermination(sender)
        }
        return .terminateLater
    }

    private func finishTermination(_ app: NSApplication) {
        guard !hasRepliedToTermination else { return }
        hasRepliedToTermination = true
        app.reply(toApplicationShouldTerminate: true)
    }
}
