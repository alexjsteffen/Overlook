import Foundation
import XCTest
@testable import OverlookCore

final class NanoKVMTests: XCTestCase {
    func testPasswordEncryptionRoundTripAndDeterminism() {
        let fixedSalt: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        let encrypted1 = NanoKVMCrypto.encryptPassword("admin", salt: fixedSalt)
        let encrypted2 = NanoKVMCrypto.encryptPassword("admin", salt: fixedSalt)
        XCTAssertEqual(encrypted1, encrypted2)
        // Base64 of "Salted__" starts with "U2FsdGVkX1"
        XCTAssertTrue(encrypted1.hasPrefix("U2FsdGVkX1"))
        XCTAssertEqual(NanoKVMCrypto.decryptPassword(encrypted1), "admin")

        // Real vector produced by NanoKVM's Go `url.QueryEscape(aes256.Encrypt("admin", utils.SecretKey))`
        let goVector = "U2FsdGVkX1%2FcGCUw6Yb260Vm%2Fgieqd%2BK%2F8%2FDJW8vSM8%3D"
        XCTAssertEqual(NanoKVMCrypto.decryptPassword(goVector), "admin")

        let (key, iv) = NanoKVMCrypto.deriveKeyAndIV(passphrase: Array("nanokvm-sipeed-2024".utf8), salt: fixedSalt)
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(), "42c3fe5fe864ee325657646ae8c9d363ba0b3496e5a88c44ba6ce6eea6c952fe")
        XCTAssertEqual(iv.map { String(format: "%02x", $0) }.joined(), "116c9a4f3b5668e5f13c47b174267d36")

