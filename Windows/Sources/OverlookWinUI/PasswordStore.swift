import Foundation
import CNativeWin

struct SavedCredentials: Codable {
    let username: String
    let password: String
}

struct PasswordStore {
    enum StoreError: LocalizedError {
        case keyring(String)
        var errorDescription: String? {
            switch self { case .keyring(let message): return message }
        }
    }

    private func check(_ message: UnsafeMutablePointer<CChar>?) throws {
        guard let message else { return }
        defer { ol_wincred_free(message) }
        throw StoreError.keyring(String(cString: message))
    }

    func load(for address: URL) throws -> SavedCredentials? {
        var message: UnsafeMutablePointer<CChar>?
        let value = ol_wincred_lookup(address.absoluteString, &message)
        defer { if let value { ol_wincred_free(value) } }
        try check(message)
        guard let value else { return nil }
        return try JSONDecoder().decode(SavedCredentials.self, from: Data(String(cString: value).utf8))
    }

    func save(_ credentials: SavedCredentials, for address: URL) throws {
        let data = try JSONEncoder().encode(credentials)
        let value = String(decoding: data, as: UTF8.self)
        var message: UnsafeMutablePointer<CChar>?
        let success = ol_wincred_store(address.absoluteString, value, &message)
        try check(message)
        if success == 0 { throw StoreError.keyring("Could not save password in Windows Credential Manager.") }
    }

    func delete(for address: URL) throws {
        var message: UnsafeMutablePointer<CChar>?
        let success = ol_wincred_clear(address.absoluteString, &message)
        try check(message)
        if success == 0 { throw StoreError.keyring("Could not remove password from Windows Credential Manager.") }
    }
}
