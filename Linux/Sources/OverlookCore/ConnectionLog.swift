import Foundation

public enum ConnectionLogCategory: String, CaseIterable, Sendable {
    case lifecycle
    case signaling
    case ice
    case stream
    case hid
    case device
    case power
    case network
}

public enum ConnectionLogLevel: Int, Comparable, CaseIterable, Sendable {
    case debug = 0
    case info = 1
    case notice = 2
    case warning = 3
    case error = 4

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var fileTag: String {
        switch self {
        case .debug: return "DBUG"
        case .info: return "INFO"
        case .notice: return "NOTE"
        case .warning: return "WARN"
        case .error: return "FAIL"
        }
    }

    public var displayName: String {
        switch self {
        case .debug: return "Debug"
        case .info: return "Info"
        case .notice: return "Notice"
        case .warning: return "Warning"
        case .error: return "Error"
        }
    }
}

public struct ConnectionLogEvent: Identifiable, Equatable, Sendable {
    public let id: UInt64
    public let date: Date
    public let level: ConnectionLogLevel
    public let category: ConnectionLogCategory
    public let message: String

    public init(id: UInt64, date: Date = Date(), level: ConnectionLogLevel, category: ConnectionLogCategory, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.category = category
        self.message = message
    }
}

public final class ConnectionLog {
    public static let shared = ConnectionLog()
    public static let capacity = 400
    private static let maxFileBytes: UInt64 = 4 * 1024 * 1024
    private static let keptGenerations = 3

    public let directoryURL: URL
    public let fileURL: URL
    private let lock = NSLock()
    private var counter: UInt64 = 0
    private var handle: FileHandle?
    private var bytesWritten: UInt64 = 0

    public private(set) var events: [ConnectionLogEvent] = []
    public private(set) var unseenProblemCount: Int = 0
    public private(set) var lastProblem: ConnectionLogEvent?
    public var onChanged: (() -> Void)?

    private static let fileFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    public init(directoryURL: URL? = nil) {
        let env = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        let root = env.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state")
        let base = directoryURL ?? root.appendingPathComponent("overlook", isDirectory: true)
        self.directoryURL = base
        self.fileURL = base.appendingPathComponent("connection.log", isDirectory: false)
    }

    public func log(_ level: ConnectionLogLevel, _ category: ConnectionLogCategory, _ message: String) {
        lock.lock()
        counter &+= 1
        let event = ConnectionLogEvent(id: counter, date: Date(), level: level, category: category, message: message)
        events.insert(event, at: 0)
        if events.count > Self.capacity {
            events.removeLast(events.count - Self.capacity)
        }
        if level >= .warning {
            unseenProblemCount += 1
            lastProblem = event
        }
        appendToFileLocked(event)
        let callback = onChanged
        lock.unlock()
        callback?()
    }

    public func debug(_ category: ConnectionLogCategory, _ message: String) { log(.debug, category, message) }
    public func info(_ category: ConnectionLogCategory, _ message: String) { log(.info, category, message) }
    public func notice(_ category: ConnectionLogCategory, _ message: String) { log(.notice, category, message) }
    public func warning(_ category: ConnectionLogCategory, _ message: String) { log(.warning, category, message) }
    public func error(_ category: ConnectionLogCategory, _ message: String) { log(.error, category, message) }

    public func markProblemsViewed() {
        lock.lock()
        unseenProblemCount = 0
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        events.removeAll()
        unseenProblemCount = 0
        lastProblem = nil
        let callback = onChanged
        lock.unlock()
        callback?()
    }

    public func formattedText(minimumLevel: ConnectionLogLevel = .debug, category: ConnectionLogCategory? = nil) -> String {
        lock.lock()
        let filtered = events.reversed().filter { event in
            event.level >= minimumLevel && (category == nil || event.category == category)
        }
        lock.unlock()
        guard !filtered.isEmpty else { return "(No connection log events matching filter)" }
        return filtered.map { event in
            "\(Self.fileFormatter.string(from: event.date))  \(event.level.fileTag)  [\(event.category.rawValue)] \(event.message)"
        }.joined(separator: "\n")
    }

    private func openFileLocked() {
        let manager = FileManager.default
        try? manager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !manager.fileExists(atPath: fileURL.path) {
            _ = manager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        if let handle {
            bytesWritten = (try? handle.seekToEnd()) ?? 0
        }
    }

    private func appendToFileLocked(_ event: ConnectionLogEvent) {
        let line = "\(Self.fileFormatter.string(from: event.date))  \(event.level.fileTag)  [\(event.category.rawValue)] \(event.message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if handle == nil { openFileLocked() }
        guard let handle else { return }
        try? handle.write(contentsOf: data)
        bytesWritten += UInt64(data.count)
        if bytesWritten > Self.maxFileBytes {
            rotateLocked()
        }
    }

    private func rotateLocked() {
        let manager = FileManager.default
        try? handle?.close()
        handle = nil
        let oldest = directoryURL.appendingPathComponent("connection.\(Self.keptGenerations).log")
        try? manager.removeItem(at: oldest)
        for gen in stride(from: Self.keptGenerations - 1, through: 1, by: -1) {
            let from = directoryURL.appendingPathComponent("connection.\(gen).log")
            let to = directoryURL.appendingPathComponent("connection.\(gen + 1).log")
            guard manager.fileExists(atPath: from.path) else { continue }
            try? manager.removeItem(at: to)
            try? manager.moveItem(at: from, to: to)
        }
        let first = directoryURL.appendingPathComponent("connection.1.log")
        try? manager.removeItem(at: first)
        try? manager.moveItem(at: fileURL, to: first)
        bytesWritten = 0
        openFileLocked()
    }
}
