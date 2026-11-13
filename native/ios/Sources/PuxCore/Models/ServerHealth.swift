import Foundation

public enum ServerHealthState: Equatable, Sendable {
    case reachable
    case unreachable
    case serverError
}

public struct ServerHealth: Equatable, Sendable {
    public let state: ServerHealthState
    public let reason: String?

    public init(state: ServerHealthState, reason: String? = nil) {
        self.state = state
        self.reason = reason
    }
}
