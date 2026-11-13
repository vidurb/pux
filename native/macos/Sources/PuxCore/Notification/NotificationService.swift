import AppKit
import Foundation
import UserNotifications

public final class NotificationCodes: @unchecked Sendable {
    public static let codeLifetime: TimeInterval = 15 * 60
    public static let maxEntries = 256

    private let lock = NSLock()
    private var codes: [String: String] = [:]
    private var expiry: [String: Date] = [:]

    public init() {}

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        cleanExpired()
        return codes.count
    }

    public func put(id: String, code: String, lifetime: TimeInterval = NotificationCodes.codeLifetime) {
        lock.lock()
        defer { lock.unlock() }
        cleanExpired()
        guard lifetime > 0 else {
            codes.removeValue(forKey: id)
            expiry.removeValue(forKey: id)
            return
        }
        if codes[id] == nil && codes.count >= Self.maxEntries,
           let oldest = expiry.min(by: { $0.value < $1.value })?.key {
            codes.removeValue(forKey: oldest)
            expiry.removeValue(forKey: oldest)
        }
        let deadline = Date().addingTimeInterval(lifetime)
        codes[id] = code
        expiry[id] = deadline
        DispatchQueue.global().asyncAfter(deadline: .now() + lifetime) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            if self.expiry[id] == deadline {
                self.codes.removeValue(forKey: id)
                self.expiry.removeValue(forKey: id)
            }
        }
    }

    public func take(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        cleanExpired()
        guard let code = codes.removeValue(forKey: id) else { return nil }
        expiry.removeValue(forKey: id)
        return code
    }

    public func remove(id: String) {
        lock.lock()
        defer { lock.unlock() }
        codes.removeValue(forKey: id)
        expiry.removeValue(forKey: id)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        codes.removeAll()
        expiry.removeAll()
    }

    #if DEBUG
    // Observe the cache without triggering expiry; used to test scheduled cleanup.
    func storedCodeForTesting(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return codes[id]
    }
    #endif

    private func cleanExpired() {
        let now = Date()
        let expiredKeys = expiry.filter { $0.value < now }.map(\.key)
        for key in expiredKeys {
            codes.removeValue(forKey: key)
            expiry.removeValue(forKey: key)
        }
    }
}

public protocol NotificationPresenter: Sendable {
    func show(notification: RelayNotification) async throws -> Bool
}

public final class NotificationService: NSObject, NotificationPresenter, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = NotificationService()

    public static let copyActionId = "copy_code"
    public static let categoryId = "pux_notification"

    public let codes = NotificationCodes()

    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return UNUserNotificationCenter.current()
    }

    public override init() {
        super.init()
        if let center = self.center {
            center.delegate = self
            setupCategory(center: center)
        }
    }

    public func setupCategory(center: UNUserNotificationCenter) {
        let copyAction = UNNotificationAction(
            identifier: Self.copyActionId,
            title: "Copy code",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryId,
            actions: [copyAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    public func show(notification: RelayNotification) async throws -> Bool {
        guard let center = center else {
            return true
        }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.categoryIdentifier = Self.categoryId

        // Copy action reads from in-memory NotificationCodes; the OTP also
        // appears in the notification body, matching the Flutter desktop client.
        var userInfo: [String: Any] = [:]
        if let url = notification.url {
            userInfo["url"] = url.absoluteString
        }
        content.userInfo = userInfo

        let id = UUID().uuidString
        if let code = notification.code {
            codes.put(id: id, code: code)
        }

        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: nil
        )

        try await center.add(request)
        return true
    }

    // MARK: - UNUserNotificationCenterDelegate

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let userInfo = response.notification.request.content.userInfo

        let code = codes.take(id: identifier)

        if response.actionIdentifier == Self.copyActionId {
            if let code = code, !code.isEmpty {
                SensitiveClipboard.shared.copy(code)
            }
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            if let urlString = userInfo["url"] as? String,
               let validatedUrl = RelayNotification.confirmationUri(urlString) {
                NSWorkspace.shared.open(validatedUrl)
            } else {
                Task { @MainActor in
                    DesktopShell.shared.showWindow()
                }
            }
        }

        completionHandler()
    }
}
