import Foundation

enum WebSocketTimedIO {
    static func runSend(
        timeout: TimeInterval,
        onDeadline: @escaping @Sendable () -> Void,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                let nanos = UInt64(max(0, timeout) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanos)
                throw ApiError.networkError("WebSocket send timeout")
            }
            do {
                guard try await group.next() != nil else {
                    throw ApiError.networkError("WebSocket send timeout")
                }
                group.cancelAll()
            } catch {
                group.cancelAll()
                if case ApiError.networkError("WebSocket send timeout") = error {
                    onDeadline()
                }
                throw error
            }
        }
    }

    static func runReceive(
        timeout: TimeInterval,
        onDeadline: @escaping @Sendable () -> Void,
        operation: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                let nanos = UInt64(max(0, timeout) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanos)
                throw ApiError.networkError("WebSocket receive timeout")
            }
            do {
                guard let message = try await group.next() else {
                    throw ApiError.networkError("WebSocket receive timeout")
                }
                group.cancelAll()
                return message
            } catch {
                group.cancelAll()
                if case ApiError.networkError("WebSocket receive timeout") = error {
                    onDeadline()
                }
                throw error
            }
        }
    }
}
