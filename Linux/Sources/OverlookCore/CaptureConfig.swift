import Foundation

public enum RecordingVideoCodec: String, CaseIterable, Codable, Equatable, Sendable {
    case h264
    case hevc

    public var title: String {
        switch self {
        case .h264: return "H.264 (VAAPI / Universal)"
        case .hevc: return "HEVC / H.265 (VAAPI / Smaller files)"
        }
    }

    public var shortTitle: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }
}

public struct VAAPIProbeStatus: Codable, Equatable, Sendable {
    public var available: Bool
    public var device: String
    public var driver: String
    public var h264: Bool
    public var hevc: Bool

    public init(available: Bool = false, device: String = "", driver: String = "", h264: Bool = false, hevc: Bool = false) {
        self.available = available
        self.device = device
        self.driver = driver
        self.h264 = h264
        self.hevc = hevc
    }

    public var summary: String {
        guard available else { return "VAAPI unavailable (software fallback)" }
        var codecs: [String] = []
        if h264 { codecs.append("H.264") }
        if hevc { codecs.append("HEVC") }
        let codecStr = codecs.isEmpty ? "No encode" : codecs.joined(separator: ", ")
        let shortDriver = driver.isEmpty ? "VA-API" : driver
        return "\(device) · \(codecStr) · \(shortDriver)"
    }
}

public struct AppPreferences: Codable, Equatable, Sendable {
    public var screenshotsFolder: String
    public var recordingsFolder: String
    public var videoCodec: RecordingVideoCodec
    public var vaapiDevice: String
    public var relativeSensitivity: Double
    public var appAppearance: String
    public var preferServerOCR: Bool
    public var serverOCRLanguage: String

    public init(
        screenshotsFolder: String = AppPreferences.defaultScreenshotsURL.path,
        recordingsFolder: String = AppPreferences.defaultRecordingsURL.path,
        videoCodec: RecordingVideoCodec = .h264,
        vaapiDevice: String = "",
        relativeSensitivity: Double = 1.0,
        appAppearance: String = "system",
        preferServerOCR: Bool = true,
        serverOCRLanguage: String = "eng"
    ) {
        self.screenshotsFolder = screenshotsFolder
        self.recordingsFolder = recordingsFolder
        self.videoCodec = videoCodec
        self.vaapiDevice = vaapiDevice
        self.relativeSensitivity = relativeSensitivity
        self.appAppearance = appAppearance
        self.preferServerOCR = preferServerOCR
        self.serverOCRLanguage = serverOCRLanguage
    }

    public static var defaultScreenshotsURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Pictures/Overlook", isDirectory: true)
    }

    public static var defaultRecordingsURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let videos = home.appendingPathComponent("Videos", isDirectory: true)
        let movies = home.appendingPathComponent("Movies", isDirectory: true)
        if FileManager.default.fileExists(atPath: videos.path) {
            return videos.appendingPathComponent("Overlook", isDirectory: true)
        }
        if FileManager.default.fileExists(atPath: movies.path) {
            return movies.appendingPathComponent("Overlook", isDirectory: true)
        }
        return videos.appendingPathComponent("Overlook", isDirectory: true)
    }
}

public struct PreferencesStore {
    public let file: URL

    public init(file: URL? = nil) {
        let env = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let root = env.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        self.file = file ?? root.appendingPathComponent("overlook/preferences.json")
    }

    public func load() -> AppPreferences {
        guard FileManager.default.fileExists(atPath: file.path),
              let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode(AppPreferences.self, from: data) else {
            return AppPreferences()
        }
        return decoded
    }

    public func save(_ prefs: AppPreferences) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(prefs).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

public enum CaptureFileNaming {
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    public static func makeFileURL(in folder: URL, deviceName: String?, date: Date = Date(), extension ext: String) -> URL {
        var stem = "Overlook"
        if let deviceName {
            let cleaned = deviceName
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                stem += " \(cleaned)"
            }
        }
        stem += " " + timestampFormatter.string(from: date)

        var candidate = folder.appendingPathComponent(stem).appendingPathExtension(ext)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) (\(counter))").appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }

    public static func durationText(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
