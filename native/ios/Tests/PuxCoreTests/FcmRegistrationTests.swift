import XCTest
@testable import PuxCore

private final class HangingRegisterFcmSource: FcmRegistrationSource, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (String) -> Void)?

    func setRegistrationHandler(_ handler: @escaping @Sendable (String) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func setApnsToken(_ token: Data) {}

    func register() async throws {
        try await Task.sleep(nanoseconds: 3_600_000_000_000)
    }

    func emitFID(_ fid: String) {
        lock.lock()
        let h = handler
        lock.unlock()
        h?(fid)
    }
}

private final class FakeFcmSource: FcmRegistrationSource, @unchecked Sendable {
    private let lock = NSLock()
    var fid: String? = "token_initial"
    var registerError: Error?
    var delayEmitError = false
    var staleError: Error?
    private var registerCalls = 0
    private var handler: (@Sendable (String) -> Void)?
    private var _apns: Data?
    private var errorHandler: (@Sendable (Error) -> Void)?

    var apns: Data? { lock.lock(); defer { lock.unlock() }; return _apns }
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return registerCalls }

    func setRegistrationHandler(_ handler: @escaping @Sendable (String) -> Void) {
        lock.lock()
        self.handler = handler
        let current = fid
        let delayed = delayEmitError
        let stale = staleError
        lock.unlock()
        if delayed, let stale {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                self?.emitError(stale)
            }
            return
        }
        if let current { handler(current) }
    }

    func setApnsToken(_ token: Data) {
        lock.lock(); _apns = token; lock.unlock()
    }

    func setErrorHandler(_ handler: @escaping @Sendable (Error) -> Void) {
        lock.lock()
        errorHandler = handler
        lock.unlock()
    }

    func emitError(_ error: Error) {
        lock.lock()
        let handler = errorHandler
        lock.unlock()
        handler?(error)
    }

    func register() async throws {
        lock.lock()
        registerCalls += 1
        let err = registerError
        let current = fid
        let h = handler
        lock.unlock()
        if let err { throw err }
        if let current, let h { h(current) }
    }

    func emit(_ value: String) {
        lock.lock()
        fid = value
        let h = handler
        lock.unlock()
        h?(value)
    }
}

private final class ObservedRemovalJournal: RemovalJournal {
    private let storage = MemoryRemovalJournal()
    let saved: XCTestExpectation
    init(saved: XCTestExpectation) { self.saved = saved }
    func read() throws -> RemovalIntent? { try storage.read() }
    func save(_ intent: RemovalIntent) throws {
        try storage.save(intent)
        saved.fulfill()
    }
    func clear() throws { try storage.clear() }
}

final class FcmRegistrationTests: XCTestCase {
    private var inMemoryStore: InMemoryKeyValueStore!
    private var recordStore: RecordStore!
    private var session: URLSession!
    private var apiClient: ApiClient!
    private var fakeSource: FakeFcmSource!

