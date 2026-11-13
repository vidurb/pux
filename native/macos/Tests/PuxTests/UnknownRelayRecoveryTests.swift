import XCTest
@testable import PuxCore

private final class FailingForgetStorage: SecureStorage, @unchecked Sendable {
    let memory = InMemoryStorage(initialValues: [
        "record_id": "12345678-1234-1234-1234-123456789012",
        "private_key": "private", "public_key": "public",
        "inbox": "test@pux.test", "server_url": "https://unused.invalid"
    ])
    func read(key: String) throws -> String? { try memory.read(key: key) }
    func write(key: String, value: String) throws { try memory.write(key: key, value: value) }
    func delete(key: String) throws { try memory.delete(key: key) }
    func deleteAll() throws { throw NSError(domain: "test.forget", code: 1) }
}

@MainActor
final class UnknownRelayRecoveryTests: PuxTestCase {
    func testFailedForgetKeepsRecoveryAndReportsStorageError() async throws {
        let controller = DeliveryController(recordStore: RecordStore(storage: FailingForgetStorage()))
        try await controller.refreshEnrollmentState()
        controller.deliveryService(controller.deliveryService, didUpdateStatus: DeliveryStatus(state: .recordUnknown))
        do {
            try await controller.forgetUnknownRelayLocally()
            XCTFail("Expected storage failure")
        } catch {}
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(controller.isEnrolled)
        XCTAssertNotNil(controller.storageError)
        XCTAssertEqual(controller.status.state, .recordUnknown)
    }
}
