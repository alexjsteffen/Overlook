import Foundation

/// Splits text into grapheme-cluster-safe chunks of at most `maxScalars` Unicode scalar values for
/// kvmd's `/api/hid/print?limit=0` endpoint, so long clipboard pastes do not exceed a single
/// request timeout and can be aborted cleanly on disconnect.
public enum RemotePasteChunker {
    public static let maxScalarsPerPart = 512

    public static func parts(of text: String, maxScalars: Int = maxScalarsPerPart) -> [String] {
        guard !text.isEmpty else { return [] }
        let limit = max(1, maxScalars)
        var parts: [String] = []
        var current = ""
        var currentScalars = 0
        for character in text {
            let scalars = character.unicodeScalars.count
            if currentScalars > 0, currentScalars + scalars > limit {
                parts.append(current)
                current = ""
                currentScalars = 0
            }
            current.append(character)
            currentScalars += scalars
        }
        if !current.isEmpty {
            parts.append(current)
        }
        return parts
    }

    public static func queryItems(keymap: String?, limit: Int = 0) -> [(String, String)] {
        var items: [(String, String)] = []
        if let keymap, !keymap.isEmpty {
            items.append(("keymap", keymap))
        }
        items.append(("limit", String(limit)))
        return items
    }
}
