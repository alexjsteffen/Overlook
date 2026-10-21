import Foundation

public struct CertificateFingerprint {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    public static func sha256(_ der: [UInt8]) -> String {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var message = der
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        let bits = UInt64(der.count) &* 8
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(message[j]) << 24 | UInt32(message[j + 1]) << 16 | UInt32(message[j + 2]) << 8 | UInt32(message[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let t1 = hh &+ (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) &+ ((e & f) ^ (~e & g)) &+ k[i] &+ w[i]
                let t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) &+ ((a & b) ^ (a & c) ^ (b & c))
                (hh, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
            }
            for (i, v) in [a, b, c, d, e, f, g, hh].enumerated() { h[i] = h[i] &+ v }
        }
        return h.map { word in
            let hex = String(word, radix: 16)
            return String(repeating: "0", count: 8 - hex.count) + hex
        }.joined()
    }

    public static func display(_ hex: String) -> String {
        let chars = Array(hex.uppercased())
        return stride(from: 0, to: chars.count, by: 2).map { String(chars[$0..<min($0 + 2, chars.count)]) }
            .joined(separator: ":")
    }
}

/// Trust-on-first-use pins for self-signed device certificates, keyed by "host:port".
public final class CertificateStore {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL? = nil) {
        let env = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let root = env.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        self.url = url ?? root.appendingPathComponent("overlook/trusted-certificates.json")
    }

    public static func key(host: String, port: Int) -> String { "\(host.lowercased()):\(port)" }

    public static func key(for url: URL) -> String? {
        guard let host = url.host, !host.isEmpty else { return nil }
        let defaultPort: Int
        switch url.scheme?.lowercased() {
        case "https", "wss": defaultPort = 443
        case "http", "ws": defaultPort = 80
        default:
            guard let port = url.port else { return nil }
            defaultPort = port
        }
        return key(host: host, port: url.port ?? defaultPort)
    }

    public func load() throws -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return try read()
    }

    public func pinned(_ key: String) -> String? { (try? load())?[key] }

    public func trust(_ key: String, sha256: String) throws {
        try update { $0[key] = sha256.lowercased() }
    }

    public func forget(_ key: String) throws {
        try update { $0.removeValue(forKey: key) }
    }

    public func forgetAll() throws {
        try update(replacingUnreadable: true) { $0.removeAll() }
    }

    private func read() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }

    private func update(replacingUnreadable: Bool = false, _ change: (inout [String: String]) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        // A corrupt file is never silently overwritten (that would drop pins); only forgetAll replaces it.
        var pins = replacingUnreadable ? ((try? read()) ?? [:]) : try read()
        change(&pins)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(pins).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