        for sample in ["admin", "Sipeed!2026#Cube", "p@ssw0rd with spaces & symbols =+/", "1234567890123456"] {
            let enc = NanoKVMCrypto.encryptPassword(sample)
            XCTAssertEqual(NanoKVMCrypto.decryptPassword(enc), sample)
        }
    }

    func testLoginFormAndResponseParsing() throws {
        let form = NanoKVMCrypto.loginForm(username: "admin", password: "secret", otp: "123456")
        XCTAssertTrue(form.contains("user=admin"))
        XCTAssertTrue(form.contains("passwd=secret123456"))
        XCTAssertTrue(form.contains("Username=admin"))
        XCTAssertTrue(form.contains("Password=U2FsdGVkX1"))

        let nanoCookieResp = Data(#"{"code":0,"msg":"success","data":null}"#.utf8)
        let parsedNanoCookie = NanoKVMCrypto.parseLoginResponse(nanoCookieResp)
        XCTAssertTrue(parsedNanoCookie.isNanoKVM)
        XCTAssertTrue(parsedNanoCookie.ok)
        XCTAssertNil(parsedNanoCookie.token)

        let nanoTokenResp = Data(#"{"code":0,"msg":"success","data":{"token":"eyJ.nano.jwt"}}"#.utf8)
        let parsedNanoToken = NanoKVMCrypto.parseLoginResponse(nanoTokenResp)
        XCTAssertTrue(parsedNanoToken.isNanoKVM)
        XCTAssertTrue(parsedNanoToken.ok)
        XCTAssertEqual(parsedNanoToken.token, "eyJ.nano.jwt")

        let nanoErrResp = Data(#"{"code":-2,"msg":"invalid username or password"}"#.utf8)
        let parsedNanoErr = NanoKVMCrypto.parseLoginResponse(nanoErrResp)
        XCTAssertTrue(parsedNanoErr.isNanoKVM)
        XCTAssertFalse(parsedNanoErr.ok)
        XCTAssertEqual(parsedNanoErr.error, "invalid username or password")

        let pikvmResp = Data(#"{"ok":true,"result":{"token":"pikvm-token"}}"#.utf8)
        let parsedPiKVM = NanoKVMCrypto.parseLoginResponse(pikvmResp)
        XCTAssertFalse(parsedPiKVM.isNanoKVM)
        XCTAssertTrue(parsedPiKVM.ok)
        XCTAssertEqual(parsedPiKVM.token, "pikvm-token")
    }

    func testNanoKVMWebRTCSignaling() throws {
        var sig = NanoKVMSignaling()
        let iceMsg = Data(#"{"event":"ice-servers","data":"[{\"urls\":[\"stun:stun.l.google.com:19302\"]}]"}"#.utf8)
        let actions1 = try sig.receive(iceMsg)
        XCTAssertEqual(actions1, [.createOffer(stunServer: "stun:stun.l.google.com:19302")])
        XCTAssertTrue(sig.negotiationStarted)
        XCTAssertFalse(sig.useLegacyEvents)

        if case .send(let offerJSON) = sig.offer("v=0\r\n") {
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(offerJSON.utf8)) as? [String: String])
            XCTAssertEqual(obj["event"], "video-offer")
            let inner = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((obj["data"] ?? "").utf8)) as? [String: String])
            XCTAssertEqual(inner["type"], "offer")
            XCTAssertEqual(inner["sdp"], "v=0\r\n")
        } else {
            XCTFail("Expected .send action for offer")
        }

        // Candidate arriving before answer is buffered until answer is processed
        let candMsg = Data(#"{"event":"video-candidate","data":"{\"candidate\":\"candidate:1 1 UDP 123 192.168.1.50 50000 typ host\",\"sdpMLineIndex\":0}"}"#.utf8)
        XCTAssertTrue(try sig.receive(candMsg).isEmpty)

        let answerMsg = Data(#"{"event":"video-answer","data":"{\"type\":\"answer\",\"sdp\":\"v=0\\r\\na=recvonly\\r\\n\"}"}"#.utf8)
        let actions2 = try sig.receive(answerMsg)
        XCTAssertEqual(actions2, [
            .answer("v=0\r\na=recvonly\r\n"),
            .candidate(0, "candidate:1 1 UDP 123 192.168.1.50 50000 typ host")
        ])

        // Legacy fallback when no ice-servers arrives
        var legacySig = NanoKVMSignaling()
        XCTAssertEqual(legacySig.fallbackOfferIfNeeded(), [.createOffer(stunServer: nil)])
        XCTAssertTrue(legacySig.useLegacyEvents)
        if case .send(let legacyOfferJSON) = legacySig.offer("v=0\r\n") {
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(legacyOfferJSON.utf8)) as? [String: String])
            XCTAssertEqual(obj["event"], "offer")
        } else {
            XCTFail("Expected legacy offer")
        }
    }

    func testNanoKVMHIDKeyboardAndMouse() {
        var kb = NanoKVMKeyboardState()
        XCTAssertEqual(kb.keyDown("ControlLeft"), [0x01, 0x01, 0x00, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(kb.keyDown("AltLeft"), [0x01, 0x05, 0x00, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(kb.keyDown("Delete"), [0x01, 0x05, 0x00, 0x4c, 0, 0, 0, 0, 0])
        XCTAssertEqual(kb.keyUp("Delete"), [0x01, 0x05, 0x00, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(kb.reset(), [0x01, 0x00, 0x00, 0, 0, 0, 0, 0, 0])

        var mouse = NanoKVMMouseState()
        // Top-left (0.0, 0.0) -> 0x0001 (1, little endian [0x01, 0x00])
        XCTAssertEqual(mouse.moveAbsolute(normalizedX: 0.0, normalizedY: 0.0), [0x02, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00])
        // Bottom-right (1.0, 1.0) -> 0x7fff + 1 = 0x8000 or 0x7fff: floor(0x7fff * 1.0) + 1 = 0x8000? Wait!
        // Let's check: in NanoKVM absolute.tsx: Math.floor(0x7fff * finalX) + 0x0001 -> at 0.5 it is 0x4000
        let center = mouse.moveAbsolute(normalizedX: 0.5, normalizedY: 0.5)
        XCTAssertEqual(center, [0x02, 0x00, 0x00, 0x40, 0x00, 0x40, 0x00])
        // Left button down at center in absolute mode
        XCTAssertEqual(mouse.button("left", pressed: true, isAbsolute: true), [0x02, 0x01, 0x00, 0x40, 0x00, 0x40, 0x00])
        // Relative move with left button held
        XCTAssertEqual(mouse.moveRelative(dx: 10, dy: -5), [[0x02, 0x01, 10, UInt8(bitPattern: Int8(-5)), 0x00]])
        // Wheel scroll in relative mode
        XCTAssertEqual(mouse.wheel(dy: -1, isAbsolute: false), [0x02, 0x01, 0x00, 0x00, 0xff])
        XCTAssertEqual(mouse.reset(isAbsolute: false), [0x02, 0x00, 0x00, 0x00, 0x00])
    }

    func testNanoKVMProtoAndTelemetry() throws {
        var telemetry = StreamTelemetry()
        let ledEvent = Data(#"{"type":"hid-led-status","data":"{\"numLock\":true,\"capsLock\":true,\"scrollLock\":false,\"known\":true}"}"#.utf8)
        telemetry.applyWebSocketEvent(ledEvent)
        XCTAssertTrue(telemetry.capsLock)
        XCTAssertTrue(telemetry.numLock)
        XCTAssertFalse(telemetry.scrollLock)
        XCTAssertEqual(telemetry.hidUSBConnected, true)

        let capEvent = Data(#"{"type":"capture-status","data":"{\"ok\":true,\"result\":0,\"mode\":\"h264\"}"}"#.utf8)
        telemetry.applyWebSocketEvent(capEvent)
        XCTAssertEqual(telemetry.hdmiOnline, true)
        XCTAssertEqual(telemetry.videoCodec, "H264")

        let infoJSON = Data(#"{"code":0,"msg":"success","data":{"ips":[{"name":"eth0","addr":"192.168.1.50","version":"IPv4","type":"Wired"}],"mdns":"kvm-cube.local","image":"v1.4.2","application":"2.5.3","deviceKey":"cube-001"}}"#.utf8)
        let wrappedInfo = try JSONDecoder().decode(NanoKVMResponse<NanoKVMInfoRsp>.self, from: infoJSON)
        XCTAssertEqual(wrappedInfo.code, 0)
        let sysInfo = NanoKVMMapper.mapSystemInfo(info: try XCTUnwrap(wrappedInfo.data), hardwareVersion: "Beta")
        XCTAssertEqual(sysInfo.hw?.platform?.model, "Sipeed NanoKVM (Beta)")
        XCTAssertEqual(sysInfo.system?.kvmd?.version, "NanoKVM 2.5.3")
    }
}
