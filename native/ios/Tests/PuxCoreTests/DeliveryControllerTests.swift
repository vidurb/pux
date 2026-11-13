import XCTest
@testable import PuxCore

private final class MockDeliveryService: DeliveryServiceProtocol, @unchecked Sendable {
    var shouldThrow: Error? = nil
    var startCalled = 0
    var stopCalled = 0

    func start() async throws {
        startCalled += 1
        if let err = shouldThrow {
            throw err
        }
    }

    func stop() async {
        stopCalled += 1
    }
}

private final class PartiallyFailingStore: KeyValueStore {
    let backing = InMemoryKeyValueStore()
    var failClear = true
    func read(_ key: String) -> String? { backing.read(key) }
    func write(_ key: String, value: String) throws { try backing.write(key, value: value) }
    func delete(_ key: String) throws { try backing.delete(key) }
    func deleteAll() throws {
        try backing.delete(RecordStore.privateKeyKey)
        if failClear { throw URLError(.cannotWriteToFile) }
        try backing.deleteAll()
    }
}

final class DeliveryControllerTests: XCTestCase {
    private func enroll(_ store: RecordStore) throws {
        try store.saveEnrollment([
            "record_id": UUID().uuidString.lowercased(),
            "public_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "private_key": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
            "inbox": "test@pux.vidur.xyz",
            "server": "https://pux.vidur.xyz"
        ])
    }

