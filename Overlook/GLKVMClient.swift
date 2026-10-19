// swiftlint:disable file_length type_body_length line_length
import Foundation
import CryptoKit

typealias GLKVMJSONObject = [String: JSONValue]

struct GLKVMResponse<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result
}

struct GLKVMEmptyResult: Decodable {}

struct GLKVMInitStatus: Decodable {
    let countryCode: String
    let isInited: Bool

    enum CodingKeys: String, CodingKey {
        case countryCode = "country_code"
        case isInited = "is_inited"
    }
}

struct GLKVMSystemGetConfigResult: Decodable {
    let config: GLKVMSystemConfig
}

struct GLKVMSystemConfigShortcut: Codable, Hashable {
    let keys: [String]
    let label: String
}

struct GLKVMSystemConfig: Codable, Hashable {
    var shortcuts: [GLKVMSystemConfigShortcut]
    var orientation: Int
    var streamQuality: Int
    var videoMode: String
    var showCursor: Bool
    var mousePolling: Int
    var mouseControl: Bool
    var relativeSense: Int
    var scrollRate: Int
    var reverseScrolling: String
    var keyboardControl: Bool
    var themeMode: String
    var mouseJiggle: Bool
    var keymap: String
    var gotMutedPanelTip: Bool
    var isAbsoluteMouse: Bool
    var fingerbotStrength: Int
    var videoProcessing: String
    var language: String
    var timezone: String

    enum CodingKeys: String, CodingKey {
        case shortcuts
        case orientation
        case streamQuality = "stream_quality"
        case videoMode = "video_mode"
        case showCursor = "show_cursor"
        case mousePolling = "mouse_polling"
        case mouseControl = "mouse_control"
        case relativeSense = "relative_sense"
        case scrollRate = "scroll_rate"
        case reverseScrolling = "reverse_scrolling"
        case keyboardControl = "keyboard_control"
        case themeMode = "theme_mode"
        case mouseJiggle = "mouse_jiggle"
        case keymap
        case gotMutedPanelTip = "got_muted_panel_tip"
        case isAbsoluteMouse = "is_absolute_mouse"
        case fingerbotStrength = "fingerbot_strength"
        case videoProcessing = "video_processing"
        case language
        case timezone
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shortcuts = (try? container.decode([GLKVMSystemConfigShortcut].self, forKey: .shortcuts)) ?? []
        orientation = (try? container.decode(Int.self, forKey: .orientation)) ?? 0
        streamQuality = (try? container.decode(Int.self, forKey: .streamQuality)) ?? 1
        videoMode = (try? container.decode(String.self, forKey: .videoMode)) ?? ""
        showCursor = (try? container.decode(Bool.self, forKey: .showCursor)) ?? true
        mousePolling = (try? container.decode(Int.self, forKey: .mousePolling)) ?? 10
        mouseControl = (try? container.decode(Bool.self, forKey: .mouseControl)) ?? true
        relativeSense = (try? container.decode(Int.self, forKey: .relativeSense)) ?? 10
        scrollRate = (try? container.decode(Int.self, forKey: .scrollRate)) ?? 5
        reverseScrolling = (try? container.decode(String.self, forKey: .reverseScrolling)) ?? "STANDARD"
        keyboardControl = (try? container.decode(Bool.self, forKey: .keyboardControl)) ?? true
        themeMode = (try? container.decode(String.self, forKey: .themeMode)) ?? "auto"
        mouseJiggle = (try? container.decode(Bool.self, forKey: .mouseJiggle)) ?? false
        keymap = (try? container.decode(String.self, forKey: .keymap)) ?? "en-us"
        gotMutedPanelTip = (try? container.decode(Bool.self, forKey: .gotMutedPanelTip)) ?? false
        isAbsoluteMouse = (try? container.decode(Bool.self, forKey: .isAbsoluteMouse)) ?? true
        fingerbotStrength = (try? container.decode(Int.self, forKey: .fingerbotStrength)) ?? 0
        videoProcessing = (try? container.decode(String.self, forKey: .videoProcessing)) ?? ""
        language = (try? container.decode(String.self, forKey: .language)) ?? "auto"
        timezone = (try? container.decode(String.self, forKey: .timezone)) ?? "UTC"
    }
}

struct GLKVMNetworkConfig: Codable, Hashable {
    var mode: String
    var ip: String
    var netmask: String
    var gateway: String
    var dns: String

    enum CodingKeys: String, CodingKey {
        case mode
        case ip
        case netmask
        case gateway
        case dns
    }

    init(mode: String = "dhcp", ip: String = "192.168.8.1", netmask: String = "255.255.255.0", gateway: String = "192.168.8.1", dns: String = "8.8.8.8") {
        self.mode = mode
        self.ip = ip
        self.netmask = netmask
        self.gateway = gateway
        self.dns = dns
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? container.decode(String.self, forKey: .mode)) ?? "dhcp"
        ip = (try? container.decode(String.self, forKey: .ip)) ?? "192.168.8.1"
        netmask = (try? container.decode(String.self, forKey: .netmask)) ?? "255.255.255.0"
        gateway = (try? container.decode(String.self, forKey: .gateway)) ?? "192.168.8.1"
        dns = (try? container.decode(String.self, forKey: .dns)) ?? "8.8.8.8"
    }
}

struct GLKVMWifiConfig: Codable, Hashable {
    var enabled: Bool
    var ssid: String
    var password: String?
    var status: String

    enum CodingKeys: String, CodingKey {
        case enabled
        case ssid
        case password
        case status
    }

    init(enabled: Bool = true, ssid: String = "Overlook-WiFi", password: String? = nil, status: String = "Connected") {
        self.enabled = enabled
        self.ssid = ssid
        self.password = password
        self.status = status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? container.decode(Bool.self, forKey: .enabled)) ?? true
        ssid = (try? container.decode(String.self, forKey: .ssid)) ?? "Overlook-WiFi"
        password = try? container.decode(String.self, forKey: .password)
        status = (try? container.decode(String.self, forKey: .status)) ?? "Connected"
    }
}

struct GLKVMEthernetConfig: Codable, Hashable {
    var connected: Bool
    var speed: String
    var ip: String
    var mac: String

    enum CodingKeys: String, CodingKey {
        case connected
        case speed
        case ip
        case mac
    }

    init(connected: Bool = true, speed: String = "1000 Mbps", ip: String = "192.168.8.100", mac: String = "00:11:22:33:44:55") {
        self.connected = connected
        self.speed = speed
        self.ip = ip
        self.mac = mac
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connected = (try? container.decode(Bool.self, forKey: .connected)) ?? true
        speed = (try? container.decode(String.self, forKey: .speed)) ?? "1000 Mbps"
        ip = (try? container.decode(String.self, forKey: .ip)) ?? "192.168.8.100"
        mac = (try? container.decode(String.self, forKey: .mac)) ?? "00:11:22:33:44:55"
    }
}

struct GLKVMTurnCredentials: Decodable {
    let password: String
    let ttl: Int
    let uris: [String]
    let username: String
}

// MARK: - PiKVM / GLKVM System Info Models (/api/info)

struct GLKVMSystemInfo: Decodable, Hashable {
    struct Hardware: Decodable, Hashable {
        struct Platform: Decodable, Hashable {
            let base: String?
            let board: String?
            let model: String?
            let serial: String?
            let type: String?
            let video: String?
        }

        struct Health: Decodable, Hashable {
            struct CPU: Decodable, Hashable {
                let percent: Double?
            }

            struct Memory: Decodable, Hashable {
                let available: Int64?
                let percent: Double?
                let total: Int64?
            }

            struct Temperature: Decodable, Hashable {
                let cpu: Double?
                let gpu: Double?
            }

            struct Throttling: Decodable, Hashable {
                struct FlagState: Decodable, Hashable {
                    let now: Bool
                    let past: Bool
                }

                struct ParsedFlags: Decodable, Hashable {
                    let freqCapped: FlagState?
                    let throttled: FlagState?
                    let undervoltage: FlagState?

                    enum CodingKeys: String, CodingKey {
                        case freqCapped = "freq_capped"
                        case throttled
                        case undervoltage
                    }
                }

                let ignorePast: Bool?
                let parsedFlags: ParsedFlags?
                let rawFlags: Int?

                enum CodingKeys: String, CodingKey {
                    case ignorePast = "ignore_past"
                    case parsedFlags = "parsed_flags"
                    case rawFlags = "raw_flags"
                }
            }

            let cpu: CPU?
            let mem: Memory?
            let temp: Temperature?
            let throttling: Throttling?
        }

        let platform: Platform?
        let health: Health?
    }

    struct System: Decodable, Hashable {
        struct KVMD: Decodable, Hashable {
            let version: String?
        }

        struct Streamer: Decodable, Hashable {
            let app: String?
            let version: String?
            let features: [String: Bool]?
        }

        struct Kernel: Decodable, Hashable {
            let system: String?
            let release: String?
            let version: String?
            let machine: String?
        }

        let kvmd: KVMD?
        let streamer: Streamer?
        let kernel: Kernel?
    }

    struct Meta: Decodable, Hashable {
        struct Server: Decodable, Hashable {
            let host: String?
        }
        let server: Server?
        let kvm: GLKVMJSONObject?
    }

    struct ExtraService: Decodable, Hashable, Identifiable {
        var id: String { name ?? path ?? daemon ?? UUID().uuidString }
        let name: String?
        let description: String?
        let icon: String?
        let path: String?
        let daemon: String?
        let port: Int?
        let enabled: Bool?
    }

    let hw: Hardware?
    let system: System?
    let meta: Meta?
    let extras: [String: ExtraService]?
    let fan: GLKVMJSONObject?
    let auth: GLKVMJSONObject?
}

