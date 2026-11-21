import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// An IPv4 or IPv6 address parsed purely in Swift (no OS socket dependency required), for
/// classifying LAN, Tailscale, link-local, loopback, and ICE candidate addresses across
/// macOS, Linux, and Windows.
public struct IPAddress: Hashable, CustomStringConvertible, Sendable {
    public enum Family: Hashable, Sendable {
        case v4
        case v6
    }

    public let family: Family
    /// 4 bytes for IPv4, 16 bytes for IPv6, in network order.
    public let bytes: [UInt8]

    public init?(_ text: String) {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("[") && cleaned.hasSuffix("]") {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        if let zone = cleaned.firstIndex(of: "%") {
            cleaned = String(cleaned[..<zone])
        }
        guard !cleaned.isEmpty else { return nil }

        if let v4 = Self.parseIPv4(cleaned) {
            self.family = .v4
            self.bytes = v4
            return
        }
        if let v6 = Self.parseIPv6(cleaned) {
            self.family = .v6
            self.bytes = v6
            return
        }
        return nil
    }

    public init?(family: Family, bytes: [UInt8]) {
        guard bytes.count == (family == .v4 ? 4 : 16) else { return nil }
        self.family = family
        self.bytes = bytes
    }

    public var description: String {
        switch family {
        case .v4:
            return bytes.map(String.init).joined(separator: ".")
        case .v6:
            return Self.formatIPv6(bytes)
        }
    }

    public func hasPrefix(_ prefix: [UInt8], length: Int) -> Bool {
        guard prefix.count * 8 >= length, bytes.count * 8 >= length else { return false }
        var remaining = length
        var index = 0
        while remaining > 0 {
            let bits = min(8, remaining)
            let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
            if bytes[index] & mask != prefix[index] & mask { return false }
            remaining -= bits
            index += 1
        }
        return true
    }

    /// Tailscale ranges: 100.64.0.0/10 and fd7a:115c:a1e0::/48.
    public var isTailscale: Bool {
        switch family {
        case .v4: return hasPrefix([100, 64], length: 10)
        case .v6: return hasPrefix([0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0], length: 48)
        }
    }

    /// RFC 1918: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16.
    public var isPrivateLAN: Bool {
        guard family == .v4 else { return false }
        return hasPrefix([10], length: 8) || hasPrefix([172, 16], length: 12) || hasPrefix([192, 168], length: 16)
    }

    /// 169.254.0.0/16 and fe80::/10.
    public var isLinkLocal: Bool {
        switch family {
        case .v4: return hasPrefix([169, 254], length: 16)
        case .v6: return hasPrefix([0xFE, 0x80], length: 10)
        }
    }

    /// 127.0.0.0/8 and ::1.
    public var isLoopback: Bool {
        switch family {
        case .v4: return hasPrefix([127], length: 8)
        case .v6: return bytes == [UInt8](repeating: 0, count: 15) + [1]
        }
    }

    private static func parseIPv4(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  !(part.count > 1 && part.first == "0"),
                  let value = UInt8(part) else {
                return nil
            }
            out.append(value)
        }
        return out
    }

    private static func parseIPv6(_ text: String) -> [UInt8]? {
        guard text.contains(":") else { return nil }
        let doubleColonSplit = text.components(separatedBy: "::")
        guard doubleColonSplit.count <= 2 else { return nil }

        func parseGroupList(_ section: String, allowTrailingIPv4: Bool) -> (hextets: [UInt16], ipv4Bytes: [UInt8]?)? {
            if section.isEmpty { return ([], nil) }
            let rawParts = section.split(separator: ":", omittingEmptySubsequences: false)
            var hextets: [UInt16] = []
            for (idx, part) in rawParts.enumerated() {
                if part.isEmpty { return nil }
                if part.contains(".") {
                    guard allowTrailingIPv4, idx == rawParts.count - 1,
                          let v4 = parseIPv4(String(part)) else { return nil }
                    return (hextets, v4)
                }
                guard part.count <= 4, let value = UInt16(part, radix: 16) else { return nil }
                hextets.append(value)
            }
            return (hextets, nil)
        }

        if doubleColonSplit.count == 1 {
            guard let parsed = parseGroupList(doubleColonSplit[0], allowTrailingIPv4: true) else { return nil }
            let expectedHextets = parsed.ipv4Bytes == nil ? 8 : 6
            guard parsed.hextets.count == expectedHextets else { return nil }
            return assembleIPv6(left: parsed.hextets, zeroCount: 0, right: [], trailingIPv4: parsed.ipv4Bytes)
        } else {
            guard let left = parseGroupList(doubleColonSplit[0], allowTrailingIPv4: false),
                  let right = parseGroupList(doubleColonSplit[1], allowTrailingIPv4: true) else { return nil }
            let expectedHextets = right.ipv4Bytes == nil ? 8 : 6
            let zeroCount = expectedHextets - (left.hextets.count + right.hextets.count)
            guard zeroCount >= 1 else { return nil }
            return assembleIPv6(left: left.hextets, zeroCount: zeroCount, right: right.hextets, trailingIPv4: right.ipv4Bytes)
        }
    }

