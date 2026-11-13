import XCTest
@testable import PuxCore

/// Hosted tests launch the production app as their host. These tests pin the rules that keep that launch
/// (and any other test process) away from the real Keychain, APNs and Firebase, and that keep a real
/// launch doing all of it.
final class PuxLaunchContextTests: XCTestCase {
  func testThisTestProcessIsDetectedAsATestRun() {
    XCTAssertEqual(PuxLaunchContext.current, .test)
  }

  func testEveryXCTestEnvironmentKeyMarksATestRun() {
    XCTAssertFalse(PuxLaunchContext.testEnvironmentKeys.isEmpty)
    for key in PuxLaunchContext.testEnvironmentKeys {
      let context = PuxLaunchContext.detect(environment: [key: "1", "HOME": "/var/mobile"], xctestLoaded: false)
      XCTAssertEqual(context, .test, key)
    }
  }

  /// A hosted run configures its app before XCTest's classes load, so the environment alone must decide.
  func testHostAppIsDetectedFromTheEnvironmentBeforeXCTestLoads() {
    let context = PuxLaunchContext.detect(
      environment: ["XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration"],
      xctestLoaded: false
    )
    XCTAssertEqual(context, .test)
  }

  func testLoadedXCTestMarksATestRunWithoutEnvironment() {
    XCTAssertEqual(PuxLaunchContext.detect(environment: [:], xctestLoaded: true), .test)
  }

  func testOrdinaryLaunchEnvironmentIsProduction() {
    let environment = [
      "HOME": "/var/mobile/Containers/Data/Application/ABCD",
      "TMPDIR": "/var/mobile/Containers/Data/Application/ABCD/tmp/",
      "CFFIXED_USER_HOME": "/var/mobile/Containers/Data/Application/ABCD",
      "OS_ACTIVITY_DT_MODE": "YES",
    ]
    XCTAssertEqual(PuxLaunchContext.detect(environment: environment, xctestLoaded: false), .production)
    XCTAssertEqual(PuxLaunchContext.detect(environment: [:], xctestLoaded: false), .production)
  }
}

final class AppBootstrapTests: XCTestCase {
  private final class StepRecorder {
    private(set) var order: [String] = []

    func steps() -> AppLaunchSteps {
      AppLaunchSteps(
        migrateLegacyKeychainItems: { self.order.append("keychain-migration") },
        observeProtectedDataAvailability: { self.order.append("protected-data-observer") },
        configureNotificationHandling: { self.order.append("notification-handling") },
        registerForRemoteNotifications: { self.order.append("apns-registration") },
        configureFirebaseDelivery: { self.order.append("firebase") }
      )
    }
  }

  func testHostedTestLaunchRunsNoProductionStep() {
    let recorder = StepRecorder()
    let ran = AppBootstrap.run(recorder.steps(), context: .test)
    XCTAssertFalse(ran)
    XCTAssertEqual(recorder.order, [])
  }

  /// The default context is what the app delegate uses, so it must not be production under XCTest.
  func testDefaultContextInThisTestProcessRunsNoProductionStep() {
    let recorder = StepRecorder()
    XCTAssertFalse(AppBootstrap.run(recorder.steps()))
    XCTAssertEqual(recorder.order, [])
  }

  func testProductionLaunchRunsEveryStepInOrder() {
    let recorder = StepRecorder()
    let ran = AppBootstrap.run(recorder.steps(), context: .production)
    XCTAssertTrue(ran)
    XCTAssertEqual(
      recorder.order,
      [
        "keychain-migration",
        "protected-data-observer",
        "notification-handling",
        "apns-registration",
        "firebase",
      ]
    )
  }
}
