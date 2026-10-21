import Foundation

public typealias KVMJSONObject = [String: JSONValue]

public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let b = try? container.decode(Bool.self) { self = .bool(b); return }
        if let i = try? container.decode(Int.self) { self = .int(i); return }
        if let d = try? container.decode(Double.self) { self = .double(d); return }
        if let s = try? container.decode(String.self) { self = .string(s); return }
        if let a = try? container.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? container.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.typeMismatch(
            JSONValue.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(exactly: value.rounded())
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

public struct KVMResponse<Result: Decodable>: Decodable {
    public let ok: Bool
    public let result: Result
}

public struct KVMEmptyResult: Decodable, Sendable {
    public init() {}
}

public struct KVMSystemGetConfigResult: Decodable, Sendable {
    public let config: KVMSystemConfig
}

public struct KVMSystemConfigShortcut: Codable, Hashable, Sendable {
    public let keys: [String]
    public let label: String

    public init(keys: [String], label: String) {
        self.keys = keys
        self.label = label
    }
}

public struct KVMSystemConfig: Codable, Hashable, Sendable {
    public var shortcuts: [KVMSystemConfigShortcut]
    public var orientation: Int
    public var streamQuality: Int
    public var videoMode: String
    public var showCursor: Bool
    public var mousePolling: Int
    public var mouseControl: Bool
    public var relativeSense: Int
    public var scrollRate: Int
    public var reverseScrolling: String
    public var keyboardControl: Bool
    public var themeMode: String
    public var mouseJiggle: Bool
    public var keymap: String
    public var gotMutedPanelTip: Bool
    public var isAbsoluteMouse: Bool
    public var fingerbotStrength: Int
    public var videoProcessing: String
    public var language: String?
    public var timezone: String?

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

    public init(
        shortcuts: [KVMSystemConfigShortcut] = [],
        orientation: Int = 0,
        streamQuality: Int = 1,
        videoMode: String = "",
        showCursor: Bool = true,
        mousePolling: Int = 10,
        mouseControl: Bool = true,
        relativeSense: Int = 10,
        scrollRate: Int = 5,
        reverseScrolling: String = "STANDARD",
        keyboardControl: Bool = true,
        themeMode: String = "0",
        mouseJiggle: Bool = false,
        keymap: String = "en-us",
        gotMutedPanelTip: Bool = false,
        isAbsoluteMouse: Bool = true,
        fingerbotStrength: Int = 0,
        videoProcessing: String = "low_latency_first",
        language: String? = nil,
        timezone: String? = nil
    ) {
        self.shortcuts = shortcuts
        self.orientation = orientation
        self.streamQuality = streamQuality
        self.videoMode = videoMode
        self.showCursor = showCursor
        self.mousePolling = mousePolling
        self.mouseControl = mouseControl
        self.relativeSense = relativeSense
        self.scrollRate = scrollRate
        self.reverseScrolling = reverseScrolling
        self.keyboardControl = keyboardControl
        self.themeMode = themeMode
        self.mouseJiggle = mouseJiggle
        self.keymap = keymap
        self.gotMutedPanelTip = gotMutedPanelTip
        self.isAbsoluteMouse = isAbsoluteMouse
        self.fingerbotStrength = fingerbotStrength
        self.videoProcessing = videoProcessing
        self.language = language
        self.timezone = timezone
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shortcuts = (try? container.decode([KVMSystemConfigShortcut].self, forKey: .shortcuts)) ?? []
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
        themeMode = (try? container.decode(String.self, forKey: .themeMode)) ?? "0"
        mouseJiggle = (try? container.decode(Bool.self, forKey: .mouseJiggle)) ?? false
        keymap = (try? container.decode(String.self, forKey: .keymap)) ?? "en-us"
        gotMutedPanelTip = (try? container.decode(Bool.self, forKey: .gotMutedPanelTip)) ?? false
        isAbsoluteMouse = (try? container.decode(Bool.self, forKey: .isAbsoluteMouse)) ?? true
        fingerbotStrength = (try? container.decode(Int.self, forKey: .fingerbotStrength)) ?? 0
        videoProcessing = (try? container.decode(String.self, forKey: .videoProcessing)) ?? "low_latency_first"
        language = try? container.decodeIfPresent(String.self, forKey: .language)
        timezone = try? container.decodeIfPresent(String.self, forKey: .timezone)
    }
}

public struct KVMNetworkConfig: Codable, Hashable, Sendable {
    public var mode: String
    public var ip: String
    public var netmask: String
    public var gateway: String
    public var dns: String

    public init(mode: String = "dhcp", ip: String = "192.168.8.1", netmask: String = "255.255.255.0", gateway: String = "192.168.8.1", dns: String = "8.8.8.8") {
        self.mode = mode
        self.ip = ip
        self.netmask = netmask
        self.gateway = gateway
        self.dns = dns
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? container.decode(String.self, forKey: .mode)) ?? "dhcp"
        ip = (try? container.decode(String.self, forKey: .ip)) ?? "192.168.8.1"
        netmask = (try? container.decode(String.self, forKey: .netmask)) ?? "255.255.255.0"
        gateway = (try? container.decode(String.self, forKey: .gateway)) ?? "192.168.8.1"
        dns = (try? container.decode(String.self, forKey: .dns)) ?? "8.8.8.8"
    }
}

