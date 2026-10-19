import Foundation
import Network
import Combine
import AppKit

@MainActor
class TailscaleManager: ObservableObject {
    @Published var isConnected = false
    @Published var status: TailscaleStatus = .unknown
    @Published var availableNodes: [TailscaleNode] = []
    @Published var currentUser: TailscaleUser?
    @Published var isInstalled = false

    private var statusTimer: Timer?
    private var processMonitor: Process?
    private var resolvedExecutableURL: URL?

    nonisolated static let candidateExecutablePaths: [String] = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
        "/usr/bin/tailscale",
    ]

    nonisolated static func findTailscaleExecutable() -> URL? {
        let fm = FileManager.default
        for path in candidateExecutablePaths where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    init() {
        checkTailscaleInstallation()
        startStatusMonitoring()
    }

    // MARK: - Installation Check

    private func checkTailscaleInstallation() {
        guard let execURL = Self.findTailscaleExecutable() else {
            isInstalled = false
            resolvedExecutableURL = nil
            return
        }
        resolvedExecutableURL = execURL
        isInstalled = true
        updateStatus()
    }

    // MARK: - Status Monitoring

    private func startStatusMonitoring() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatus()
            }
        }
        if let statusTimer {
            RunLoop.main.add(statusTimer, forMode: .common)
        }
    }

    private func updateStatus() {
        guard isInstalled, let execURL = resolvedExecutableURL else { return }

        Task {
            guard let snapshot = await Self.fetchStatusSnapshot(executableURL: execURL) else { return }
            await MainActor.run {
                self.status = snapshot.status
                self.isConnected = (snapshot.status == .connected)
                self.availableNodes = snapshot.nodes
                if let user = snapshot.user {
                    self.currentUser = user
                }
            }
        }
    }

    private struct StatusSnapshot {
        let status: TailscaleStatus
        let nodes: [TailscaleNode]
        let user: TailscaleUser?
    }

    nonisolated private static func fetchStatusSnapshot(executableURL: URL) async -> StatusSnapshot? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let task = Process()
                task.executableURL = executableURL
                task.arguments = ["status", "--json"]

                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = pipe

                do {
                    try task.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    task.waitUntilExit()

                    guard task.terminationStatus == 0,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        continuation.resume(returning: nil)
                        return
                    }

                    let backendState = (json["BackendState"] as? String) ?? ""
                    let status: TailscaleStatus
                    switch backendState {
                    case "Running":
                        status = .connected
                    case "Starting":
                        status = .connecting
                    case "Stopped", "NeedsLogin", "NoState":
                        status = .disconnected
                    default:
                        status = .unknown
                    }

                    var nodes: [TailscaleNode] = []
                    if let peerList = json["Peer"] as? [String: Any] {
                        for (nodeID, peerData) in peerList {
                            guard let peerDict = peerData as? [String: Any] else { continue }
                            let hostname = (peerDict["HostName"] as? String) ?? ""
                            let rawDNS = (peerDict["DNSName"] as? String) ?? ""
                            let dnsName = rawDNS.hasSuffix(".") ? String(rawDNS.dropLast()) : rawDNS
                            let os = (peerDict["OS"] as? String) ?? ""
                            let online = (peerDict["Online"] as? Bool) ?? false
                            let addresses = (peerDict["TailscaleIPs"] as? [String]) ?? []
                            let tags = (peerDict["Tags"] as? [String]) ?? []

                            if !hostname.isEmpty || !dnsName.isEmpty || !addresses.isEmpty {
                                nodes.append(
                                    TailscaleNode(
                                        id: nodeID,
                                        hostname: hostname.isEmpty ? dnsName : hostname,
                                        dnsName: dnsName.isEmpty ? (addresses.first ?? hostname) : dnsName,
                                        os: os,
                                        online: online,
                                        addresses: addresses,
                                        tags: tags
                                    )
                                )
                            }
                        }
                    }

                    var resolvedUser: TailscaleUser? = nil
                    if let userStr = json["User"] as? String {
                        resolvedUser = TailscaleUser(loginName: userStr, displayName: userStr, profilePictureURL: nil)
                    } else if let selfNode = json["Self"] as? [String: Any],
                              let userID = selfNode["UserID"] as? Int,
                              let userMap = json["User"] as? [String: Any],
                              let userProfile = userMap[String(userID)] as? [String: Any] {
                        let loginName = (userProfile["LoginName"] as? String) ?? ""
                        let displayName = (userProfile["DisplayName"] as? String) ?? loginName
                        resolvedUser = TailscaleUser(loginName: loginName, displayName: displayName, profilePictureURL: nil)
                    }

                    continuation.resume(returning: StatusSnapshot(status: status, nodes: nodes, user: resolvedUser))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Connection Management

    func connect() async throws {
        guard isInstalled, let execURL = resolvedExecutableURL else {
            throw TailscaleError.notInstalled
        }

        try await runTailscaleCommand(executableURL: execURL, arguments: ["up"]) { output in
            TailscaleError.connectionFailed(output)
        }
        updateStatus()
    }

    func disconnect() async throws {
        guard isInstalled, let execURL = resolvedExecutableURL else {
            throw TailscaleError.notInstalled
        }

        try await runTailscaleCommand(executableURL: execURL, arguments: ["down"]) { output in
            TailscaleError.disconnectionFailed(output)
        }
        updateStatus()
    }

    nonisolated private func runTailscaleCommand(
        executableURL: URL,
        arguments: [String],
        errorTransform: @escaping @Sendable (String) -> TailscaleError
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = executableURL
                task.arguments = arguments

                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = pipe

                do {
                    try task.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    task.waitUntilExit()

                    if task.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let output = String(data: data, encoding: .utf8) ?? ""
                        continuation.resume(throwing: errorTransform(output))
                    }
                } catch {
                    continuation.resume(throwing: errorTransform(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - KVM Device Discovery

    func discoverKVMDevices() async -> [KVMDevice] {
        guard isConnected else { return [] }

        var kvmDevices: [KVMDevice] = []

        for node in availableNodes where node.online && node.isKVMDevice {
            if let device = await createKVMDevice(from: node) {
                kvmDevices.append(device)
            }
        }

        return kvmDevices
    }

    private func createKVMDevice(from node: TailscaleNode) async -> KVMDevice? {
        let commonPorts = [443, 8443, 80, 8080]
        let hostCandidate = node.dnsName.isEmpty ? (node.addresses.first ?? node.hostname) : node.dnsName
        guard !hostCandidate.isEmpty else { return nil }

        for port in commonPorts {
            if await isKVMServiceAvailable(host: hostCandidate, port: port) {
                return KVMDevice(
                    id: "tailscale-\(node.id)",
                    name: "\(node.hostname) (Tailscale)",
                    host: hostCandidate,
                    port: port,
                    type: .tailscale,
                    authToken: "",
                    capabilities: [.videoStreaming, .keyboardInput, .mouseInput, .virtualMedia, .powerManagement, .ocrSupport]
                )
            }
        }

        return nil
    }

    private func isKVMServiceAvailable(host: String, port: Int) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return false
        }

        final class ContinuationGate {
            var resumed = false
        }

        let queue = DispatchQueue(label: "com.overlook.tailscale.probe")
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)

        return await withCheckedContinuation { continuation in
            let gate = ContinuationGate()

            let timeoutWork = DispatchWorkItem {
                if gate.resumed { return }
                gate.resumed = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: false)
            }

            queue.asyncAfter(deadline: .now() + 2.5, execute: timeoutWork)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.resumed { return }
                    gate.resumed = true
                    timeoutWork.cancel()
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    if gate.resumed { return }
                    gate.resumed = true
                    timeoutWork.cancel()
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }

    // MARK: - Network Configuration

    func getTailscaleIP() -> String? {
        guard let node = availableNodes.first(where: { $0.isCurrentMachine }) else { return nil }
        return node.addresses.first
    }

    func enableMagicDNS() async throws {
        guard isInstalled, let execURL = resolvedExecutableURL else {
            throw TailscaleError.notInstalled
        }
        try await runTailscaleCommand(executableURL: execURL, arguments: ["set", "--magic-dns=true"]) { _ in
            TailscaleError.configurationFailed
        }
    }

    func enableKeyExpiry() async throws {
        guard isInstalled, let execURL = resolvedExecutableURL else {
            throw TailscaleError.notInstalled
        }
        try await runTailscaleCommand(executableURL: execURL, arguments: ["set", "--key-expire=90d"]) { _ in
            TailscaleError.configurationFailed
        }
    }

    // MARK: - Authentication

    func login() async throws {
        guard isInstalled, let execURL = resolvedExecutableURL else {
            throw TailscaleError.notInstalled
        }
        try await runTailscaleCommand(executableURL: execURL, arguments: ["login"]) { _ in
            TailscaleError.authenticationFailed
        }
        updateStatus()
    }

    func logout() async throws {
        guard isInstalled, let execURL = resolvedExecutableURL else {
            throw TailscaleError.notInstalled
        }
        try await runTailscaleCommand(executableURL: execURL, arguments: ["logout"]) { _ in
            TailscaleError.authenticationFailed
        }
        updateStatus()
    }

    deinit {
        statusTimer?.invalidate()
        processMonitor?.terminate()
    }
}

