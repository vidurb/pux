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
    NotificationSettingsChannel.register(messenger: engineBridge.applicationRegistrar.messenger())
  }
}

/// What flutter_local_notifications can't report about notification settings.
enum NotificationSettingsChannel {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "xyz.vidur.pux/notification_permissions", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      // pux's notifications aren't time-sensitive, so that setting changes
      // nothing and isn't reported.
      case "getStatus":
        UNUserNotificationCenter.current().getNotificationSettings { settings in
          let summary = settings.scheduledDeliverySetting == .enabled
          DispatchQueue.main.async { result(["scheduledSummary": summary]) }
        }
      // Whether the user has been asked yet, which checkPermissions can't tell
      // from a denial. Dart shows its explainer before the system prompt only
      // while this is "notDetermined".
      case "getAuthorizationStatus":
        UNUserNotificationCenter.current().getNotificationSettings { settings in
          let status = name(of: settings.authorizationStatus)
          DispatchQueue.main.async { result(status) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func name(of status: UNAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "notDetermined"
    case .denied: return "denied"
    case .authorized: return "authorized"
    case .provisional: return "provisional"
    case .ephemeral: return "ephemeral"
    @unknown default: return "unknown"
    }
  }
}