public struct KVMWifiConfig: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var ssid: String
    public var password: String?
    public var status: String

    public init(enabled: Bool = true, ssid: String = "Overlook-WiFi", password: String? = nil, status: String = "Connected") {
        self.enabled = enabled
        self.ssid = ssid
        self.password = password
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? container.decode(Bool.self, forKey: .enabled)) ?? true
        ssid = (try? container.decode(String.self, forKey: .ssid)) ?? "Overlook-WiFi"
        password = try? container.decode(String.self, forKey: .password)
        status = (try? container.decode(String.self, forKey: .status)) ?? "Connected"
    }
}

public struct KVMEthernetConfig: Codable, Hashable, Sendable {
    public var connected: Bool
    public var speed: String
    public var ip: String
    public var mac: String

    public init(connected: Bool = true, speed: String = "1000 Mbps", ip: String = "192.168.8.100", mac: String = "00:11:22:33:44:55") {
        self.connected = connected
        self.speed = speed
        self.ip = ip
        self.mac = mac
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connected = (try? container.decode(Bool.self, forKey: .connected)) ?? true
        speed = (try? container.decode(String.self, forKey: .speed)) ?? "1000 Mbps"
        ip = (try? container.decode(String.self, forKey: .ip)) ?? "192.168.8.100"
        mac = (try? container.decode(String.self, forKey: .mac)) ?? "00:11:22:33:44:55"
    }
}

// MARK: - System Info (/api/info)

public struct KVMSystemInfo: Decodable, Hashable, Sendable {
    public struct Hardware: Decodable, Hashable, Sendable {
        public struct Platform: Decodable, Hashable, Sendable {
            public let base: String?
            public let board: String?
            public let model: String?
            public let serial: String?
            public let type: String?
            public let video: String?
        }

        public struct Health: Decodable, Hashable, Sendable {
            public struct CPU: Decodable, Hashable, Sendable {
                public let percent: Double?
            }

            public struct Memory: Decodable, Hashable, Sendable {
                public let available: Int64?
                public let percent: Double?
                public let total: Int64?
            }

            public struct Temperature: Decodable, Hashable, Sendable {
                public let cpu: Double?
                public let gpu: Double?
            }

            public struct Throttling: Decodable, Hashable, Sendable {
                public struct FlagState: Decodable, Hashable, Sendable {
                    public let now: Bool
                    public let past: Bool
                }

                public struct ParsedFlags: Decodable, Hashable, Sendable {
                    public let freqCapped: FlagState?
                    public let throttled: FlagState?
                    public let undervoltage: FlagState?

                    enum CodingKeys: String, CodingKey {
                        case freqCapped = "freq_capped"
                        case throttled
                        case undervoltage
                    }
                }

                public let ignorePast: Bool?
                public let parsedFlags: ParsedFlags?
                public let rawFlags: Int?

                enum CodingKeys: String, CodingKey {
                    case ignorePast = "ignore_past"
                    case parsedFlags = "parsed_flags"
                    case rawFlags = "raw_flags"
                }
            }

