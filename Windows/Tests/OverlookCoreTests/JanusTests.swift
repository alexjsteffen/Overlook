import Foundation
import XCTest
@testable import OverlookCore

final class JanusTests: XCTestCase {
    func packet(_ fields: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: fields) }
    func sent(_ actions: [JanusSignaling.Action]) throws -> [String: Any] {
        guard case .send(let message) = try XCTUnwrap(actions.first) else { throw JanusSignaling.Failure.protocolError("Expected outgoing message") }
        return message
    }
    func setup() throws -> JanusSignaling {
        var state = JanusSignaling()
        let create = try sent(state.begin())
        XCTAssertEqual(create["janus"] as? String, "create")
        // Acknowledgement must not consume the transaction before success arrives.
        XCTAssertTrue(try state.receive(packet(["janus": "ack", "transaction": create["transaction"]!])).isEmpty)
        let attach = try sent(state.receive(packet(["janus": "success", "transaction": create["transaction"]!, "data": ["id": 123]])))
        XCTAssertEqual(attach["plugin"] as? String, "janus.plugin.ustreamer")
        XCTAssertEqual(attach["session_id"] as? Int64, 123)
        let watch = try sent(state.receive(packet(["janus": "success", "transaction": attach["transaction"]!, "data": ["id": 456]])))
        let body = try XCTUnwrap(watch["body"] as? [String: Any])
        XCTAssertEqual(body["request"] as? String, "watch")
        XCTAssertEqual((body["params"] as? [String: Any])?["video"] as? Bool, true)
        XCTAssertEqual((body["params"] as? [String: Any])?["audio"] as? Bool, false)
        return state
    }
    func testNegotiationAndRouting() throws {
        var state = try setup()
        let actions = try state.receive(packet(["janus": "event", "sender": 456, "jsep": ["type": "offer", "sdp": "v=0\r\n"]]))
        guard case .offer(let sdp) = try XCTUnwrap(actions.first) else { return XCTFail("Missing offer") }
        XCTAssertEqual(sdp, "v=0\r\n")
        let answer = try sent([state.answer("answer-sdp")])
        XCTAssertEqual(answer["handle_id"] as? Int64, 456)
        XCTAssertEqual((answer["jsep"] as? [String: String])?["type"], "answer")
        XCTAssertTrue(try state.receive(packet(["janus": "event", "sender": 999, "jsep": ["type": "offer", "sdp": "bad"]])).isEmpty)
        XCTAssertTrue(try state.receive(packet(["janus": "webrtcup", "session_id": 999])).isEmpty)
        let keepalive = try sent([state.keepalive()])
        XCTAssertNil(keepalive["handle_id"])
        XCTAssertEqual(keepalive["session_id"] as? Int64, 123)
    }
    func testCandidateAndFailures() throws {
        var state = try setup()
        let actions = try state.receive(packet(["janus": "trickle", "sender": 456, "candidate": ["candidate": "candidate:test", "sdpMLineIndex": 0]]))
        guard case .candidate(let line, let text) = try XCTUnwrap(actions.first) else { return XCTFail("Missing candidate") }
        XCTAssertEqual(line, 0); XCTAssertEqual(text, "candidate:test")
        XCTAssertThrowsError(try state.receive(packet(["janus": "hangup", "reason": "device stopped"])))
        XCTAssertThrowsError(try state.receive(packet(["janus": "error", "error": ["reason": "unauthorized"]])))
        XCTAssertThrowsError(try state.receive(packet(["janus": "event", "sender": 456, "plugindata": ["data": ["error": "No signal"]]])))
        XCTAssertThrowsError(try state.receive(Data("not json".utf8)))
    }
    func testCredentialEncodingAndEndpoints() throws {
        XCTAssertEqual(KVMRequest.form(["passwd": "a&b=+ ü"]), "passwd=a%26b%3D%2B%20%C3%BC")
        let base = try DeviceAddress.parse("https://[::1]:8443/proxy/")
        XCTAssertEqual(KVMRequest.endpoint(base, path: "janus/ws", websocket: true).absoluteString, "wss://[::1]:8443/proxy/janus/ws")
        XCTAssertEqual(KVMRequest.endpoint(try DeviceAddress.parse("pikvm.local"), path: "api/auth/login").path, "/api/auth/login")
    }
}