// MARK: - Supporting Types
enum TailscaleStatus: String, CaseIterable {
    case unknown = "unknown"
    case disconnected = "disconnected"
    case connecting = "connecting"
    case connected = "connected"

    var displayName: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        }
    }
}

struct TailscaleNode: Identifiable, Codable {
    let id: String
    let hostname: String
    let dnsName: String
    let os: String
    let online: Bool
    let addresses: [String]
    let tags: [String]

    var isKVMDevice: Bool {
        let lowerHost = hostname.lowercased()
        let lowerDNS = dnsName.lowercased()
        return lowerHost.contains("kvm") ||
               lowerHost.contains("pikvm") ||
               lowerHost.contains("glkvm") ||
               lowerHost.contains("comet") ||
               lowerHost.contains("remote") ||
               lowerDNS.contains("kvm") ||
               tags.contains("tag:kvm") ||
               tags.contains("tag:pikvm") ||
               tags.contains("tag:remote") ||
               os.lowercased().contains("linux")
    }

    var isCurrentMachine: Bool {
        return hostname.contains(Foundation.Host.current().localizedName ?? "")
    }

    var displayAddresses: String {
        return addresses.joined(separator: ", ")
    }
}

struct TailscaleUser: Codable {
    let loginName: String
    let displayName: String
    let profilePictureURL: URL?

