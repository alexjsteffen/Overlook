import Foundation

public struct Device: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public let address: URL

    public init(name: String, address: String) throws {
        self.id = UUID()
        self.address = try DeviceAddress.parse(address)
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.name.isEmpty { self.name = self.address.host ?? "KVM" }
    }
}

public enum DeviceAddress {
    public static func parse(_ input: String) throws -> URL {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else { throw AddressError.invalid }
        let value = text.contains("://") ? text : "https://" + text
        guard var parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { throw AddressError.invalid }
        parts.scheme = scheme
        if parts.path.isEmpty { parts.path = "/" }
        guard let url = parts.url else { throw AddressError.invalid }
        return url
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
        let env = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let root = env.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        self.file = file ?? root.appendingPathComponent("overlook/devices.json")
    }
    public func load() throws -> [Device] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let devices = try JSONDecoder().decode([Device].self, from: Data(contentsOf: file))
        // Validate disk data too; never open arbitrary file/javascript URLs from a modified file.
        for device in devices { _ = try DeviceAddress.parse(device.address.absoluteString) }
        return devices
    }
    public func save(_ devices: [Device]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                               withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(devices).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