// MARK: - HID Models (/api/hid)

struct GLKVMHidKeymapsState: Decodable, Hashable {
    struct Keymaps: Decodable, Hashable {
        let `default`: String
        let available: [String]
    }

    let keymaps: Keymaps
}

struct GLKVMHidState: Decodable, Hashable {
    struct Jiggler: Decodable, Hashable {
        let active: Bool
        let enabled: Bool
        let interval: Double

        init(active: Bool = false, enabled: Bool = false, interval: Double = 60) {
            self.active = active
            self.enabled = enabled
            self.interval = interval
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            active = (try? container.decode(Bool.self, forKey: .active)) ?? false
            enabled = (try? container.decode(Bool.self, forKey: .enabled)) ?? false
            interval = (try? container.decode(Double.self, forKey: .interval)) ?? 60
        }

        enum CodingKeys: String, CodingKey {
            case active, enabled, interval
        }
    }

    struct Outputs: Decodable, Hashable {
        let active: String
        let available: [String]

        init(active: String = "", available: [String] = []) {
            self.active = active
            self.available = available
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            active = (try? container.decode(String.self, forKey: .active)) ?? ""
            available = (try? container.decode([String].self, forKey: .available)) ?? []
        }

        enum CodingKeys: String, CodingKey {
            case active, available
        }
    }

    struct Keyboard: Decodable, Hashable {
        struct LEDs: Decodable, Hashable {
            let caps: Bool
            let num: Bool
            let scroll: Bool

            init(caps: Bool = false, num: Bool = false, scroll: Bool = false) {
                self.caps = caps
                self.num = num
                self.scroll = scroll
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                caps = (try? container.decode(Bool.self, forKey: .caps)) ?? false
                num = (try? container.decode(Bool.self, forKey: .num)) ?? false
                scroll = (try? container.decode(Bool.self, forKey: .scroll)) ?? false
            }

            enum CodingKeys: String, CodingKey {
                case caps, num, scroll
            }
        }

        let leds: LEDs
        let online: Bool
        let outputs: Outputs?
    }

    struct Mouse: Decodable, Hashable {
        let absolute: Bool?
        let online: Bool
        let outputs: Outputs?
    }

    let busy: Bool?
    let connected: Bool?
    let enabled: Bool
    let online: Bool
    let jiggler: Jiggler
    let keyboard: Keyboard?
    let mouse: Mouse?
}

// MARK: - ATX Models (/api/atx)

struct GLKVMAtxState: Decodable, Hashable {
    struct LEDs: Decodable, Hashable {
        let hdd: Bool
        let power: Bool
    }

    let busy: Bool
    let enabled: Bool
    let leds: LEDs
}

// MARK: - Streamer & OCR Models (/api/streamer)

struct GLKVMStreamerState: Decodable, Hashable {
    struct Features: Decodable, Hashable {
        let quality: Bool
        let resolution: Bool
        let h264: Bool
        let zeroDelay: Bool?

        enum CodingKeys: String, CodingKey {
            case quality
            case resolution
            case h264
            case zeroDelay = "zero_delay"
        }
    }

    struct Limits: Decodable, Hashable {
        struct MinMax: Decodable, Hashable {
            let min: Int
            let max: Int
        }

        let desiredFps: MinMax
        let h264Bitrate: MinMax?
        let h264Gop: MinMax?

        enum CodingKeys: String, CodingKey {
            case desiredFps = "desired_fps"
            case h264Bitrate = "h264_bitrate"
            case h264Gop = "h264_gop"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let minMax = try? container.decode(MinMax.self, forKey: .desiredFps) {
                desiredFps = minMax
            } else {
                desiredFps = MinMax(min: 0, max: 60)
            }
            h264Bitrate = try? container.decode(MinMax.self, forKey: .h264Bitrate)
            h264Gop = try? container.decode(MinMax.self, forKey: .h264Gop)
        }
    }

    struct Params: Decodable, Hashable {
        let desiredFps: Int?
        let quality: Int?
        let h264Bitrate: Int?
        let h264Gop: Int?
        let zeroDelay: Bool?
        let resolution: String?

        enum CodingKeys: String, CodingKey {
            case desiredFps = "desired_fps"
            case quality
            case h264Bitrate = "h264_bitrate"
            case h264Gop = "h264_gop"
            case zeroDelay = "zero_delay"
            case resolution
        }
    }

    struct LiveStreamer: Decodable, Hashable {
        struct Encoder: Decodable, Hashable {
            let quality: Int?
            let type: String?
        }

        struct H264: Decodable, Hashable {
            let bitrate: Int?
            let fps: Int?
            let gop: Int?
            let online: Bool?
        }

        struct Source: Decodable, Hashable {
            struct Resolution: Decodable, Hashable {
                let width: Int
                let height: Int
            }

            let capturedFps: Int?
            let desiredFps: Int?
            let online: Bool?
            let resolution: Resolution?

            enum CodingKeys: String, CodingKey {
                case capturedFps = "captured_fps"
                case desiredFps = "desired_fps"
                case online
                case resolution
            }
        }

        struct Stream: Decodable, Hashable {
            let clients: Int?
            let queuedFps: Int?

            enum CodingKeys: String, CodingKey {
                case clients
                case queuedFps = "queued_fps"
            }
        }

        let encoder: Encoder?
        let h264: H264?
        let source: Source?
        let stream: Stream?
    }

    let features: Features?
    let limits: Limits?
    let params: Params?
    let streamer: LiveStreamer?
}

struct GLKVMStreamerOcrState: Decodable, Hashable {
    struct OcrInfo: Decodable, Hashable {
        struct Langs: Decodable, Hashable {
            let available: [String]
            let `default`: [String]
        }

        let enabled: Bool
        let langs: Langs?
    }

    let ocr: OcrInfo
}

// MARK: - Mass Storage Drive Models (/api/msd)

struct GLKVMMsdImageInfo: Decodable, Hashable, Identifiable {
    var id: String { name }
    let name: String
    let size: Int64
    let complete: Bool
    let inStorage: Bool
    let removable: Bool

    init(name: String, size: Int64 = 0, complete: Bool = true, inStorage: Bool = true, removable: Bool = true) {
        self.name = name
        self.size = size
        self.complete = complete
        self.inStorage = inStorage
        self.removable = removable
    }
}

struct GLKVMMsdState: Decodable, Hashable {
    struct Drive: Decodable, Hashable {
        let imageName: String?
        let imageSize: Int64?
        let connected: Bool
        let cdrom: Bool
        let rw: Bool

        enum CodingKeys: String, CodingKey {
            case image
            case connected
            case cdrom
            case rw
        }

        init(imageName: String? = nil, imageSize: Int64? = nil, connected: Bool = false, cdrom: Bool = true, rw: Bool = false) {
            self.imageName = imageName
            self.imageSize = imageSize
            self.connected = connected
            self.cdrom = cdrom
            self.rw = rw
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            connected = (try? container.decode(Bool.self, forKey: .connected)) ?? false
            cdrom = (try? container.decode(Bool.self, forKey: .cdrom)) ?? true
            rw = (try? container.decode(Bool.self, forKey: .rw)) ?? false

            if let imageString = try? container.decode(String.self, forKey: .image) {
                imageName = imageString
                imageSize = nil
            } else if let imageObj = try? container.decode([String: JSONValue].self, forKey: .image) {
                imageName = imageObj["name"]?.stringValue
                imageSize = imageObj["size"]?.intValue.map(Int64.init)
            } else {
                imageName = nil
                imageSize = nil
            }
        }
    }

    struct Storage: Decodable, Hashable {
        let size: Int64
        let free: Int64
        let uploading: Bool
        let downloading: Bool
        let images: [GLKVMMsdImageInfo]

        enum CodingKeys: String, CodingKey {
            case size
            case free
            case uploading
            case downloading
            case images
            case parts
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var resolvedSize = (try? container.decode(Int64.self, forKey: .size)) ?? 0
            var resolvedFree = (try? container.decode(Int64.self, forKey: .free)) ?? 0

            if resolvedSize == 0,
               let parts = try? container.decode([String: [String: JSONValue]].self, forKey: .parts),
               let defaultPart = parts[""] ?? parts.values.first {
                resolvedSize = defaultPart["size"]?.intValue.map(Int64.init) ?? 0
                resolvedFree = defaultPart["free"]?.intValue.map(Int64.init) ?? 0
            }
            size = resolvedSize
            free = resolvedFree

            if let upBool = try? container.decode(Bool.self, forKey: .uploading) {
                uploading = upBool
            } else if let upObj = try? container.decode(JSONValue.self, forKey: .uploading) {
                uploading = !upObj.isNull
            } else {
                uploading = false
            }

            if let downBool = try? container.decode(Bool.self, forKey: .downloading) {
                downloading = downBool
            } else if let downObj = try? container.decode(JSONValue.self, forKey: .downloading) {
                downloading = !downObj.isNull
            } else {
                downloading = false
            }

            var parsedImages: [GLKVMMsdImageInfo] = []
            if let imagesDict = try? container.decode([String: [String: JSONValue]].self, forKey: .images) {
                for (name, info) in imagesDict {
                    let imgSize = info["size"]?.intValue.map(Int64.init) ?? 0
                    let complete = info["complete"]?.boolValue ?? true
                    let inStorage = info["in_storage"]?.boolValue ?? true
                    let removable = info["removable"]?.boolValue ?? true
                    parsedImages.append(
                        GLKVMMsdImageInfo(
                            name: name,
                            size: imgSize,
                            complete: complete,
                            inStorage: inStorage,
                            removable: removable
                        )
                    )
                }
            }
            images = parsedImages.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    struct Features: Decodable, Hashable {
        let multi: Bool
        let cdrom: Bool
        let rw: Bool

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            multi = (try? container.decode(Bool.self, forKey: .multi)) ?? true
            cdrom = (try? container.decode(Bool.self, forKey: .cdrom)) ?? true
            rw = (try? container.decode(Bool.self, forKey: .rw)) ?? true
        }

