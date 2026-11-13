import XCTest
@testable import PuxCore

final class KeychainXCTestGuardTests: PuxTestCase {
    func testProcessIsUnderXCTest() {
        XCTAssertTrue(KeychainStorage.isRunningUnderXCTest, "SwiftPM and xctest runs must be detected")
    }

    func testProductionKeychainInitWouldBeBlocked() {
        XCTAssertTrue(KeychainStorage.isRunningUnderXCTest)
        // Convenience init calls preconditionFailure when isRunningUnderXCTest; exercised via KeychainStorageTests + in-memory injection.
    }
}