            public let cpu: CPU?
            public let mem: Memory?
            public let temp: Temperature?
            public let throttling: Throttling?
        }

        public let platform: Platform?
        public let health: Health?
    }

    public struct System: Decodable, Hashable, Sendable {
        public struct KVMD: Decodable, Hashable, Sendable {
            public let version: String?
        }

        public struct Streamer: Decodable, Hashable, Sendable {
            public let app: String?
            public let version: String?
            public let features: [String: Bool]?
        }

        public struct Kernel: Decodable, Hashable, Sendable {
            public let system: String?
            public let release: String?
            public let version: String?
            public let machine: String?
        }

        public let kvmd: KVMD?
        public let streamer: Streamer?
        public let kernel: Kernel?
    }

    public let hw: Hardware?
    public let system: System?
}

// MARK: - HID (/api/hid)

public struct KVMHidKeymapsState: Decodable, Hashable, Sendable {
    public struct Keymaps: Decodable, Hashable, Sendable {
        public let `default`: String
        public let available: [String]
    }
    public let keymaps: Keymaps
}

public struct KVMHidState: Decodable, Hashable, Sendable {
    public struct Jiggler: Decodable, Hashable, Sendable {
        public let active: Bool
        public let enabled: Bool
        public let interval: Double

        public init(active: Bool = false, enabled: Bool = false, interval: Double = 60) {
            self.active = active
            self.enabled = enabled
            self.interval = interval
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            active = (try? container.decode(Bool.self, forKey: .active)) ?? false
            enabled = (try? container.decode(Bool.self, forKey: .enabled)) ?? false
            interval = (try? container.decode(Double.self, forKey: .interval)) ?? 60
        }

        enum CodingKeys: String, CodingKey { case active, enabled, interval }
    }

    public struct Outputs: Decodable, Hashable, Sendable {
        public let active: String
        public let available: [String]

        public init(active: String = "", available: [String] = []) {
            self.active = active
            self.available = available
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            active = (try? container.decode(String.self, forKey: .active)) ?? ""
            available = (try? container.decode([String].self, forKey: .available)) ?? []
        }

        enum CodingKeys: String, CodingKey { case active, available }
    }

    public struct Keyboard: Decodable, Hashable, Sendable {
        public struct LEDs: Decodable, Hashable, Sendable {
            public let caps: Bool
            public let num: Bool
            public let scroll: Bool

            public init(caps: Bool = false, num: Bool = false, scroll: Bool = false) {
                self.caps = caps
                self.num = num
                self.scroll = scroll
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                caps = (try? container.decode(Bool.self, forKey: .caps)) ?? false
                num = (try? container.decode(Bool.self, forKey: .num)) ?? false
                scroll = (try? container.decode(Bool.self, forKey: .scroll)) ?? false
            }

            enum CodingKeys: String, CodingKey { case caps, num, scroll }
        }

        public let leds: LEDs
        public let online: Bool
        public let outputs: Outputs?
    }

    public struct Mouse: Decodable, Hashable, Sendable {
        public let absolute: Bool?
        public let online: Bool
        public let outputs: Outputs?
    }

    public let busy: Bool?
    public let connected: Bool?
    public let enabled: Bool
    public let online: Bool
    public let jiggler: Jiggler
    public let keyboard: Keyboard?
    public let mouse: Mouse?
}

// MARK: - ATX (/api/atx)

public struct KVMAtxState: Decodable, Hashable, Sendable {
    public struct LEDs: Decodable, Hashable, Sendable {
        public let hdd: Bool
        public let power: Bool
    }
    public let busy: Bool
    public let enabled: Bool
    public let leds: LEDs
}

public enum KVMAtxPowerAction: String, CaseIterable, Sendable {
    case on
    case off
    case offHard = "off_hard"
    case resetHard = "reset_hard"

    public var displayName: String {
        switch self {
        case .on: return "Power On"
        case .off: return "Graceful Off"
        case .offHard: return "Hard Off"
        case .resetHard: return "Hard Reset"
        }
    }
}

public enum KVMAtxButton: String, CaseIterable, Sendable {
    case power
    case powerLong = "power_long"
    case reset

