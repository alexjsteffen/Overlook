import Foundation
import XCTest
@testable import OverlookCore

final class DeviceTests: XCTestCase {
    func testAddresses() throws {
        XCTAssertEqual(try DeviceAddress.parse(" pikvm.local ").absoluteString, "https://pikvm.local/")
        XCTAssertEqual(try DeviceAddress.parse("http://192.168.1.9:8080/kvm/").port, 8080)
        XCTAssertEqual(try DeviceAddress.parse("https://[::1]:8443/").port, 8443)
        for invalid in ["", "file:///etc/passwd", "javascript:alert(1)", "https://user:secret@host", "https://host/?token=secret", "https://host/#secret", "https://a b", "https://host:99999"] {
            XCTAssertThrowsError(try DeviceAddress.parse(invalid), invalid)
        }
    }
    func testRoundTripAndPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeviceStore(file: root.appendingPathComponent("devices.json"))
        XCTAssertEqual(try store.load(), [])
        let device = try Device(name: "Lab", address: "pikvm.local")
        try store.save([device])
        XCTAssertEqual(try store.load(), [device])
        let attributes = try FileManager.default.attributesOfItem(atPath: store.file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try store.save([])
        XCTAssertEqual(try store.load(), [])
    }
    func testCorruptFileIsNotSilentlyOverwritten() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not json".utf8).write(to: file)
        XCTAssertThrowsError(try DeviceStore(file: file).load())
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "not json")
    }
    func testUntrustedStoredAddress() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let json = """
        [{"id":"\(UUID().uuidString)","name":"Unsafe","address":"file:///etc/passwd"}]
        """
        try Data(json.utf8).write(to: file)
        XCTAssertThrowsError(try DeviceStore(file: file).load())
    }
}
