#if os(iOS)
#if canImport(UIKit)
import UIKit
import UserNotifications
import PuxCore

public class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Every launch side effect goes through AppBootstrap, which runs none of them when this app is
        // the host of an XCTest run: hosted tests must not migrate the Keychain or touch APNs/Firebase.
        AppBootstrap.run(AppLaunchSteps(
            migrateLegacyKeychainItems: {
                // Migrate items from legacy app-only keychain group to shared group
                PuxKeychain.migrateLegacyItems()
            },
            observeProtectedDataAvailability: {
                // Launched before the first unlock, the old items are not readable yet.
                NotificationCenter.default.addObserver(
                    forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                    object: nil,
                    queue: nil
                ) { _ in
                    PuxKeychain.migrateLegacyItems()
                    RecordStore.shared.refreshFromStorage()
                }
            },
            configureNotificationHandling: {
                NotificationPermissions.shared.openSettingsHandler = {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                UNUserNotificationCenter.current().delegate = self
            },
            registerForRemoteNotifications: {
                application.registerForRemoteNotifications()
            },
            configureFirebaseDelivery: {
                // Configure supported Firebase Messaging SDK
                if NativeFirebaseRegistrationSource.shared.configure() {
                    DeliveryController.shared.deliveryService = FcmRegistration(
                        source: NativeFirebaseRegistrationSource.shared,
                        recordStore: .shared,
                        onRefreshError: { error in
                            Task { @MainActor in
                                DeliveryController.shared.reportError(error)
                            }
                        }
                    )
                }
            }
        ))

        return true
    }

    public func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            await DeliveryController.shared.handleApnsToken(deviceToken)
        }
    }

    public func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            DeliveryController.shared.reportError(error)
        }
    }

    // Display push alerts in the foreground too (matching Flutter behavior)
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound, .badge, .list])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }

    // Handles user tapping on a notification banner or alert
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let urlStr = response.notification.request.content.userInfo["confirmation_url"] as? String,
           let url = URL(string: urlStr),
           RelayNotification.isConfirmationUrlAllowed(url) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
        completionHandler()
    }
}
#endif

#endif
