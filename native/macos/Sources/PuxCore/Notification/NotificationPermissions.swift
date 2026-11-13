import AppKit
import Foundation
import UserNotifications

public enum NotificationAccess: String, Sendable, Equatable {
    case allowed
    case off
    case notAsked
    case quiet

    public var hidesCodes: Bool {
        return self == .off || self == .notAsked
    }
}

public protocol NotificationPermissionsProtocol: Sendable {
    func check() async -> NotificationAccess
    func ask() async -> NotificationAccess
}

public final class NotificationPermissions: NotificationPermissionsProtocol, @unchecked Sendable {
    public static let shared = NotificationPermissions()

    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return UNUserNotificationCenter.current()
    }

    public init() {}

    public func check() async -> NotificationAccess {
        guard let center = center else {
            return .allowed
        }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notAsked
        case .denied:
            return .off
        case .authorized:
            if settings.alertSetting == .enabled {
                return .allowed
            } else {
                return .quiet
            }
        case .provisional:
            return .quiet
        @unknown default:
            return .off
        }
    }

    public func ask() async -> NotificationAccess {
        guard let center = center else {
            return .allowed
        }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            // Error ignored, check status below
        }
        return await check()
    }

    public static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }
}
