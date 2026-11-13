import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

public enum NotificationAccess: Equatable, Sendable {
    case allowed
    case off
    case notAsked
    case quiet

    public static let denied: NotificationAccess = .off

    public var hidesCodes: Bool {
        self == .off || self == .notAsked
    }
}

public enum DeliveryRestriction: String, CaseIterable, Identifiable, Sendable {
    case scheduledSummary

    public var id: String { rawValue }
}

public struct DeliveryRestrictionStatus: Equatable, Sendable {
    public let active: Set<DeliveryRestriction>
    public let clear: Set<DeliveryRestriction>

    public init(active: Set<DeliveryRestriction> = [], clear: Set<DeliveryRestriction> = []) {
        self.active = active
        self.clear = clear
    }
}

@MainActor
public final class NotificationPermissions: ObservableObject {
    public static let shared = NotificationPermissions()

    @Published public private(set) var access: NotificationAccess = .allowed
    @Published public private(set) var quietDelivery: DeliveryRestrictionStatus = DeliveryRestrictionStatus()

    public var status: NotificationAccess {
        access
    }

    public var isScheduledDeliveryOn: Bool {
        quietDelivery.active.contains(.scheduledSummary)
    }

    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func check() async -> NotificationAccess {
        let settings = await center.notificationSettings()
        let currentAccess: NotificationAccess
        var activeRestrictions: Set<DeliveryRestriction> = []
        var clearRestrictions: Set<DeliveryRestriction> = []

        switch settings.authorizationStatus {
        case .notDetermined:
            currentAccess = .notAsked
        case .denied:
            currentAccess = .off
        case .provisional:
            currentAccess = .quiet
        case .authorized, .ephemeral:
            if settings.alertSetting == .disabled {
                currentAccess = .quiet
            } else {
                currentAccess = .allowed
            }
        @unknown default:
            currentAccess = .allowed
        }

        if #available(iOS 15.0, *) {
            if settings.scheduledDeliverySetting == .enabled {
                activeRestrictions.insert(.scheduledSummary)
            } else {
                clearRestrictions.insert(.scheduledSummary)
            }
        }

        self.access = currentAccess
        self.quietDelivery = DeliveryRestrictionStatus(active: activeRestrictions, clear: clearRestrictions)
        return currentAccess
    }

    public func ask() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            _ = await check()
            return granted
        } catch {
            _ = await check()
            return false
        }
    }

    public var openSettingsHandler: (@MainActor () -> Void)? = nil

    @MainActor
    public func openSettings() {
        if let handler = openSettingsHandler {
            handler()
            return
        }

    }
}