    public var displayName: String {
        switch self {
        case .power: return "Click Power"
        case .powerLong: return "Hold Power (5s+)"
        case .reset: return "Click Reset"
        }
    }
}

// MARK: - Streamer & OCR (/api/streamer)

public struct KVMStreamerState: Decodable, Hashable, Sendable {
    public struct Features: Decodable, Hashable, Sendable {
        public let quality: Bool
        public let resolution: Bool
        public let h264: Bool
        public let zeroDelay: Bool?

        enum CodingKeys: String, CodingKey {
            case quality
            case resolution
            case h264
            case zeroDelay = "zero_delay"
        }
    }

    public struct Limits: Decodable, Hashable, Sendable {
        public struct MinMax: Decodable, Hashable, Sendable {
            public let min: Int
            public let max: Int
            public init(min: Int, max: Int) { self.min = min; self.max = max }
        }

        public let desiredFps: MinMax
        public let h264Bitrate: MinMax?
        public let h264Gop: MinMax?

        enum CodingKeys: String, CodingKey {
            case desiredFps = "desired_fps"
            case h264Bitrate = "h264_bitrate"
            case h264Gop = "h264_gop"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            desiredFps = (try? container.decode(MinMax.self, forKey: .desiredFps)) ?? MinMax(min: 0, max: 60)
            h264Bitrate = try? container.decode(MinMax.self, forKey: .h264Bitrate)
            h264Gop = try? container.decode(MinMax.self, forKey: .h264Gop)
        }
    }

    public struct Params: Decodable, Hashable, Sendable {
        public let desiredFps: Int?
        public let quality: Int?
        public let h264Bitrate: Int?
        public let h264Gop: Int?
        public let zeroDelay: Bool?
        public let resolution: String?

        enum CodingKeys: String, CodingKey {
            case desiredFps = "desired_fps"
            case quality
            case h264Bitrate = "h264_bitrate"
            case h264Gop = "h264_gop"
            case zeroDelay = "zero_delay"
            case resolution
        }
    }

    public struct LiveStreamer: Decodable, Hashable, Sendable {
        public struct Encoder: Decodable, Hashable, Sendable {
            public let quality: Int?
            public let type: String?
        }

        public struct H264: Decodable, Hashable, Sendable {
            public let bitrate: Int?
            public let fps: Int?
            public let gop: Int?
            public let online: Bool?
        }

        public struct Source: Decodable, Hashable, Sendable {
            public struct Resolution: Decodable, Hashable, Sendable {
                public let width: Int
                public let height: Int
            }

            public let capturedFps: Int?
            public let desiredFps: Int?
            public let online: Bool?
            public let resolution: Resolution?

            enum CodingKeys: String, CodingKey {
                case capturedFps = "captured_fps"
                case desiredFps = "desired_fps"
                case online
                case resolution
            }
        }

        public let encoder: Encoder?
        public let h264: H264?
        public let source: Source?
    }

    public let features: Features?
    public let limits: Limits?
    public let params: Params?
    public let streamer: LiveStreamer?
}

public struct KVMStreamerOcrState: Decodable, Hashable, Sendable {
    public struct OcrInfo: Decodable, Hashable, Sendable {
        public struct Langs: Decodable, Hashable, Sendable {
            public let available: [String]
            public let `default`: [String]
        }
        public let enabled: Bool
        public let langs: Langs?
    }
    public let ocr: OcrInfo
}

// MARK: - Mass Storage Drive (/api/msd)

public struct KVMMsdImageInfo: Decodable, Hashable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let size: Int64
    public let complete: Bool
    public let inStorage: Bool
    public let removable: Bool

    public init(name: String, size: Int64 = 0, complete: Bool = true, inStorage: Bool = true, removable: Bool = true) {
        self.name = name
        self.size = size
        self.complete = complete
        self.inStorage = inStorage
        self.removable = removable
    }
}

public struct KVMMsdState: Decodable, Hashable, Sendable {
    public struct Drive: Decodable, Hashable, Sendable {
        public let imageName: String?
        public let imageSize: Int64?
        public let connected: Bool
        public let cdrom: Bool
        public let rw: Bool

        enum CodingKeys: String, CodingKey {
            case image, connected, cdrom, rw
        }

