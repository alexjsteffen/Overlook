import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URLSession's WebSocket send machinery must not be entered concurrently, or while its task
/// is being torn down. Actor isolation alone is insufficient: send suspends and actors reenter.
actor WebSocketSendQueue {
    enum SendError: Error {
        case closed
    }

    private let socket: URLSessionWebSocketTask
    private var tail: Task<Void, Error>?
    private var closed = false

    init(socket: URLSessionWebSocketTask) {
        self.socket = socket
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard !closed else { throw SendError.closed }
        let previous = tail
        let next = Task {
            // A failed frame must not prevent subsequent queued frames from being considered.
            if let previous { _ = await previous.result }
            guard !closed else { throw SendError.closed }
            try await socket.send(message)
        }
        tail = next
        try await next.value
    }

    /// Refuse queued frames, wait for the current send to leave CFNetwork, then cancel the task.
    /// Cancellation of a caller waiting on send does not cancel its already-started frame.
    func close() async {
        guard !closed else { return }
        closed = true
        if let tail { _ = await tail.result }
        socket.cancel(with: .goingAway, reason: nil)
    }
}
