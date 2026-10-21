import Foundation
import XCTest
@testable import OverlookCore

final class KVMModelsTests: XCTestCase {
    func testTOTPGeneratorRFC6238() {
        // RFC 4226 / RFC 6238 ASCII secret "12345678901234567890" -> Base32 "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        XCTAssertEqual(TOTPGenerator.generateCode(base32Secret: secret, date: Date(timeIntervalSince1970: 59)), "287082")
        XCTAssertEqual(TOTPGenerator.generateCode(base32Secret: secret, date: Date(timeIntervalSince1970: 1111111109)), "081804")
        XCTAssertEqual(TOTPGenerator.generateCode(base32Secret: secret, date: Date(timeIntervalSince1970: 1234567890)), "005924")
        XCTAssertEqual(TOTPGenerator.resolveTwoFactorCode(" 123456 "), "123456")
        XCTAssertEqual(TOTPGenerator.resolveTwoFactorCode(secret, date: Date(timeIntervalSince1970: 59)), "287082")
        XCTAssertEqual(TOTPGenerator.resolveTwoFactorCode(""), "")
        XCTAssertNil(TOTPGenerator.resolveTwoFactorCode("!!!invalid!!!"))
    }

    func testEDIDCatalogMatchingAndResolution() {
        XCTAssertFalse(EDIDCatalog.options.isEmpty)
        XCTAssertEqual(EDIDCatalog.matchingOptionID(for: ""), EDIDCatalog.customOptionID)
        let e1080 = try! XCTUnwrap(EDIDCatalog.resolvedEdid(forID: "E1920x1080"))
        XCTAssertEqual(EDIDCatalog.matchingOptionID(for: e1080), "E1920x1080")
        let e4k = try! XCTUnwrap(EDIDCatalog.resolvedEdid(forID: "E3840x2160"))
        XCTAssertEqual(EDIDCatalog.matchingOptionID(for: e4k), "E3840x2160")
        XCTAssertNil(EDIDCatalog.resolvedEdid(forID: EDIDCatalog.customOptionID))
    }

    func testSystemConfigAndSubsystemsDecoding() throws {
        let configJSON = """
        {
          "ok": true,
          "result": {
            "config": {
              "shortcuts": [{"keys": ["ControlLeft", "AltLeft", "Delete"], "label": "CAD"}],
              "orientation": 90,
              "stream_quality": 2,
              "video_mode": "h264",
              "show_cursor": false,
              "mouse_polling": 20,
              "mouse_control": true,
              "relative_sense": 15,
              "scroll_rate": 8,
              "reverse_scrolling": "VERTICAL",
              "keyboard_control": true,
              "theme_mode": "1",
              "mouse_jiggle": true,
              "keymap": "de",
              "got_muted_panel_tip": true,
              "is_absolute_mouse": false,
              "fingerbot_strength": 40,
              "video_processing": "quality_first",
              "language": "en-US",
              "timezone": "UTC"
            }
          }
        }
        """
        let decoded = try JSONDecoder().decode(KVMResponse<KVMSystemGetConfigResult>.self, from: Data(configJSON.utf8))
        XCTAssertTrue(decoded.ok)
        let cfg = decoded.result.config
        XCTAssertEqual(cfg.orientation, 90)
        XCTAssertEqual(cfg.streamQuality, 2)
        XCTAssertEqual(cfg.showCursor, false)
        XCTAssertEqual(cfg.keymap, "de")
        XCTAssertEqual(cfg.isAbsoluteMouse, false)
        XCTAssertEqual(cfg.videoProcessing, "quality_first")
        XCTAssertEqual(cfg.shortcuts.first?.label, "CAD")
        XCTAssertEqual(KVMVideoQualityPreset.detect(config: cfg, streamer: nil), .high)

        let msdJSON = """
        {
          "ok": true,
          "result": {
            "enabled": true,
            "online": true,
            "busy": false,
            "drive": {"image": {"name": "ubuntu.iso", "size": 1048576}, "connected": true, "cdrom": true, "rw": false},
            "storage": {"size": 8000000, "free": 4000000, "uploading": false, "downloading": false, "images": {"ubuntu.iso": {"size": 1048576, "complete": true, "in_storage": true, "removable": true}}}
          }
        }
        """
        let msd = try JSONDecoder().decode(KVMResponse<KVMMsdState>.self, from: Data(msdJSON.utf8)).result
        XCTAssertEqual(msd.drive?.imageName, "ubuntu.iso")
        XCTAssertEqual(msd.drive?.connected, true)
        XCTAssertEqual(msd.storage?.images.first?.name, "ubuntu.iso")

        let gpioJSON = """
        {
          "ok": true,
          "result": {
            "model": {"scheme": {"inputs": {"in1": {}}, "outputs": {"out1": {"switch": true, "pulse": {"delay": 0.5, "min_delay": 0.1, "max_delay": 2.0}}}}},
            "state": {"inputs": {"in1": {"online": true, "state": true, "busy": false}}, "outputs": {"out1": {"online": true, "state": false, "busy": false}}}
          }
        }
        """
        let gpio = try JSONDecoder().decode(KVMResponse<KVMGpioState>.self, from: Data(gpioJSON.utf8)).result
        XCTAssertEqual(gpio.inputChannels, ["in1"])
        XCTAssertEqual(gpio.inputs["in1"]?.state, true)
        XCTAssertEqual(gpio.outputSchemes["out1"]?.pulseDelay, 0.5)

        let switchJSON = """
        {
          "ok": true,
          "result": {
            "enabled": true,
            "active_port": 2,
            "ports": {"0": {"name": "Server A", "dummy": true, "beacon": false}, "2": {"name": "Server B", "dummy": false, "beacon": true}}
          }
        }
        """
        let sw = try JSONDecoder().decode(KVMResponse<KVMSwitchState>.self, from: Data(switchJSON.utf8)).result
        XCTAssertEqual(sw.activePort, "2")
        XCTAssertEqual(sw.ports.count, 2)
    }

