import XCTest
@testable import PuxCore

final class KeychainAppProbeTests: PuxTestCase {
    func testProbeServiceDoesNotUseProductionName() {
        XCTAssertNotEqual(KeychainAppProbe.service, KeychainStorage.service)
    }

    func testAppProbeRoundTrip() throws {
        do {
            try KeychainAppProbe.run()
        } catch let error as NSError where error.domain == NSOSStatusErrorDomain && (error.code == -34018 || error.code == -25291) {
            throw XCTSkip("Keychain entitlement or service unavailable in test host (\(error.code))")
        }
    }
}
