import XCTest
@testable import PuxCore

final class RecordStoreTests: PuxTestCase {
    private let validKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    private var inMemoryStorage: InMemoryStorage!
    private var store: RecordStore!

    override func setUp() {
        super.setUp()
        inMemoryStorage = InMemoryStorage()
        store = RecordStore(storage: inMemoryStorage, defaultServerUrl: "https://pux.default")
    }

    private func validDict() -> [String: Any] {
        return [
            "v": 1,
            "record_id": "00000000-0000-4000-8000-000000000001",
            "private_key": validKey,
            "public_key": validKey,
            "inbox": "token@pux.example",
            "server": "https://pux.example"
        ]
    }

    func testParseValidPayload() throws {
        let payload = try EnrollmentPayload.parse(dictionary: validDict())
        XCTAssertEqual(payload.recordId, "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(payload.publicKey, validKey)
        XCTAssertEqual(payload.inbox, "token@pux.example")
        XCTAssertEqual(payload.server, "https://pux.example")
    }

    func testRejectsMissingV() {
        var dict = validDict()
        dict.removeValue(forKey: "v")
        XCTAssertThrowsError(try EnrollmentPayload.parse(dictionary: dict))
    }

    func testRejectsUnsupportedVersion() {
        var dict = validDict()
        dict["v"] = 2
        XCTAssertThrowsError(try EnrollmentPayload.parse(dictionary: dict))
    }

    func testRejectsNonUuidRecordId() {
        var dict = validDict()
        dict["record_id"] = "../../admin"
        XCTAssertThrowsError(try EnrollmentPayload.parse(dictionary: dict))
    }

    func testRejectsInvalidKeyLength() {
        var dict = validDict()
        dict["private_key"] = "too-short"
        XCTAssertThrowsError(try EnrollmentPayload.parse(dictionary: dict))
    }

    func testValidateServerUrl() throws {
        XCTAssertEqual(
            try EnrollmentPayload.validateServerUrl("https://pux.example"),
            "https://pux.example"
        )
        XCTAssertEqual(
            try EnrollmentPayload.validateServerUrl("https://pux.example:8443/"),
            "https://pux.example:8443"
        )
        XCTAssertEqual(
            try EnrollmentPayload.validateServerUrl("http://localhost:4000"),
            "http://localhost:4000"
        )
        XCTAssertEqual(
            try EnrollmentPayload.validateServerUrl("http://127.0.0.1:4000"),
            "http://127.0.0.1:4000"
        )
        XCTAssertEqual(
            try EnrollmentPayload.validateServerUrl("http://10.0.2.2:4000"),
            "http://10.0.2.2:4000"
        )

        for bad in [
            "http://pux.example",
            "http://192.168.1.10:4000",
            "ftp://pux.example",
            "javascript:alert(1)",
            "pux.example",
            "https://user:pass@pux.example",
            "https://pux.example/api",
            "https://pux.example?x=1",
        ] {
            XCTAssertThrowsError(try EnrollmentPayload.validateServerUrl(bad), "Expected failure for \(bad)")
        }
    }

    func testSaveEnrollmentStoresValuesAndChecksEnrolled() async throws {
        let payload = try EnrollmentPayload.parse(dictionary: validDict())
        let beforeEnrolled = try await store.isEnrolled()
        XCTAssertFalse(beforeEnrolled)

        try store.saveEnrollment(payload)
        let afterEnrolled = try await store.isEnrolled()
        XCTAssertTrue(afterEnrolled)
        XCTAssertEqual(try store.recordId(), "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(try store.inbox(), "token@pux.example")
        XCTAssertEqual(store.serverUrl, "https://pux.example")
    }

    func testClearForgetsEnrollmentButKeepsNotificationAsked() async throws {
        let payload = try EnrollmentPayload.parse(dictionary: validDict())
        try store.saveEnrollment(payload)
        try store.saveDeviceId("dev_123")
        try store.saveNotificationPermissionAsked()
        try store.saveNotificationExplainerSkipped()

        let isEnrolledBefore = try await store.isEnrolled()
        XCTAssertTrue(isEnrolledBefore)
        XCTAssertEqual(try store.deviceId(), "dev_123")
        XCTAssertTrue(try store.notificationPermissionAsked())
        XCTAssertTrue(try store.notificationExplainerSkipped())

        try store.clear()

        let isEnrolledAfter = try await store.isEnrolled()
        XCTAssertFalse(isEnrolledAfter)
        XCTAssertNil(try store.deviceId())
        XCTAssertNil(try store.recordId())
        XCTAssertEqual(store.serverUrl, "https://pux.default")
        XCTAssertTrue(try store.notificationPermissionAsked())
        XCTAssertFalse(try store.notificationExplainerSkipped())
    }

    func testDesktopDeviceIdGenerates32HexCharsAndPersists() throws {
        let id1 = try store.desktopDeviceId()
        XCTAssertEqual(id1.count, 32)
        let id2 = try store.desktopDeviceId()
        XCTAssertEqual(id1, id2)
    }

    /// Verifies upgrade from the released Flutter macOS storage layout
    /// where keys were saved via flutter_secure_storage (generic passwords,
    /// service "flutter_secure_storage_service").
    func testFlutterKeychainUpgradeFixture() async throws {
        let flutterFixtureData: [String: String] = [
            "record_id": "11111111-2222-4333-8444-555555555555",
            "private_key": validKey,
            "public_key": validKey,
            "inbox": "flutter-upgrade@pux.example",
            "server_url": "https://relay.flutter.example",
            "desktop_device_id": "0123456789abcdef0123456789abcdef",
            "device_id": "dev_flutter_987",
            "notification_permission_asked": "true",
            "notification_explainer_skipped": "true"
        ]

        let preloadedStorage = InMemoryStorage(initialValues: flutterFixtureData)
        let upgradedStore = RecordStore(storage: preloadedStorage, defaultServerUrl: "https://pux.default")

        // 1. App should detect active enrollment immediately
        let enrolled = try await upgradedStore.isEnrolled()
        XCTAssertTrue(enrolled, "Existing Flutter enrollment must be recognized immediately")

        // 2. All stored identifiers and credentials match Flutter values
        XCTAssertEqual(try upgradedStore.recordId(), "11111111-2222-4333-8444-555555555555")
        XCTAssertEqual(try upgradedStore.privateKey(), validKey)
        XCTAssertEqual(try upgradedStore.publicKey(), validKey)
        XCTAssertEqual(try upgradedStore.inbox(), "flutter-upgrade@pux.example")
        XCTAssertEqual(upgradedStore.serverUrl, "https://relay.flutter.example")
        XCTAssertEqual(try upgradedStore.deviceId(), "dev_flutter_987")
        XCTAssertEqual(try upgradedStore.desktopDeviceId(), "0123456789abcdef0123456789abcdef", "Must retain Flutter desktop_device_id")
        XCTAssertTrue(try upgradedStore.notificationPermissionAsked())
        XCTAssertTrue(try upgradedStore.notificationExplainerSkipped())

        // 3. Payload export produces matching v1 dictionary
        let payload = try upgradedStore.enrollmentPayload()
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.version, 1)
        XCTAssertEqual(payload?.recordId, "11111111-2222-4333-8444-555555555555")
        XCTAssertEqual(payload?.server, "https://relay.flutter.example")
        XCTAssertEqual(payload?.inbox, "flutter-upgrade@pux.example")

        let dict = payload?.asDictionary()
        XCTAssertEqual(dict?["v"] as? Int, 1)
        XCTAssertEqual(dict?["record_id"] as? String, "11111111-2222-4333-8444-555555555555")
        XCTAssertEqual(dict?["server"] as? String, "https://relay.flutter.example")
        XCTAssertEqual(dict?["inbox"] as? String, "flutter-upgrade@pux.example")
    }

    @MainActor
    func testDeletionFailurePreservesLocalEnrollment() async throws {
        let payload = try EnrollmentPayload.parse(dictionary: validDict())
        try store.saveEnrollment(payload)
        let before = try await store.isEnrolled()
        XCTAssertTrue(before)

        let transport = MockTransport { req in
            // Simulate network or server 500 failure on DELETE
            return (Data("Server error".utf8), HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }

        let apiClient = ApiClient(recordStore: store, transport: transport)
        let controller = DeliveryController(recordStore: store, apiClient: apiClient)

        do {
            try await controller.deleteRelayEverywhere()
            XCTFail("Should have thrown error on server deletion failure")
        } catch {
            // Expected error
        }

        // Local keys must NOT have been erased!
        let stillEnrolled = try await store.isEnrolled()
        XCTAssertTrue(stillEnrolled, "Failed server deletion must preserve local keys and enrollment")
        XCTAssertEqual(try store.recordId(), "00000000-0000-4000-8000-000000000001")
    }

    @MainActor
    func testRemoveDeviceFailurePreservesLocalEnrollment() async throws {
        let payload = try EnrollmentPayload.parse(dictionary: validDict())
        try store.saveEnrollment(payload)
        try store.saveDeviceId("dev_test_device")
        let before = try await store.isEnrolled()
        XCTAssertTrue(before)

        let transport = MockTransport { req in
            return (Data("Offline".utf8), HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }

        let apiClient = ApiClient(recordStore: store, transport: transport)
        let controller = DeliveryController(recordStore: store, apiClient: apiClient)

        do {
            try await controller.removeThisDevice()
            XCTFail("Should have thrown error on device removal failure")
        } catch {
            // Expected error
        }

        // Local keys and device must NOT be wiped
        let stillEnrolled = try await store.isEnrolled()
        XCTAssertTrue(stillEnrolled, "Failed device removal must preserve local enrollment")
        XCTAssertEqual(try store.deviceId(), "dev_test_device")
    }

    @MainActor
    func testInitializationKeychainErrorSetsStorageErrorAndDoesNotEnroll() async {
        final class FailingStorage: SecureStorage, @unchecked Sendable {
            func read(key: String) throws -> String? {
                throw NSError(domain: NSOSStatusErrorDomain, code: -34018, userInfo: [NSLocalizedDescriptionKey: "errSecMissingEntitlement (-34018)"])
            }
            func write(key: String, value: String) throws {
                throw NSError(domain: NSOSStatusErrorDomain, code: -34018, userInfo: [NSLocalizedDescriptionKey: "errSecMissingEntitlement (-34018)"])
            }
            func delete(key: String) throws {}
            func deleteAll() throws {}
        }

        let failingStore = RecordStore(storage: FailingStorage(), defaultServerUrl: "https://pux.test")
        let controller = DeliveryController(recordStore: failingStore)

        await controller.initialize()

        XCTAssertNotNil(controller.storageError, "Keychain read failure must surface as storageError")
        XCTAssertFalse(controller.isEnrolled, "Keychain read failure must not present as enrolled")
        XCTAssertNil(controller.currentInbox)
    }

    @MainActor
    func testCommitEnrollmentSucceedsWithoutBlockingOnNetwork() async throws {
        // Even when offline or server unreachable, local enrollment must save immediately
        let transport = MockTransport { _ in
            throw ApiError.networkError("Offline")
        }
        let apiClient = ApiClient(recordStore: store, transport: transport)
        let controller = DeliveryController(recordStore: store, apiClient: apiClient)

        let payload = try EnrollmentPayload.parse(dictionary: validDict())
        try await controller.commitEnrollment(payload)

        let enrolled = try await store.isEnrolled()
        XCTAssertTrue(enrolled, "Commit enrollment must persist local keys immediately")
        XCTAssertTrue(controller.isEnrolled)
    }
}
