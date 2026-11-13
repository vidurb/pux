import Foundation

/// A decrypted code kept in memory: one that may not have reached the user,
/// or one just delivered where pux can't tell whether the OS showed it.
/// Stored in memory only: decrypted codes are NEVER written to disk.
public final class HeldDelivery: Identifiable, @unchecked Sendable {
    public var id: String { deliveryId }
    public let deliveryId: String
    public let notification: RelayNotification
    public var expiresAt: Date
    public var notified: Bool

    public init(
        deliveryId: String,
        notification: RelayNotification,
        expiresAt: Date,
        notified: Bool
    ) {
        self.deliveryId = deliveryId
        self.notification = notification
        self.expiresAt = expiresAt
        self.notified = notified
    }
}
