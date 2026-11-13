import Foundation

public protocol WebSocketConnection: AnyObject, Sendable {
    func connect()
    func disconnect()
    func sendPing() async throws
    func sendPing(timeout: TimeInterval) async throws
    func sendText(_ text: String) async throws
    func sendText(_ text: String, timeout: TimeInterval) async throws
    func receiveMessage() async throws -> String
    func receiveMessage(timeout: TimeInterval) async throws -> String
}

public extension WebSocketConnection {
    func sendPing(timeout: TimeInterval) async throws {
        try await sendText("{\"type\":\"ping\"}", timeout: timeout)
    }
}

public final class NativeWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let url: URL
    private let headers: [String: String]
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()

    public init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }

    public func connect() {
        var request = URLRequest(url: url)
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let session = URLSession(configuration: .default)
        self.session = session
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
    }

    public func disconnect() {
        lock.lock()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        lock.unlock()
    }

    public func sendPing() async throws {
        try await sendText("{\"type\":\"ping\"}")
    }

    public func sendText(_ text: String) async throws {
        guard let task = lockedTask() else { throw ApiError.networkError("WebSocket not connected") }
        try await task.send(.string(text))
    }

    public func sendText(_ text: String, timeout: TimeInterval) async throws {
        try await WebSocketTimedIO.runSend(timeout: timeout, onDeadline: cancelInFlightOperations) {
            try await self.sendText(text)
        }
    }

    public func receiveMessage() async throws -> String {
        guard let task = lockedTask() else { throw ApiError.networkError("WebSocket not connected") }
        let msg = try await task.receive()
        switch msg {
        case .string(let text):
            return text
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                throw ApiError.networkError("Invalid UTF-8 data from WebSocket")
            }
            return text
        @unknown default:
            throw ApiError.networkError("Unknown WebSocket message format")
        }
    }

    public func receiveMessage(timeout: TimeInterval) async throws -> String {
        try await WebSocketTimedIO.runReceive(timeout: timeout, onDeadline: cancelInFlightOperations) {
            try await self.receiveMessage()
        }
    }

  /// URLSessionWebSocketTask.receive() does not respect Task cancellation; cancel the task to unblock.
    private func cancelInFlightOperations() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel(with: .goingAway, reason: nil)
    }

    private func lockedTask() -> URLSessionWebSocketTask? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }
}