        enum CodingKeys: String, CodingKey {
            case multi, cdrom, rw
        }
    }

    let enabled: Bool
    let online: Bool
    let busy: Bool
    let drive: Drive?
    let storage: Storage?
    let features: Features?
}

struct GLKVMMSDPartitionDevice: Decodable, Hashable {
    let path: String
    let size: Int
    let uuid: String
    let filesystem: String
    let label: String
    let isCurrent: Bool

    enum CodingKeys: String, CodingKey {
        case path
        case size
        case uuid
        case filesystem
        case label
        case isCurrent = "is_current"
    }
}

struct GLKVMMSDPartitionShowResult: Decodable, Hashable {
    let devices: [String: GLKVMMSDPartitionDevice]
}

struct GLKVMMSDWriteImageInfo: Decodable, Hashable {
    let name: String
    let size: Int
    let written: Int
}

struct GLKVMMSDWriteResult: Decodable, Hashable {
    let image: GLKVMMSDWriteImageInfo
}

// MARK: - GPIO Models (/api/gpio)

struct GLKVMGpioState: Decodable, Hashable {
    struct ChannelScheme: Decodable, Hashable, Identifiable {
        var id: String { channel }
        let channel: String
        let switchEnabled: Bool
        let pulseDelay: Double
        let minDelay: Double
        let maxDelay: Double
        let driver: String?
        let pin: String?
    }

    struct ChannelRuntimeState: Decodable, Hashable {
        let online: Bool
        let state: Bool
        let busy: Bool
    }

    let inputChannels: [String]
    let outputSchemes: [String: ChannelScheme]
    let inputs: [String: ChannelRuntimeState]
    let outputs: [String: ChannelRuntimeState]

    enum CodingKeys: String, CodingKey {
        case model
        case state
    }

    init(
        inputChannels: [String] = [],
        outputSchemes: [String: ChannelScheme] = [:],
        inputs: [String: ChannelRuntimeState] = [:],
        outputs: [String: ChannelRuntimeState] = [:]
    ) {
        self.inputChannels = inputChannels
        self.outputSchemes = outputSchemes
        self.inputs = inputs
        self.outputs = outputs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let modelObj = try? container.decode([String: JSONValue].self, forKey: .model)
        let stateObj = try? container.decode([String: JSONValue].self, forKey: .state)

        var parsedInputNames: Set<String> = []
        var parsedOutputSchemes: [String: ChannelScheme] = [:]

        if let scheme = modelObj?["scheme"] {
            if case .object(let ins) = scheme["inputs"] {
                parsedInputNames.formUnion(ins.keys)
            }
            if case .object(let outs) = scheme["outputs"] {
                for (ch, val) in outs {
                    let switchCap = val["switch"]?.boolValue ?? true
                    let pulseObj = val["pulse"]
                    let delay = pulseObj?["delay"]?.doubleValue ?? 0.0
                    let minDelay = pulseObj?["min_delay"]?.doubleValue ?? 0.0
                    let maxDelay = pulseObj?["max_delay"]?.doubleValue ?? 0.0
                    let hwObj = val["hw"]
                    let driver = hwObj?["driver"]?.stringValue
                    let pin = hwObj?["pin"]?.stringValue ?? hwObj?["pin"]?.intValue.map(String.init)
                    parsedOutputSchemes[ch] = ChannelScheme(
                        channel: ch,
                        switchEnabled: switchCap,
                        pulseDelay: delay,
                        minDelay: minDelay,
                        maxDelay: maxDelay,
                        driver: driver,
                        pin: pin
                    )
                }
            }
        }

        var parsedInputs: [String: ChannelRuntimeState] = [:]
        var parsedOutputs: [String: ChannelRuntimeState] = [:]

        if let inputsObj = stateObj?["inputs"], case .object(let ins) = inputsObj {
            for (ch, val) in ins {
                parsedInputNames.insert(ch)
                parsedInputs[ch] = ChannelRuntimeState(
                    online: val["online"]?.boolValue ?? false,
                    state: val["state"]?.boolValue ?? false,
                    busy: val["busy"]?.boolValue ?? false
                )
            }
        }

        if let outputsObj = stateObj?["outputs"], case .object(let outs) = outputsObj {
            for (ch, val) in outs {
                parsedOutputs[ch] = ChannelRuntimeState(
                    online: val["online"]?.boolValue ?? false,
                    state: val["state"]?.boolValue ?? false,
                    busy: val["busy"]?.boolValue ?? false
                )
                if parsedOutputSchemes[ch] == nil {
                    parsedOutputSchemes[ch] = ChannelScheme(
                        channel: ch,
                        switchEnabled: true,
                        pulseDelay: 0.1,
                        minDelay: 0.1,
                        maxDelay: 5.0,
                        driver: nil,
                        pin: nil
                    )
                }
            }
        }

        self.inputChannels = parsedInputNames.sorted()
        self.outputSchemes = parsedOutputSchemes
        self.inputs = parsedInputs
        self.outputs = parsedOutputs
    }
}

// MARK: - PiKVM Switch Models (/api/switch)

struct GLKVMSwitchState: Decodable, Hashable {
    struct PortConfig: Decodable, Hashable, Identifiable {
        var id: String { port }
        let port: String
        let name: String
        let edidId: String?
        let dummy: Bool
        let beacon: Bool
    }

    let enabled: Bool
    let activePort: String?
    let ports: [PortConfig]
    let edids: [String: String]
    let raw: GLKVMJSONObject

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        let rawObj = (try? single.decode(GLKVMJSONObject.self)) ?? [:]
        self.raw = rawObj

        self.enabled = rawObj["enabled"]?.boolValue ?? (!rawObj.isEmpty)
        if let activeInt = rawObj["active_port"]?.intValue ?? rawObj["active"]?.intValue {
            self.activePort = String(activeInt)
        } else if let activeStr = rawObj["active_port"]?.stringValue ?? rawObj["active"]?.stringValue {
            self.activePort = activeStr
        } else {
            self.activePort = nil
        }

        var parsedPorts: [PortConfig] = []
        if let portsVal = rawObj["ports"] {
            if case .object(let dict) = portsVal {
                for (key, val) in dict {
                    parsedPorts.append(
                        PortConfig(
                            port: key,
                            name: val["name"]?.stringValue ?? "Port \(key)",
                            edidId: val["edid_id"]?.stringValue,
                            dummy: val["dummy"]?.boolValue ?? false,
                            beacon: val["beacon"]?.boolValue ?? false
                        )
                    )
                }
            } else if case .array(let arr) = portsVal {
                for (idx, val) in arr.enumerated() {
                    let portId = val["port"]?.stringValue ?? val["id"]?.stringValue ?? String(idx)
                    parsedPorts.append(
                        PortConfig(
                            port: portId,
                            name: val["name"]?.stringValue ?? "Port \(portId)",
                            edidId: val["edid_id"]?.stringValue,
                            dummy: val["dummy"]?.boolValue ?? false,
                            beacon: val["beacon"]?.boolValue ?? false
                        )
                    )
                }
            }
        }
        self.ports = parsedPorts.sorted { $0.port.localizedStandardCompare($1.port) == .orderedAscending }

        var parsedEdids: [String: String] = [:]
        if let edidsVal = rawObj["edids"], case .object(let dict) = edidsVal {
            for (id, val) in dict {
                parsedEdids[id] = val["name"]?.stringValue ?? id
            }
        }
        self.edids = parsedEdids
    }
}

// MARK: - Redfish Models (/redfish/v1)

struct GLKVMRedfishSystem: Decodable, Hashable {
    let id: String?
    let hostName: String?
    let powerState: String?
    let allowableResetTypes: [String]

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case hostName = "HostName"
        case powerState = "PowerState"
        case actions = "Actions"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decode(String.self, forKey: .id)
        hostName = try? container.decode(String.self, forKey: .hostName)
        powerState = try? container.decode(String.self, forKey: .powerState)

        var resetTypes: [String] = []
        if let actions = try? container.decode(GLKVMJSONObject.self, forKey: .actions),
           let resetObj = actions["#ComputerSystem.Reset"],
           case .array(let arr) = resetObj["ResetType@Redfish.AllowableValues"] {
            resetTypes = arr.compactMap(\.stringValue)
        }
        allowableResetTypes = resetTypes.isEmpty
            ? ["On", "ForceOff", "GracefulShutdown", "ForceRestart", "ForceOn", "PushPowerButton"]
            : resetTypes
    }
}

struct GLKVMRedfishVirtualMedia: Decodable, Hashable {
    let id: String?
    let name: String?
    let image: String?
    let imageName: String?
    let inserted: Bool
    let writeProtected: Bool
    let mediaTypes: [String]

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case image = "Image"
        case imageName = "ImageName"
        case inserted = "Inserted"
        case writeProtected = "WriteProtected"
        case mediaTypes = "MediaTypes"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decode(String.self, forKey: .id)
        name = try? container.decode(String.self, forKey: .name)
        image = try? container.decode(String.self, forKey: .image)
        imageName = try? container.decode(String.self, forKey: .imageName)
        inserted = (try? container.decode(Bool.self, forKey: .inserted)) ?? false
        writeProtected = (try? container.decode(Bool.self, forKey: .writeProtected)) ?? true
        mediaTypes = (try? container.decode([String].self, forKey: .mediaTypes)) ?? []
    }
}