    override func setUp() {
        super.setUp()
        inMemoryStore = InMemoryKeyValueStore()
        recordStore = RecordStore(storage: inMemoryStore, defaultServerUrl: "https://pux.test")
        session = MockURLProtocol.makeSession()
        apiClient = ApiClient(session: session, recordStore: recordStore)
        fakeSource = FakeFcmSource()

        try! recordStore.saveEnrollment([
            "v": 1,
            "record_id": "00000000-0000-4000-8000-000000000001",
            "private_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "public_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "inbox": "inbox@pux.test",
            "server": "https://pux.test"
        ])
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testRegistrationRegistersAndReusesDeviceId() async throws {
        var registeredDevices: [String?] = []

        MockURLProtocol.requestHandler = { request in
            let body = try! JSONSerialization.jsonObject(with: request.bodyData!) as! [String: Any]
            registeredDevices.append(body["device_id"] as? String)

            let isFirst = registeredDevices.count == 1
            let responseJson = ["device_id": isFirst ? "dev_first_id" : "dev_first_id"]
            let data = try! JSONSerialization.data(withJSONObject: responseJson)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let reg = FcmRegistration(
            source: fakeSource,
            apiClient: apiClient,
            recordStore: recordStore
        )

        try await reg.start()
        XCTAssertEqual(fakeSource.callCount, 1)
        XCTAssertEqual(recordStore.deviceId(), "dev_first_id")
        XCTAssertEqual(registeredDevices, [nil])

        await reg.handleApnsToken(Data([1]))
        // Token refresh should reuse existing device_id
        fakeSource.emit("token_refreshed")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(recordStore.deviceId(), "dev_first_id")
        XCTAssertEqual(registeredDevices, [nil, "dev_first_id"])
    }


    func testApnsTokenBeforeStartIsPreservedAndStoppedRefreshIsIgnored() async throws {
        var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            let body = try JSONSerialization.jsonObject(with: request.bodyData!) as! [String: Any]
            XCTAssertEqual(body["push_token"] as? String, "token_initial")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONSerialization.data(withJSONObject: ["device_id": "device"]))
        }
        let registration = FcmRegistration(source: fakeSource, apiClient: apiClient, recordStore: recordStore)
        let apns = Data([1, 2, 3])
        await registration.handleApnsToken(apns)
        try await registration.start()
        XCTAssertEqual(fakeSource.apns, apns)
        await registration.stop()
        fakeSource.emit("late-token")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(requests, 1)
    }

    @MainActor
    func testRemovalWaitsForRegistrationAndBlocksResumeUntilDeleteCompletes() async throws {
        let registerStarted = expectation(description: "registration started")
        let deleteStarted = expectation(description: "delete started")
        let registerGate = DispatchSemaphore(value: 0)
        let deleteGate = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var methods: [String] = []
        MockURLProtocol.requestHandler = { request in
            lock.lock(); methods.append(request.httpMethod!); lock.unlock()
            if request.httpMethod == "POST" {
                registerStarted.fulfill()
                _ = registerGate.wait(timeout: .now() + 10)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        try JSONSerialization.data(withJSONObject: ["device_id": "new-device"]))
            }
            XCTAssertTrue(request.url!.path.hasSuffix("/new-device"))
            deleteStarted.fulfill()
            _ = deleteGate.wait(timeout: .now() + 10)
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        let service = FcmRegistration(source: fakeSource, apiClient: apiClient, recordStore: recordStore)
        await service.handleApnsToken(Data([1]))
        let controller = DeliveryController(recordStore: recordStore, deliveryService: service)
        let start = Task { await controller.start() }
        await fulfillment(of: [registerStarted], timeout: 5)
        let removal = Task { try await controller.removeDevice(apiClient: apiClient) }
        await Task.yield()
        await controller.onResume()
        registerGate.signal()
        await fulfillment(of: [deleteStarted], timeout: 5)
        await controller.onResume()
        await controller.start()
        deleteGate.signal()
        try await removal.value
        await start.value
        lock.lock(); let observed = methods; lock.unlock()
        XCTAssertEqual(observed, ["POST", "DELETE"])
        XCTAssertEqual(recordStore.deviceId(), "new-device")
        try await controller.endRemoval(resume: false)
    }

