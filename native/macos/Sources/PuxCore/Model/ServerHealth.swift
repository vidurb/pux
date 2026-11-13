import Foundation

public enum ServerHealthState: Equatable, Sendable {
    case checking
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

public struct TestCodeResponse: Equatable, Sendable {
    public let otp: String
    public let devices: Int

    public init(otp: String, devices: Int) {
        self.otp = otp
        self.devices = devices
    }
}
