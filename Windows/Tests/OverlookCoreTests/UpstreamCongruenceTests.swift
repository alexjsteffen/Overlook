import Foundation
import XCTest
@testable import OverlookCore

final class UpstreamCongruenceTests: XCTestCase {
    func testMediaRouteLANAndOfferFiltering() {
        let interfaces = [
            LocalInterfaceAddress(
                name: "eth0",
                address: IPAddress("192.168.1.50")!,
                netmask: IPAddress("255.255.255.0")!
            ),
            LocalInterfaceAddress(
                name: "tailscale0",
                address: IPAddress("100.64.0.10")!,
                netmask: IPAddress("255.192.0.0")!
            )
        ]

        let route = MediaRoute.decide(
            preference: .chosenNetwork,
            host: "192.168.1.120",
            resolved: [],
            interfaces: interfaces
        )
        XCTAssertEqual(route.scope, .chosen(.lan))
        XCTAssertFalse(route.addsPublicSTUN)
        XCTAssertEqual(route.onLinkLocalAddresses, [IPAddress("192.168.1.50")!])

        let lanHost = ICECandidateLine("a=candidate:1 1 UDP 2130706431 192.168.1.120 50000 typ host")!
        let srflx = ICECandidateLine("a=candidate:2 1 UDP 1694498815 1.2.3.4 50001 typ srflx raddr 192.168.1.120 rport 50000")!
        let tsCandidate = ICECandidateLine("a=candidate:3 1 UDP 2130706431 100.64.0.22 50002 typ host")!
        let loopback = ICECandidateLine("a=candidate:4 1 UDP 2130706431 127.0.0.1 50003 typ host")!
        let onLinkLocal = ICECandidateLine("a=candidate:5 1 UDP 2130706431 192.168.1.50 50004 typ host")!

        XCTAssertTrue(route.keepsRemote(lanHost))
        XCTAssertFalse(route.keepsRemote(srflx))
        XCTAssertFalse(route.keepsRemote(tsCandidate))
        XCTAssertTrue(route.keepsLocal(onLinkLocal))
        XCTAssertFalse(route.keepsLocal(tsCandidate))
        XCTAssertFalse(route.keepsLocal(loopback))

        let mixedOffer = [
            "v=0",
            "m=video 9 UDP/TLS/RTP/SAVPF 96",
            "c=IN IP4 0.0.0.0",
            "a=candidate:1 1 UDP 2130706431 192.168.1.120 50000 typ host",
            "a=candidate:2 1 UDP 2130706431 100.64.0.22 50002 typ host",
            "a=candidate:3 1 UDP 1694498815 1.2.3.4 50001 typ srflx"
        ].joined(separator: "\n")

        let filtered = route.filterRemoteOffer(mixedOffer)
        XCTAssertFalse(filtered.keptWholeOffer)
        XCTAssertEqual(filtered.dropped.count, 2)
        XCTAssertTrue(filtered.sdp.contains("192.168.1.120"))
        XCTAssertFalse(filtered.sdp.contains("100.64.0.22"))
        XCTAssertFalse(filtered.sdp.contains("typ srflx"))

        // If filtering would empty all candidates in a section, preserve the whole offer.
        let srflxOnlyOffer = [
            "v=0",
            "m=video 9 UDP/TLS/RTP/SAVPF 96",
            "a=candidate:2 1 UDP 1694498815 1.2.3.4 50001 typ srflx"
        ].joined(separator: "\n")
        let fallback = route.filterRemoteOffer(srflxOnlyOffer)
        XCTAssertTrue(fallback.keptWholeOffer)
        XCTAssertTrue(fallback.dropped.isEmpty)
        XCTAssertEqual(fallback.sdp, srflxOnlyOffer)
    }

    func testMediaRouteTailscaleDNSUnclassifiedAndAll() {
        let tsRoute = MediaRoute.decide(preference: .chosenNetwork, host: "100.64.5.9")
        XCTAssertEqual(tsRoute.scope, .chosen(.tailscale))
        XCTAssertFalse(tsRoute.addsPublicSTUN)
        XCTAssertTrue(tsRoute.keepsRemote(ICECandidateLine("a=candidate:1 1 UDP 1 100.64.5.9 4000 typ host")!))
        XCTAssertFalse(tsRoute.keepsRemote(ICECandidateLine("a=candidate:2 1 UDP 1 192.168.1.2 4000 typ host")!))

        let dnsLanRoute = MediaRoute.decide(preference: .chosenNetwork, host: "glkvm.local", resolved: ["10.0.0.42"], interfaces: [])
        XCTAssertEqual(dnsLanRoute.scope, .chosen(.lan))

        let publicRoute = MediaRoute.decide(preference: .chosenNetwork, host: "kvm.example.com", resolved: ["93.184.216.34"])
        XCTAssertEqual(publicRoute.scope, .all)
        XCTAssertNotNil(publicRoute.unclassifiedReason)
        XCTAssertTrue(publicRoute.addsPublicSTUN)

        let allLocalRoute = MediaRoute.decide(preference: .all, host: "192.168.1.10")
        XCTAssertEqual(allLocalRoute.scope, .all)
        XCTAssertFalse(allLocalRoute.addsPublicSTUN)
    }