    func testTelemetryAndWebSocketEvents() {
        var telemetry = StreamTelemetry()
        telemetry.hidLink = .connected
        let hidMsg = #"{"event_type":"hid_state","event":{"connected":true,"keyboard":{"leds":{"caps":true,"num":false,"scroll":true}}}}"#
        XCTAssertFalse(telemetry.applyWebSocketEvent(Data(hidMsg.utf8)))
        XCTAssertEqual(telemetry.hidUSBConnected, true)
        XCTAssertTrue(telemetry.capsLock)
        XCTAssertFalse(telemetry.numLock)
        XCTAssertTrue(telemetry.scrollLock)
        XCTAssertEqual(telemetry.hidLinkText, "Connected · queue 0 · USB up")

        let streamerMsg = #"{"event_type":"streamer_state","event":{"source":{"online":true,"captured_fps":60,"desired_fps":60,"resolution":{"width":1920,"height":1080}},"h264":{"online":true,"bitrate":2500}}}"#
        telemetry.applyWebSocketEvent(Data(streamerMsg.utf8))
        XCTAssertEqual(telemetry.hdmiText, "1920x1080 · 60 fps · signal")
        XCTAssertEqual(telemetry.videoKbps, 2500)
        XCTAssertEqual(telemetry.videoCodec, "H264")

        let pongMsg = #"{"event_type":"pong","event":{}}"#
        XCTAssertTrue(telemetry.applyWebSocketEvent(Data(pongMsg.utf8)))

        let statsJSON = #"{"width":1920,"height":1080,"fps":60,"kbps":3200,"jitter_ms":3,"packets_lost":1,"pli_count":0,"nack_count":2,"rtt_ms":9,"codec":"H264","path":"host → host · UDP","remote":"192.168.1.10:50000"}"#
        telemetry.applyNativeStatsJSON(Data(statsJSON.utf8))
        XCTAssertEqual(telemetry.videoText, "1920x1080 · 60 fps · 3200 kbps")
        XCTAssertEqual(telemetry.repairText, "0 PLI · 2 NACK")
        XCTAssertEqual(telemetry.networkPath, "host → host · UDP")
    }

    func testPreferencesAndCaptureNaming() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PreferencesStore(file: dir.appendingPathComponent("preferences.json"))
        var prefs = store.load()
        XCTAssertEqual(prefs.videoCodec, .h264)
        prefs.videoCodec = .hevc
        prefs.relativeSensitivity = 1.75
        try store.save(prefs)
        XCTAssertEqual(store.load(), prefs)

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixedDate = Date(timeIntervalSince1970: 1700000000)
        let first = CaptureFileNaming.makeFileURL(in: dir, deviceName: "Lab:KVM/1", date: fixedDate, extension: "png")
        try Data("x".utf8).write(to: first)
        let second = CaptureFileNaming.makeFileURL(in: dir, deviceName: "Lab:KVM/1", date: fixedDate, extension: "png")
        XCTAssertTrue(second.lastPathComponent.contains("(2).png"))
        XCTAssertEqual(CaptureFileNaming.durationText(65), "1:05")
        XCTAssertEqual(CaptureFileNaming.durationText(3661), "1:01:01")
    }

    func testConnectionLog() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = ConnectionLog(directoryURL: dir)
        log.info(.lifecycle, "Connecting to KVM")
        log.warning(.ice, "ICE candidate slow")
        XCTAssertEqual(log.events.count, 2)
        XCTAssertEqual(log.unseenProblemCount, 1)
        XCTAssertEqual(log.lastProblem?.message, "ICE candidate slow")
        XCTAssertTrue(log.formattedText(minimumLevel: .warning).contains("ICE candidate slow"))
        XCTAssertFalse(log.formattedText(minimumLevel: .warning).contains("Connecting to KVM"))
        log.markProblemsViewed()
        XCTAssertEqual(log.unseenProblemCount, 0)
        log.clear()
        XCTAssertTrue(log.events.isEmpty)
    }
}
