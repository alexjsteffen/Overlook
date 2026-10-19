import Foundation
import SwiftUI

/// State for `WebUISettingsPanel` that must outlive the view.
///
/// Ticket 03: the settings panel is now conditionally mounted (it is unmounted while closed, so
/// its Picker-heavy body is never evaluated and it costs no layout pass). Everything the panel
/// used to keep in `@State` — loaded device config, keymaps, streamer state, section expansion,
/// in-progress drafts, error history — lives here instead, owned by `ContentView` as a
/// `@StateObject`, so closing and reopening the panel shows the previously loaded content
/// instead of starting from scratch.
@MainActor
final class WebUISettingsPanelModel: ObservableObject {
    struct ErrorEntry: Identifiable, Hashable {
        let id = UUID()
        let date: Date
        let message: String
    }

    /// One of the custom-quality streamer text fields.
    enum StreamerField: Hashable {
        case fps
        case quality
        case bitrate
        case gop
        case resolution
    }

    /// Tag of the "Custom" entry in the video quality picker (i.e. "use the streamer fields").
    static let videoQualityCustomTag: Int = -1
    /// Tag of the "Insane" preset, which is a preset the device config itself cannot represent.
    static let videoQualityInsaneTag: Int = 4

    // Loaded remote state.
    @Published var config: GLKVMSystemConfig?
    @Published var systemInfo: GLKVMSystemInfo?
    @Published var keymaps: GLKVMHidKeymapsState?
    @Published var hidState: GLKVMHidState?
    @Published var atxState: GLKVMAtxState?
    @Published var streamerState: GLKVMStreamerState?
    @Published var ocrState: GLKVMStreamerOcrState?
    @Published var msdState: GLKVMMsdState?
    @Published var msdPartitions: GLKVMMSDPartitionShowResult?
    @Published var gpioState: GLKVMGpioState?
    @Published var switchState: GLKVMSwitchState?
    @Published var redfishSystem: GLKVMRedfishSystem?
    @Published var redfishMedia: GLKVMRedfishVirtualMedia?

    // In-flight indicators.
    @Published var isLoading = false
    @Published var isApplying = false
    @Published var isApplyingStreamer = false
    @Published var isApplyingEdid = false
    @Published var isApplyingHid = false
    @Published var isApplyingAtx = false
    @Published var isApplyingMsd = false
    @Published var isApplyingGpio = false
    @Published var isApplyingSwitch = false
    @Published var isApplyingRedfish = false
    @Published var isSendingHidTextOrShortcut = false
    @Published var isFetchingLogs = false

    // Errors.
    @Published var errorMessage: String?
    @Published var errorHistory: [ErrorEntry] = []
    @Published var showingErrorHistory: Bool = false

    // Section expansion.
    @Published var isVideoExpanded = true
    @Published var isRemoteExpanded = true
    @Published var isKeyboardExpanded = true
    @Published var isVirtualMediaExpanded = false
    @Published var isGpioExpanded = false
    @Published var isSwitchExpanded = false
    @Published var isAudioExpanded = false
    @Published var isCaptureExpanded = false
    @Published var isSystemExpanded = false
    @Published var isNetworkExpanded = false
    @Published var isAdvancedExpanded = false

    // EDID.
    @Published var currentEdid: String = ""
    @Published var selectedEdidOption: String = "CUSTOMIZE"
    @Published var customEdidDraft: String = ""
    @Published var isProgrammaticEdidSelectionUpdate: Bool = false

    // Video quality.
    @Published var selectedVideoQualityPreset: Int = 1
    @Published var isProgrammaticQualityPresetUpdate: Bool = false

    /// Mirror of the streamer fields' `@FocusState` (which cannot live in an `ObservableObject`).
    var focusedStreamerField: StreamerField?

    // Debounced apply tasks.
    var applyTask: Task<Void, Never>?
    var applyStreamerTask: Task<Void, Never>?

    // Streamer drafts.
    @Published var isProgrammaticStreamerDraftUpdate: Bool = false
    @Published var streamerDesiredFps: Int = 30
    @Published var streamerQuality: Int = 80
    @Published var streamerH264Bitrate: Int = 2000
    @Published var streamerH264Gop: Int = 30
    @Published var streamerZeroDelay: Bool = false
    @Published var streamerResolution: String = ""

    @Published var streamerDesiredFpsText: String = ""
    @Published var streamerQualityText: String = ""
    @Published var streamerH264BitrateText: String = ""
    @Published var streamerH264GopText: String = ""

    // Keyboard & Remote Text Typing drafts.
    @Published var remoteTypeTextDraft: String = ""
    @Published var remoteTypeSlowMode: Bool = false
    @Published var remoteTypeDelaySeconds: Double = 0.02
    @Published var remoteTypeLimit: Int = 0
    @Published var customShortcutKeysDraft: String = "ControlLeft,AltLeft,Delete"

    // Virtual Media (MSD) drafts.
    @Published var msdSelectedImage: String = ""
    @Published var msdCdromMode: Bool = true
    @Published var msdReadWriteMode: Bool = false
    @Published var msdRemoteURLDraft: String = ""
    @Published var msdRemoteImageNameDraft: String = ""
    @Published var msdRemoteUserDraft: String = ""
    @Published var msdRemotePasswordDraft: String = ""
    @Published var msdRemoteVerifyTLS: Bool = true

    // GPIO drafts.
    @Published var gpioPulseDelayDrafts: [String: Double] = [:]

    // PiKVM Switch drafts.
    @Published var switchTargetPortDraft: String = "0"
    @Published var switchBeaconColorDraft: String = "FFA500:BF:0028"
    @Published var switchPortNameDraft: String = ""
    @Published var switchPortDummyDraft: Bool = false
    @Published var switchPortEdidIdDraft: String = ""

    // ATX & Redfish options.
    @Published var atxWaitForCompletion: Bool = false
    @Published var redfishSelectedResetType: GLKVMClient.RedfishResetType = .GracefulShutdownFallback

    // System Logs & Prometheus sheets.
    @Published var deviceServiceLogText: String = ""
    @Published var logSeekSeconds: Int = 3600
    @Published var showingDeviceLogSheet: Bool = false
    @Published var prometheusMetricsText: String = ""
    @Published var showingPrometheusSheet: Bool = false

    // Audio device enumeration.
    @Published var audioInputDevices: [CoreAudioDeviceInfo] = []
    @Published var audioOutputDevices: [CoreAudioDeviceInfo] = []

    // Network & System state
    @Published var networkConfig: GLKVMNetworkConfig?
    @Published var wifiConfig: GLKVMWifiConfig?
    @Published var ethernetConfig: GLKVMEthernetConfig?

    @Published var isApplyingNetwork = false
    @Published var isApplyingWifi = false

    // Network draft fields
    @Published var networkMode: String = "dhcp"
    @Published var networkIP: String = "192.168.8.1"
    @Published var networkNetmask: String = "255.255.255.0"
    @Published var networkGateway: String = "192.168.8.1"
    @Published var networkDNS: String = "8.8.8.8"

    @Published var wifiEnabled: Bool = true
    @Published var wifiSSID: String = "Overlook-WiFi"
    @Published var wifiPassword: String = ""
    @Published var wifiStatus: String = "Connected"

    @Published var ethernetConnected: Bool = true
    @Published var ethernetSpeed: String = "1000 Mbps"
    @Published var ethernetIP: String = "192.168.8.100"
    @Published var ethernetMAC: String = "00:11:22:33:44:55"
}

extension GLKVMClient.RedfishResetType {
    static var GracefulShutdownFallback: GLKVMClient.RedfishResetType { .gracefulShutdown }
}
