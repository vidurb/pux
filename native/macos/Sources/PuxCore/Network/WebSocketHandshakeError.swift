import Foundation

public enum WebSocketHandshakeOutcome: Equatable {
    case completed(deferred: [String])
    case failed(deferred: [String], reason: FailureReason)

    public enum FailureReason: Equatable {
        case pongTimeout
        case sendTimeout
        case transport(String)
    }

    public var deferred: [String] {
        switch self {
        case .completed(let messages):
            return messages
        case .failed(let messages, _):
            return messages
        }
    }
}