        public init(from decoder: Decoder) throws {
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

    public struct Storage: Decodable, Hashable, Sendable {
        public let size: Int64
        public let free: Int64
        public let uploading: Bool
        public let downloading: Bool
        public let images: [KVMMsdImageInfo]

        enum CodingKeys: String, CodingKey {
            case size, free, uploading, downloading, images, parts
        }

        public init(from decoder: Decoder) throws {
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

            var parsedImages: [KVMMsdImageInfo] = []
            if let imagesDict = try? container.decode([String: [String: JSONValue]].self, forKey: .images) {
                for (name, info) in imagesDict {
                    let imgSize = info["size"]?.intValue.map(Int64.init) ?? 0
                    let complete = info["complete"]?.boolValue ?? true
                    let inStorage = info["in_storage"]?.boolValue ?? true
                    let removable = info["removable"]?.boolValue ?? true
                    parsedImages.append(
                        KVMMsdImageInfo(name: name, size: imgSize, complete: complete, inStorage: inStorage, removable: removable)
                    )
                }
            }
            images = parsedImages.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    public let enabled: Bool
    public let online: Bool
    public let busy: Bool
    public let drive: Drive?
    public let storage: Storage?
}

public struct KVMMSDPartitionDevice: Decodable, Hashable, Sendable {
    public let path: String
    public let size: Int
    public let uuid: String
    public let filesystem: String
    public let label: String
    public let isCurrent: Bool

    enum CodingKeys: String, CodingKey {
        case path, size, uuid, filesystem, label
        case isCurrent = "is_current"
    }
}

public struct KVMMSDPartitionShowResult: Decodable, Hashable, Sendable {
    public let devices: [String: KVMMSDPartitionDevice]
}

// MARK: - GPIO (/api/gpio)

public struct KVMGpioState: Decodable, Hashable, Sendable {
    public struct ChannelScheme: Decodable, Hashable, Identifiable, Sendable {
        public var id: String { channel }
        public let channel: String
        public let switchEnabled: Bool
        public let pulseDelay: Double
        public let minDelay: Double
        public let maxDelay: Double
        public let driver: String?
        public let pin: String?
    }

    public struct ChannelRuntimeState: Decodable, Hashable, Sendable {
        public let online: Bool
        public let state: Bool
        public let busy: Bool
    }

    public let inputChannels: [String]
    public let outputSchemes: [String: ChannelScheme]
    public let inputs: [String: ChannelRuntimeState]
    public let outputs: [String: ChannelRuntimeState]

    enum CodingKeys: String, CodingKey { case model, state }

    public init(from decoder: Decoder) throws {
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
                        channel: ch, switchEnabled: switchCap, pulseDelay: delay,
                        minDelay: minDelay, maxDelay: maxDelay, driver: driver, pin: pin
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
                        channel: ch, switchEnabled: true, pulseDelay: 0.1,
                        minDelay: 0.1, maxDelay: 5.0, driver: nil, pin: nil
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

// MARK: - PiKVM Switch (/api/switch)

public struct KVMSwitchState: Decodable, Hashable, Sendable {
    public struct PortConfig: Decodable, Hashable, Identifiable, Sendable {
        public var id: String { port }
        public let port: String
        public let name: String
        public let edidId: String?
        public let dummy: Bool
        public let beacon: Bool
    }

    public let enabled: Bool
    public let activePort: String?
    public let ports: [PortConfig]
    public let edids: [String: String]

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        let rawObj = (try? single.decode(KVMJSONObject.self)) ?? [:]
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

// MARK: - Redfish (/redfish/v1)

public enum KVMRedfishResetType: String, CaseIterable, Sendable {
    case on = "On"
    case forceOff = "ForceOff"
    case gracefulShutdown = "GracefulShutdown"
    case forceRestart = "ForceRestart"
    case forceOn = "ForceOn"
    case pushPowerButton = "PushPowerButton"
}

public struct KVMRedfishSystem: Decodable, Hashable, Sendable {
    public let id: String?
    public let hostName: String?
    public let powerState: String?
    public let allowableResetTypes: [String]

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case hostName = "HostName"
        case powerState = "PowerState"
        case actions = "Actions"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decode(String.self, forKey: .id)
        hostName = try? container.decode(String.self, forKey: .hostName)
        powerState = try? container.decode(String.self, forKey: .powerState)

        var resetTypes: [String] = []
        if let actions = try? container.decode(KVMJSONObject.self, forKey: .actions),
           let resetObj = actions["#ComputerSystem.Reset"],
           case .array(let arr) = resetObj["ResetType@Redfish.AllowableValues"] {
            resetTypes = arr.compactMap(\.stringValue)
        }
        allowableResetTypes = resetTypes.isEmpty
            ? KVMRedfishResetType.allCases.map(\.rawValue)
            : resetTypes
    }
}

// MARK: - Video Quality Presets

public enum KVMVideoQualityPreset: Int, CaseIterable, Sendable {
    case low = 0
    case medium = 1
    case high = 2
    case ultraHigh = 3
    case insane = 4
    case custom = -1

    public var title: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .ultraHigh: return "Ultra-high"
        case .insane: return "Insane"
        case .custom: return "Custom"
        }
    }

    public var streamerParams: [String: String]? {
        switch self {
        case .low: return ["h264_bitrate": "500", "h264_gop": "30"]
        case .medium: return ["h264_bitrate": "2000", "h264_gop": "30"]
        case .high: return ["h264_bitrate": "5000", "h264_gop": "60"]
        case .ultraHigh: return ["h264_bitrate": "8000", "h264_gop": "60"]
        case .insane: return ["quality": "100", "h264_bitrate": "20000", "h264_gop": "60"]
        case .custom: return nil
        }
    }

    public var configStreamQuality: Int? {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        case .ultraHigh, .insane: return 3
        case .custom: return nil
        }
    }

    public static func detect(config: KVMSystemConfig?, streamer: KVMStreamerState?) -> KVMVideoQualityPreset {
        if let params = streamer?.params,
           params.h264Bitrate == 20000,
           params.h264Gop == 60,
           params.quality == 100 {
            return .insane
        }
        if let sq = config?.streamQuality, let preset = KVMVideoQualityPreset(rawValue: sq), (0...3).contains(sq) {
            return preset
        }
        return .custom
    }
}

// MARK: - TOTP / 2FA Helper (RFC 6238 pure Swift HMAC-SHA1)

public enum TOTPGenerator {
    public static func generateCode(base32Secret: String, date: Date = Date(), period: TimeInterval = 30, digits: Int = 6) -> String? {
        guard let keyBytes = decodeBase32(base32Secret), !keyBytes.isEmpty else { return nil }
        let counter = UInt64(floor(date.timeIntervalSince1970 / period))
        var msg = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 {
            msg[7 - i] = UInt8((counter >> (i * 8)) & 0xff)
        }
        let hash = hmacSHA1(key: keyBytes, message: msg)
        guard let lastByte = hash.last else { return nil }
        let offset = Int(lastByte & 0x0f)
        guard offset + 3 < hash.count else { return nil }
        let truncated =
            (UInt32(hash[offset] & 0x7f) << 24) |
            (UInt32(hash[offset + 1]) << 16) |
            (UInt32(hash[offset + 2]) << 8) |
            UInt32(hash[offset + 3])
        var mod: UInt32 = 1
        for _ in 0..<digits { mod *= 10 }
        let otp = truncated % mod
        return String(format: "%0\(digits)u", otp)
    }

    public static func resolveTwoFactorCode(_ input: String?, date: Date = Date()) -> String? {
        guard let raw = input?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return ""
        }
        let stripped = raw.replacingOccurrences(of: " ", with: "")
        if stripped.count == 6, stripped.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return stripped
        }
        return generateCode(base32Secret: stripped, date: date)
    }

