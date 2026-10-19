import Foundation
import Combine
import CoreGraphics

@MainActor
class HardwareControlManager: ObservableObject {
    @Published var virtualMediaMounted = false
    @Published var powerState: PowerState = .unknown
    @Published var availableMedia: [VirtualMedia] = []
    @Published var isTransferring = false
    @Published var transferProgress: Double = 0.0

    @Published var msdState: GLKVMMsdState?
    @Published var atxState: GLKVMAtxState?
    @Published var gpioState: GLKVMGpioState?
    @Published var switchState: GLKVMSwitchState?
    @Published var redfishSystem: GLKVMRedfishSystem?

    private var connectedDevice: KVMDevice?
    private weak var client: GLKVMClient?

    func setup(with device: KVMDevice, client: GLKVMClient? = nil) {
        connectedDevice = device
        self.client = client ?? (try? GLKVMClient(device: device))
        Task {
            await refreshAllStates()
        }
    }

    func setClient(_ client: GLKVMClient?) {
        self.client = client
        if client == nil {
            virtualMediaMounted = false
            powerState = .unknown
            availableMedia = []
            msdState = nil
            atxState = nil
            gpioState = nil
            switchState = nil
            redfishSystem = nil
        }
    }

    func refreshAllStates() async {
        guard let client else { return }

        async let atxReq = try? client.getAtxState()
        async let msdReq = try? client.getMsdState()
        async let gpioReq = try? client.getGpioState()
        async let switchReq = try? client.getSwitchState()
        async let redfishReq = try? client.getRedfishSystem()

        let (atx, msd, gpio, sw, rf) = await (atxReq, msdReq, gpioReq, switchReq, redfishReq)

        if let atx {
            self.atxState = atx
            self.powerState = atx.leds.power ? .on : .off
        } else if let rf, let pState = rf.powerState?.lowercased() {
            self.redfishSystem = rf
            self.powerState = (pState == "on") ? .on : (pState == "off" ? .off : .unknown)
        }

        if let msd {
            self.msdState = msd
            self.virtualMediaMounted = msd.drive?.connected ?? false
            self.availableMedia = (msd.storage?.images ?? []).map { info in
                VirtualMedia(
                    id: info.name,
                    name: info.name,
                    type: info.name.lowercased().hasSuffix(".iso") ? .iso : .usb,
                    fileName: info.name,
                    fileSize: Int(info.size),
                    imageData: nil,
                    url: nil
                )
            }
        }

        if let gpio {
            self.gpioState = gpio
        }
        if let sw {
            self.switchState = sw
        }
        if let rf {
            self.redfishSystem = rf
        }
    }

    // MARK: - Virtual Media Management (PiKVM / GLKVM MSD API)

    func mountVirtualMedia(_ media: VirtualMedia, cdrom: Bool = true, rw: Bool = false) async throws {
        guard let client else {
            throw HardwareControlError.notConnected
        }

        isTransferring = true
        transferProgress = 0.1
        defer {
            isTransferring = false
            transferProgress = 0.0
        }

        do {
            if let data = media.imageData, !data.isEmpty {
                transferProgress = 0.3
                _ = try await client.msdWrite(image: media.fileName, data: data, removeIncomplete: true)
            } else if let remoteURL = media.url,
                      let scheme = remoteURL.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" {
                transferProgress = 0.3
                _ = try await client.msdWriteRemote(url: remoteURL, image: media.fileName)
            } else if let localURL = media.url, localURL.isFileURL {
                transferProgress = 0.3
                let data = try Data(contentsOf: localURL)
                _ = try await client.msdWrite(image: media.fileName, data: data, removeIncomplete: true)
            }

            transferProgress = 0.7
            try await client.setMsdParams(image: media.fileName, cdrom: cdrom, rw: rw)
            transferProgress = 0.9
            try await client.setMsdConnected(true)
            transferProgress = 1.0

            await refreshAllStates()
            virtualMediaMounted = true
        } catch {
            throw HardwareControlError.mediaMountFailed(error)
        }
    }

    func unmountVirtualMedia() async throws {
        guard let client else {
            throw HardwareControlError.notConnected
        }

        do {
            try await client.setMsdConnected(false)
            virtualMediaMounted = false
            await refreshAllStates()
        } catch {
            throw HardwareControlError.mediaMountFailed(error)
        }
    }

    func removeVirtualMedia(imageName: String) async throws {
        guard let client else {
            throw HardwareControlError.notConnected
        }
        try await client.msdRemove(image: imageName)
        await refreshAllStates()
    }

    func resetVirtualMedia() async throws {
        guard let client else {
            throw HardwareControlError.notConnected
        }
        try await client.msdReset()
        await refreshAllStates()
    }

    func createVirtualMedia(from url: URL, type: VirtualMediaType) async throws -> VirtualMedia {
        let imageData = try Data(contentsOf: url)
        let fileName = url.lastPathComponent

        return VirtualMedia(
            id: UUID().uuidString,
            name: fileName,
            type: type,
            fileName: fileName,
            fileSize: imageData.count,
            imageData: imageData,
            url: url
        )
    }

    // MARK: - ATX Power Management (PiKVM / GLKVM ATX & Redfish API)

    func powerOn(wait: Bool = false) async throws {
        try await performAtxPower(.on, wait: wait)
    }

    func powerOff(wait: Bool = false) async throws {
        try await performAtxPower(.off, wait: wait)
    }

    func powerOffHard(wait: Bool = false) async throws {
        try await performAtxPower(.offHard, wait: wait)
    }

    func powerCycle(wait: Bool = false) async throws {
        try await performAtxPower(.resetHard, wait: wait)
    }

    func reset(wait: Bool = false) async throws {
        try await performAtxPower(.resetHard, wait: wait)
    }

    func clickAtxButton(_ button: GLKVMClient.AtxButton, wait: Bool = false) async throws {
        guard let client else {
            throw HardwareControlError.notConnected
        }
        do {
            try await client.atxClick(button, wait: wait)
            await refreshAllStates()
        } catch {
            throw HardwareControlError.powerCommandFailed
        }
    }

    private func performAtxPower(_ action: GLKVMClient.AtxPowerAction, wait: Bool) async throws {
        guard let client else {
            throw HardwareControlError.notConnected
        }
        do {
            try await client.atxPower(action, wait: wait)
            await refreshAllStates()
        } catch {
            // Fallback to Redfish ComputerSystem.Reset if ATX endpoint fails
            let redfishMap: [GLKVMClient.AtxPowerAction: GLKVMClient.RedfishResetType] = [
                .on: .on,
                .off: .gracefulShutdown,
                .offHard: .forceOff,
                .resetHard: .forceRestart,
            ]
            if let resetType = redfishMap[action],
               (try? await client.redfishSystemReset(resetType: resetType)) != nil {
                await refreshAllStates()
                return
            }
            throw HardwareControlError.powerCommandFailed
        }
    }

    // MARK: - GPIO Control (PiKVM GPIO API)

    func switchGpio(channel: String, state: Bool, wait: Bool = false) async throws {
        guard let client else {
            throw HardwareControlError.notConnected
        }
        try await client.switchGpioChannel(channel: channel, state: state, wait: wait)
        self.gpioState = try? await client.getGpioState()
    }

    func pulseGpio(channel: String, delay: Double? = nil, wait: Bool = false) async throws {
        guard let client else {
            throw HardwareControlError.notConnected
        }
        try await client.pulseGpioChannel(channel: channel, delay: delay, wait: wait)
        self.gpioState = try? await client.getGpioState()
    }

    // MARK: - Streamer & Hardware Quality

    func setVideoQuality(_ quality: VideoQuality) async throws {
        guard let client else {
            throw HardwareControlError.notConnected
        }
        let params: [String: String]
        switch quality {
        case .low:
            params = ["h264_bitrate": "500", "h264_gop": "30", "quality": "50"]
        case .medium:
            params = ["h264_bitrate": "2000", "h264_gop": "30", "quality": "70"]
        case .high:
            params = ["h264_bitrate": "5000", "h264_gop": "60", "quality": "85"]
        case .ultra:
            params = ["h264_bitrate": "15000", "h264_gop": "60", "quality": "100"]
        }
        try await client.setStreamerParams(params)
    }

    func disconnect() {
        client = nil
        connectedDevice = nil
        virtualMediaMounted = false
        powerState = .unknown
        availableMedia = []
        msdState = nil
        atxState = nil
        gpioState = nil
        switchState = nil
        redfishSystem = nil
    }
}