    @MainActor
    func testRestartAfterServerDeletionBlocksRegistrationUntilExplicitRecovery() async throws {
        let storage = InMemoryKeyValueStore()
        let journal = MemoryRemovalJournal()
        let store = RecordStore(storage: storage, removalJournal: journal)
        try enroll(store)
        try store.saveDeviceId("device-id")
        let session = MockURLProtocol.makeSession()
        let api = ApiClient(session: session, recordStore: store)
        var deletes = 0
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            deletes += 1
            return (HTTPURLResponse(url: request.url!, statusCode: deletes == 1 ? 204 : 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { MockURLProtocol.requestHandler = nil }
        let first = DeliveryController(recordStore: store, deliveryService: MockDeliveryService())
        try await first.removeDevice(apiClient: api)
        XCTAssertEqual(try store.removalIntent(), .device)
        // Simulate process death after server success but before local cleanup.
        let restartedStore = RecordStore(storage: storage, removalJournal: journal)
        let service = MockDeliveryService()
        let restarted = DeliveryController(recordStore: restartedStore, deliveryService: service)
        await restarted.start()
        await restarted.onResume()
        XCTAssertEqual(service.startCalled, 0)
        try await restarted.recoverRemoval(.device, apiClient: api)
        XCTAssertEqual(deletes, 2)
        XCTAssertNil(try restartedStore.removalIntent())
        XCTAssertFalse(restartedStore.isEnrolled())
    }

    @MainActor
    func testRestartAfterIntentBeforeNetworkBlocksStartup() async throws {
        let journal = MemoryRemovalJournal()
        let storage = InMemoryKeyValueStore()
        let store = RecordStore(storage: storage, removalJournal: journal)
        try enroll(store)
        let first = DeliveryController(recordStore: store, deliveryService: MockDeliveryService())
        try await first.prepareRemoval(.relay)
        let restarted = RecordStore(storage: storage, removalJournal: journal)
        let service = MockDeliveryService()
        let controller = DeliveryController(recordStore: restarted, deliveryService: service)
        await controller.start()
        XCTAssertEqual(try restarted.removalIntent(), .relay)
        XCTAssertEqual(service.startCalled, 0)
    }

    @MainActor
    func testUnreadableJournalFailsClosedAndFailedCancellationKeepsIntent() async throws {
        let journal = MemoryRemovalJournal(.device)
        let store = RecordStore(storage: InMemoryKeyValueStore(), removalJournal: journal)
        try enroll(store)
        let service = MockDeliveryService()
        let controller = DeliveryController(recordStore: store, deliveryService: service)
        journal.failReads = true
        await controller.onResume()
        XCTAssertEqual(service.startCalled, 0)
        journal.failReads = false
        journal.failWrites = true
        do { try await controller.endRemoval(resume: true); XCTFail("Expected clear failure") } catch {}
        await controller.start()
        XCTAssertEqual(service.startCalled, 0)
        XCTAssertEqual(try store.removalIntent(), .device)
    }

    @MainActor
    func testPartialLocalClearKeepsJournalAcrossRestart() async throws {
        let storage = PartiallyFailingStore()
        let journal = MemoryRemovalJournal()
        let store = RecordStore(storage: storage, removalJournal: journal)
        try enroll(store)
        let controller = DeliveryController(recordStore: store, deliveryService: MockDeliveryService())
        do { try await controller.finishRemovalLocally(); XCTFail("Expected clear failure") } catch {}
        XCTAssertEqual(try store.removalIntent(), .local)
        let restartedStore = RecordStore(storage: storage, removalJournal: journal)
        let service = MockDeliveryService()
        let restarted = DeliveryController(recordStore: restartedStore, deliveryService: service)
        await restarted.onResume()
        XCTAssertEqual(service.startCalled, 0)
        storage.failClear = false
        try await restarted.recoverRemoval(.local)
        XCTAssertNil(try restartedStore.removalIntent())
        XCTAssertFalse(restartedStore.isEnrolled())
    }

    @MainActor
    func testJournalWriteFailurePreventsServerDeletion() async throws {
        let journal = MemoryRemovalJournal()
        let store = RecordStore(storage: InMemoryKeyValueStore(), removalJournal: journal)
        try enroll(store)
        try store.saveDeviceId("device-id")
        journal.failWrites = true
        MockURLProtocol.requestHandler = { _ in XCTFail("No network request permitted"); throw URLError(.badURL) }
        defer { MockURLProtocol.requestHandler = nil }
        let api = ApiClient(session: MockURLProtocol.makeSession(), recordStore: store)
        let service = MockDeliveryService()
        let controller = DeliveryController(recordStore: store, deliveryService: service)
        await controller.start()
        XCTAssertEqual(service.startCalled, 1)
        do { try await controller.removeDevice(apiClient: api); XCTFail("Expected journal failure") } catch {}
        XCTAssertEqual(service.stopCalled, 1)
        XCTAssertEqual(controller.status.state, .idle)
        await controller.onResume()
        XCTAssertEqual(service.startCalled, 1)
        XCTAssertTrue(store.isEnrolled())
        journal.failWrites = false
        try await controller.endRemoval(resume: true)
        XCTAssertEqual(service.startCalled, 2)
    }

    @MainActor
    func testRelayRecoveryAfter204Then401CompletesLocalCleanup() async throws {
        let storage = InMemoryKeyValueStore()
        let journal = MemoryRemovalJournal()
        let store = RecordStore(storage: storage, removalJournal: journal)
        try enroll(store)
        let api = ApiClient(session: MockURLProtocol.makeSession(), recordStore: store)
        var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            XCTAssertEqual(request.httpMethod, "DELETE")
            return (HTTPURLResponse(url: request.url!, statusCode: requests == 1 ? 204 : 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { MockURLProtocol.requestHandler = nil }
        let first = DeliveryController(recordStore: store, deliveryService: MockDeliveryService())
        try await first.prepareRemoval(.relay)
        try await api.deleteRecord(recordId: store.recordId()!)
        // Relaunch after the successful server deletion, before local cleanup.
        let restartedStore = RecordStore(storage: storage, removalJournal: journal)
        let service = MockDeliveryService()
        let restarted = DeliveryController(recordStore: restartedStore, deliveryService: service)
        let restartedAPI = ApiClient(session: MockURLProtocol.makeSession(), recordStore: restartedStore)
        try await restarted.recoverRemoval(.relay, apiClient: restartedAPI)
        XCTAssertNil(try restartedStore.removalIntent())
        XCTAssertFalse(restartedStore.isEnrolled())
        XCTAssertEqual(requests, 2)
    }

    @MainActor
    func testExplicitCancellationClearsJournalAndResumes() async throws {
        let journal = MemoryRemovalJournal(.device)
        let store = RecordStore(storage: InMemoryKeyValueStore(), removalJournal: journal)
        try enroll(store)
        let service = MockDeliveryService()
        let controller = DeliveryController(recordStore: store, deliveryService: service)
        await controller.onResume()
        XCTAssertEqual(service.startCalled, 0)
        try await controller.endRemoval(resume: true)
        XCTAssertNil(try store.removalIntent())
        XCTAssertEqual(service.startCalled, 1)
    }

    func testBackoffExponentialGrowthAndCapping() {
        let b0 = DeliveryController.calculateBackoff(attempt: 0, randomFraction: 0.0)
        XCTAssertEqual(b0, 2.0)

        let b1 = DeliveryController.calculateBackoff(attempt: 1, randomFraction: 0.0)
        XCTAssertEqual(b1, 4.0)

        let b4 = DeliveryController.calculateBackoff(attempt: 4, randomFraction: 0.0)
        XCTAssertEqual(b4, 32.0)

        let b10 = DeliveryController.calculateBackoff(attempt: 10, randomFraction: 0.0)
        XCTAssertEqual(b10, 300.0)
    }

    @MainActor
    func testUndecryptableIncrement() {
        let inMemory = InMemoryKeyValueStore()
        let store = RecordStore(storage: inMemory)
        let controller = DeliveryController(recordStore: store)

        XCTAssertEqual(controller.status.undecryptable, 0)
        controller.reportUndecryptable()
        XCTAssertEqual(controller.status.undecryptable, 1)
        controller.reportUndecryptable()
        XCTAssertEqual(controller.status.undecryptable, 2)
    }

    @MainActor
    func testReportErrorTransitions() {
        let inMemory = InMemoryKeyValueStore()
        let store = RecordStore(storage: inMemory)
        let controller = DeliveryController(recordStore: store)

        controller.reportError(PuxError.recordNotFound)
        XCTAssertEqual(controller.status.state, .recordUnknown)

        controller.reportError(PuxError.tooManyDevices)
        XCTAssertEqual(controller.status.state, .tooManyDevices)

        controller.reportError(PuxError.rateLimited)
        XCTAssertEqual(controller.status.state, .retrying)
    }

    @MainActor
    func testDeliveryServiceNilTransitionsToFirebaseUnconfigured() async throws {
        let inMemory = InMemoryKeyValueStore()
        let store = RecordStore(storage: inMemory)
        try store.saveEnrollment([
            "record_id": UUID().uuidString.lowercased(),
            "public_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "private_key": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
            "inbox": "test@pux.vidur.xyz",
            "server": "https://pux.vidur.xyz"
        ])

        let controller = DeliveryController(recordStore: store, deliveryService: nil)
        controller.deliveryService = nil

        await controller.start()
        XCTAssertEqual(controller.status.state, .firebaseUnconfigured)
        XCTAssertEqual(controller.status.message, "Push notifications are not configured in this build.")
    }

    @MainActor
    func testRemovalSuspendsResumeAndCancellationRestartsDelivery() async throws {
        let store = RecordStore(storage: InMemoryKeyValueStore())
        try store.saveEnrollment([
            "record_id": UUID().uuidString.lowercased(),
            "public_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "private_key": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
            "inbox": "test@pux.vidur.xyz",
            "server": "https://pux.vidur.xyz"
        ])
        let service = MockDeliveryService()
        let controller = DeliveryController(recordStore: store, deliveryService: service)
        await controller.start()
        await controller.beginRemoval()
        await controller.onResume()
        await controller.start()
        controller.reportError(URLError(.notConnectedToInternet))
        XCTAssertEqual(service.startCalled, 1)
        XCTAssertEqual(controller.status.state, .idle)
        try await controller.endRemoval(resume: true)
        XCTAssertEqual(service.startCalled, 2)
        XCTAssertEqual(controller.status.state, .ready)
    }

    @MainActor
    func testDeliveryServiceSuccessTransitionsToReady() async throws {
        let inMemory = InMemoryKeyValueStore()
        let store = RecordStore(storage: inMemory)
        try store.saveEnrollment([
            "record_id": UUID().uuidString.lowercased(),
            "public_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "private_key": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
            "inbox": "test@pux.vidur.xyz",
            "server": "https://pux.vidur.xyz"
        ])

        let mockService = MockDeliveryService()
        let controller = DeliveryController(recordStore: store, deliveryService: mockService)

        await controller.start()
        XCTAssertEqual(controller.status.state, .ready)
        XCTAssertEqual(mockService.startCalled, 1)

        await controller.onResume()
        XCTAssertEqual(mockService.startCalled, 1) // not stale yet

        await controller.stop()
        XCTAssertEqual(controller.status.state, .idle)
        XCTAssertEqual(mockService.stopCalled, 1)
    }
}
