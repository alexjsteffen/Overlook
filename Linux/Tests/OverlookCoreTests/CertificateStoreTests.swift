import Foundation
import XCTest
@testable import OverlookCore

final class CertificateStoreTests: XCTestCase {
    func testSHA256() {
        XCTAssertEqual(CertificateFingerprint.sha256([]), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(CertificateFingerprint.sha256(Array("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(CertificateFingerprint.sha256(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(CertificateFingerprint.sha256([UInt8](repeating: 0x61, count: 1_000_000)),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }
    func testDisplay() {
        XCTAssertEqual(CertificateFingerprint.display("ab01cd"), "AB:01:CD")
        XCTAssertEqual(CertificateFingerprint.display(""), "")
    }
    func testKeys() {
        XCTAssertEqual(CertificateStore.key(host: "PiKVM.Local", port: 443), "pikvm.local:443")
        XCTAssertEqual(CertificateStore.key(for: URL(string: "https://PiKVM.local/")!), "pikvm.local:443")
        XCTAssertEqual(CertificateStore.key(for: URL(string: "wss://pikvm.local/api/ws")!), "pikvm.local:443")
        XCTAssertEqual(CertificateStore.key(for: URL(string: "http://pikvm.local")!), "pikvm.local:80")
        XCTAssertEqual(CertificateStore.key(for: URL(string: "ws://pikvm.local")!), "pikvm.local:80")
        XCTAssertEqual(CertificateStore.key(for: URL(string: "https://10.0.0.2:8443/kvm/")!), "10.0.0.2:8443")
        XCTAssertNil(CertificateStore.key(for: URL(string: "file:///etc/passwd")!))
    }
    func testRoundTripPermissionsAndForget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CertificateStore(url: root.appendingPathComponent("overlook/trusted-certificates.json"))
        XCTAssertEqual(try store.load(), [:])
        XCTAssertNil(store.pinned("a:443"))
        try store.trust("a:443", sha256: "AA")
        try store.trust("b:443", sha256: "bb")
        XCTAssertEqual(try CertificateStore(url: store.url).load(), ["a:443": "aa", "b:443": "bb"])
        XCTAssertEqual(store.pinned("a:443"), "aa")
        let file = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dir = try FileManager.default.attributesOfItem(atPath: store.url.deletingLastPathComponent().path)
        XCTAssertEqual((dir[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        try store.forget("a:443")
        XCTAssertEqual(try store.load(), ["b:443": "bb"])
        try store.forgetAll()
        XCTAssertEqual(try store.load(), [:])
    }
    func testCorruptFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not json".utf8).write(to: file)
        let store = CertificateStore(url: file)
        XCTAssertThrowsError(try store.load())
        XCTAssertNil(store.pinned("a:443"))
        XCTAssertThrowsError(try store.trust("a:443", sha256: "aa"))
        try store.forgetAll()
        XCTAssertEqual(try store.load(), [:])
    }
    func testDefaultPath() {
        XCTAssertTrue(CertificateStore().url.path.hasSuffix("/overlook/trusted-certificates.json"))
    }
}