// MARK: - Supporting Types
struct VirtualMedia: Identifiable, Codable {
    let id: String
    let name: String
    let type: VirtualMediaType
    let fileName: String
    let fileSize: Int
    let imageData: Data?
    let url: URL?

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }
}

enum VirtualMediaType: String, Codable, CaseIterable {
    case cd = "cd"
    case dvd = "dvd"
    case usb = "usb"
    case floppy = "floppy"
    case iso = "iso"
    case unknown = "unknown"

    var displayName: String {
        switch self {
        case .cd:
            return "CD-ROM"
        case .dvd:
            return "DVD"
        case .usb:
            return "USB Drive"
        case .floppy:
            return "Floppy Disk"
        case .iso:
            return "ISO Image"
        case .unknown:
            return "Unknown"
        }
    }
}

enum PowerState: String, Codable, CaseIterable {
    case on = "on"
    case off = "off"
    case sleeping = "sleeping"
    case unknown = "unknown"

    var displayName: String {
        switch self {
        case .on:
            return "Powered On"
        case .off:
            return "Powered Off"
        case .sleeping:
            return "Sleeping"
        case .unknown:
            return "Unknown"
        }
    }
}

enum VideoQuality: String, Codable, CaseIterable {
    case low = "low"
    case medium = "medium"
    case high = "high"
    case ultra = "ultra"

    var displayName: String {
        switch self {
        case .low:
            return "Low (480p)"
        case .medium:
            return "Medium (720p)"
        case .high:
            return "High (1080p)"
        case .ultra:
            return "Ultra (4K)"
        }
    }

    var resolution: CGSize {
        switch self {
        case .low:
            return CGSize(width: 640, height: 480)
        case .medium:
            return CGSize(width: 1280, height: 720)
        case .high:
            return CGSize(width: 1920, height: 1080)
        case .ultra:
            return CGSize(width: 3840, height: 2160)
        }
    }
}

enum HardwareControlError: Error, LocalizedError {
    case notConnected
    case mediaMountFailed(Error)
    case powerCommandFailed
    case hardwareFeatureNotSupported
    case transferFailed

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to KVM device"
        case .mediaMountFailed(let error):
            return "Failed to mount virtual media: \(error.localizedDescription)"
        case .powerCommandFailed:
            return "Failed to execute power command"
        case .hardwareFeatureNotSupported:
            return "Hardware feature not supported by device"
        case .transferFailed:
            return "File transfer failed"
        }
    }
}

// MARK: - KVM Device Extension
extension KVMDevice {
    var hardwareControlPort: Int {
        return port
    }

    var supportsVirtualMedia: Bool {
        return capabilities.contains(.virtualMedia)
    }

    var supportsPowerManagement: Bool {
        return capabilities.contains(.powerManagement)
    }
}