// MARK: - TOTP / 2FA Helper (RFC 6238)

enum GLKVMTOTPGenerator {
    /// Generates a 6-digit TOTP code from a Base32-encoded secret (e.g. from `/etc/kvmd/totp.secret`).
    static func generateCode(base32Secret: String, date: Date = Date(), period: TimeInterval = 30, digits: Int = 6) -> String? {
        guard let keyData = decodeBase32(base32Secret), !keyData.isEmpty else { return nil }
        let counter = UInt64(floor(date.timeIntervalSince1970 / period))
        var bigEndianCounter = counter.bigEndian
        let counterData = Data(bytes: &bigEndianCounter, count: MemoryLayout<UInt64>.size)

        let key = SymmetricKey(data: keyData)
        let hmac = HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: key)
        let hashBytes = Array(hmac)
        guard let lastByte = hashBytes.last else { return nil }
        let offset = Int(lastByte & 0x0f)
        guard offset + 3 < hashBytes.count else { return nil }

        let truncatedHash =
            (UInt32(hashBytes[offset] & 0x7f) << 24) |
            (UInt32(hashBytes[offset + 1]) << 16) |
            (UInt32(hashBytes[offset + 2]) << 8) |
            UInt32(hashBytes[offset + 3])

        var modulus: UInt32 = 1
        for _ in 0..<digits { modulus *= 10 }
        let otp = truncatedHash % modulus
        return String(format: "%0\(digits)u", otp)
    }

    /// Seconds remaining in the current TOTP window (`1...30`).
    static func remainingSeconds(date: Date = Date(), period: Int = 30) -> Int {
        let now = Int(date.timeIntervalSince1970)
        return period - (now % period)
    }

    /// Resolves either a 6-digit OTP code or a Base32 TOTP secret into a 6-digit code.
    static func resolveTwoFactorCode(_ input: String?, date: Date = Date()) -> String {
        guard let raw = input?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return ""
        }
        let stripped = raw.replacingOccurrences(of: " ", with: "")
        if stripped.count == 6, stripped.allSatisfy(\.isNumber) {
            return stripped
        }
        return generateCode(base32Secret: stripped, date: date) ?? stripped
    }

    private static func decodeBase32(_ input: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var lookup: [Character: UInt8] = [:]
        for (i, ch) in alphabet.enumerated() {
            lookup[ch] = UInt8(i)
        }

        let cleaned = input
            .uppercased()
            .filter { !$0.isWhitespace && $0 != "=" && $0 != "-" }
        guard !cleaned.isEmpty else { return nil }

        var buffer: UInt32 = 0
        var bitsLeft = 0
        var output = Data()

        for ch in cleaned {
            guard let val = lookup[ch] else { return nil }
            buffer = (buffer << 5) | UInt32(val)
            bitsLeft += 5
            if bitsLeft >= 8 {
                bitsLeft -= 8
                let byte = UInt8((buffer >> bitsLeft) & 0xff)
                output.append(byte)
            }
        }
        return output
    }
}

// MARK: - WebSocket Models

struct GLKVMWebSocketEvent: Decodable, Hashable {
    let eventType: String
    let event: JSONValue?
    /// For a `pong`: the time since the ping it answers, measured by the socket that sent it.
    var roundTripMs: Int? = nil

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case event
    }
}

struct GLKVMWebSocketSend: Encodable {
    let eventType: String
    let event: JSONValue

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case event
    }
}

struct GLKVMAuthLoginResult: Decodable {
    let token: String?

    enum CodingKeys: String, CodingKey {
        case token
        case authToken = "auth_token"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decodeIfPresent(String.self, forKey: .token)
            ?? container.decodeIfPresent(String.self, forKey: .authToken)
    }
}

// MARK: - GLKVMClient

final class GLKVMClient {
    enum ClientError: Error {
        case invalidBaseURL
        case invalidURL
        case httpError(statusCode: Int, body: String?)
        case decodingFailed
    }

    enum InfoField: String, CaseIterable {
        case auth
        case extras
        case fan
        case hw
        case meta
        case system
    }

    let baseURL: URL
    var authToken: String?
    /// Optional single-request header credentials (`X-KVMD-User` / `X-KVMD-Passwd`) for PiKVM endpoints when session cookie is not active.
    var kvmdUser: String?
    var kvmdPasswd: String?

    private let session: URLSession

    init(host: String, port: Int = 443, authToken: String? = nil) throws {
        let scheme = Self.defaultHTTPScheme(for: port)
        guard let url = URL(string: "\(scheme)://\(host):\(port)") else {
            throw ClientError.invalidBaseURL
        }

        self.baseURL = url
        self.authToken = authToken

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60

        // Self-signed device certificates are pinned on first use; see DeviceTrustStore.
        self.session = URLSession(configuration: config, delegate: DeviceTrustSessionDelegate(), delegateQueue: nil)
    }

    static func defaultHTTPScheme(for port: Int) -> String {
        switch port {
        case 80, 8080:
            return "http"
        default:
            return "https"
        }
    }

    static func defaultWebSocketScheme(for port: Int) -> String {
        defaultHTTPScheme(for: port) == "https" ? "wss" : "ws"
    }

    convenience init(device: KVMDevice) throws {
        try self.init(host: device.host, port: device.port, authToken: device.authToken.isEmpty ? nil : device.authToken)
    }

