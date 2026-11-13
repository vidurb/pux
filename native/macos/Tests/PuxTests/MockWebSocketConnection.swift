import Foundation
@testable import PuxCore

final class MockWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    var sent: [String] = []
    var inbound: [String] = []
    var inboundIndex = 0

    private let lock = NSLock()
    private var receiveWait: CheckedContinuation<Void, Error>?
    private var sendWait: CheckedContinuation<Void, Error>?
    private var blockReceive = false
    private var blockSend = false

    func connect() {}
    func disconnect() {}

    func sendPing() async throws {
        try await sendText("{\"type\":\"ping\"}")
    }

    func sendText(_ text: String) async throws {
        try await sendText(text, timeout: 60)
    }

    func sendText(_ text: String, timeout: TimeInterval) async throws {
        try await WebSocketTimedIO.runSend(timeout: timeout, onDeadline: cancelSend) {
            if self.blockSend {
                self.blockSend = false
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.lock.lock()
                    self.sendWait = continuation
                    self.lock.unlock()
                }
            }
            self.sent.append(text)
        }
    }

    func receiveMessage() async throws -> String {
        if blockReceive {
            blockReceive = false
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                receiveWait = continuation
                lock.unlock()
            }
        }
        if inboundIndex < inbound.count {
            defer { inboundIndex += 1 }
            return inbound[inboundIndex]
        }
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return "{\"type\":\"pong\"}"
    }

    func receiveMessage(timeout: TimeInterval) async throws -> String {
        try await WebSocketTimedIO.runReceive(timeout: timeout, onDeadline: cancelReceive) {
            try await self.receiveMessage()
        }
    }

    func blockNextReceive() {
        blockReceive = true
    }

    func blockNextSend() {
        blockSend = true
    }

    func pingSendCount() -> Int {
        sent.filter { $0.contains("\"type\":\"ping\"") || $0.contains("\"type\": \"ping\"") }.count
    }

    private func cancelReceive() {
        lock.lock()
        let wait = receiveWait
        receiveWait = nil
        lock.unlock()
        wait?.resume(throwing: CancellationError())
    }

    private func cancelSend() {
        lock.lock()
        let wait = sendWait
        sendWait = nil
        lock.unlock()
        wait?.resume(throwing: CancellationError())
    }
}
