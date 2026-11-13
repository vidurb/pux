import Foundation

/// Whether this process is a real app run or an XCTest run.
///
/// App-hosted tests launch the production app as their host, so without a guard they would run the
/// production launch work (Keychain migration, APNs registration, Firebase) before any test starts.
public enum PuxLaunchContext: Equatable, Sendable {
  case production
  case test

  /// Set by XCTest / xcodebuild in test processes, including the host app of hosted tests. The host
  /// app is configured before the test bundle (and so before XCTest's classes) is loaded, so the
  /// environment is the signal that is visible that early.
  static let testEnvironmentKeys: [String] = [
    "XCTestConfigurationFilePath",
    "XCTestBundlePath",
    "XCTestSessionIdentifier",
    "XCInjectBundleInto",
  ]

  public static let current: PuxLaunchContext = detect()

  static func detect(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    xctestLoaded: Bool = NSClassFromString("XCTestCase") != nil
  ) -> PuxLaunchContext {
    if xctestLoaded { return .test }
    for key in testEnvironmentKeys where environment[key] != nil { return .test }
    return .production
  }
}

/// The side effects the app performs when it launches. Each one talks to a production service, so the
/// app runs them only through `AppBootstrap.run`, which refuses to in test processes.
public struct AppLaunchSteps {
  /// Moves un-grouped Flutter-era Keychain items into the shared access group.
  public var migrateLegacyKeychainItems: () -> Void
  /// Repeats the migration and reloads state once protected data becomes available after first unlock.
  public var observeProtectedDataAvailability: () -> Void
  /// Notification-center delegate and settings deep link.
  public var configureNotificationHandling: () -> Void
  /// Asks iOS for an APNs device token.
  public var registerForRemoteNotifications: () -> Void
  /// Configures Firebase Messaging and installs the FCM delivery service.
  public var configureFirebaseDelivery: () -> Void

  public init(
    migrateLegacyKeychainItems: @escaping () -> Void,
    observeProtectedDataAvailability: @escaping () -> Void,
    configureNotificationHandling: @escaping () -> Void,
    registerForRemoteNotifications: @escaping () -> Void,
    configureFirebaseDelivery: @escaping () -> Void
  ) {
    self.migrateLegacyKeychainItems = migrateLegacyKeychainItems
    self.observeProtectedDataAvailability = observeProtectedDataAvailability
    self.configureNotificationHandling = configureNotificationHandling
    self.registerForRemoteNotifications = registerForRemoteNotifications
    self.configureFirebaseDelivery = configureFirebaseDelivery
  }
}

public enum AppBootstrap {
  /// Runs the launch steps in their production order. In a test process it runs none of them.
  /// - Returns: whether the steps ran.
  @discardableResult
  public static func run(_ steps: AppLaunchSteps, context: PuxLaunchContext = .current) -> Bool {
    guard context == .production else { return false }
    steps.migrateLegacyKeychainItems()
    steps.observeProtectedDataAvailability()
    steps.configureNotificationHandling()
    steps.registerForRemoteNotifications()
    steps.configureFirebaseDelivery()
    return true
  }
}