    private func makeURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ClientError.invalidURL
        }

        components.path = "/" + trimmed
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw ClientError.invalidURL
        }

        return url
    }

    private func applyAuthenticationHeaders(to request: inout URLRequest) {
        if let authToken, !authToken.isEmpty {
            request.setValue("auth_token=\(authToken)", forHTTPHeaderField: "Cookie")
        } else if let kvmdUser, let kvmdPasswd, !kvmdUser.isEmpty {
            request.setValue(kvmdUser, forHTTPHeaderField: "X-KVMD-User")
            request.setValue(kvmdPasswd, forHTTPHeaderField: "X-KVMD-Passwd")
        }
    }

    private func request<Response: Decodable>(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil,
        responseType: Response.Type
    ) async throws -> Response {
        let url = try makeURL(path: path, queryItems: query)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body

        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        applyAuthenticationHeaders(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.decodingFailed
        }

        guard (200...299).contains(http.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8)
            var errorMessage: String? = nil
            if let wrapped = try? JSONDecoder().decode(GLKVMResponse<GLKVMJSONObject>.self, from: data) {
                if case .string(let s) = wrapped.result["error_msg"] {
                    errorMessage = s
                } else if case .string(let s) = wrapped.result["message"] {
                    errorMessage = s
                } else if case .string(let s) = wrapped.result["error"] {
                    errorMessage = s
                }
            }
            throw ClientError.httpError(statusCode: http.statusCode, body: errorMessage ?? bodyString)
        }

        let decoder = JSONDecoder()
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            let preview = String(data: data.prefix(512), encoding: .utf8) ?? "<binary \(data.count)B>"
            NSLog("[Overlook glkvm] decode failed for %@ (status=%d): %@ | body: %@", url.absoluteString, http.statusCode, "\(error)", preview)
            throw ClientError.decodingFailed
        }
    }

    // MARK: - Auth API (/api/auth/*)

    func isInited() async throws -> GLKVMInitStatus {
        let response = try await request(
            method: "GET",
            path: "api/init/is_inited",
            responseType: GLKVMResponse<GLKVMInitStatus>.self
        )

        return response.result
    }

    func authCheck() async throws {
        _ = try await request(
            method: "GET",
            path: "api/auth/check",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    /// Authenticates with PiKVM / GLKVM. If 2FA (`twoFactorCodeOrSecret`) is provided, the 6-digit
    /// TOTP code is appended to the password without spaces as specified by the PiKVM API.
    func authLogin(user: String = "admin", password: String, twoFactorCodeOrSecret: String? = nil) async throws -> String {
        // If a Base32 TOTP secret is used and less than 2 seconds remain in the window, wait briefly
        // so the generated code does not expire mid-flight (per PiKVM API best practices).
        if let raw2FA = twoFactorCodeOrSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw2FA.isEmpty,
           raw2FA.count > 6,
           GLKVMTOTPGenerator.remainingSeconds() <= 2 {
            try? await Task.sleep(nanoseconds: 2_100_000_000)
        }

        let totpSuffix = GLKVMTOTPGenerator.resolveTwoFactorCode(twoFactorCodeOrSecret)
        let combinedPassword = password + totpSuffix

        let boundary = "----OverlookBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
        body.append("Content-Disposition: form-data; name=\"user\"\r\n\r\n".data(using: .utf8) ?? Data())
        body.append("\(user)\r\n".data(using: .utf8) ?? Data())
        body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
        body.append("Content-Disposition: form-data; name=\"passwd\"\r\n\r\n".data(using: .utf8) ?? Data())
        body.append("\(combinedPassword)\r\n".data(using: .utf8) ?? Data())
        body.append("--\(boundary)--\r\n".data(using: .utf8) ?? Data())

        let url = try makeURL(path: "api/auth/login")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.decodingFailed
        }

        guard (200...299).contains(http.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8)
            throw ClientError.httpError(statusCode: http.statusCode, body: bodyString)
        }

        if let wrapped = try? JSONDecoder().decode(GLKVMResponse<GLKVMAuthLoginResult>.self, from: data) {
            if let token = wrapped.result.token, !token.isEmpty {
                return token
            }
            if wrapped.ok == false {
                let bodyString = String(data: data, encoding: .utf8)
                throw ClientError.httpError(statusCode: http.statusCode, body: bodyString)
            }
        }

        if let token = authTokenFromSetCookieHeaders(in: http, for: url) {
            return token
        }

        let preview = String(data: data.prefix(512), encoding: .utf8) ?? "<binary \(data.count)B>"
        NSLog("[Overlook glkvm] login succeeded but no auth token was found. body: %@", preview)
        throw ClientError.decodingFailed
    }

    /// Invalidates the current session token (`POST /api/auth/logout`).
    func authLogout() async throws {
        _ = try await request(
            method: "POST",
            path: "api/auth/logout",
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
        authToken = nil
    }

    // MARK: - System Functions (/api/info, /api/log, /api/system/*, /api/export/prometheus/metrics)

    /// Returns general information about the PiKVM / GLKVM device (`GET /api/info`).
    func getSystemInfo(fields: [InfoField] = []) async throws -> GLKVMSystemInfo {
        var query: [URLQueryItem] = []
        if !fields.isEmpty {
            query.append(URLQueryItem(name: "fields", value: fields.map(\.rawValue).joined(separator: ",")))
        }
        let response = try await request(
            method: "GET",
            path: "api/info",
            query: query,
            responseType: GLKVMResponse<GLKVMSystemInfo>.self
        )
        return response.result
    }

    /// Returns plain-text service logs from all KVMD services (`GET /api/log`).
    func getSystemLog(seekSeconds: Int = 3600, follow: Bool = false) async throws -> String {
        let query = [
            URLQueryItem(name: "seek", value: String(max(0, seekSeconds))),
            URLQueryItem(name: "follow", value: follow ? "1" : "0"),
        ]
        let data = try await requestData(
            method: "GET",
            path: "api/log",
            query: query
        )
        return String(decoding: data, as: UTF8.self)
    }

    /// Returns Prometheus metrics exported by the KVM (`GET /api/export/prometheus/metrics`).
    func getPrometheusMetrics() async throws -> String {
        let data = try await requestData(
            method: "GET",
            path: "api/export/prometheus/metrics"
        )
        return String(decoding: data, as: UTF8.self)
    }

    func getSystemConfig() async throws -> GLKVMSystemConfig {
        let response = try await request(
            method: "GET",
            path: "api/system/get_config",
            responseType: GLKVMResponse<GLKVMSystemGetConfigResult>.self
        )

        return response.result.config
    }

    func setSystemConfig(_ config: GLKVMSystemConfig) async throws -> GLKVMSystemConfig {
        let encoder = JSONEncoder()
        let body = try encoder.encode(config)

        let response = try await request(
            method: "POST",
            path: "api/system/set_config",
            body: body,
            contentType: "application/json",
            responseType: GLKVMResponse<GLKVMSystemGetConfigResult>.self
        )

        return response.result.config
    }

    // MARK: - Network Config (/api/network/*)

    func getNetworkConfig() async throws -> GLKVMNetworkConfig {
        let response = try await request(
            method: "GET",
            path: "api/network/config",
            responseType: GLKVMResponse<GLKVMNetworkConfig>.self
        )
        return response.result
    }

    func setNetworkConfig(_ config: GLKVMNetworkConfig) async throws -> GLKVMNetworkConfig {
        let encoder = JSONEncoder()
        let body = try encoder.encode(config)
        let response = try await request(
            method: "POST",
            path: "api/network/config",
            body: body,
            contentType: "application/json",
            responseType: GLKVMResponse<GLKVMNetworkConfig>.self
        )
        return response.result
    }

    func getWifiConfig() async throws -> GLKVMWifiConfig {
        let response = try await request(
            method: "GET",
            path: "api/network/wifi",
            responseType: GLKVMResponse<GLKVMWifiConfig>.self
        )
        return response.result
    }

    func setWifiConfig(_ config: GLKVMWifiConfig) async throws -> GLKVMWifiConfig {
        let encoder = JSONEncoder()
        let body = try encoder.encode(config)
        let response = try await request(
            method: "POST",
            path: "api/network/wifi",
            body: body,
            contentType: "application/json",
            responseType: GLKVMResponse<GLKVMWifiConfig>.self
        )
        return response.result
    }

    func getEthernetConfig() async throws -> GLKVMEthernetConfig {
        let response = try await request(
            method: "GET",
            path: "api/network/ethernet",
            responseType: GLKVMResponse<GLKVMEthernetConfig>.self
        )
        return response.result
    }

    // MARK: - Streamer (/api/streamer/*)

    func getStreamerState() async throws -> GLKVMStreamerState {
        let response = try await request(
            method: "GET",
            path: "api/streamer",
            responseType: GLKVMResponse<GLKVMStreamerState>.self
        )
        return response.result
    }

    func setStreamerParams(_ params: [String: String]) async throws {
        let queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        _ = try await request(
            method: "POST",
            path: "api/streamer/set_params",
            query: queryItems,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    /// Captures a JPEG snapshot from the video streamer (`GET /api/streamer/snapshot`).
    func getStreamerSnapshot(
        save: Bool = false,
        load: Bool = false,
        allowOffline: Bool = false,
        preview: Bool = false,
        previewMaxWidth: Int? = nil,
        previewMaxHeight: Int? = nil,
        previewQuality: Int? = nil
    ) async throws -> Data {
        var query: [URLQueryItem] = []
        if save { query.append(URLQueryItem(name: "save", value: "1")) }
        if load { query.append(URLQueryItem(name: "load", value: "1")) }
        if allowOffline { query.append(URLQueryItem(name: "allow_offline", value: "1")) }
        if preview { query.append(URLQueryItem(name: "preview", value: "1")) }
        if let previewMaxWidth { query.append(URLQueryItem(name: "preview_max_width", value: String(previewMaxWidth))) }
        if let previewMaxHeight { query.append(URLQueryItem(name: "preview_max_height", value: String(previewMaxHeight))) }
        if let previewQuality { query.append(URLQueryItem(name: "preview_quality", value: String(previewQuality))) }

        return try await requestData(
            method: "GET",
            path: "api/streamer/snapshot",
            query: query
        )
    }

    /// Performs server-side Tesseract OCR on a streamer snapshot (`GET /api/streamer/snapshot?ocr=true`).
    func performStreamerOCR(
        langs: [String] = ["eng"],
        left: Int? = nil,
        top: Int? = nil,
        right: Int? = nil,
        bottom: Int? = nil
    ) async throws -> String {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "ocr", value: "true"),
        ]
        if !langs.isEmpty {
            query.append(URLQueryItem(name: "ocr_langs", value: langs.joined(separator: ",")))
        }
        if let left, left >= 0 { query.append(URLQueryItem(name: "ocr_left", value: String(left))) }
        if let top, top >= 0 { query.append(URLQueryItem(name: "ocr_top", value: String(top))) }
        if let right, right >= 0 { query.append(URLQueryItem(name: "ocr_right", value: String(right))) }
        if let bottom, bottom >= 0 { query.append(URLQueryItem(name: "ocr_bottom", value: String(bottom))) }

        let data = try await requestData(
            method: "GET",
            path: "api/streamer/snapshot",
            query: query
        )
        return String(decoding: data, as: UTF8.self)
    }

    /// Removes/deletes the saved snapshot from memory (`DELETE /api/streamer/snapshot`).
    func deleteStreamerSnapshot() async throws {
        _ = try await request(
            method: "DELETE",
            path: "api/streamer/snapshot",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    /// Retrieves the state and available languages of the PiKVM OCR service (`GET /api/streamer/ocr`).
    func getStreamerOcrState() async throws -> GLKVMStreamerOcrState {
        let response = try await request(
            method: "GET",
            path: "api/streamer/ocr",
            responseType: GLKVMResponse<GLKVMStreamerOcrState>.self
        )
        return response.result
    }

    func setHIDParams(_ params: [String: String]) async throws {
        let queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        _ = try await request(
            method: "POST",
            path: "api/hid/set_params",
            query: queryItems,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func getTurnCredentials() async throws -> GLKVMTurnCredentials {
        let response = try await request(
            method: "GET",
            path: "api/turn/get_turn",
            responseType: GLKVMResponse<GLKVMTurnCredentials>.self
        )

        return response.result
    }

    func websocketURL(stream: Bool = true) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ClientError.invalidURL
        }
        components.scheme = baseURL.scheme == "http" ? "ws" : "wss"
        components.path = "/api/ws"
        if !stream {
            components.queryItems = [URLQueryItem(name: "stream", value: "0")]
        }
        guard let url = components.url else {
            throw ClientError.invalidURL
        }
        return url
    }

    func mediaWebsocketURL() throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ClientError.invalidURL
        }
        components.scheme = baseURL.scheme == "http" ? "ws" : "wss"
        components.path = "/api/media/ws"
        guard let url = components.url else {
            throw ClientError.invalidURL
        }
        return url
    }
}

private func authTokenFromSetCookieHeaders(in response: HTTPURLResponse, for url: URL) -> String? {
    var headerFields: [String: String] = [:]
    for (key, value) in response.allHeaderFields {
        headerFields[String(describing: key)] = String(describing: value)
    }

    return HTTPCookie
        .cookies(withResponseHeaderFields: headerFields, for: url)
        .first(where: { $0.name == "auth_token" })?
        .value
}

extension GLKVMClient.ClientError: CustomStringConvertible, LocalizedError {
    var description: String {
        switch self {
        case .invalidBaseURL:
            return "invalidBaseURL"
        case .invalidURL:
            return "invalidURL"
        case .decodingFailed:
            return "decodingFailed"
        case .httpError(let statusCode, let body):
            if let body, !body.isEmpty {
                return "httpError(\(statusCode)): \(body)"
            }
            return "httpError(\(statusCode))"
        }
    }

    var errorDescription: String? { description }
}

