import Foundation

public enum DeliveryState: Equatable, Sendable {
    /// Not enrolled, or not started yet.
    case idle
    case connecting
    /// Registered and ready to receive codes.
    case ready
    /// Transient failure, retry scheduled.
    case retrying
    /// Firebase push not configured in this build.
    case firebaseUnconfigured
    /// Record no longer known by server (deleted or pruned).
    case recordUnknown
    /// Max devices limit reached.
    case tooManyDevices
}

public struct DeliveryStatus: Equatable, Sendable {
    public let state: DeliveryState
    public let message: String?
    public let undecryptable: Int

    public init(state: DeliveryState, message: String? = nil, undecryptable: Int = 0) {
        self.state = state
        self.message = message
        self.undecryptable = undecryptable
    }

    public func copyWith(
        state: DeliveryState? = nil,
        message: String? = nil,
        undecryptable: Int? = nil
    ) -> DeliveryStatus {
        DeliveryStatus(
            state: state ?? self.state,
            message: message ?? self.message,
            undecryptable: undecryptable ?? self.undecryptable
        )
    }
}