    var initials: String {
        let components = displayName.components(separatedBy: " ")
        return components.compactMap { $0.first }.map(String.init).joined().uppercased()
    }
}

enum TailscaleError: Error, LocalizedError {
    case notInstalled
    case connectionFailed(String)
    case disconnectionFailed(String)
    case authenticationFailed
    case configurationFailed
    case networkUnavailable
    case manualInstallationRequired

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Tailscale is not installed"
        case .connectionFailed(let message):
            return "Failed to connect to Tailscale: \(message)"
        case .disconnectionFailed(let message):
            return "Failed to disconnect from Tailscale: \(message)"
        case .authenticationFailed:
            return "Tailscale authentication failed"
        case .configurationFailed:
            return "Failed to configure Tailscale"
        case .networkUnavailable:
            return "Network is not available"
        case .manualInstallationRequired:
            return "Install Tailscale from tailscale.com, then try again"
        }
    }
}

// MARK: - Tailscale Installation Helper
extension TailscaleManager {
    /// Overlook does not download and run installers: an unverified binary fetched over the
    /// network and executed from a temp directory is exactly what Gatekeeper exists to prevent.
    /// Installation is the user's action on Tailscale's download page.
    func installTailscale() async throws {
        openTailscaleWebsite()
        throw TailscaleError.manualInstallationRequired
    }

    func openTailscaleWebsite() {
        if let url = URL(string: "https://tailscale.com/download/mac/") {
            NSWorkspace.shared.open(url)
        }
    }
}
