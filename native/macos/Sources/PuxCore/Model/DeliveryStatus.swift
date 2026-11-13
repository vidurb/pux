import Foundation

public enum DeliveryState: Equatable, Sendable {
    case idle
    case connecting
    case ready
    case retrying
    case recordUnknown
    case tooManyDevices
}

public struct DeliveryStatus: Equatable, Sendable {
    public let state: DeliveryState
    public let message: String?
    public let undecryptable: Int

    public init(state: DeliveryState = .idle, message: String? = nil, undecryptable: Int = 0) {
        self.state = state
        self.message = message
        self.undecryptable = undecryptable
    }

    public func replacing(state: DeliveryState? = nil, message: String? = nil, undecryptable: Int? = nil) -> DeliveryStatus {
        DeliveryStatus(
            state: state ?? self.state,
            message: message ?? self.message,
            undecryptable: undecryptable ?? self.undecryptable
        )
    }
}