    public static func decodeBase32(_ input: String) -> [UInt8]? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var lookup: [Character: UInt8] = [:]
        for (i, ch) in alphabet.enumerated() { lookup[ch] = UInt8(i) }
        let cleaned = input.uppercased().filter { !$0.isWhitespace && $0 != "=" && $0 != "-" }
        guard !cleaned.isEmpty else { return nil }
        var buffer: UInt32 = 0
        var bitsLeft = 0
        var output: [UInt8] = []
        for ch in cleaned {
            guard let val = lookup[ch] else { return nil }
            buffer = (buffer << 5) | UInt32(val)
            bitsLeft += 5
            if bitsLeft >= 8 {
                bitsLeft -= 8
                output.append(UInt8((buffer >> bitsLeft) & 0xff))
            }
        }
        return output
    }

    private static func sha1(_ data: [UInt8]) -> [UInt8] {
        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xC3D2E1F0

        var msg = data
        let bitLen = UInt64(data.count) &* 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            msg.append(UInt8(truncatingIfNeeded: bitLen >> UInt64(shift)))
        }

        func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
        var w = [UInt32](repeating: 0, count: 80)

        for chunk in stride(from: 0, to: msg.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = (UInt32(msg[j]) << 24) | (UInt32(msg[j + 1]) << 16) | (UInt32(msg[j + 2]) << 8) | UInt32(msg[j + 3])
            }
            for i in 16..<80 {
                w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)
            }
            var a = h0, b = h1, c = h2, d = h3, e = h4
            for i in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch i {
                case 0..<20:
                    f = (b & c) | ((~b) & d)
                    k = 0x5A827999
                case 20..<40:
                    f = b ^ c ^ d
                    k = 0x6ED9EBA1
                case 40..<60:
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8F1BBCDC
                default:
                    f = b ^ c ^ d
                    k = 0xCA62C1D6
                }
                let temp = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = rotl(b, 30)
                b = a
                a = temp
            }
            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
        }

        var out: [UInt8] = []
        out.reserveCapacity(20)
        for word in [h0, h1, h2, h3, h4] {
            out.append(UInt8((word >> 24) & 0xff))
            out.append(UInt8((word >> 16) & 0xff))
            out.append(UInt8((word >> 8) & 0xff))
            out.append(UInt8(word & 0xff))
        }
        return out
    }

    private static func hmacSHA1(key: [UInt8], message: [UInt8]) -> [UInt8] {
        let blockSize = 64
        var k = key.count > blockSize ? sha1(key) : key
        if k.count < blockSize {
            k.append(contentsOf: repeatElement(0, count: blockSize - k.count))
        }
        let oKeyPad = k.map { $0 ^ 0x5c }
        let iKeyPad = k.map { $0 ^ 0x36 }
        let inner = sha1(iKeyPad + message)
        return sha1(oKeyPad + inner)
    }
}

