import Foundation

public struct Device: Codable, Equatable, Identifiable, Sendable {
    public static let generatedPrefixes = ["Manual KVM @ ", "KVM @ ", "GLKVM @ ", "NanoKVM @ "]

    public let id: UUID
    public var name: String
    public var nickname: String?
    public let address: URL
    public var addresses: [URL]
    public var lastUsedAddress: URL?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case nickname
        case address
        case addresses
        case lastUsedAddress
    }

    public init(name: String, address: String) throws {
        self.id = UUID()
        let parsed = try DeviceAddress.parse(address)
        self.address = parsed
        self.addresses = [parsed]
        self.lastUsedAddress = nil
        let cleaned = Self.cleanNickname(name)
        self.nickname = cleaned
        if let cleaned {
            self.name = cleaned
        } else {
            let host = parsed.host ?? "KVM"
            self.name = parsed.port.map { "\(host):\($0)" } ?? host
        }
    }

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        nickname: String? = nil,
        address: URL,
        addresses: [URL] = [],
        lastUsedAddress: URL? = nil
    ) {
        self.id = id
        self.address = address
        var merged = addresses
        if !merged.contains(address) {
            merged.insert(address, at: 0)
        }
        self.addresses = merged
        self.lastUsedAddress = lastUsedAddress
        let explicitNickname = Self.cleanNickname(nickname) ?? Self.cleanNickname(name)
        self.nickname = explicitNickname
        if let explicitNickname {
            self.name = explicitNickname
        } else {
            let host = address.host ?? "KVM"
            self.name = address.port.map { "\(host):\($0)" } ?? host
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        let primary = try container.decode(URL.self, forKey: .address)
        let decodedAddresses = (try? container.decodeIfPresent([URL].self, forKey: .addresses)) ?? nil
        let decodedLastUsed = (try? container.decodeIfPresent(URL.self, forKey: .lastUsedAddress)) ?? nil
        let decodedName = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? nil
        let decodedNickname = (try? container.decodeIfPresent(String.self, forKey: .nickname)) ?? nil

        self.address = primary
        var uniqueAddresses = decodedAddresses ?? []
        if !uniqueAddresses.contains(primary) {
            uniqueAddresses.insert(primary, at: 0)
        }
        self.addresses = uniqueAddresses
        self.lastUsedAddress = decodedLastUsed

        let cleanedNick = Self.cleanNickname(decodedNickname) ?? Self.cleanNickname(decodedName)
        self.nickname = cleanedNick
        if let cleanedNick {
            self.name = cleanedNick
        } else {
            let fallbackName = decodedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !fallbackName.isEmpty {
                self.name = fallbackName
            } else {
                let host = primary.host ?? "KVM"
                self.name = primary.port.map { "\(host):\($0)" } ?? host
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(nickname, forKey: .nickname)
        try container.encode(address, forKey: .address)
        try container.encode(addresses, forKey: .addresses)
        try container.encodeIfPresent(lastUsedAddress, forKey: .lastUsedAddress)
    }

    public var preferredAddress: URL {
        if let lastUsedAddress, addresses.contains(lastUsedAddress) {
            return lastUsedAddress
        }
        return addresses.first ?? address
    }

    public func includes(_ candidate: URL) -> Bool {
        address == candidate || addresses.contains(candidate)
    }

    public func via(_ candidate: URL) -> Device {
        var merged = addresses
        if !merged.contains(candidate) {
            merged.append(candidate)
        }
        return Device(
            id: id,
            name: nickname ?? name,
            nickname: nickname,
            address: candidate,
            addresses: merged,
            lastUsedAddress: candidate
        )
    }

    public static func cleanNickname(_ raw: String?) -> String? {
        guard var trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        for prefix in generatedPrefixes {
            if trimmed.hasPrefix(prefix) {
                trimmed = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : nil
            }
        }
        return trimmed
    }
}

public enum DeviceAddress {
    public static func parse(_ input: String) throws -> URL {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else { throw AddressError.invalid }
        let hasScheme = text.contains("://")
        let isExplicitHTTP = text.lowercased().hasPrefix("http://")
        let value = hasScheme ? text : "https://" + text
        guard var parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { throw AddressError.invalid }
        if isExplicitHTTP {
            parts.scheme = "http"
        } else {
            parts.scheme = (!hasScheme && (parts.port == 80 || parts.port == 8080)) ? "http" : scheme
        }
        if parts.path.isEmpty { parts.path = "/" }
        guard let url = parts.url else { throw AddressError.invalid }
        return url
    }

    public static func resolvedPort(for url: URL) -> Int {
        if let port = url.port { return port }
        return url.scheme?.lowercased() == "http" ? 80 : 443
    }
}

public enum AddressError: LocalizedError {
    case invalid
    public var errorDescription: String? {
        "Enter a hostname or an HTTP(S) URL without credentials, query parameters, or a fragment."
    }
}

/// Stores addresses only. Browser cookies, passwords, and certificate exceptions stay in memory.
public struct DeviceStore {
    public let file: URL
    public init(file: URL? = nil) {
        if let file {
            self.file = file
            return
        }
        #if os(Windows)
        let env = ProcessInfo.processInfo.environment["APPDATA"]
        let root = env.flatMap { !$0.isEmpty ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AppData/Roaming", isDirectory: true)
        self.file = root.appendingPathComponent("Overlook/devices.json")
        #else
        let env = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let root = env.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        self.file = root.appendingPathComponent("overlook/devices.json")
        #endif
    }
    public func load() throws -> [Device] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let devices = try JSONDecoder().decode([Device].self, from: Data(contentsOf: file))
        // Validate disk data too; never open arbitrary file/javascript URLs from a modified file.
        for device in devices {
            _ = try DeviceAddress.parse(device.address.absoluteString)
            for addr in device.addresses {
                _ = try DeviceAddress.parse(addr.absoluteString)
            }
        }
        return devices
    }
    public func save(_ devices: [Device]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                               withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(devices).write(to: file, options: .atomic)
        #if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #endif
    }
}