extension GLKVMClient {
    fileprivate func requestData(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> Data {
        let url = try makeURL(path: path, queryItems: query)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body

        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        applyAuthenticationHeaders(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.decodingFailed
        }

        guard (200...299).contains(http.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8)
            var errorMessage: String? = nil
            if let wrapped = try? JSONDecoder().decode(GLKVMResponse<GLKVMJSONObject>.self, from: data) {
                if case .string(let s) = wrapped.result["error_msg"] {
                    errorMessage = s
                } else if case .string(let s) = wrapped.result["message"] {
                    errorMessage = s
                } else if case .string(let s) = wrapped.result["error"] {
                    errorMessage = s
                }
            }
            throw ClientError.httpError(statusCode: http.statusCode, body: errorMessage ?? bodyString)
        }

        return data
    }
}

extension GLKVMClient {
    func getEDID() async throws -> String {
        let data = try await requestData(
            method: "GET",
            path: "api/upgrade/get_edid"
        )

        let decoder = JSONDecoder()

        if let wrapped = try? decoder.decode(GLKVMResponse<String>.self, from: data) {
            return wrapped.result
        }

        if let wrapped = try? decoder.decode(GLKVMResponse<GLKVMJSONObject>.self, from: data) {
            if case .string(let s) = wrapped.result["edid"] {
                return s
            }
            if case .string(let s) = wrapped.result["EDID"] {
                return s
            }
        }

        if let s = String(data: data, encoding: .utf8) {
            return s
        }

        throw ClientError.decodingFailed
    }

    func setEDID(_ edid: String) async throws {
        let boundary = "----geckoformboundary\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
        body.append("Content-Disposition: form-data; name=\"edid\"\r\n\r\n".data(using: .utf8) ?? Data())
        body.append("\(edid)\r\n".data(using: .utf8) ?? Data())
        body.append("--\(boundary)--\r\n".data(using: .utf8) ?? Data())

        _ = try await requestData(
            method: "POST",
            path: "api/upgrade/edid",
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
    }
}

// MARK: - HID API (/api/hid/*)

extension GLKVMClient {
    func getHidState() async throws -> GLKVMHidState {
        let response = try await request(
            method: "GET",
            path: "api/hid",
            responseType: GLKVMResponse<GLKVMHidState>.self
        )
        return response.result
    }