    private static func assembleIPv6(left: [UInt16], zeroCount: Int, right: [UInt16], trailingIPv4: [UInt8]?) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        for h in left {
            bytes.append(UInt8(h >> 8))
            bytes.append(UInt8(h & 0xFF))
        }
        if zeroCount > 0 {
            bytes.append(contentsOf: repeatElement(UInt8(0), count: zeroCount * 2))
        }
        for h in right {
            bytes.append(UInt8(h >> 8))
            bytes.append(UInt8(h & 0xFF))
        }
        if let trailingIPv4 {
            bytes.append(contentsOf: trailingIPv4)
        }
        return bytes
    }

    private static func formatIPv6(_ bytes: [UInt8]) -> String {
        guard bytes.count == 16 else { return "" }
        var groups: [UInt16] = []
        groups.reserveCapacity(8)
        for i in stride(from: 0, to: 16, by: 2) {
            groups.append((UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1]))
        }
        var bestStart = -1
        var bestLen = 0
        var curStart = -1
        var curLen = 0
        for (i, g) in groups.enumerated() {
            if g == 0 {
                if curStart == -1 { curStart = i; curLen = 1 } else { curLen += 1 }
                if curLen > bestLen { bestStart = curStart; bestLen = curLen }
            } else {
                curStart = -1
                curLen = 0
            }
        }
        if bestLen < 2 {
            return groups.map { String($0, radix: 16) }.joined(separator: ":")
        }
        let prefix = groups[..<bestStart].map { String($0, radix: 16) }.joined(separator: ":")
        let suffix = groups[(bestStart + bestLen)...].map { String($0, radix: 16) }.joined(separator: ":")
        return "\(prefix)::\(suffix)"
    }
}

public enum MediaNetworkRules {
    public static func isDirectlyReachable(host: String) -> Bool {
        var name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasPrefix("[") && name.hasSuffix("]") {
            name = String(name.dropFirst().dropLast())
        }
        if name.hasSuffix(".") {
            name.removeLast()
        }
        guard !name.isEmpty else { return false }

        if let address = IPAddress(name) {
            switch address.family {
            case .v4:
                return address.isPrivateLAN || address.isLoopback || address.isLinkLocal || address.isTailscale
            case .v6:
                return address.isTailscale
            }
        }
        if name == "localhost" || name.hasSuffix(".local") || name.hasSuffix(".ts.net") {
            return true
        }
        return !name.contains(".") && !name.contains(":")
    }
}

/// Which network interfaces/candidates WebRTC media may use.
public enum MediaAddressesPreference: String, CaseIterable, Codable, Identifiable, Sendable {
    case chosenNetwork
    case all

    public var id: Self { self }

    public var title: String {
        switch self {
        case .chosenNetwork: return "Chosen network only"
        case .all: return "All addresses"
        }
    }
}

public enum MediaNetwork: Equatable, Sendable {
    case lan
    case tailscale

    public var name: String {
        switch self {
        case .lan: return "the LAN"
        case .tailscale: return "Tailscale"
        }
    }

    public static func classify(_ address: IPAddress) -> MediaNetwork? {
        if address.isTailscale { return .tailscale }
        if address.isPrivateLAN { return .lan }
        return nil
    }

    public static func classify(host: String) -> MediaNetwork? {
        let name = normalized(host)
        if let address = IPAddress(name) {
            return classify(address)
        }
        if name.hasSuffix(".ts.net") {
            return .tailscale
        }
        return nil
    }

    public static func needsResolution(host: String) -> Bool {
        let name = normalized(host)
        return !name.isEmpty && IPAddress(name) == nil && !name.hasSuffix(".ts.net")
    }

    private static func normalized(_ host: String) -> String {
        var name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasSuffix(".") {
            name.removeLast()
        }
        return name
    }
}

public struct ICECandidateLine: Equatable, Sendable {
    public let address: String
    public let type: String

    public var ip: IPAddress? { IPAddress(address) }

