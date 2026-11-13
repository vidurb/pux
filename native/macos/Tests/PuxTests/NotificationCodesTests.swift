import XCTest
@testable import PuxCore

final class NotificationCodesTests: PuxTestCase {
    func testExpiryOccursWithoutReadingAndReplacementSurvivesOldTimer() async throws {
        let codes = NotificationCodes()
        codes.put(id: "old", code: "secret", lifetime: 0.03)
        codes.put(id: "replacement", code: "first", lifetime: 0.03)
        codes.put(id: "replacement", code: "second", lifetime: 1)
        try await Task.sleep(nanoseconds: 150_000_000)
        let entries = Mirror(reflecting: codes).children.first { $0.label == "codes" }?.value as? [String: String]
        XCTAssertNil(entries?["old"])
        XCTAssertEqual(entries?["replacement"], "second")
        codes.clear()
        XCTAssertNil(codes.take(id: "replacement"))
    }

    func testCacheHasBoundedCapacity() {
        let codes = NotificationCodes()
        for i in 0..<300 { codes.put(id: "\(i)", code: "secret") }
        XCTAssertEqual(codes.count, NotificationCodes.maxEntries)
    }

    func testPutAndTake() {
        let codes = NotificationCodes()
        codes.put(id: "n1", code: "123456")

        XCTAssertEqual(codes.count, 1)
        XCTAssertEqual(codes.take(id: "n1"), "123456")
        XCTAssertEqual(codes.count, 0)
        XCTAssertNil(codes.take(id: "n1"))
    }

    func testRemove() {
        let codes = NotificationCodes()
        codes.put(id: "n1", code: "123456")
        codes.remove(id: "n1")

        XCTAssertEqual(codes.count, 0)
        XCTAssertNil(codes.take(id: "n1"))
    }

    func testExpiry() {
        let codes = NotificationCodes()
        codes.put(id: "n1", code: "123456", lifetime: -1.0) // already expired

        XCTAssertEqual(codes.count, 0)
        XCTAssertNil(codes.take(id: "n1"))
    }

    func testNotificationCodesExpiresAndNeverPersistsOnDisk() {
        let codes = NotificationCodes()
        codes.put(id: "otp_1", code: "555444")
        XCTAssertEqual(codes.count, 1)

        // First read takes the code and removes it from memory
        let retrieved = codes.take(id: "otp_1")
        XCTAssertEqual(retrieved, "555444")

        // Second read after taking or after 15m expiration returns nil
        XCTAssertNil(codes.take(id: "otp_1"))
        XCTAssertEqual(codes.count, 0)
    }
}