// MARK: - API Endpoint & Query Builders

public enum KVMAPIEndpoint {
    public static func url(_ base: URL, path: String, query: [(String, String)] = []) -> URL {
        var endpoint = KVMRequest.endpoint(base, path: path)
        if !query.isEmpty, var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
            if let withQuery = components.url {
                endpoint = withQuery
            }
        }
        return endpoint
    }

    public static func multipartEdid(_ edid: String, boundary: String = "----OverlookEDIDBoundary") -> (contentType: String, body: Data) {
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"edid\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(edid)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return ("multipart/form-data; boundary=\(boundary)", body)
    }

    public static func decodeEdidResponse(_ data: Data) -> String? {
        let decoder = JSONDecoder()
        if let wrapped = try? decoder.decode(KVMResponse<String>.self, from: data) {
            return wrapped.result
        }
        if let wrapped = try? decoder.decode(KVMResponse<KVMJSONObject>.self, from: data) {
            if let s = wrapped.result["edid"]?.stringValue { return s }
            if let s = wrapped.result["EDID"]?.stringValue { return s }
        }
        return String(data: data, encoding: .utf8)
    }

    public static func extractErrorMessage(_ data: Data, status: Int) -> String {
        if let wrapped = try? JSONDecoder().decode(KVMResponse<KVMJSONObject>.self, from: data) {
            if let s = wrapped.result["error_msg"]?.stringValue, !s.isEmpty { return s }
            if let s = wrapped.result["message"]?.stringValue, !s.isEmpty { return s }
            if let s = wrapped.result["error"]?.stringValue, !s.isEmpty { return s }
        }
        if let text = String(data: data.prefix(256), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return "HTTP \(status): \(text)"
        }
        return "HTTP \(status)"
    }
}