    public init?(_ line: String) {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("a=") {
            text.removeFirst(2)
        }
        guard text.hasPrefix("candidate:") else { return nil }
        let fields = text.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 8, fields[6] == "typ" else { return nil }
        address = String(fields[4])
        type = String(fields[7]).lowercased()
    }

    public var label: String {
        type == "host" ? address : "\(address) \(type)"
    }
}

public struct RemoteOfferFilterResult: Equatable, Sendable {
    public let sdp: String
    public let dropped: [ICECandidateLine]
    public let keptWholeOffer: Bool
    public var usedWhole: [ICECandidateLine]

    public init(sdp: String, dropped: [ICECandidateLine], keptWholeOffer: Bool, usedWhole: [ICECandidateLine] = []) {
        self.sdp = sdp
        self.dropped = dropped
        self.keptWholeOffer = keptWholeOffer
        self.usedWhole = usedWhole
    }

    public var usedWholeLabels: [String] {
        var seen: Set<String> = []
        return usedWhole.map(\.label).filter { seen.insert($0).inserted }
    }
}

public struct LocalInterfaceAddress: Equatable, Sendable {
    public let name: String
    public let address: IPAddress
    public let netmask: IPAddress

    public init(name: String, address: IPAddress, netmask: IPAddress) {
        self.name = name
        self.address = address
        self.netmask = netmask
    }

    public func sharesSubnet(with other: IPAddress) -> Bool {
        guard address.family == .v4, other.family == .v4, netmask.family == .v4 else { return false }
        guard netmask.bytes != [255, 255, 255, 255] else { return false }
        for index in 0..<4 where (address.bytes[index] & netmask.bytes[index]) != (other.bytes[index] & netmask.bytes[index]) {
            return false
        }
        return true
    }

    public static func current() -> [LocalInterfaceAddress] {
        #if canImport(Darwin) || canImport(Glibc)
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [LocalInterfaceAddress] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int64(entry.pointee.ifa_flags)
            guard (flags & Int64(IFF_UP)) != 0,
                  let addr = entry.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = entry.pointee.ifa_netmask else { continue }
            func bytes(_ pointer: UnsafeMutablePointer<sockaddr>) -> [UInt8] {
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inet in
                    withUnsafeBytes(of: inet.pointee.sin_addr) { Array($0) }
                }
            }
            guard let address = IPAddress(family: .v4, bytes: bytes(addr)),
                  let netmask = IPAddress(family: .v4, bytes: bytes(mask)) else { continue }
            let ifaName = entry.pointee.ifa_name.map { String(cString: $0) } ?? ""
            found.append(LocalInterfaceAddress(name: ifaName, address: address, netmask: netmask))
        }
        return found
        #else
        return []
        #endif
    }
}

public struct MediaRoute: Equatable, Sendable {
    public enum Scope: Equatable, Sendable {
        case chosen(MediaNetwork)
        case all
    }

    public let scope: Scope
    public let host: String
    public let peerAddress: IPAddress?
    public let onLinkLocalAddresses: Set<IPAddress>
    public let unclassifiedReason: String?

    public static func allAddresses(host: String = "") -> MediaRoute {
        MediaRoute(scope: .all, host: host, peerAddress: nil, onLinkLocalAddresses: [], unclassifiedReason: nil)
    }

    public static func decide(
        preference: MediaAddressesPreference,
        host: String,
        resolved: [String] = [],
        interfaces: [LocalInterfaceAddress] = LocalInterfaceAddress.current()
    ) -> MediaRoute {
        guard preference == .chosenNetwork else { return .allAddresses(host: host) }

        let peerAddress: IPAddress?
        let network: MediaNetwork?
        if MediaNetwork.needsResolution(host: host) {
            peerAddress = resolved.lazy.compactMap { IPAddress($0) }.first
            network = peerAddress.flatMap { MediaNetwork.classify($0) }
        } else {
            peerAddress = IPAddress(host)
            network = MediaNetwork.classify(host: host)
        }

        guard let network else {
            let reason: String
            if MediaNetwork.needsResolution(host: host), peerAddress == nil {
                reason = "\(host) did not resolve"
            } else if let peerAddress, peerAddress.description != host {
                reason = "\(host) resolved to \(peerAddress), which is neither a LAN nor a Tailscale address"
            } else {
                reason = "\(host) is neither a LAN nor a Tailscale address"
            }
            return MediaRoute(scope: .all, host: host, peerAddress: peerAddress, onLinkLocalAddresses: [], unclassifiedReason: reason)
        }

        var onLink: Set<IPAddress> = []
        if network == .lan, let peerAddress {
            onLink = Set(interfaces.filter { $0.sharesSubnet(with: peerAddress) }.map(\.address))
        }
        return MediaRoute(scope: .chosen(network), host: host, peerAddress: peerAddress, onLinkLocalAddresses: onLink, unclassifiedReason: nil)
    }