    @MainActor
    func testRestartDuringHeldRegistrationDrainPreservesRemovalIntent() async throws {
        let requestStarted = expectation(description: "registration request started")
        let intentSaved = expectation(description: "removal intent saved before drain")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let journal = ObservedRemovalJournal(saved: intentSaved)
        let store = RecordStore(storage: inMemoryStore, removalJournal: journal, defaultServerUrl: "https://pux.test")
        let api = ApiClient(session: session, recordStore: store)
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            requestStarted.fulfill()
            _ = gate.wait(timeout: .now() + 10)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONSerialization.data(withJSONObject: ["device_id": "new-device"]))
        }
        let service = FcmRegistration(source: fakeSource, apiClient: api, recordStore: store)
        let controller = DeliveryController(recordStore: store, deliveryService: service)
        let start = Task { await controller.start() }
        await fulfillment(of: [requestStarted], timeout: 5)
        let removal = Task { try await controller.prepareRemoval(.device) }
        await fulfillment(of: [intentSaved], timeout: 5)
        // Model a new process while the original request and drain are still held.
        let restartedStore = RecordStore(storage: inMemoryStore, removalJournal: journal, defaultServerUrl: "https://pux.test")
        let restarted = DeliveryController(recordStore: restartedStore, deliveryService: service)
        XCTAssertEqual(try restartedStore.removalIntent(), .device)
        await restarted.start()
        await restarted.onResume()
        XCTAssertEqual(fakeSource.callCount, 1)
        XCTAssertEqual(restarted.status.state, .idle)
        gate.signal()
        try await removal.value
        await start.value
        XCTAssertEqual(try restartedStore.removalIntent(), .device)
        XCTAssertEqual(restartedStore.deviceId(), "new-device")
    }

    @MainActor
    func testRemovalReconcilesLostRegistrationResponseBeforeDelete() async throws {
        var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            if requests == 1 { throw URLError(.networkConnectionLost) }
            if requests == 2 {
                let body = try JSONSerialization.jsonObject(with: request.bodyData!) as! [String: Any]
                XCTAssertEqual(body["push_token"] as? String, "token_initial")
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        try JSONSerialization.data(withJSONObject: ["device_id": "recovered-device"]))
            }
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertTrue(request.url!.path.hasSuffix("/recovered-device"))
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        let service = FcmRegistration(source: fakeSource, apiClient: apiClient, recordStore: recordStore)
        let controller = DeliveryController(recordStore: recordStore, deliveryService: service)
        await controller.start()
        XCTAssertEqual(recordStore.pendingRegistration(), "token_initial")
        try await controller.removeDevice(apiClient: apiClient)
        XCTAssertNil(recordStore.pendingRegistration())
        XCTAssertEqual(requests, 3)
        try await controller.endRemoval(resume: false)
    }

    @MainActor
    func testRemovalTreats401OnDeleteAsAlreadyGone() async throws {
        try recordStore.saveDeviceId("known-device")
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        let controller = DeliveryController(recordStore: recordStore, deliveryService: FcmRegistration())
        try await controller.removeDevice(apiClient: apiClient)
        try await controller.finishRemovalLocally()
        XCTAssertFalse(recordStore.isEnrolled())
    }

    @MainActor
    func testRemovalWithoutKnownDeviceRequiresExplicitForget() async throws {
        let controller = DeliveryController(recordStore: recordStore, deliveryService: FcmRegistration())
        do {
            try await controller.removeDevice(apiClient: apiClient)
            XCTFail("An unknown registration must not be silently forgotten")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("cannot be identified"))
        }
        try await controller.endRemoval(resume: false)
    }

    func testFirebaseConfigValidation() {
        let invalidDict: [String: Any] = [
            "API_KEY": "REPLACE_ME",
            "PROJECT_ID": "pux-test",
            "GCM_SENDER_ID": "12345",
            "GOOGLE_APP_ID": "1:12345:ios:abcdef",
            "BUNDLE_ID": "xyz.vidur.pux"
        ]
        XCTAssertNil(FirebaseConfig.load(fromDictionary: invalidDict))

        let validDict: [String: Any] = [
            "API_KEY": "AIzaSyRealApiKey12345",
            "PROJECT_ID": "pux-test",
            "GCM_SENDER_ID": "12345",
            "GOOGLE_APP_ID": "1:12345:ios:abcdef",
            "BUNDLE_ID": "xyz.vidur.pux"
        ]
        let config = FirebaseConfig.load(fromDictionary: validDict)
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.apiKey, "AIzaSyRealApiKey12345")
        XCTAssertEqual(config?.projectId, "pux-test")
    }

    func testFcmRegistrationTokenRefreshAndError() async throws {
        let fake = FakeFcmSource()
        var reportedError: Error?
        let reg = FcmRegistration(
            source: fake,
            apiClient: apiClient,
            recordStore: recordStore,
            onRefreshError: { err in reportedError = err }
        )

        MockURLProtocol.requestHandler = { request in
            let responseJson = ["device_id": "new_dev_123"]
            let data = try! JSONSerialization.data(withJSONObject: responseJson)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        try await reg.start()
        XCTAssertEqual(recordStore.deviceId(), "new_dev_123")

        await reg.handleApnsToken(Data([1]))
        // Refresh with new token succeeds
        fake.emit("new_token_456")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(reportedError)

        // Error during refresh is propagated to handler
        MockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://pux.test")!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        fake.emit("another_token_789")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(reportedError)
    }

    func testFcmRegistrationTimesOutWithoutHanging() async {
        let fake = FakeFcmSource()
        fake.fid = nil
        let reg = FcmRegistration(
            source: fake,
            apiClient: apiClient,
            recordStore: recordStore,
            registrationTimeout: 0.15
        )
        await reg.handleApnsToken(Data([1]))
        let start = Date()
        do {
            try await reg.start()
            XCTFail("Expected timeout")
        } catch let err as PuxError {
            XCTAssertEqual(err, .fcmRegistrationTimedOut)
        } catch {
            XCTFail("Unexpected \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
        await reg.stop()
    }

    func testLateFIDAfterTimeoutStillRegistersOnRefresh() async throws {
        let fake = FakeFcmSource()
        fake.fid = nil
        let reg = FcmRegistration(
            source: fake,
            apiClient: apiClient,
            recordStore: recordStore,
            registrationTimeout: 0.15
        )
        await reg.handleApnsToken(Data([1]))
        do {
            try await reg.start()
            XCTFail("Expected timeout")
        } catch {}
        await reg.stop()

        fake.fid = "late-fid"
        MockURLProtocol.requestHandler = { request in
            let body = try! JSONSerialization.jsonObject(with: request.bodyData!) as! [String: Any]
            XCTAssertEqual(body["push_token"] as? String, "late-fid")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONSerialization.data(withJSONObject: ["device_id": "dev_late"]))
        }
        let reg2 = FcmRegistration(source: fake, apiClient: apiClient, recordStore: recordStore)
        await reg2.handleApnsToken(Data([1]))
        try await reg2.start()
        XCTAssertEqual(recordStore.deviceId(), "dev_late")
        await reg2.stop()
    }

    func testEarlyFIDBeforeWaiterIsBuffered() async throws {
        let fake = FakeFcmSource()
        fake.fid = "early-fid"

        MockURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: URL(string: "https://pux.test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             try JSONSerialization.data(withJSONObject: ["device_id": "dev_early"]))
        }

        let reg = FcmRegistration(source: fake, apiClient: apiClient, recordStore: recordStore)
        await reg.handleApnsToken(Data([1]))
        try await reg.start()
        XCTAssertEqual(recordStore.deviceId(), "dev_early")
        await reg.stop()
    }

    @MainActor
    func testRemovalDeletesWithKnownDeviceDespitePendingRegistration() async throws {
        try recordStore.saveDeviceId("known-device")
        try recordStore.savePendingRegistration("uncertain-fid")
        var deleteCalled = false
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "DELETE" {
                deleteCalled = true
                XCTAssertTrue(request.url!.path.hasSuffix("/known-device"))
                return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            }
            XCTFail("Should not register when device id is known")
            throw URLError(.badURL)
        }
        let controller = DeliveryController(recordStore: recordStore, deliveryService: FcmRegistration())
        try await controller.removeDevice(apiClient: apiClient)
        XCTAssertTrue(deleteCalled)
        XCTAssertNil(recordStore.pendingRegistration())
        XCTAssertEqual(try recordStore.uncertainRegistrationRemovalWarningPhase(), .awaitingAcknowledgement)
        try await controller.finishRemovalLocally()
        XCTAssertEqual(try recordStore.uncertainRegistrationRemovalWarningPhase(), .awaitingAcknowledgement)
        try recordStore.acknowledgeUncertainRegistrationRemovalWarning()
        XCTAssertNil(try recordStore.uncertainRegistrationRemovalWarningPhase())
    }

    func testInitialFIDWaitsWhenRegisterNeverCompletes() async throws {
        let hanging = HangingRegisterFcmSource()
        let reg = FcmRegistration(
            source: hanging,
            apiClient: apiClient,
            recordStore: recordStore,
            registrationTimeout: 0.15
        )
        await reg.handleApnsToken(Data([1]))
        let start = Date()
        do {
            try await reg.start()
            XCTFail("Expected timeout")
        } catch let err as PuxError {
            XCTAssertEqual(err, .fcmRegistrationTimedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
        await reg.stop()
    }

    func testFIDCompletesWhileRegisterHangs() async throws {
        let hanging = HangingRegisterFcmSource()
        MockURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: URL(string: "https://pux.test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             try JSONSerialization.data(withJSONObject: ["device_id": "dev_hung"]))
        }
        let reg = FcmRegistration(source: hanging, apiClient: apiClient, recordStore: recordStore, registrationTimeout: 5)
        await reg.handleApnsToken(Data([1]))
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            hanging.emitFID("fid-while-hung")
        }
        try await reg.start()
        XCTAssertEqual(recordStore.deviceId(), "dev_hung")
        await reg.stop()
    }

    func testFirebaseErrorDuringInitialFIDWaitFailsStart() async throws {
        let fake = FakeFcmSource()
        fake.fid = nil
        let reg = FcmRegistration(
            source: fake,
            apiClient: apiClient,
            recordStore: recordStore,
            registrationTimeout: 2
        )
        await reg.handleApnsToken(Data([1]))
        let startTask = Task {
            try await reg.start()
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        fake.emitError(PuxError.serverError(statusCode: 503, message: "FCM unavailable"))
        do {
            try await startTask.value
            XCTFail("Expected error")
        } catch let err as PuxError {
            if case .serverError(let code, _) = err { XCTAssertEqual(code, 503) }
            else { XCTFail("Unexpected \(err)") }
        }
        await reg.stop()
    }

    @MainActor
    func testRemovalWarningSurvivesDeleteFailureAndPendingDeleteFailure() async throws {
        try recordStore.saveDeviceId("known-device")
        try recordStore.savePendingRegistration("uncertain-fid")
        inMemoryStore.shouldFailOnDelete = RecordStore.pendingRegistrationKey

        var deleteAttempts = 0
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "DELETE" {
                deleteAttempts += 1
                return (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
            }
            XCTFail("Unexpected request")
            throw URLError(.badURL)
        }
        let controller = DeliveryController(recordStore: recordStore, deliveryService: FcmRegistration())
        do {
            try await controller.removeDevice(apiClient: apiClient)
            XCTFail("Expected delete failure")
        } catch {}
        XCTAssertEqual(deleteAttempts, 1)
        XCTAssertEqual(try recordStore.uncertainRegistrationRemovalWarningPhase(), .recorded)
        XCTAssertFalse(try recordStore.uncertainRegistrationRemovalWarningAwaitingAcknowledgement())
        XCTAssertNotNil(recordStore.pendingRegistration())
    }

    @MainActor
    func testJournalWriteFailureStillDeletesKnownDevice() async throws {
        let journal = MemoryUncertainRegistrationWarningJournal()
        journal.failRecord = true
        let storage = InMemoryKeyValueStore()
        let store = RecordStore(storage: storage, uncertainRegistrationWarningJournal: journal)
        try store.saveEnrollment([
            "v": 1,
            "record_id": "00000000-0000-4000-8000-000000000001",
            "private_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "public_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "inbox": "inbox@pux.test",
            "server": "https://pux.test"
        ])
        try store.saveDeviceId("known-device")
        try store.savePendingRegistration("uncertain-fid")
        recordStore = store
        apiClient = ApiClient(session: session, recordStore: store)

        var deleteCalled = false
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "DELETE" {
                deleteCalled = true
                return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            }
            throw URLError(.badURL)
        }
        let controller = DeliveryController(recordStore: store, deliveryService: FcmRegistration())
        do {
            try await controller.removeDevice(apiClient: apiClient)
            XCTFail("Expected journal persistence error after delete")
        } catch let err as PuxError {
            if case .serverError(_, let message) = err {
                XCTAssertTrue(message.contains("removed from the server"))
            } else { XCTFail("Unexpected \(err)") }
        }
        XCTAssertTrue(deleteCalled)
        XCTAssertNil(try store.uncertainRegistrationRemovalWarningPhase())
        XCTAssertEqual(store.pendingRegistration(), "uncertain-fid")
    }

    @MainActor
    func testJournalReadFailurePropagatesOnRetryFinalization() async throws {
        let journal = MemoryUncertainRegistrationWarningJournal()
        let storage = InMemoryKeyValueStore()
        let store = RecordStore(storage: storage, uncertainRegistrationWarningJournal: journal)
        try store.saveEnrollment([
            "v": 1,
            "record_id": "00000000-0000-4000-8000-000000000001",
            "private_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "public_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "inbox": "inbox@pux.test",
            "server": "https://pux.test"
        ])
        try store.saveDeviceId("known-device")
        journal.stored = .recorded
        journal.failRead = true
        apiClient = ApiClient(session: session, recordStore: store)
        var deleteCalled = false
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "DELETE" {
                deleteCalled = true
                return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            }
            throw URLError(.badURL)
        }
        let controller = DeliveryController(recordStore: store, deliveryService: FcmRegistration())
        do {
            try await controller.removeDevice(apiClient: apiClient)
            XCTFail("Expected journal read failure")
        } catch let err as PuxError {
            if case .serverError(_, let message) = err {
                XCTAssertTrue(message.contains("could not be read or updated"))
            } else { XCTFail("Unexpected \(err)") }
        }
        XCTAssertTrue(deleteCalled)
        journal.failRead = false
        XCTAssertEqual(try store.uncertainRegistrationRemovalWarningPhase(), .recorded)
    }

    @MainActor
    func testJournalReadFailureDuringRecordStillDeletesAndKeepsPending() async throws {
        let journal = MemoryUncertainRegistrationWarningJournal()
        journal.failRead = true
        let storage = InMemoryKeyValueStore()
        let store = RecordStore(storage: storage, uncertainRegistrationWarningJournal: journal)
        try store.saveEnrollment([
            "v": 1,
            "record_id": "00000000-0000-4000-8000-000000000001",
            "private_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "public_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "inbox": "inbox@pux.test",
            "server": "https://pux.test"
        ])
        try store.saveDeviceId("known-device")
        try store.savePendingRegistration("uncertain-fid")
        apiClient = ApiClient(session: session, recordStore: store)
        var deleteCalled = false
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "DELETE" {
                deleteCalled = true
                return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            }
            throw URLError(.badURL)
        }
        let controller = DeliveryController(recordStore: store, deliveryService: FcmRegistration())
        do {
            try await controller.removeDevice(apiClient: apiClient)
            XCTFail("Expected unresolved warning error")
        } catch let err as PuxError {
            if case .serverError(_, let message) = err {
                XCTAssertTrue(message.contains("could not be read or updated"))
            } else { XCTFail("Unexpected \(err)") }
        }
        XCTAssertTrue(deleteCalled)
        XCTAssertEqual(store.pendingRegistration(), "uncertain-fid")
    }

    @MainActor
    func testMarkPhaseFailureAfterSuccessfulDeleteSurfacesError() async throws {
        let journal = MemoryUncertainRegistrationWarningJournal()
        let storage = InMemoryKeyValueStore()
        let store = RecordStore(storage: storage, uncertainRegistrationWarningJournal: journal)
        try store.saveEnrollment([
            "v": 1,
            "record_id": "00000000-0000-4000-8000-000000000001",
            "private_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "public_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "inbox": "inbox@pux.test",
            "server": "https://pux.test"
        ])
        try store.saveDeviceId("known-device")
        try store.savePendingRegistration("uncertain-fid")
        journal.failMarkComplete = true
        apiClient = ApiClient(session: session, recordStore: store)

        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "DELETE" {
                return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            }
            throw URLError(.badURL)
        }
        let controller = DeliveryController(recordStore: store, deliveryService: FcmRegistration())
        do {
            try await controller.removeDevice(apiClient: apiClient)
            XCTFail("Expected phase finalization error")
        } catch let err as PuxError {
            if case .serverError(_, let message) = err {
                XCTAssertTrue(message.contains("could not be finalized"))
            } else { XCTFail("Unexpected \(err)") }
        }
        XCTAssertEqual(try store.uncertainRegistrationRemovalWarningPhase(), .recorded)
        XCTAssertFalse(try store.uncertainRegistrationRemovalWarningAwaitingAcknowledgement())
    }

    func testStaleFirebaseErrorDoesNotFailNewFIDWait() async throws {
        let fake = FakeFcmSource()
        fake.fid = nil
        fake.delayEmitError = true
        fake.staleError = PuxError.serverError(statusCode: 503, message: "stale")
        let reg = FcmRegistration(
            source: fake,
            apiClient: apiClient,
            recordStore: recordStore,
            registrationTimeout: 0.15
        )
        await reg.handleApnsToken(Data([1]))
        do {
            try await reg.start()
        } catch {}
        await reg.stop()
        try await Task.sleep(nanoseconds: 250_000_000)

        fake.fid = "good-fid"
        fake.delayEmitError = false
        fake.staleError = nil
        MockURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: URL(string: "https://pux.test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             try JSONSerialization.data(withJSONObject: ["device_id": "dev_good"]))
        }
        let reg2 = FcmRegistration(source: fake, apiClient: apiClient, recordStore: recordStore, registrationTimeout: 2)
        await reg2.handleApnsToken(Data([1]))
        try await reg2.start()
        XCTAssertEqual(recordStore.deviceId(), "dev_good")
        await reg2.stop()
    }

    func testStopDuringInitialFIDWaitEndsWithoutHang() async throws {
        let hanging = HangingRegisterFcmSource()
        let reg = FcmRegistration(
            source: hanging,
            apiClient: apiClient,
            recordStore: recordStore,
            registrationTimeout: 5
        )
        await reg.handleApnsToken(Data([1]))
        let startTask = Task {
            try await reg.start()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await reg.stop()
        do {
            try await startTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch let err as PuxError where err == .fcmRegistrationTimedOut {
            XCTFail("Stop should cancel before timeout")
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testFcmRegistrationThrowsWhenNoConfig() async {
        MockURLProtocol.requestHandler = { _ in
            XCTFail("No network requests should be made when config is absent")
            throw URLError(.badURL)
        }

        let reg = FcmRegistration(
            source: nil,
            apiClient: apiClient,
            recordStore: recordStore
        )

        do {
            try await reg.start()
            XCTFail("Expected firebaseNotConfigured error")
        } catch let err as PuxError {
            XCTAssertEqual(err, .firebaseNotConfigured)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
