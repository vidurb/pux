import Foundation

public struct PendingDelivery: Equatable, @unchecked Sendable {
    public let deliveryId: String
    public let envelope: [String: Any]

    public init(deliveryId: String, envelope: [String: Any]) {
        self.deliveryId = deliveryId
        self.envelope = envelope
    }

    public static func == (lhs: PendingDelivery, rhs: PendingDelivery) -> Bool {
        return lhs.deliveryId == rhs.deliveryId
    }
}
