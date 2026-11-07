import Foundation
import CNativeWin
import OverlookCore

enum PasswordStatus {
    case ready
    case missing(String)
    case error(String)
}

final class PasswordStore {
    func load(for device: Device) -> (String?, PasswordStatus) {
        var message: UnsafeMutablePointer<CChar>?
        let value = device.address.withCString { address in
            ol_wincred_lookup(address, &message)
        }
        defer {
            ol_wincred_free(value)
            ol_wincred_free(message)
        }

        if let message {
            return (nil, .error(String(cString: message)))
        }
        guard let value else { return (nil, .ready) }
        return (String(cString: value), .ready)
    }

    func save(_ password: String, for device: Device) -> PasswordStatus {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return clear(for: device)
        }

        var message: UnsafeMutablePointer<CChar>?
        let ok = device.address.withCString { address in
            trimmed.withCString { value in
                ol_wincred_store(address, value, &message)
            }
        }
        defer { ol_wincred_free(message) }

        if ok != 0 { return .ready }
        if let message {
            return .error(String(cString: message))
        }
        return .error("Could not save password to Windows Credential Manager.")
    }

    func clear(for device: Device) -> PasswordStatus {
        var message: UnsafeMutablePointer<CChar>?
        let ok = device.address.withCString { address in
            ol_wincred_clear(address, &message)
        }
        defer { ol_wincred_free(message) }

        if ok != 0 { return .ready }
        if let message {
            return .error(String(cString: message))
        }
        return .error("Could not remove password from Windows Credential Manager.")
    }
}