    func testRemotePasteChunker() {
        XCTAssertEqual(RemotePasteChunker.parts(of: ""), [])

        let text1200 = String(repeating: "a", count: 1200)
        let parts = RemotePasteChunker.parts(of: text1200)
        XCTAssertEqual(parts.map { $0.unicodeScalars.count }, [512, 512, 176])

        // Ensure multi-scalar grapheme clusters (family emoji / ZWJ sequences) are never torn apart.
        let family = "👨‍👩‍👧‍👦"
        let combined = String(repeating: "x", count: 510) + family + "y"
        let graphemeParts = RemotePasteChunker.parts(of: combined)
        XCTAssertEqual(graphemeParts.count, 2)
        XCTAssertEqual(graphemeParts[0].count, 510)
        XCTAssertEqual(graphemeParts[1], family + "y")

        let query = RemotePasteChunker.queryItems(keymap: "en-us", limit: 0)
        XCTAssertEqual(query.map(\.0), ["keymap", "limit"])
        XCTAssertEqual(query.map(\.1), ["en-us", "0"])
    }

    func testJanusSenderFilterAndSignalingDrop() throws {
        var filter = JanusSenderFilter()
        XCTAssertEqual(filter.verdict(for: ["janus": "webrtcup", "sender": Int64(10)], videoHandle: 10, audioHandle: 20), .leg(.video))
        XCTAssertEqual(filter.verdict(for: ["janus": "webrtcup", "sender": Int64(20)], videoHandle: 10, audioHandle: 20), .leg(.audio))
        XCTAssertEqual(filter.verdict(for: ["janus": "timeout"], videoHandle: 10, audioHandle: 20), .session)

        let noSenderTrickle: [String: Any] = ["janus": "trickle", "candidate": ["candidate": "c", "sdpMLineIndex": 0]]
        XCTAssertEqual(filter.verdict(for: noSenderTrickle, videoHandle: 10, audioHandle: 20), .drop(sender: nil, isFirst: true))
        XCTAssertEqual(filter.verdict(for: noSenderTrickle, videoHandle: 10, audioHandle: 20), .drop(sender: nil, isFirst: false))

        let staleSender: [String: Any] = ["janus": "event", "sender": Int64(999), "jsep": ["type": "offer"]]
        XCTAssertEqual(filter.verdict(for: staleSender, videoHandle: 10, audioHandle: 20), .drop(sender: 999, isFirst: true))
        XCTAssertEqual(JanusSenderFilter.describe(staleSender), "event with offer")

        filter.reset()
        XCTAssertEqual(filter.verdict(for: staleSender, videoHandle: 10, audioHandle: 20), .drop(sender: 999, isFirst: true))

        // JanusSignaling should also drop trickle messages that omit `sender`.
        var sig = JanusSignaling()
        _ = sig.begin()
        let dropData = try JSONSerialization.data(withJSONObject: ["janus": "trickle", "candidate": ["candidate": "candidate:x", "sdpMLineIndex": 0]])
        XCTAssertTrue(try sig.receive(dropData).isEmpty)
    }

    func testConnectionLogActiveDeviceLabel() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = ConnectionLog(directoryURL: dir)
        log.activeDeviceLabel = "Lab-KVM"
        log.info(.lifecycle, "Opening session")
        log.activeDeviceLabel = nil
        log.info(.lifecycle, "Closed session")

        XCTAssertNil(log.events[0].deviceLabel)
        XCTAssertEqual(log.events[1].deviceLabel, "Lab-KVM")
        XCTAssertTrue(log.formattedText().contains("[Lab-KVM]"))
    }

    func testLegacyDeviceAndPreferencesDecoding() throws {
        let legacyDeviceJSON = """
        {"id":"11111111-1111-1111-1111-111111111111","name":"Rack KVM","address":"https://192.168.1.50"}
        """
        let decodedDevice = try JSONDecoder().decode(Device.self, from: Data(legacyDeviceJSON.utf8))
        XCTAssertEqual(decodedDevice.addresses, [URL(string: "https://192.168.1.50")!])
        XCTAssertEqual(decodedDevice.preferredAddress, URL(string: "https://192.168.1.50")!)

        let tsURL = try DeviceAddress.parse("http://100.64.1.5")
        XCTAssertEqual(DeviceAddress.resolvedPort(for: tsURL), 80)
        let roamed = decodedDevice.via(tsURL)
        XCTAssertEqual(roamed.lastUsedAddress, tsURL)
        XCTAssertEqual(roamed.preferredAddress, tsURL)
        XCTAssertEqual(roamed.addresses.count, 2)

        let legacyPrefsJSON = """
        {"screenshotsFolder":"/tmp/s","recordingsFolder":"/tmp/r","videoCodec":"h264","vaapiDevice":"","relativeSensitivity":1.2,"appAppearance":"dark"}
        """
        let prefs = try JSONDecoder().decode(AppPreferences.self, from: Data(legacyPrefsJSON.utf8))
        XCTAssertEqual(prefs.mediaAddresses, .chosenNetwork)
        XCTAssertEqual(prefs.wakeDisplayOnConnect, true)
    }
}