    func setHidConnected(_ connected: Bool) async throws {
        _ = try await request(
            method: "POST",
            path: "api/hid/set_connected",
            query: [URLQueryItem(name: "connected", value: connected ? "true" : "false")],
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func resetHid() async throws {
        _ = try await request(
            method: "POST",
            path: "api/hid/reset",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func getHidKeymaps() async throws -> GLKVMHidKeymapsState {
        let response = try await request(
            method: "GET",
            path: "api/hid/keymaps",
            responseType: GLKVMResponse<GLKVMHidKeymapsState>.self
        )
        return response.result
    }

    func hidPrint(
        text: String,
        keymap: String? = nil,
        limit: Int? = nil,
        slow: Bool? = nil,
        delay: Double? = nil
    ) async throws {
        var query: [URLQueryItem] = []
        if let keymap, !keymap.isEmpty {
            query.append(URLQueryItem(name: "keymap", value: keymap))
        }
        if let limit {
            query.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if let slow {
            query.append(URLQueryItem(name: "slow", value: slow ? "true" : "false"))
        }
        if let delay {
            let clampedDelay = max(0.0, min(5.0, delay))
            query.append(URLQueryItem(name: "delay", value: String(format: "%.3f", clampedDelay)))
        }
        let body = text.data(using: .utf8) ?? Data()
        _ = try await request(
            method: "POST",
            path: "api/hid/print",
            query: query,
            body: body,
            contentType: "text/plain; charset=utf-8",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func sendHidShortcut(keys: [String]) async throws {
        _ = try await request(
            method: "POST",
            path: "api/hid/events/send_shortcut",
            query: [URLQueryItem(name: "keys", value: keys.joined(separator: ","))],
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func sendHidKey(key: String, state: Bool? = nil, finish: Bool? = nil) async throws {
        var query: [URLQueryItem] = [URLQueryItem(name: "key", value: key)]
        if let state {
            query.append(URLQueryItem(name: "state", value: state ? "true" : "false"))
        }
        if let finish {
            query.append(URLQueryItem(name: "finish", value: finish ? "true" : "false"))
        }
        _ = try await request(
            method: "POST",
            path: "api/hid/events/send_key",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func sendHidMouseButton(button: String, state: Bool? = nil) async throws {
        var query: [URLQueryItem] = [URLQueryItem(name: "button", value: button)]
        if let state {
            query.append(URLQueryItem(name: "state", value: state ? "true" : "false"))
        }
        _ = try await request(
            method: "POST",
            path: "api/hid/events/send_mouse_button",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func sendHidMouseMove(toX: Int, toY: Int) async throws {
        _ = try await request(
            method: "POST",
            path: "api/hid/events/send_mouse_move",
            query: [
                URLQueryItem(name: "to_x", value: String(toX)),
                URLQueryItem(name: "to_y", value: String(toY)),
            ],
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func sendHidMouseRelative(deltaX: Int, deltaY: Int) async throws {
        _ = try await request(
            method: "POST",
            path: "api/hid/events/send_mouse_relative",
            query: [
                URLQueryItem(name: "delta_x", value: String(deltaX)),
                URLQueryItem(name: "delta_y", value: String(deltaY)),
            ],
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func sendHidMouseWheel(deltaX: Int, deltaY: Int) async throws {
        _ = try await request(
            method: "POST",
            path: "api/hid/events/send_mouse_wheel",
            query: [
                URLQueryItem(name: "delta_x", value: String(deltaX)),
                URLQueryItem(name: "delta_y", value: String(deltaY)),
            ],
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }
}

// MARK: - Mass Storage Drive API (/api/msd/*)

extension GLKVMClient {
    func getMsdState() async throws -> GLKVMMsdState {
        let response = try await request(
            method: "GET",
            path: "api/msd",
            responseType: GLKVMResponse<GLKVMMsdState>.self
        )
        return response.result
    }

    func getMsdRawState() async throws -> GLKVMJSONObject {
        let response = try await request(
            method: "GET",
            path: "api/msd",
            responseType: GLKVMResponse<GLKVMJSONObject>.self
        )
        return response.result
    }

    func setMsdParams(
        image: String? = nil,
        cdrom: Bool? = nil,
        rw: Bool? = nil,
        user: String? = nil,
        passwd: String? = nil,
        verify: Bool? = nil
    ) async throws {
        var query: [URLQueryItem] = []
        if let image {
            query.append(URLQueryItem(name: "image", value: image))
        }
        if let cdrom {
            query.append(URLQueryItem(name: "cdrom", value: cdrom ? "1" : "0"))
        }
        if let rw {
            query.append(URLQueryItem(name: "rw", value: rw ? "1" : "0"))
        }
        if let user, !user.isEmpty {
            query.append(URLQueryItem(name: "user", value: user))
        }
        if let passwd, !passwd.isEmpty {
            query.append(URLQueryItem(name: "passwd", value: passwd))
        }
        if let verify {
            query.append(URLQueryItem(name: "verify", value: verify ? "true" : "false"))
        }
        _ = try await request(
            method: "POST",
            path: "api/msd/set_params",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func setMsdConnected(_ connected: Bool) async throws {
        _ = try await request(
            method: "POST",
            path: "api/msd/set_connected",
            query: [URLQueryItem(name: "connected", value: connected ? "1" : "0")],
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func msdPartitionShow() async throws -> GLKVMMSDPartitionShowResult {
        let response = try await request(
            method: "GET",
            path: "api/msd/partition_show",
            responseType: GLKVMResponse<GLKVMMSDPartitionShowResult>.self
        )
        return response.result
    }

    func msdPartitionConnect() async throws {
        _ = try await request(
            method: "GET",
            path: "api/msd/partition_connect",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func msdPartitionDisconnect() async throws {
        _ = try await request(
            method: "GET",
            path: "api/msd/partition_disconnect",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func msdPartitionFormat(path: String) async throws {
        _ = try await request(
            method: "GET",
            path: "api/msd/partition_format",
            query: [URLQueryItem(name: "path", value: path)],
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func msdRead(image: String, compress: String? = nil) async throws -> Data {
        var query: [URLQueryItem] = [URLQueryItem(name: "image", value: image)]
        if let compress {
            query.append(URLQueryItem(name: "compress", value: compress))
        }
        return try await requestData(
            method: "GET",
            path: "api/msd/read",
            query: query
        )
    }

    @discardableResult
    func msdWrite(image: String, data: Data, prefix: String? = nil, removeIncomplete: Bool? = nil) async throws -> GLKVMMSDWriteResult? {
        var query: [URLQueryItem] = [URLQueryItem(name: "image", value: image)]
        if let prefix {
            query.append(URLQueryItem(name: "prefix", value: prefix))
        }
        if let removeIncomplete {
            query.append(URLQueryItem(name: "remove_incomplete", value: removeIncomplete ? "true" : "false"))
        }
        let responseData = try await requestData(
            method: "POST",
            path: "api/msd/write",
            query: query,
            body: data,
            contentType: "application/octet-stream"
        )
        if let wrapped = try? JSONDecoder().decode(GLKVMResponse<GLKVMMSDWriteResult>.self, from: responseData) {
            return wrapped.result
        }
        return nil
    }

    @discardableResult
    func msdWriteRemote(
        url: URL,
        image: String? = nil,
        prefix: String? = nil,
        insecure: Bool? = nil,
        timeout: Double? = nil,
        removeIncomplete: Bool? = nil
    ) async throws -> [GLKVMMSDWriteResult] {
        var query: [URLQueryItem] = [URLQueryItem(name: "url", value: url.absoluteString)]
        if let image, !image.isEmpty {
            query.append(URLQueryItem(name: "image", value: image))
        }
        if let prefix {
            query.append(URLQueryItem(name: "prefix", value: prefix))
        }
        if let insecure {
            query.append(URLQueryItem(name: "insecure", value: insecure ? "true" : "false"))
        }
        if let timeout {
            query.append(URLQueryItem(name: "timeout", value: String(Int(timeout))))
        }
        if let removeIncomplete {
            query.append(URLQueryItem(name: "remove_incomplete", value: removeIncomplete ? "true" : "false"))
        }

        let data = try await requestData(
            method: "POST",
            path: "api/msd/write_remote",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded"
        )

        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline)
        let decoder = JSONDecoder()

        var results: [GLKVMMSDWriteResult] = []
        results.reserveCapacity(lines.count)

        for line in lines {
            let lineData = Data(line.utf8)
            if let wrapped = try? decoder.decode(GLKVMResponse<GLKVMMSDWriteResult>.self, from: lineData) {
                results.append(wrapped.result)
                continue
            }
            if let unwrapped = try? decoder.decode(GLKVMMSDWriteResult.self, from: lineData) {
                results.append(unwrapped)
                continue
            }
        }

        return results
    }

    func msdRemove(image: String) async throws {
        _ = try await request(
            method: "POST",
            path: "api/msd/remove",
            query: [URLQueryItem(name: "image", value: image)],
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func msdReset() async throws {
        _ = try await request(
            method: "POST",
            path: "api/msd/reset",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }
}

// MARK: - ATX Power API (/api/atx/*)

extension GLKVMClient {
    enum AtxPowerAction: String, CaseIterable {
        case on
        case off
        case offHard = "off_hard"
        case resetHard = "reset_hard"

        var displayName: String {
            switch self {
            case .on: return "Power On"
            case .off: return "Graceful Off"
            case .offHard: return "Hard Off"
            case .resetHard: return "Hard Reset"
            }
        }
    }

    enum AtxButton: String, CaseIterable {
        case power
        case powerLong = "power_long"
        case reset

        var displayName: String {
            switch self {
            case .power: return "Click Power"
            case .powerLong: return "Hold Power (5s+)"
            case .reset: return "Click Reset"
            }
        }
    }

    func getAtxState() async throws -> GLKVMAtxState {
        let response = try await request(
            method: "GET",
            path: "api/atx",
            responseType: GLKVMResponse<GLKVMAtxState>.self
        )
        return response.result
    }

    func atxPower(_ action: AtxPowerAction, wait: Bool? = nil) async throws {
        var query: [URLQueryItem] = [URLQueryItem(name: "action", value: action.rawValue)]
        if let wait {
            query.append(URLQueryItem(name: "wait", value: wait ? "true" : "false"))
        }
        _ = try await request(
            method: "POST",
            path: "api/atx/power",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func atxClick(_ button: AtxButton, wait: Bool? = nil) async throws {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "button", value: button.rawValue),
        ]
        if let wait {
            query.append(URLQueryItem(name: "wait", value: wait ? "true" : "false"))
        }
        _ = try await request(
            method: "POST",
            path: "api/atx/click",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }
}

// MARK: - GPIO API (/api/gpio/*)

extension GLKVMClient {
    func getGpioState() async throws -> GLKVMGpioState {
        let response = try await request(
            method: "GET",
            path: "api/gpio",
            responseType: GLKVMResponse<GLKVMGpioState>.self
        )
        return response.result
    }

    func switchGpioChannel(channel: String, state: Bool, wait: Bool? = nil) async throws {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "channel", value: channel),
            URLQueryItem(name: "state", value: state ? "1" : "0"),
        ]
        if let wait {
            query.append(URLQueryItem(name: "wait", value: wait ? "1" : "0"))
        }
        _ = try await request(
            method: "POST",
            path: "api/gpio/switch",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func pulseGpioChannel(channel: String, delay: Double? = nil, wait: Bool? = nil) async throws {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "channel", value: channel),
        ]
        if let delay {
            query.append(URLQueryItem(name: "delay", value: String(delay)))
        }
        if let wait {
            query.append(URLQueryItem(name: "wait", value: wait ? "1" : "0"))
        }
        _ = try await request(
            method: "POST",
            path: "api/gpio/pulse",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }
}

// MARK: - PiKVM Switch API (/api/switch/*)

extension GLKVMClient {
    func getSwitchState() async throws -> GLKVMSwitchState {
        let response = try await request(
            method: "GET",
            path: "api/switch",
            responseType: GLKVMResponse<GLKVMSwitchState>.self
        )
        return response.result
    }

    func switchSetActivePrev() async throws {
        _ = try await request(
            method: "POST",
            path: "api/switch/set_active_prev",
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func switchSetActiveNext() async throws {
        _ = try await request(
            method: "POST",
            path: "api/switch/set_active_next",
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func switchSetActive(port: String) async throws {
        _ = try await request(
            method: "POST",
            path: "api/switch/set_active",
            query: [URLQueryItem(name: "port", value: port)],
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func switchSetBeacon(state: Bool, port: String? = nil, uplink: Int? = nil, downlink: Int? = nil) async throws {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "state", value: state ? "1" : "0"),
        ]
        if let port, !port.isEmpty { query.append(URLQueryItem(name: "port", value: port)) }
        if let uplink { query.append(URLQueryItem(name: "uplink", value: String(uplink))) }
        if let downlink { query.append(URLQueryItem(name: "downlink", value: String(downlink))) }

        _ = try await request(
            method: "POST",
            path: "api/switch/set_beacon",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func switchSetPortParams(
        port: String,
        edidId: String? = nil,
        dummy: Bool? = nil,
        name: String? = nil,
        atxClickPowerDelay: Double? = nil,
        atxClickPowerLongDelay: Double? = nil,
        atxClickResetDelay: Double? = nil
    ) async throws {
        var query: [URLQueryItem] = [URLQueryItem(name: "port", value: port)]
        if let edidId { query.append(URLQueryItem(name: "edid_id", value: edidId)) }
        if let dummy { query.append(URLQueryItem(name: "dummy", value: dummy ? "1" : "0")) }
        if let name { query.append(URLQueryItem(name: "name", value: name)) }
        if let atxClickPowerDelay { query.append(URLQueryItem(name: "atx_click_power_delay", value: String(atxClickPowerDelay))) }
        if let atxClickPowerLongDelay { query.append(URLQueryItem(name: "atx_click_power_long_delay", value: String(atxClickPowerLongDelay))) }
        if let atxClickResetDelay { query.append(URLQueryItem(name: "atx_click_reset_delay", value: String(atxClickResetDelay))) }

        _ = try await request(
            method: "POST",
            path: "api/switch/set_port_params",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    /// Sets beacon color, brightness, and blink interval (`FFA500:BF:0028`) (`POST /api/switch/set_colors`).
    func switchSetColors(beaconHexSpec: String) async throws {
        let query = [URLQueryItem(name: "beacon", value: beaconHexSpec)]
        let body = beaconHexSpec.data(using: .utf8) ?? Data()
        _ = try await request(
            method: "POST",
            path: "api/switch/set_colors",
            query: query,
            body: body,
            contentType: "text/plain; charset=utf-8",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func switchReset(unit: Int, bootloader: Bool = false) async throws {
        let query = [
            URLQueryItem(name: "unit", value: String(max(0, min(4, unit)))),
            URLQueryItem(name: "bootloader", value: bootloader ? "1" : "0"),
        ]
        _ = try await request(
            method: "POST",
            path: "api/switch/reset",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func switchCreateEdid(name: String, dataHex: String) async throws {
        let query = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "data", value: dataHex),
        ]
        _ = try await request(
            method: "POST",
            path: "api/switch/edids/create",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func switchChangeEdid(id: String, name: String? = nil, dataHex: String? = nil) async throws {
        var query = [URLQueryItem(name: "id", value: id)]
        if let name, !name.isEmpty { query.append(URLQueryItem(name: "name", value: name)) }
        if let dataHex, !dataHex.isEmpty { query.append(URLQueryItem(name: "data", value: dataHex)) }
        _ = try await request(
            method: "POST",
            path: "api/switch/edids/change",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func switchRemoveEdid(id: String) async throws {
        let query = [URLQueryItem(name: "id", value: id)]
        _ = try await request(
            method: "POST",
            path: "api/switch/edids/remove",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func switchAtxPower(port: String, action: AtxPowerAction) async throws {
        let query = [
            URLQueryItem(name: "port", value: port),
            URLQueryItem(name: "action", value: action.rawValue),
        ]
        _ = try await request(
            method: "POST",
            path: "api/switch/atx/power",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func switchAtxClick(port: String, button: AtxButton) async throws {
        let query = [
            URLQueryItem(name: "port", value: port),
            URLQueryItem(name: "button", value: button.rawValue),
        ]
        _ = try await request(
            method: "POST",
            path: "api/switch/atx/click",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }
}

// MARK: - Redfish API (/redfish/v1/*)

extension GLKVMClient {
    enum RedfishResetType: String, CaseIterable {
        case on = "On"
        case forceOff = "ForceOff"
        case gracefulShutdown = "GracefulShutdown"
        case forceRestart = "ForceRestart"
        case forceOn = "ForceOn"
        case pushPowerButton = "PushPowerButton"
    }

    func getRedfishSystem(systemId: String = "0") async throws -> GLKVMRedfishSystem {
        let data = try await requestData(
            method: "GET",
            path: "redfish/v1/Systems/\(systemId)"
        )
        return try JSONDecoder().decode(GLKVMRedfishSystem.self, from: data)
    }

    func redfishSystemReset(systemId: String = "0", resetType: RedfishResetType) async throws {
        let payload = ["ResetType": resetType.rawValue]
        let body = try JSONEncoder().encode(payload)
        _ = try await requestData(
            method: "POST",
            path: "redfish/v1/Systems/\(systemId)/Actions/ComputerSystem.Reset",
            body: body,
            contentType: "application/json"
        )
    }

    func getRedfishVirtualMedia() async throws -> GLKVMRedfishVirtualMedia {
        let data = try await requestData(
            method: "GET",
            path: "redfish/v1/Managers/BMC/VirtualMedia/MSD"
        )
        return try JSONDecoder().decode(GLKVMRedfishVirtualMedia.self, from: data)
    }

    func redfishInsertMedia(
        imageURLOrName: String,
        inserted: Bool = true,
        writeProtected: Bool = true,
        userName: String? = nil,
        password: String? = nil,
        verifyCertificate: Bool = true,
        driveOptical: Bool? = nil
    ) async throws {
        var payload: [String: JSONValue] = [
            "Image": .string(imageURLOrName),
            "Inserted": .bool(inserted),
            "WriteProtected": .bool(writeProtected),
            "VerifyCertificate": .bool(verifyCertificate),
        ]
        if let userName, !userName.isEmpty { payload["UserName"] = .string(userName) }
        if let password, !password.isEmpty { payload["Password"] = .string(password) }
        if let driveOptical {
            payload["DriveOptical"] = .object([
                "Oem": .object([
                    "PiKVM": .object([
                        "DriveOptical": .bool(driveOptical)
                    ])
                ])
            ])
        }
        let body = try JSONEncoder().encode(payload)
        _ = try await requestData(
            method: "POST",
            path: "redfish/v1/Managers/BMC/VirtualMedia/MSD/Actions/VirtualMedia.InsertMedia",
            body: body,
            contentType: "application/json"
        )
    }

    func redfishEjectMedia() async throws {
        _ = try await requestData(
            method: "POST",
            path: "redfish/v1/Managers/BMC/VirtualMedia/MSD/Actions/VirtualMedia.EjectMedia",
            body: Data("{}".utf8),
            contentType: "application/json"
        )
    }
}

extension GLKVMClient {
    func resetStreamer() async throws {
        _ = try await request(
            method: "POST",
            path: "api/streamer/reset",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }
}

extension GLKVMClient {
    func makeWebSocketClient(stream: Bool = true) throws -> WebSocketClient {
        let url = try websocketURL(stream: stream)

        var request = URLRequest(url: url)
        applyAuthenticationHeaders(to: &request)

        return WebSocketClient(session: session, request: request)
    }

    actor WebSocketClient {
        enum WebSocketError: Error {
            case notConnected
            case encodingFailed
            case decodingFailed
        }

        nonisolated let events: AsyncStream<GLKVMWebSocketEvent>
        private let continuation: AsyncStream<GLKVMWebSocketEvent>.Continuation

        private let session: URLSession
        private let request: URLRequest

        private var task: URLSessionWebSocketTask?
        private var receiveTask: Task<Void, Never>?
        private var pingTask: Task<Void, Never>?
        /// When the last ping went out; cleared by the pong that answers it.
        private var pingSentAt: ContinuousClock.Instant?
        /// True once a frame has been sent successfully; cleared when the socket drops.
        private(set) var isConnected = false
        private(set) var isConnecting = false

        init(session: URLSession, request: URLRequest) {
            self.session = session
            self.request = request

            var c: AsyncStream<GLKVMWebSocketEvent>.Continuation!
            self.events = AsyncStream { continuation in
                c = continuation
            }
            self.continuation = c
        }

        func connect() {
            guard task == nil else { return }
            let ws = session.webSocketTask(with: request)
            task = ws
            isConnecting = true
            ws.resume()

            receiveTask = Task { [weak self] in
                guard let self else { return }
                await self.receiveLoop()
            }

            pingTask = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { break }
                    do {
                        await self.markPingSent()
                        try await self.send(eventType: "ping")
                    } catch {
                        // A failed ping is how a silently dropped socket is noticed.
                        await self.markDisconnected()
                        break
                    }
                }
            }
        }

        func disconnect() {
            receiveTask?.cancel()
            receiveTask = nil

            pingTask?.cancel()
            pingTask = nil

            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            isConnected = false
            isConnecting = false

            continuation.finish()
        }

        /// Clears the keyboard report and releases every mouse button on the device, so a key or
        /// button that was down when the socket goes away does not stay down on the target.
        func releaseAllHIDInputs() async throws {
            try await sendBinary(Data([0x01, 0x00]))
            try await sendHidMouseButton(button: "left", state: false)
            try await sendHidMouseButton(button: "right", state: false)
            try await sendHidMouseButton(button: "middle", state: false)
        }

        /// A client is single-use: once its socket drops, the event stream ends so the owner
        /// notices (the ping loop is how a silently dead socket is caught), and the owner opens a
        /// fresh client rather than reconnecting this one.
        private func markDisconnected() {
            receiveTask?.cancel()
            receiveTask = nil
            pingTask?.cancel()
            pingTask = nil
            task?.cancel()
            task = nil
            isConnected = false
            isConnecting = false
            continuation.finish()
        }

        private func markPingSent() {
            pingSentAt = .now
        }

        /// Attaches the measured round trip to a pong; other events pass through untouched.
        private func timed(_ event: GLKVMWebSocketEvent) -> GLKVMWebSocketEvent {
            guard event.eventType == "pong", let sentAt = pingSentAt else { return event }
            pingSentAt = nil
            var timedEvent = event
            timedEvent.roundTripMs = Int(((ContinuousClock.now - sentAt) / .milliseconds(1)).rounded())
            return timedEvent
        }

        func send(eventType: String, event: JSONValue = .object([:])) async throws {
            guard let task else {
                throw WebSocketError.notConnected
            }

            let payload = GLKVMWebSocketSend(eventType: eventType, event: event)
            let encoder = JSONEncoder()
            let data: Data
            do {
                data = try encoder.encode(payload)
            } catch {
                throw WebSocketError.encodingFailed
            }

            let text = String(decoding: data, as: UTF8.self)
            try await task.send(.string(text))
            // The socket may have been dropped while the frame was in flight.
            guard self.task === task else { return }
            isConnecting = false
            isConnected = true
        }

        /// Sends a JSON key event over the PiKVM WebSocket (`{"event_type": "key", "event": {"key": ..., "state": ...}}`).
        func sendKeyJSONEvent(key: String, state: Bool) async throws {
            try await send(
                eventType: "key",
                event: .object([
                    "key": .string(key),
                    "state": .bool(state)
                ])
            )
        }

        private func sendBinary(_ data: Data) async throws {
            guard let task else {
                throw WebSocketError.notConnected
            }
            try await task.send(.data(data))
            guard self.task === task else { return }
            isConnecting = false
            isConnected = true
        }

        func sendHidKey(key: String, state: Bool, finish: Bool = false) async throws {
            var payload = Data()
            payload.reserveCapacity(2 + key.utf8.count)
            payload.append(0x01)
            payload.append(state ? 0x01 : 0x00)
            payload.append(contentsOf: key.utf8)
            try await sendBinary(payload)

            if finish {
                let finishPayload = Data([0x01, 0x00])
                try await sendBinary(finishPayload)
            }
        }

        func sendHidMouseButton(button: String, state: Bool) async throws {
            var payload = Data()
            payload.reserveCapacity(2 + button.utf8.count)
            payload.append(0x02)
            payload.append(state ? 0x01 : 0x00)
            payload.append(contentsOf: button.utf8)
            try await sendBinary(payload)
        }

        func sendHidMouseMove(toX: Int, toY: Int) async throws {
            let sx = Int16(clamping: toX)
            let sy = Int16(clamping: toY)
            let ux = UInt16(bitPattern: sx)
            let uy = UInt16(bitPattern: sy)
            let payload = Data([
                0x03,
                UInt8((ux >> 8) & 0xFF),
                UInt8(ux & 0xFF),
                UInt8((uy >> 8) & 0xFF),
                UInt8(uy & 0xFF),
            ])
            try await sendBinary(payload)
        }

        func sendHidMouseRelative(deltaX: Int, deltaY: Int, squash: Bool = false) async throws {
            let dx = UInt8(bitPattern: Int8(clamping: deltaX))
            let dy = UInt8(bitPattern: Int8(clamping: deltaY))
            let payload = Data([
                0x04,
                squash ? 0x01 : 0x00,
                dx,
                dy,
            ])
            try await sendBinary(payload)
        }

        func sendHidMouseWheel(deltaX: Int, deltaY: Int, squash: Bool = false) async throws {
            let dx = UInt8(bitPattern: Int8(clamping: deltaX))
            let dy = UInt8(bitPattern: Int8(clamping: deltaY))
            let payload = Data([
                0x05,
                squash ? 0x01 : 0x00,
                dx,
                dy,
            ])
            try await sendBinary(payload)
        }

        private func receiveLoop() async {
            let decoder = JSONDecoder()
            while !Task.isCancelled {
                guard let task else { break }
                do {
                    let msg = try await task.receive()
                    switch msg {
                    case .string(let text):
                        guard let data = text.data(using: .utf8) else { continue }
                        if let event = try? decoder.decode(GLKVMWebSocketEvent.self, from: data) {
                            continuation.yield(timed(event))
                        }
                    case .data(let data):
                        if let event = try? decoder.decode(GLKVMWebSocketEvent.self, from: data) {
                            continuation.yield(timed(event))
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    markDisconnected()
                    break
                }
            }
        }
    }
}