    public var appliedPreference: MediaAddressesPreference {
        if case .chosen = scope { return .chosenNetwork }
        return .all
    }

    public var addsPublicSTUN: Bool {
        switch scope {
        case .chosen: return false
        case .all: return !MediaNetworkRules.isDirectlyReachable(host: host)
        }
    }

    public func keepsRemote(_ candidate: ICECandidateLine) -> Bool {
        switch scope {
        case .all:
            return true
        case .chosen(.lan):
            guard candidate.type == "host", let ip = candidate.ip else { return false }
            return ip.isPrivateLAN
        case .chosen(.tailscale):
            return candidate.ip?.isTailscale == true
        }
    }

    public func keepsLocal(_ candidate: ICECandidateLine) -> Bool {
        switch scope {
        case .all:
            return true
        case .chosen(.tailscale):
            return candidate.ip?.isTailscale == true
        case .chosen(.lan):
            guard let ip = candidate.ip else { return false }
            if ip.isTailscale || ip.isLoopback { return false }
            return onLinkLocalAddresses.isEmpty || onLinkLocalAddresses.contains(ip)
        }
    }

    public func filterRemoteOffer(_ sdp: String) -> RemoteOfferFilterResult {
        guard case .chosen = scope else {
            return RemoteOfferFilterResult(sdp: sdp, dropped: [], keptWholeOffer: false)
        }
        let lines = sdp.components(separatedBy: "\n")
        var kept: [String] = []
        var dropped: [ICECandidateLine] = []
        var all: [ICECandidateLine] = []
        var sectionHad = 0
        var sectionKept = 0
        var emptiedASection = false

        func closeSection() {
            if sectionHad > 0 && sectionKept == 0 { emptiedASection = true }
            sectionHad = 0
            sectionKept = 0
        }

        for line in lines {
            if line.hasPrefix("m=") {
                closeSection()
            }
            if line.hasPrefix("a=candidate:"), let candidate = ICECandidateLine(line) {
                all.append(candidate)
                sectionHad += 1
                if keepsRemote(candidate) {
                    sectionKept += 1
                } else {
                    dropped.append(candidate)
                    continue
                }
            }
            kept.append(line)
        }
        closeSection()

        if emptiedASection {
            return RemoteOfferFilterResult(sdp: sdp, dropped: [], keptWholeOffer: true, usedWhole: all)
        }
        return RemoteOfferFilterResult(sdp: kept.joined(separator: "\n"), dropped: dropped, keptWholeOffer: false)
    }

    public var connectDescription: String {
        switch scope {
        case .chosen(let network):
            var text = "Video and audio limited to \(network.name) (chosen network only), connecting through \(host)"
            if let peerAddress, peerAddress.description != host {
                text += " (\(peerAddress))"
            }
            switch network {
            case .lan:
                text += "; VPN and loopback adapters left out"
                if !onLinkLocalAddresses.isEmpty {
                    let addresses = onLinkLocalAddresses.map(\.description).sorted().joined(separator: ", ")
                    text += "; local candidates limited to \(addresses)"
                }
            case .tailscale:
                text += "; only Tailscale candidates used"
            }
            return text
        case .all:
            if let unclassifiedReason {
                return "Video and audio may use any network (all addresses) for this connect: \(unclassifiedReason)"
            }
            return "Video and audio may use any network (all addresses)"
        }
    }

    public var limitDescription: String {
        if case .chosen(let network) = scope {
            return "Video and audio limited to \(network.name) (chosen network only)"
        }
        return "Video and audio may use any network (all addresses)"
    }
}

public enum HostResolver {
    public static func addresses(of host: String, timeout: TimeInterval = 2) -> [String] {
        #if canImport(Darwin) || canImport(Glibc)
        let lock = NSLock()
        var resolved: [String]?
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let found = lookUp(host)
            lock.lock()
            if resolved == nil { resolved = found }
            lock.unlock()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        lock.lock()
        let out = resolved ?? []
        lock.unlock()
        return out
        #else
        _ = host
        _ = timeout
        return []
        #endif
    }

    #if canImport(Darwin) || canImport(Glibc)
    private static func lookUp(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = Int32(SOCK_STREAM)
        #endif
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(result) }
        var addresses: [String] = []
        for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let addr = entry.pointee.ai_addr else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(cString: buffer)
                if !addresses.contains(text) { addresses.append(text) }
            }
        }
        return addresses
    }
    #endif
}
