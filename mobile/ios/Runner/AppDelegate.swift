import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    PuxKeychain.migrateLegacyItems()
    // Launched before the first unlock, the old items are not readable yet.
    NotificationCenter.default.addObserver(
      forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: nil
    ) { _ in PuxKeychain.migrateLegacyItems() }
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
    }
    application.registerForRemoteNotifications()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    FlutterMethodChannel(
      name: "xyz.vidur.pux/notification_permissions",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    ).setMethodCallHandler { call, result in
      guard call.method == "getStatus" else {
        result(FlutterMethodNotImplemented)
        return
      }
      // flutter_local_notifications reports the rest of these settings. pux's
      // notifications aren't time-sensitive, so that setting changes nothing
      // and isn't reported.
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        let summary = settings.scheduledDeliverySetting == .enabled
        DispatchQueue.main.async { result(["scheduledSummary": summary]) }
      }
    }
  }
}
