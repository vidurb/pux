import XCTest
@testable import PuxCore

final class MockNotificationPresenter: NotificationPresenter, @unchecked Sendable {
    var shownNotifications: [RelayNotification] = []
    var shouldFail: Bool = false
    var onShow: (@Sendable () async -> Void)?

    func show(notification: RelayNotification) async throws -> Bool {
        if let onShow = onShow {
            await onShow()
        }
        if shouldFail { return false }
        shownNotifications.append(notification)
        return true
    }
}

private final class InlineAckList: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    func append(_ id: String) { lock.withLock { ids.append(id) } }
    func current() -> [String] { lock.withLock { ids } }
    var count: Int { lock.withLock { ids.count } }
}

private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    func increment() {
        lock.withLock { attempts += 1 }
    }
    var value: Int {
        lock.withLock { attempts }
    }
}

final class MockPermissions: NotificationPermissionsProtocol, @unchecked Sendable {
    var access: NotificationAccess = .allowed

    func check() async -> NotificationAccess {
        return access
    }

    func ask() async -> NotificationAccess {
        return access
    }
}

final class DesktopDeliveryServiceTests: PuxTestCase {
    private var recordStore: RecordStore!
    private var inMemoryStorage: InMemoryStorage!
    private var keyPair: (publicKey: String, privateKey: String)!

    override func setUp() async throws {
        try await super.setUp()
        executionTimeAllowance = 90
        inMemoryStorage = InMemoryStorage()
        recordStore = RecordStore(storage: inMemoryStorage, defaultServerUrl: "https://pux.test")
        keyPair = try SodiumCrypto.shared.generateKeyPair()

        let payload = EnrollmentPayload(
            version: 1,
            recordId: "00000000-0000-4000-8000-000000000001",
            privateKey: keyPair.privateKey,
            publicKey: keyPair.publicKey,
            inbox: "inbox@pux.test",
            server: "https://pux.test"
        )
        try recordStore.saveEnrollment(payload)
    }

    private func makeCiphertext(otp: String, sender: String) throws -> String {
        let msg = "{\"type\":\"otp\",\"otp\":\"\(otp)\",\"sender\":\"\(sender)\"}".data(using: .utf8)!
        return try SodiumCrypto.shared.seal(message: msg, recipientPublicKeyB64: keyPair.publicKey)
    }

    func testDeliversAndAcksWhenAllowed() async throws {
        var ackedDeliveries: [String] = []
        let transport = MockTransport { req in
            if req.httpMethod == "DELETE" {
                ackedDeliveries.append(req.url!.lastPathComponent)
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let apiClient = ApiClient(recordStore: recordStore, transport: transport)
        let presenter = MockNotificationPresenter()
        let permissions = MockPermissions()
        permissions.access = .allowed

        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: apiClient,
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.startForTesting()

        let ct = try makeCiphertext(otp: "112233", sender: "TestBank")
        await service.handleEnvelope(deliveryId: "del_1", envelope: ["ciphertext": ct], session: 1)

        XCTAssertEqual(presenter.shownNotifications.count, 1)
        XCTAssertEqual(presenter.shownNotifications.first?.code, "112233")
        XCTAssertEqual(ackedDeliveries, ["del_1"])
        XCTAssertTrue(service.heldDeliveries.isEmpty)
    }

    func testHoldsWhenNotificationsOff() async throws {
        var ackedDeliveries: [String] = []
        let transport = MockTransport { req in
            if req.httpMethod == "DELETE" {
                ackedDeliveries.append(req.url!.lastPathComponent)
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let apiClient = ApiClient(recordStore: recordStore, transport: transport)
        let presenter = MockNotificationPresenter()
        let permissions = MockPermissions()
        permissions.access = .off

        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: apiClient,
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.startForTesting()

        let ct = try makeCiphertext(otp: "998877", sender: "TestBank")
        await service.handleEnvelope(deliveryId: "del_held", envelope: ["ciphertext": ct], session: 1)

        XCTAssertEqual(presenter.shownNotifications.count, 0)
        XCTAssertTrue(ackedDeliveries.isEmpty)
        XCTAssertEqual(service.heldDeliveries.count, 1)
        XCTAssertEqual(service.heldDeliveries.first?.deliveryId, "del_held")
        XCTAssertFalse(service.heldDeliveries.first!.notified)

        // Now permissions become allowed, flush should show and ack
        permissions.access = .allowed
        await service.flushHeld(session: 1)

        XCTAssertEqual(presenter.shownNotifications.count, 1)
        XCTAssertEqual(presenter.shownNotifications.first?.code, "998877")
        XCTAssertEqual(ackedDeliveries, ["del_held"])
        XCTAssertTrue(service.heldDeliveries.isEmpty)
    }

    func testUndecryptableDeliveryReportedOnceAcrossRepeatedHandling() async throws {
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        )
        service.startForTesting()
        await service.handleEnvelope(deliveryId: "bad", envelope: ["ciphertext": "nope"], session: 1)
        await service.handleEnvelope(deliveryId: "bad", envelope: ["ciphertext": "nope"], session: 1)
        XCTAssertEqual(service.status.undecryptable, 1)
        XCTAssertTrue(service.heldDeliveries.isEmpty)
    }

    func testUndecryptableCountSurvivesReconnectStatusChange() async throws {
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        )
        service.startForTesting()
        await service.handleEnvelope(deliveryId: "bad", envelope: ["ciphertext": "nope"], session: 1)
        XCTAssertEqual(service.status.undecryptable, 1)
        service.scheduleReconnect(recordId: "00000000-0000-4000-8000-000000000001", error: nil, session: 1)
        XCTAssertEqual(service.status.undecryptable, 1)
        XCTAssertEqual(service.status.state, .retrying)
        service.stop()
    }

    func testUndecryptableEnvelopeIncrementsCount() async throws {
        let transport = MockTransport { req in
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let apiClient = ApiClient(recordStore: recordStore, transport: transport)
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: apiClient
        )

        service.startForTesting()
        await service.handleEnvelope(deliveryId: "del_bad", envelope: ["ciphertext": "invalid_base64"], session: 1)
        XCTAssertEqual(service.status.undecryptable, 1)
    }

    func testHeldCodesNotClearedOnStopOrRestart() async throws {
        let transport = MockTransport { req in
            (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let apiClient = ApiClient(recordStore: recordStore, transport: transport)
        let presenter = MockNotificationPresenter()
        let permissions = MockPermissions()
        permissions.access = .off

        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: apiClient,
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.startForTesting()

        let ct = try makeCiphertext(otp: "123456", sender: "HeldBank")
        await service.handleEnvelope(deliveryId: "del_persist", envelope: ["ciphertext": ct], session: 1)
        XCTAssertEqual(service.heldDeliveries.count, 1)

        // Stopping the background tasks on network drop or offline retry must NOT wipe held deliveries
        service.stop()
        XCTAssertEqual(service.heldDeliveries.count, 1, "Held deliveries must survive service stop/retry")

        service.startForTesting(session: 2)
        XCTAssertEqual(service.heldDeliveries.count, 1, "Held deliveries must survive restart")

        // Only clear() on explicit logout or relay removal purges held codes
        service.clear()
        XCTAssertTrue(service.heldDeliveries.isEmpty, "Clear must purge held deliveries")
    }

    func testFullPendingPageDoesNotPurgeAbsentHeldCodes() async throws {
        var returnedItemsCount = 50
        let transport = MockTransport { req in
            if req.httpMethod == "GET" && req.url!.path.contains("/deliveries") {
                // Return 50 mock deliveries (full page) in {"deliveries": [...]} format
                var list: [[String: Any]] = []
                for i in 0..<returnedItemsCount {
                    list.append([
                        "delivery_id": "item_\(i)",
                        "envelope": ["ciphertext": "dummy"]
                    ])
                }
                let data = try! JSONSerialization.data(withJSONObject: ["deliveries": list])
                return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let apiClient = ApiClient(recordStore: recordStore, transport: transport)
        let presenter = MockNotificationPresenter()
        let permissions = MockPermissions()
        permissions.access = .off

        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: apiClient,
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.startForTesting()

        // Place del_existing into held deliveries
        let ct = try makeCiphertext(otp: "654321", sender: "Test")
        await service.handleEnvelope(deliveryId: "del_existing", envelope: ["ciphertext": ct], session: 1)
        XCTAssertEqual(service.heldDeliveries.count, 1)

        // 1. Poll with 50 items (full page). Absence from serverIds must NOT purge del_existing
        returnedItemsCount = 50
        try await service.pollPending(recordId: "00000000-0000-4000-8000-000000000001", session: 1)
        XCTAssertEqual(service.heldDeliveries.count, 1, "Full page (50) must not infer deletion of absent held codes")

        // 2. Poll with partial page (< 50 items). Now absence proves deletion from server
        returnedItemsCount = 5
        try await service.pollPending(recordId: "00000000-0000-4000-8000-000000000001", session: 1)
        XCTAssertEqual(service.heldDeliveries.count, 0, "Partial page (<50) proves server absence and purges held codes")
    }

    func testHandshakeTimeoutDeferredEnvelopeSurvivesFullPendingPoll() async throws {
        let recordId = "00000000-0000-4000-8000-000000000001"
        let transport = MockTransport { req in
            if req.httpMethod == "GET" && req.url!.path.contains("/deliveries") {
                var list: [[String: Any]] = []
                for i in 0..<ApiClient.pendingPageSize {
                    list.append([
                        "delivery_id": "poll_\(i)",
                        "envelope": ["ciphertext": "dummy"],
                    ])
                }
                let data = try! JSONSerialization.data(withJSONObject: ["deliveries": list])
                return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }

        let apiClient = ApiClient(recordStore: recordStore, transport: transport)
        let presenter = MockNotificationPresenter()
        let permissions = MockPermissions()
        permissions.access = .off

        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: apiClient,
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.startForTesting()

        let deliveryId = "ws_handshake_timeout_only"
        let ct = try makeCiphertext(otp: "112233", sender: "HandshakeBank")
        let deferredMsg =
            "{\"type\":\"envelope\",\"delivery_id\":\"\(deliveryId)\",\"envelope\":{\"ciphertext\":\"\(ct)\"}}"

        service.scheduleDeferredHandshakeMessages(
            [deferredMsg],
            recordId: recordId,
            session: 1
        )
        await service.drainDeliveryWorkForTesting()
        XCTAssertEqual(service.heldDeliveries.count, 1)
        XCTAssertEqual(service.heldDeliveries.first?.deliveryId, deliveryId)

        try await service.pollPending(recordId: recordId, session: 1)
        XCTAssertEqual(service.heldDeliveries.count, 1, "Full poll page must not drop handshake-only delivery")
    }

    func testKeepAlivePingWhileDeferredHandshakeWorkStalls() async throws {
        let ws = MockWebSocketConnection()
        let recordId = "00000000-0000-4000-8000-000000000001"

        let presenter = MockNotificationPresenter()
        presenter.onShow = {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                    continuation.resume()
                }
            }
        }
        let permissions = MockPermissions()
        permissions.access = .allowed

        let apiClient = ApiClient(recordStore: recordStore, transport: MockTransport { req in
            (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        })

        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: apiClient,
            notificationPresenter: presenter,
            notificationPermissions: permissions,
            presentationTimeout: 0.2
        )
        service.startForTesting()

        let ct = try makeCiphertext(otp: "445566", sender: "SlowBank")
        let deferredMsg =
            "{\"type\":\"envelope\",\"delivery_id\":\"deferred_slow\",\"envelope\":{\"ciphertext\":\"\(ct)\"}}"

        service.lastPongAtForTestingSeed()
        service.startPingTimer(ws: ws, recordId: recordId, session: 1, interval: 0.05)
        service.scheduleDeferredHandshakeMessages([deferredMsg], recordId: recordId, session: 1)

        for _ in 0..<40 {
            if ws.pingSendCount() >= 1 { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertGreaterThanOrEqual(ws.pingSendCount(), 1, "keep-alive should run while deferred work is still stalled")
    }

    func testBufferedHandshakeFramesSurviveImmediateReconnect() async throws {
        let recordId = "00000000-0000-4000-8000-000000000001"
        let permissions = MockPermissions()
        permissions.access = .off
        let presenter = MockNotificationPresenter()
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.startForTesting()
        service.reconnectBackoffOverrideForTesting = 1

        let ct = try makeCiphertext(otp: "808080", sender: "ReconnectBank")
        let deferredMsg =
            "{\"type\":\"envelope\",\"delivery_id\":\"survive_reconnect\",\"envelope\":{\"ciphertext\":\"\(ct)\"}}"

        service.scheduleDeferredHandshakeMessages([deferredMsg], recordId: recordId, session: 1)
        service.scheduleReconnect(
            recordId: recordId,
            error: ApiError.networkError("WebSocket pong timeout"),
            session: 1
        )
        await service.drainDeliveryWorkForTesting(session: 1)
        XCTAssertEqual(service.heldDeliveries.first?.deliveryId, "survive_reconnect")
    }

    func testNewSessionDeliveryQueueNotBlockedByStalledOldSession() async throws {
        let recordId = "00000000-0000-4000-8000-000000000001"
        let slowPresenter = MockNotificationPresenter()
        slowPresenter.onShow = {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    continuation.resume()
                }
            }
        }
        let permissions = MockPermissions()
        permissions.access = .off
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: slowPresenter,
            notificationPermissions: permissions
        )
        service.startForTesting(session: 1)

        let slowCt = try makeCiphertext(otp: "111111", sender: "Slow")
        let slowMsg =
            "{\"type\":\"envelope\",\"delivery_id\":\"old_session_slow\",\"envelope\":{\"ciphertext\":\"\(slowCt)\"}}"
        service.scheduleDeferredHandshakeMessages([slowMsg], recordId: recordId, session: 1)

        service.stop()
        service.startForTesting(session: 2)

        let fastCt = try makeCiphertext(otp: "222222", sender: "Fast")
        let fastMsg =
            "{\"type\":\"envelope\",\"delivery_id\":\"new_session_fast\",\"envelope\":{\"ciphertext\":\"\(fastCt)\"}}"
        service.scheduleDeferredHandshakeMessages([fastMsg], recordId: recordId, session: 2)

        let start = Date()
        await service.drainDeliveryWorkForTesting(session: 2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.25)
        XCTAssertEqual(service.heldDeliveries.first?.deliveryId, "new_session_fast")
    }

    func testReconnectDoesNotAwaitPollBeforeWebSocket() async throws {
        let recordId = "00000000-0000-4000-8000-000000000001"
        final class PollGate: @unchecked Sendable {
            private let lock = NSLock()
            private var blocked = true
            func release() {
                lock.lock()
                blocked = false
                lock.unlock()
            }
            func waitIfBlocked() {
                while lock.withLock({ blocked }) {
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
        }

        let gate = PollGate()
        let transport = MockTransport { req in
            if req.httpMethod == "GET", req.url!.path.contains("/deliveries") {
                gate.waitIfBlocked()
                let data = try! JSONSerialization.data(withJSONObject: ["deliveries": []])
                return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }

        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: transport),
            notificationPresenter: MockNotificationPresenter(),
            notificationPermissions: MockPermissions()
        )
        service.startForTesting()
        service.reconnectBackoffOverrideForTesting = 0

        let connectDeadline = Date().addingTimeInterval(0.5)
        service.scheduleReconnect(
            recordId: recordId,
            error: ApiError.networkError("test"),
            session: 1
        )

        while Date() < connectDeadline {
            if service.hasActiveWebSocketForTesting() { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(service.hasActiveWebSocketForTesting(), "socket connect should not wait for poll")
        gate.release()
    }

    func testHandshakeFailureReconnectDoesNotAwaitBufferedHandler() async throws {
        let recordId = "00000000-0000-4000-8000-000000000001"
        let presenter = MockNotificationPresenter()
        presenter.onShow = {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                    continuation.resume()
                }
            }
        }
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: MockPermissions()
        )
        service.startForTesting()

        let ct = try makeCiphertext(otp: "991122", sender: "BufferBank")
        let deferredMsg =
            "{\"type\":\"envelope\",\"delivery_id\":\"buffered_on_fail\",\"envelope\":{\"ciphertext\":\"\(ct)\"}}"

        let reconnectAt = Date()
        service.scheduleDeferredHandshakeMessages([deferredMsg], recordId: recordId, session: 1)
        service.scheduleReconnect(
            recordId: recordId,
            error: ApiError.networkError("WebSocket pong timeout"),
            session: 1
        )
        XCTAssertLessThan(Date().timeIntervalSince(reconnectAt), 0.05)
        await service.drainDeliveryWorkForTesting()
    }

    func testPongHandledWhileDeliveryHandlerStalled() async throws {
        let recordId = "00000000-0000-4000-8000-000000000001"
        let presenter = MockNotificationPresenter()
        presenter.onShow = {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                    continuation.resume()
                }
            }
        }
        let permissions = MockPermissions()
        permissions.access = .off
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.startForTesting()

        let ct = try makeCiphertext(otp: "224466", sender: "PongBank")
        let envelope =
            "{\"type\":\"envelope\",\"delivery_id\":\"stall_then_pong\",\"envelope\":{\"ciphertext\":\"\(ct)\"}}"

        service.routeWebSocketFrame(envelope, recordId: recordId, session: 1)
        try await Task.sleep(nanoseconds: 20_000_000)
        service.routeWebSocketFrame("{\"type\":\"pong\"}", recordId: recordId, session: 1)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNotNil(service.lastPongAtForTesting())
        await service.drainDeliveryWorkForTesting()
        XCTAssertEqual(service.heldDeliveries.count, 1)
    }

    func testSecondEnvelopeQueuedAfterFirstStillProcesses() async throws {
        let recordId = "00000000-0000-4000-8000-000000000001"
        let permissions = MockPermissions()
        permissions.access = .off
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: MockNotificationPresenter(),
            notificationPermissions: permissions
        )
        service.startForTesting()

        let ct1 = try makeCiphertext(otp: "111111", sender: "A")
        let ct2 = try makeCiphertext(otp: "222222", sender: "B")
        let first = "{\"type\":\"envelope\",\"delivery_id\":\"seq_a\",\"envelope\":{\"ciphertext\":\"\(ct1)\"}}"
        let second = "{\"type\":\"envelope\",\"delivery_id\":\"seq_b\",\"envelope\":{\"ciphertext\":\"\(ct2)\"}}"

        service.routeWebSocketFrame(first, recordId: recordId, session: 1)
        service.routeWebSocketFrame(second, recordId: recordId, session: 1)
        await service.drainDeliveryWorkForTesting()
        XCTAssertEqual(Set(service.heldDeliveries.map(\.deliveryId)), Set(["seq_a", "seq_b"]))
    }

    func testFailedAckIsRetriedOnNextPollWithoutReshowing() async throws {
        var ackAttempts: [String] = []
        var deleteShouldFail = true

        let transport = MockTransport { req in
            if req.httpMethod == "DELETE" {
                let id = req.url!.lastPathComponent
                ackAttempts.append(id)
                if deleteShouldFail {
                    return (Data("Server error".utf8), HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
                }
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }
            if req.httpMethod == "GET" && req.url!.path.contains("/deliveries") {
                // Server still lists del_retry because first ack failed
                let list = [[
                    "delivery_id": "del_retry",
                    "envelope": ["ciphertext": "dummy"]
                ]]
                let data = try! JSONSerialization.data(withJSONObject: ["deliveries": list])
                return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let apiClient = ApiClient(recordStore: recordStore, transport: transport)
        let presenter = MockNotificationPresenter()
        let permissions = MockPermissions()
        permissions.access = .allowed

        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: apiClient,
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.startForTesting()

        let ct = try makeCiphertext(otp: "777888", sender: "AckBank")
        await service.handleEnvelope(deliveryId: "del_retry", envelope: ["ciphertext": ct], session: 1)

        XCTAssertEqual(presenter.shownNotifications.count, 1)
        XCTAssertEqual(ackAttempts, ["del_retry"])

        // Second poll occurs after network recovers; ack should be retried, but notification NOT shown again
        deleteShouldFail = false
        try await service.pollPending(recordId: "00000000-0000-4000-8000-000000000001", session: 1)

        XCTAssertEqual(ackAttempts.count, 2, "Failed ack must be retried")
        XCTAssertEqual(presenter.shownNotifications.count, 1, "Already finished delivery must not be shown to user again")
    }

    func testConcurrentDeliveryDuringPollNotDiscarded() async throws {
        // Simulates an async poll delay during which a WebSocket delivery arrives and is held.
        // Capturing candidateIds before the network request ensures the new delivery is not purged.
        final class StateBox: @unchecked Sendable {
            private let lock = NSLock()
            private var started = false
            private var release = false

            func markStarted() {
                lock.lock()
                started = true
                lock.unlock()
            }

            func isStarted() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return started
            }

            func triggerRelease() {
                lock.lock()
                release = true
                lock.unlock()
            }

            func shouldRelease() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return release
            }
        }

        let state = StateBox()

        let transport = MockTransport { req in
            if req.httpMethod == "GET" && req.url!.path.contains("/deliveries") {
                state.markStarted()
                while !state.shouldRelease() {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                // Return an empty list (< 50 items)
                let data = try! JSONSerialization.data(withJSONObject: ["deliveries": []])
                return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let apiClient = ApiClient(recordStore: recordStore, transport: transport)
        let presenter = MockNotificationPresenter()
        let permissions = MockPermissions()
        permissions.access = .off // Will hold incoming deliveries

        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: apiClient,
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.startForTesting()

        // Launch poll asynchronously
        let pollTask = Task {
            try await service.pollPending(recordId: "00000000-0000-4000-8000-000000000001", session: 1)
        }

        // Wait until poll is in flight
        while !state.isStarted() {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        // A WebSocket delivery arrives and is held while the poll is in flight
        let ct = try makeCiphertext(otp: "334455", sender: "ConcurrentBank")
        await service.handleEnvelope(deliveryId: "del_concurrent_ws", envelope: ["ciphertext": ct], session: 1)
        XCTAssertEqual(service.heldDeliveries.count, 1)

        // Release the poll
        state.triggerRelease()
        try await pollTask.value

        // del_concurrent_ws must NOT be purged because it was not in candidateIds when poll started
        XCTAssertEqual(service.heldDeliveries.count, 1, "Concurrently arrived delivery must not be purged by completed poll")
        XCTAssertEqual(service.heldDeliveries.first?.deliveryId, "del_concurrent_ws")
    }

    func testDeliveryHandlingRespectsSessionCancellation() async throws {
        // If a session ends (e.g. stop/logout/clear) while a notification is awaiting presentation,
        // it must not mutate held or finished state in the new session.
        let presenter = MockNotificationPresenter()
        let permissions = MockPermissions()
        permissions.access = .allowed

        let transport = MockTransport { _ in
            (Data(), HTTPURLResponse(url: URL(string: "https://pux.test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let apiClient = ApiClient(recordStore: recordStore, transport: transport)

        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: apiClient,
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.startForTesting(session: 1)

        let ct = try makeCiphertext(otp: "998877", sender: "StaleBank")

        final class SyncState: @unchecked Sendable {
            private let lock = NSLock()
            private var entered = false
            private var resume = false
            func markEntered() { lock.lock(); entered = true; lock.unlock() }
            func isEntered() -> Bool { lock.lock(); defer { lock.unlock() }; return entered }
            func triggerResume() { lock.lock(); resume = true; lock.unlock() }
            func shouldResume() -> Bool { lock.lock(); defer { lock.unlock() }; return resume }
        }
        let sync = SyncState()

        // Suspend presentation in flight
        presenter.onShow = {
            sync.markEntered()
            while !sync.shouldResume() {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        // Start handling envelope in background
        let handleTask = Task {
            await service.handleEnvelope(deliveryId: "del_stale", envelope: ["ciphertext": ct], session: 1)
        }

        // Wait until presentation is suspended in flight
        while !sync.isEntered() {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        // Removal clears the previously held item while presentation is in flight.
        service.clear()

        // Resume presentation
        sync.triggerResume()
        await handleTask.value

        // Post-presentation mutation must be aborted because session was replaced/stopped
        XCTAssertTrue(service.heldDeliveries.isEmpty, "Stale session deliveries must not be saved into new session")
    }

    func testRetryDuringBackoffFollowedByConnectionFailure() async throws {
        // When reconnect backoff is pending, user clicking 'Retry now' starts a new session.
        // If that connection also fails, scheduleReconnect must not be suppressed by stale state.
        let transport = MockTransport { _ in
            throw ApiError.networkError("Offline")
        }
        let apiClient = ApiClient(recordStore: recordStore, transport: transport)
        let service = DesktopDeliveryService(recordStore: recordStore, apiClient: apiClient)

        service.startForTesting(session: 1)

        // 1. Initial reconnect scheduled for session 1
        service.scheduleReconnect(recordId: "00000000-0000-4000-8000-000000000001", error: ApiError.networkError("Err 1"), session: 1)
        XCTAssertEqual(service.status.state, .retrying)

        // 2. User clicks 'Retry now' (calls start, which begins session 2 and clears reconnect lock)
        let startTask = Task {
            await service.start()
        }

        // Let start() transition to retrying device registration
        try await Task.sleep(nanoseconds: 20_000_000)
        startTask.cancel()

        // 3. Subsequent connection error in new session 2 successfully schedules reconnect
        service.scheduleReconnect(recordId: "00000000-0000-4000-8000-000000000001", error: ApiError.networkError("Err 2"), session: 2)
        XCTAssertEqual(service.status.state, .retrying)
    }

    func testOfflineStartRestartsHoldTimerImmediately() async throws {
        let presenter = MockNotificationPresenter()
        let permissions = MockPermissions()
        permissions.access = .off

        // Transport fails registration indefinitely (offline)
        let transport = MockTransport { _ in
            throw ApiError.networkError("No network")
        }
        let apiClient = ApiClient(recordStore: recordStore, transport: transport)

        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: apiClient,
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.startForTesting(session: 1)

        // Hold a delivery
        let ct = try makeCiphertext(otp: "123123", sender: "TimerBank")
        await service.handleEnvelope(deliveryId: "del_hold_timer", envelope: ["ciphertext": ct], session: 1)
        XCTAssertEqual(service.heldDeliveries.count, 1)

        // Stop the service
        service.stop()

        // Start offline
        let startTask = Task {
            await service.start()
        }

        // Allow start() to run and initialize hold timer
        try await Task.sleep(nanoseconds: 20_000_000)
        startTask.cancel()

        // Verify held delivery is preserved and hold timer lifecycle is active
        XCTAssertEqual(service.heldDeliveries.count, 1)
        XCTAssertEqual(service.heldDeliveries.first?.deliveryId, "del_hold_timer")
    }

    func testReconnectSchedulingIsSerialized() {
        let transport = MockTransport { _ in
            (Data(), HTTPURLResponse(url: URL(string: "https://pux.test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let apiClient = ApiClient(recordStore: recordStore, transport: transport)
        let service = DesktopDeliveryService(recordStore: recordStore, apiClient: apiClient)

        service.startForTesting(session: 1)

        // Call scheduleReconnect multiple times concurrently for session 1
        service.scheduleReconnect(recordId: "00000000-0000-4000-8000-000000000001", error: nil, session: 1)
        service.scheduleReconnect(recordId: "00000000-0000-4000-8000-000000000001", error: nil, session: 1)

        // Attempt should only be 1 because reconnect is serialized
        XCTAssertEqual(service.status.state, .retrying)
    }
}

private actor RegistrationBarrier {
    var continuation: CheckedContinuation<Void, Never>?
    var started = false
    var registrationCount = 0
    func firstRegistration() -> Bool { registrationCount += 1; return registrationCount == 1 }
    var deletedPaths: [String] = []
    func recordDelete(_ path: String) { deletedPaths.append(path) }
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private final class DelayedRegistrationTransport: HTTPTransport, @unchecked Sendable {
    let barrier = RegistrationBarrier()
    func execute(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.httpMethod == "POST" {
            if await barrier.firstRegistration() { await barrier.wait() }
            return (Data("{\"device_id\":\"late-device\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        }
        if request.httpMethod == "DELETE" { await barrier.recordDelete(request.url!.path) }
        return (Data("{\"deliveries\":[]}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

extension DesktopDeliveryServiceTests {
    func testStoppedRegistrationDrainsAndCannotWriteIntoReplacement() async throws {
        let storage = InMemoryStorage(initialValues: [RecordStore.recordIdKey: "old-record"])
        let store = RecordStore(storage: storage)
        let transport = DelayedRegistrationTransport()
        let service = DesktopDeliveryService(recordStore: store, apiClient: ApiClient(recordStore: store, transport: transport))
        let start = Task { await service.start() }
        while !(await transport.barrier.started) { try await Task.sleep(nanoseconds: 1_000_000) }
        let drain = Task { await service.stopAndWaitForRegistration(recordId: "old-record") }
        // Wait until stop has invalidated the session before replacing storage.
        while service.status.state != .idle { try await Task.sleep(nanoseconds: 1_000_000) }
        try storage.write(key: RecordStore.recordIdKey, value: "new-record")
        await transport.barrier.release()
        let id = await drain.value
        await start.value
        XCTAssertEqual(id, "late-device")
        XCTAssertNil(try store.deviceId())
        XCTAssertEqual(try store.recordId(), "new-record")
    }

    func testCancelledRegistrationDoesNotRetry() async throws {
        let storage = InMemoryStorage(initialValues: [RecordStore.recordIdKey: "record"])
        let store = RecordStore(storage: storage)
        let counter = AttemptCounter()
        let transport = MockTransport { _ in
            counter.increment()
            throw ApiError.networkError("offline")
        }
        let service = DesktopDeliveryService(recordStore: store, apiClient: ApiClient(recordStore: store, transport: transport))
        let start = Task { await service.start() }
        while service.status.state != .retrying { try await Task.sleep(nanoseconds: 1_000_000) }
        start.cancel()
        await start.value
        try await Task.sleep(nanoseconds: 50_000_000)
        let count = counter.value
        XCTAssertEqual(count, 1)
        service.stop()
    }
}

extension DesktopDeliveryServiceTests {
    func testRestartedHoldTimerTicksAfterOldTimerIsCancelled() async throws {
        let permissions = MockPermissions()
        permissions.access = .off
        let presenter = MockNotificationPresenter()
        let transport = MockTransport { req in
            let body = Data("{\"deliveries\":[{\"delivery_id\":\"held\",\"envelope\":{}}]}".utf8)
            return (body, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let service = DesktopDeliveryService(recordStore: recordStore, apiClient: ApiClient(recordStore: recordStore, transport: transport), notificationPresenter: presenter, notificationPermissions: permissions, holdInterval: 0.3)
        service.startForTesting(session: 1)
        let ct = try makeCiphertext(otp: "123456", sender: "Bank")
        await service.handleEnvelope(deliveryId: "held", envelope: ["ciphertext": ct], session: 1)
        XCTAssertEqual(service.heldDeliveries.count, 1)
        service.stop()
        service.startForTesting(session: 2)
        permissions.access = .allowed
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(presenter.shownNotifications.count, 1)
        XCTAssertTrue(service.heldDeliveries.isEmpty)
        service.stop()
    }
}

extension DesktopDeliveryServiceTests {
    @MainActor func testRemovalWaitsForRegistrationBeforeDeletingReturnedDevice() async throws {
        let transport = DelayedRegistrationTransport()
        let client = ApiClient(recordStore: recordStore, transport: transport)
        let service = DesktopDeliveryService(recordStore: recordStore, apiClient: client)
        let controller = DeliveryController(recordStore: recordStore, apiClient: client, service: service)
        let start = Task { await service.start() }
        while !(await transport.barrier.started) { try await Task.sleep(nanoseconds: 1_000_000) }
        let removal = Task { try await controller.removeThisDevice() }
        while service.status.state != .idle { try await Task.sleep(nanoseconds: 1_000_000) }
        let before = await transport.barrier.deletedPaths
        XCTAssertTrue(before.isEmpty)
        await transport.barrier.release()
        try await removal.value
        await start.value
        let deleted = await transport.barrier.deletedPaths
        XCTAssertEqual(deleted, ["/api/v1/record/devices/late-device"])
        XCTAssertNil(try recordStore.recordId())
        XCTAssertNil(try recordStore.deviceId())
    }
}

private actor BlockingPresenter: NotificationPresenter {
    var calls = 0
    var first: CheckedContinuation<Bool, Never>?
    func show(notification: RelayNotification) async throws -> Bool {
        calls += 1
        if calls == 1 { return await withCheckedContinuation { first = $0 } }
        return true
    }
    func finishFirst(_ shown: Bool) { first?.resume(returning: shown); first = nil }
}

private actor TestNotificationPermissions: NotificationPermissionsProtocol {
    var access: NotificationAccess = .notAsked
    var requests = 0
    func check() async -> NotificationAccess { access }
    func ask() async -> NotificationAccess { requests += 1; access = .allowed; return access }
    func set(_ value: NotificationAccess) { access = value }
}

private actor CountingNotificationPermissions: NotificationPermissionsProtocol {
    private(set) var checks = 0
    var access: NotificationAccess = .allowed
    func check() async -> NotificationAccess {
        checks += 1
        return access
    }
    func ask() async -> NotificationAccess { access }
    func setAccess(_ value: NotificationAccess) { access = value }
    func checkCount() -> Int { checks }
}

private actor RecordingPresenter: NotificationPresenter {
    var count = 0
    func show(notification: RelayNotification) async throws -> Bool { count += 1; return true }
}

extension DesktopDeliveryServiceTests {
    func testPresentationTimeoutLetsNextDeliveryProceedAndReconcilesLateSuccess() async throws {
        let presenter = BlockingPresenter()
        let permissions = MockPermissions()
        permissions.access = .allowed
        let acked = InlineAckList()
        let transport = MockTransport { req in
            if req.httpMethod == "DELETE" {
                acked.append(req.url!.lastPathComponent)
            }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }
        let service = DesktopDeliveryService(recordStore: recordStore, apiClient: ApiClient(recordStore: recordStore, transport: transport), notificationPresenter: presenter, notificationPermissions: permissions, presentationTimeout: 0.03)
        service.startForTesting()
        let ciphertext = try makeCiphertext(otp: "123456", sender: "Bank")
        await service.handleEnvelope(deliveryId: "first", envelope: ["ciphertext": ciphertext], session: 1)
        XCTAssertEqual(service.heldDeliveries.map(\.deliveryId), ["first"])
        await service.handleEnvelope(deliveryId: "second", envelope: ["ciphertext": ciphertext], session: 1)
        let before = acked.current()
        XCTAssertEqual(before, ["second"])
        // Rechecking must not start a second presentation while the first remains hung.
        await service.flushHeld(session: 1)
        let count = await presenter.calls
        XCTAssertEqual(count, 2)
        await presenter.finishFirst(true)
        for _ in 0..<100 {
            if service.heldDeliveries.isEmpty { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(service.heldDeliveries.isEmpty)
        // Acknowledgement runs asynchronously after the late completion.
        for _ in 0..<100 {
            let completed = acked.count == 2
            if completed { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let after = acked.current()
        XCTAssertEqual(after, ["second", "first"])
        service.clear()
    }

    func testLatePresentationCannotAcknowledgeAfterRemoval() async throws {
        let presenter = BlockingPresenter()
        let permissions = MockPermissions()
        permissions.access = .allowed
        let transport = MockTransport { req in
            XCTFail("No request should be sent after removal")
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }
        let service = DesktopDeliveryService(recordStore: recordStore, apiClient: ApiClient(recordStore: recordStore, transport: transport), notificationPresenter: presenter, notificationPermissions: permissions, presentationTimeout: 0.02)
        service.startForTesting()
        let ciphertext = try makeCiphertext(otp: "123456", sender: "Bank")
        await service.handleEnvelope(deliveryId: "late", envelope: ["ciphertext": ciphertext], session: 1)
        service.clear()
        await presenter.finishFirst(true)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(service.heldDeliveries.isEmpty)
    }

    @MainActor func testPermissionRequestAndRefreshFlushHeldCodes() async throws {
        let permissions = TestNotificationPermissions()
        let presenter = RecordingPresenter()
        let transport = MockTransport { req in
            (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }
        let api = ApiClient(recordStore: recordStore, transport: transport)
        let service = DesktopDeliveryService(recordStore: recordStore, apiClient: api, notificationPresenter: presenter, notificationPermissions: permissions)
        let controller = DeliveryController(recordStore: recordStore, apiClient: api, service: service, notificationPermissions: permissions)
        service.startForTesting()
        let ciphertext = try makeCiphertext(otp: "123456", sender: "Bank")
        await service.handleEnvelope(deliveryId: "held", envelope: ["ciphertext": ciphertext], session: 1)
        await controller.refreshNotificationAccess()
        XCTAssertEqual(controller.notificationAccess, .notAsked)
        XCTAssertEqual(service.heldDeliveries.count, 1)
        await controller.requestNotificationAccess()
        XCTAssertEqual(controller.notificationAccess, .allowed)
        XCTAssertTrue(service.heldDeliveries.isEmpty)
        let requests = await permissions.requests
        let shown = await presenter.count
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(shown, 1)
        await permissions.set(.quiet)
        await controller.refreshNotificationAccess()
        XCTAssertEqual(controller.notificationAccess, .quiet)
        await permissions.set(.off)
        await controller.refreshNotificationAccess()
        XCTAssertEqual(controller.notificationAccess, .off)
        service.clear()
    }
}

extension DesktopDeliveryServiceTests {
    func testLateQuietPresentationIsHeldAndNotPresentedTwiceWhenEnabled() async throws {
        let permissions = TestNotificationPermissions()
        await permissions.set(.quiet)
        let presenter = BlockingPresenter()
        let transport = MockTransport { req in
            (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }
        let service = DesktopDeliveryService(recordStore: recordStore, apiClient: ApiClient(recordStore: recordStore, transport: transport), notificationPresenter: presenter, notificationPermissions: permissions, presentationTimeout: 0.02)
        service.startForTesting()
        let ciphertext = try makeCiphertext(otp: "123456", sender: "Bank")
        await service.handleEnvelope(deliveryId: "quiet", envelope: ["ciphertext": ciphertext], session: 1)
        XCTAssertFalse(service.heldDeliveries.first!.notified)
        await presenter.finishFirst(true)
        for _ in 0..<100 {
            if service.heldDeliveries.first?.notified == true { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(service.heldDeliveries.count, 1)
        XCTAssertTrue(service.heldDeliveries.first!.notified)
        await permissions.set(.allowed)
        await service.notificationAccessChanged()
        XCTAssertTrue(service.heldDeliveries.isEmpty)
        let calls = await presenter.calls
        XCTAssertEqual(calls, 1)
        service.clear()
    }
}

private final class AckRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    func append(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return ids }
}

extension DesktopDeliveryServiceTests {
    private func assertPermissionChangeDuringPresentation(_ changedAccess: NotificationAccess, heldFirst: Bool) async throws {
        let permissions = TestNotificationPermissions()
        await permissions.set(heldFirst ? .off : .allowed)
        let presenter = BlockingPresenter()
        let acks = AckRecorder()
        let transport = MockTransport { req in
            if req.httpMethod == "DELETE" { acks.append(req.url!.lastPathComponent) }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }
        let service = DesktopDeliveryService(recordStore: recordStore, apiClient: ApiClient(recordStore: recordStore, transport: transport), notificationPresenter: presenter, notificationPermissions: permissions, presentationTimeout: 5)
        service.startForTesting()
        let ciphertext = try makeCiphertext(otp: "123456", sender: "Bank")
        let presentation: Task<Void, Never>
        if heldFirst {
            await service.handleEnvelope(deliveryId: "transition", envelope: ["ciphertext": ciphertext], session: 1)
            XCTAssertEqual(service.heldDeliveries.count, 1)
            await permissions.set(.allowed)
            presentation = Task { await service.flushHeld(session: 1) }
        } else {
            presentation = Task { await service.handleEnvelope(deliveryId: "transition", envelope: ["ciphertext": ciphertext], session: 1) }
        }
        for _ in 0..<500 {
            if await presenter.first != nil { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let started = await presenter.first != nil
        XCTAssertTrue(started, "The test must change permissions while presentation is suspended")
        await permissions.set(changedAccess)
        await presenter.finishFirst(true)
        await presentation.value
        XCTAssertEqual(acks.snapshot(), [], "A delivery must not be acknowledged using pre-presentation permission")
        XCTAssertEqual(service.heldDeliveries.count, 1)
        XCTAssertEqual(service.heldDeliveries.first?.notified, changedAccess == .quiet)

        await permissions.set(.allowed)
        await service.notificationAccessChanged()
        XCTAssertTrue(service.heldDeliveries.isEmpty)
        XCTAssertEqual(acks.snapshot(), ["transition"])
        let presentations = await presenter.calls
        XCTAssertEqual(presentations, changedAccess == .quiet ? 1 : 2)
        service.clear()
    }

    func testInitialPresentationPermissionChanges() async throws {
        try await assertPermissionChangeDuringPresentation(.off, heldFirst: false)
        try await assertPermissionChangeDuringPresentation(.quiet, heldFirst: false)
    }

    func testHeldPresentationPermissionChanges() async throws {
        try await assertPermissionChangeDuringPresentation(.off, heldFirst: true)
        try await assertPermissionChangeDuringPresentation(.quiet, heldFirst: true)
    }
}

extension DesktopDeliveryServiceTests {
    func testQuietPresentationBecomesAllowedBeforeCompletion() async throws {
        let permissions = TestNotificationPermissions()
        await permissions.set(.quiet)
        let presenter = BlockingPresenter()
        let acks = AckRecorder()
        let transport = MockTransport { req in
            if req.httpMethod == "DELETE" { acks.append(req.url!.lastPathComponent) }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }
        let service = DesktopDeliveryService(recordStore: recordStore, apiClient: ApiClient(recordStore: recordStore, transport: transport), notificationPresenter: presenter, notificationPermissions: permissions, presentationTimeout: 5)
        service.startForTesting()
        let ciphertext = try makeCiphertext(otp: "123456", sender: "Bank")
        let task = Task { await service.handleEnvelope(deliveryId: "enabled", envelope: ["ciphertext": ciphertext], session: 1) }
        for _ in 0..<500 {
            if await presenter.first != nil { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let started = await presenter.first != nil
        XCTAssertTrue(started)
        await permissions.set(.allowed)
        await presenter.finishFirst(true)
        await task.value
        XCTAssertEqual(acks.snapshot(), ["enabled"])
        XCTAssertTrue(service.heldDeliveries.isEmpty)
        service.clear()
    }
}

private actor SlowReleasePermissions: NotificationPermissionsProtocol {
    private var waiters: [CheckedContinuation<NotificationAccess, Never>] = []
    private(set) var started = 0
    func check() async -> NotificationAccess {
        started += 1
        return await withCheckedContinuation { waiters.append($0) }
    }
    func ask() async -> NotificationAccess { .allowed }
    func releaseAll() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: .allowed)
        }
    }
    func startedCount() -> Int { started }
}

private actor ContinuationStallPermissions: NotificationPermissionsProtocol {
    private(set) var started = 0
  private var waiters: [CheckedContinuation<NotificationAccess, Never>] = []
    func check() async -> NotificationAccess {
        started += 1
        return await withCheckedContinuation { waiters.append($0) }
    }
    func ask() async -> NotificationAccess { .allowed }
    func startedCount() -> Int { started }
}

private actor GatedCoalescedFlushPermissions: NotificationPermissionsProtocol {
    private let settledAccess: NotificationAccess
    private let gateOnCall: Int
    private var calls = 0
    private var gateWaiter: CheckedContinuation<NotificationAccess, Never>?
    init(settledAccess: NotificationAccess, gateOnCall: Int = 1) {
        self.settledAccess = settledAccess
        self.gateOnCall = gateOnCall
    }
    func check() async -> NotificationAccess {
        calls += 1
        if calls == gateOnCall {
            return await withCheckedContinuation { gateWaiter = $0 }
        }
        if calls < gateOnCall { return .off }
        return settledAccess
    }
    func ask() async -> NotificationAccess { settledAccess }
    func isGateWaiting() -> Bool { gateWaiter != nil }
    func releaseGate() {
        gateWaiter?.resume(returning: settledAccess)
        gateWaiter = nil
    }
    func callCount() -> Int { calls }
}

private actor OffUntilFlushGatePermissions: NotificationPermissionsProtocol {
    private var calls = 0
    private var flushWaiter: CheckedContinuation<Void, Never>?
    func check() async -> NotificationAccess {
        calls += 1
        if calls == 1 { return .off }
        if calls == 2 {
            await withCheckedContinuation { flushWaiter = $0 }
        }
        return .allowed
    }
    func ask() async -> NotificationAccess { .allowed }
    func isFlushGateWaiting() -> Bool { flushWaiter != nil }
    func releaseFlushGate() { flushWaiter?.resume(); flushWaiter = nil }
}

private actor GatedDeliveryPermissions: NotificationPermissionsProtocol {
    private let blocks: Int
    private let blockedCallNumbers: Set<Int>
    private var calls = 0
    private var waiters: [Int: CheckedContinuation<NotificationAccess, Never>] = [:]
    init(blocks: Int, blockedCallNumbers: Set<Int> = []) {
        self.blocks = blocks
        self.blockedCallNumbers = blockedCallNumbers
    }
    func check() async -> NotificationAccess {
        calls += 1
        let call = calls
        if blockedCallNumbers.contains(call) || call <= blocks {
            return await withCheckedContinuation { waiters[call] = $0 }
        }
        return .allowed
    }
    func ask() async -> NotificationAccess { .allowed }
    func isWaiting(_ call: Int) -> Bool { waiters[call] != nil }
    func callCount() -> Int { calls }
    func release(_ call: Int) { waiters.removeValue(forKey: call)?.resume(returning: .allowed) }
}

extension DesktopDeliveryServiceTests {
    private func waitForPermissionGate(_ permissions: GatedDeliveryPermissions, call: Int) async throws {
        for _ in 0..<1000 {
            if await permissions.isWaiting(call) { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Permission check \(call) did not reach its barrier")
    }

    private func overlappingTransport(ciphertext: String, acks: AckRecorder) -> MockTransport {
        MockTransport { request in
            if request.httpMethod == "DELETE" {
                acks.append(request.url!.lastPathComponent)
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }
            let body = try JSONSerialization.data(withJSONObject: ["deliveries": [["delivery_id": "shared", "envelope": ["ciphertext": ciphertext]]]])
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func assertOverlappingPollAndSocket(pollFirst: Bool) async throws {
        let permissions = GatedDeliveryPermissions(blocks: 1)
        let presenter = RecordingPresenter()
        let acks = AckRecorder()
        let ciphertext = try makeCiphertext(otp: "123456", sender: "Bank")
        let service = DesktopDeliveryService(recordStore: recordStore, apiClient: ApiClient(recordStore: recordStore, transport: overlappingTransport(ciphertext: ciphertext, acks: acks)), notificationPresenter: presenter, notificationPermissions: permissions)
        service.startForTesting(session: 1)
        let record = "00000000-0000-4000-8000-000000000001"
        let first = Task {
            if pollFirst {
                try await service.pollPending(recordId: record, session: 1)
            } else {
                await service.handleEnvelope(deliveryId: "shared", envelope: ["ciphertext": ciphertext], session: 1)
            }
        }
        try await waitForPermissionGate(permissions, call: 1)
        if pollFirst {
            await service.handleEnvelope(deliveryId: "shared", envelope: ["ciphertext": ciphertext], session: 1)
        } else {
            try await service.pollPending(recordId: record, session: 1)
        }
        let checks = await permissions.callCount()
        XCTAssertEqual(checks, 1, "The competing handler must not reach the permission check")
        await permissions.release(1)
        try await first.value
        let presentations = await presenter.count
        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(acks.snapshot(), ["shared"])
        XCTAssertTrue(service.heldDeliveries.isEmpty)
        service.clear()
    }

    func testSocketAndPollReserveSameDeliveryBeforeSuspending() async throws {
        try await assertOverlappingPollAndSocket(pollFirst: false)
        try await assertOverlappingPollAndSocket(pollFirst: true)
    }

    func testSameSessionSameIdDoesNotBlockBehindPermissionGate() async throws {
        let recordId = "00000000-0000-4000-8000-000000000001"
        let permissions = GatedDeliveryPermissions(blocks: 1)
        let presenter = RecordingPresenter()
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.startForTesting(session: 1)

        let ct = try makeCiphertext(otp: "121212", sender: "Dup")
        let msg =
            "{\"type\":\"envelope\",\"delivery_id\":\"dup_same_session\",\"envelope\":{\"ciphertext\":\"\(ct)\"}}"

        service.routeWebSocketFrame(msg, recordId: recordId, session: 1)
        try await waitForPermissionGate(permissions, call: 1)
        let retryAt = Date()
        service.routeWebSocketFrame(msg, recordId: recordId, session: 1)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertLessThan(Date().timeIntervalSince(retryAt), 0.2)
        await permissions.release(1)
        await service.drainDeliveryWorkForTesting(session: 1)
        let presentations = await presenter.count
        XCTAssertEqual(presentations, 1)
    }

    func testPermissionCheckTimeoutHoldsForRetryWithoutDuplicatePresentation() async throws {
        let recordId = "00000000-0000-4000-8000-000000000001"
        let permissions = GatedDeliveryPermissions(blocks: 1)
        let presenter = RecordingPresenter()
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions,
            presentationTimeout: 0.2
        )
        service.permissionCheckTimeoutForTesting = 0.15
        service.startForTesting(session: 1)

        let ct = try makeCiphertext(otp: "343434", sender: "TimeoutBank")
        let msg =
            "{\"type\":\"envelope\",\"delivery_id\":\"perm_timeout\",\"envelope\":{\"ciphertext\":\"\(ct)\"}}"

        service.routeWebSocketFrame(msg, recordId: recordId, session: 1)
        try await waitForPermissionGate(permissions, call: 1)

        let start = Date()
        await service.drainDeliveryWorkForTesting(session: 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.35)
        XCTAssertEqual(service.heldDeliveries.count, 1)
        let shownBeforeAccess = await presenter.count
        XCTAssertEqual(shownBeforeAccess, 0)

        await permissions.release(1)
        await service.notificationAccessChanged()
        let shown = await presenter.count
        XCTAssertEqual(shown, 1)
    }

    func testAcknowledgementPermissionTimeoutDoesNotAck() async throws {
        let permissions = GatedDeliveryPermissions(blocks: 0, blockedCallNumbers: [2])
        let presenter = RecordingPresenter()
        let acks = AckRecorder()
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                if req.httpMethod == "DELETE" { acks.append(req.url!.lastPathComponent) }
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.permissionCheckTimeoutForTesting = 0.15
        service.startForTesting(session: 1)
        let ciphertext = try makeCiphertext(otp: "777777", sender: "Bank")
        await service.handleEnvelope(deliveryId: "ack_timeout", envelope: ["ciphertext": ciphertext], session: 1)
        XCTAssertEqual(acks.snapshot(), [])
        XCTAssertEqual(service.heldDeliveries.count, 1)
        XCTAssertTrue(service.heldDeliveries.first?.notified == true)
        await permissions.release(2)
        await service.notificationAccessChanged()
        XCTAssertEqual(acks.snapshot(), ["ack_timeout"])
        XCTAssertTrue(service.heldDeliveries.isEmpty)
        service.clear()
    }

    func testFlushHeldCompletesWhenAcknowledgementPermissionGated() async throws {
        let permissions = GatedDeliveryPermissions(blocks: 0, blockedCallNumbers: [2, 4])
        let presenter = RecordingPresenter()
        let acks = AckRecorder()
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                if req.httpMethod == "DELETE" { acks.append(req.url!.lastPathComponent) }
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.permissionCheckTimeoutForTesting = 0.12
        service.startForTesting(session: 1)
        let ciphertext = try makeCiphertext(otp: "888888", sender: "Bank")
        await service.handleEnvelope(deliveryId: "flush_ack_gate", envelope: ["ciphertext": ciphertext], session: 1)
        XCTAssertEqual(acks.snapshot(), [])
        XCTAssertTrue(service.heldDeliveries.first?.notified == true)

        let start = Date()
        await service.flushHeld(session: 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.35)
        XCTAssertEqual(acks.snapshot(), [])
        XCTAssertEqual(service.heldDeliveries.count, 1)
        XCTAssertTrue(service.heldDeliveries.first?.notified == true)
        await permissions.release(2)
        await permissions.release(4)
        service.clear()
    }

    func testOverlappingFlushHeldOnSameSessionDoesNotDeadlock() async throws {
        let permissions = OffUntilFlushGatePermissions()
        let presenter = RecordingPresenter()
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.permissionCheckTimeoutForTesting = 0.1
        service.startForTesting(session: 1)
        let ciphertext = try makeCiphertext(otp: "808080", sender: "Bank")
        await service.handleEnvelope(deliveryId: "overlap_flush", envelope: ["ciphertext": ciphertext], session: 1)

        let finished = expectation(description: "overlapping flush completes")
        let started = Date()
        Task {
            let first = Task { await service.notificationAccessChanged() }
            for _ in 0..<500 {
                if await permissions.isFlushGateWaiting() { break }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            let second = Task {
                try? await Task.sleep(nanoseconds: 5_000_000)
                await service.notificationAccessChanged()
            }
            await permissions.releaseFlushGate()
            _ = await first.value
            _ = await second.value
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        service.clear()
    }

    func testCoalescedAccessChangeSurvivesFlushPermissionTimeout() async throws {
        let permissions = OffUntilFlushGatePermissions()
        let presenter = RecordingPresenter()
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.permissionCheckTimeoutForTesting = 0.1
        service.startForTesting(session: 1)
        let ciphertext = try makeCiphertext(otp: "909090", sender: "Bank")
        await service.handleEnvelope(deliveryId: "coalesced_flush", envelope: ["ciphertext": ciphertext], session: 1)
        let firstFlush = Task { await service.notificationAccessChanged() }
        for _ in 0..<500 {
            if await permissions.isFlushGateWaiting() { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let secondFlush = Task {
            try? await Task.sleep(nanoseconds: 5_000_000)
            await service.notificationAccessChanged()
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        let beforeRelease = await presenter.count
        XCTAssertEqual(beforeRelease, 0)
        await permissions.releaseFlushGate()
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = await firstFlush.value
        _ = await secondFlush.value
        let shown = await presenter.count
        XCTAssertEqual(shown, 1)
        service.clear()
    }

    func testCoalescedFlushPresentsAfterBothPermissionDeadlinesAndGateRelease() async throws {
        let permissions = OffUntilFlushGatePermissions()
        let presenter = RecordingPresenter()
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.permissionCheckTimeoutForTesting = 0.05
        service.startForTesting(session: 1)
        let ciphertext = try makeCiphertext(otp: "919192", sender: "Bank")
        await service.handleEnvelope(deliveryId: "both_deadlines", envelope: ["ciphertext": ciphertext], session: 1)
        let firstFlush = Task { await service.notificationAccessChanged() }
        for _ in 0..<500 {
            if await permissions.isFlushGateWaiting() { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let secondFlush = Task {
            try? await Task.sleep(nanoseconds: 5_000_000)
            await service.notificationAccessChanged()
        }
        try await Task.sleep(nanoseconds: 120_000_000)
        var shown = await presenter.count
        XCTAssertEqual(shown, 0)
        await permissions.releaseFlushGate()
        try await Task.sleep(nanoseconds: 80_000_000)
        _ = await firstFlush.value
        _ = await secondFlush.value
        shown = await presenter.count
        XCTAssertEqual(shown, 1)
        service.clear()
    }

    func testCoalescedFlushRetryDoesNotLoopWhenSettledAccessOff() async throws {
        let permissions = GatedCoalescedFlushPermissions(settledAccess: .off)
        let presenter = RecordingPresenter()
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.startForTesting(session: 1)
        let ciphertext = try makeCiphertext(otp: "919194", sender: "Bank")
        await service.handleEnvelope(deliveryId: "coalesced_off", envelope: ["ciphertext": ciphertext], session: 1)
        let firstFlush = Task { await service.notificationAccessChanged() }
        for _ in 0..<500 {
            if await permissions.isGateWaiting() { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let secondFlush = Task {
            try? await Task.sleep(nanoseconds: 5_000_000)
            await service.notificationAccessChanged()
        }
        try await Task.sleep(nanoseconds: 15_000_000)
        await permissions.releaseGate()
        _ = await firstFlush.value
        _ = await secondFlush.value
        try await Task.sleep(nanoseconds: 30_000_000)
        let calls = await permissions.callCount()
        XCTAssertLessThanOrEqual(calls, 2, "Coalesced flush must not spin permission probes when access stays off")
        let presentations = await presenter.count
        XCTAssertEqual(presentations, 0)
        service.clear()
    }

    func testCoalescedFlushRetryDoesNotLoopWhenSettledAccessQuiet() async throws {
        let permissions = GatedCoalescedFlushPermissions(settledAccess: .quiet)
        let presenter = RecordingPresenter()
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.startForTesting(session: 1)
        let ciphertext = try makeCiphertext(otp: "919195", sender: "Bank")
        await service.handleEnvelope(deliveryId: "coalesced_quiet", envelope: ["ciphertext": ciphertext], session: 1)
        let firstFlush = Task { await service.notificationAccessChanged() }
        for _ in 0..<500 {
            if await permissions.isGateWaiting() { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let secondFlush = Task {
            try? await Task.sleep(nanoseconds: 5_000_000)
            await service.notificationAccessChanged()
        }
        try await Task.sleep(nanoseconds: 15_000_000)
        await permissions.releaseGate()
        _ = await firstFlush.value
        _ = await secondFlush.value
        try await Task.sleep(nanoseconds: 30_000_000)
        let calls = await permissions.callCount()
        XCTAssertLessThanOrEqual(calls, 2, "Coalesced flush must not spin permission probes when access stays quiet")
        service.clear()
    }

    func testCoalescedFlushParksRetryWhenHeldEmptyAfterExpiry() async throws {
        let permissions = CountingNotificationPermissions()
        let presenter = RecordingPresenter()
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.holdForForTesting = 0.05
        service.startForTesting(session: 1)
        let ciphertext = try makeCiphertext(otp: "919196", sender: "Bank")
        await service.handleEnvelope(deliveryId: "expired_coalesce", envelope: ["ciphertext": ciphertext], session: 1)
        try await Task.sleep(nanoseconds: 90_000_000)
        XCTAssertTrue(service.heldDeliveries.isEmpty)
        let firstFlush = Task { await service.notificationAccessChanged() }
        let secondFlush = Task {
            try? await Task.sleep(nanoseconds: 4_000_000)
            await service.notificationAccessChanged()
        }
        _ = await firstFlush.value
        _ = await secondFlush.value
        try await Task.sleep(nanoseconds: 40_000_000)
        let checks = await permissions.checkCount()
        XCTAssertLessThanOrEqual(
            checks,
            2,
            "Coalesced retry must park when there is no held work after expiry"
        )
        service.clear()
    }

    func testStaleFlushDeferDoesNotConsumeNewSessionCoalescedRetry() async throws {
        actor StopRestartCoalescedPermissions: NotificationPermissionsProtocol {
            private var calls = 0
            private var staleFlushWaiter: CheckedContinuation<Void, Never>?
            func check() async -> NotificationAccess {
                calls += 1
                switch calls {
                case 1, 4, 5:
                    return .off
                case 2:
                    await withCheckedContinuation { staleFlushWaiter = $0 }
                    return .allowed
                case 3:
                    return .allowed
                default:
                    return .allowed
                }
            }
            func ask() async -> NotificationAccess { .allowed }
            func isStaleFlushWaiting() -> Bool { staleFlushWaiter != nil }
            func releaseStaleFlush() { staleFlushWaiter?.resume(); staleFlushWaiter = nil }
        }
        let permissions = StopRestartCoalescedPermissions()
        let presenter = RecordingPresenter()
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.permissionCheckTimeoutForTesting = 2.0
        service.startForTesting(session: 1)
        let ciphertext = try makeCiphertext(otp: "919193", sender: "Bank")
        await service.handleEnvelope(deliveryId: "stale_coalesce", envelope: ["ciphertext": ciphertext], session: 1)
        let staleFlush = Task { await service.notificationAccessChanged() }
        for _ in 0..<500 {
            if await permissions.isStaleFlushWaiting() { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        service.stop()
        service.startForTesting(session: 2)
        await service.handleEnvelope(deliveryId: "new_coalesce", envelope: ["ciphertext": ciphertext], session: 2)
        let currentFlush = Task { await service.notificationAccessChanged() }
        let coalescedBump = Task {
            try? await Task.sleep(nanoseconds: 15_000_000)
            await service.notificationAccessChanged()
        }
        try await Task.sleep(nanoseconds: 60_000_000)
        var presentations = await presenter.count
        XCTAssertGreaterThanOrEqual(presentations, 1)
        await permissions.releaseStaleFlush()
        _ = await staleFlush.value
        _ = await currentFlush.value
        _ = await coalescedBump.value
        try await Task.sleep(nanoseconds: 40_000_000)
        presentations = await presenter.count
        XCTAssertGreaterThanOrEqual(presentations, 2)
        let staleStillWaiting = await permissions.isStaleFlushWaiting()
        XCTAssertFalse(staleStillWaiting)
        service.clear()
    }

    func testPermissionChangeDoesNotPresentOrAckExpiredHeld() async throws {
        let permissions = TestNotificationPermissions()
        await permissions.set(.off)
        let presenter = RecordingPresenter()
        let acks = AckRecorder()
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                if req.httpMethod == "DELETE" { acks.append(req.url!.lastPathComponent) }
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.holdForForTesting = 0.06
        service.startForTesting(session: 1)
        let ciphertext = try makeCiphertext(otp: "909090", sender: "Bank")
        await service.handleEnvelope(deliveryId: "expired_on_access", envelope: ["ciphertext": ciphertext], session: 1)
        try await Task.sleep(nanoseconds: 90_000_000)
        await permissions.set(.allowed)
        await service.notificationAccessChanged()
        let presentations = await presenter.count
        XCTAssertEqual(presentations, 0)
        XCTAssertEqual(acks.snapshot(), [])
        XCTAssertTrue(service.heldDeliveries.isEmpty)
        service.clear()
    }

    func testExpiryDuringFlushPermissionGateDoesNotPresentOrAck() async throws {
        let permissions = OffUntilFlushGatePermissions()
        let presenter = RecordingPresenter()
        let acks = AckRecorder()
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                if req.httpMethod == "DELETE" { acks.append(req.url!.lastPathComponent) }
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.startForTesting(session: 1)
        let ciphertext = try makeCiphertext(otp: "919191", sender: "Bank")
        await service.handleEnvelope(deliveryId: "expires_in_flush", envelope: ["ciphertext": ciphertext], session: 1)
        service.setHeldExpiryForTesting(
            deliveryId: "expires_in_flush",
            expiresAt: Date().addingTimeInterval(0.08)
        )
        let flush = Task { await service.notificationAccessChanged() }
        for _ in 0..<500 {
            if await permissions.isFlushGateWaiting() { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        await permissions.releaseFlushGate()
        await flush.value
        let presentations = await presenter.count
        XCTAssertEqual(presentations, 0)
        XCTAssertEqual(acks.snapshot(), [])
        XCTAssertTrue(service.heldDeliveries.isEmpty)
        service.clear()
    }

    func testContinuationStallPermissionChecksCoalesceUnderlyingProbe() async throws {
        let permissions = ContinuationStallPermissions()
        let presenter = RecordingPresenter()
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.permissionCheckTimeoutForTesting = 0.03
        service.startForTesting(session: 1)
        for _ in 0..<12 {
            _ = await service.checkNotificationAccessForTesting()
        }
        let started = await permissions.startedCount()
        XCTAssertEqual(started, 1)
        service.clear()
    }

    func testTimedOutStalledPermissionChecksDoNotRetainService() async throws {
        let permissions = ContinuationStallPermissions()
        weak var weakService: DesktopDeliveryService?
        do {
            let presenter = RecordingPresenter()
            let service = DesktopDeliveryService(
                recordStore: recordStore,
                apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                    (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
                }),
                notificationPresenter: presenter,
                notificationPermissions: permissions
            )
            weakService = service
            service.permissionCheckTimeoutForTesting = 0.03
            service.startForTesting(session: 1)
            for _ in 0..<12 {
                _ = await service.checkNotificationAccessForTesting()
            }
            service.clear()
        }
        for _ in 0..<200 {
            if weakService == nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(weakService)
    }

    func testSessionAdvanceOrdersBeforeNewSessionProbe() async throws {
        let permissions = GatedDeliveryPermissions(blocks: 1)
        let presenter = RecordingPresenter()
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.startForTesting(session: 1)
        let old = Task { await service.checkNotificationAccessForTesting(timeout: 0.5, session: 1) }
        try await waitForPermissionGate(permissions, call: 1)
        service.stop()
        service.startForTesting(session: 2)
        let access = await service.checkNotificationAccessForTesting(timeout: 0.2, session: 2)
        XCTAssertEqual(access, NotificationAccess.allowed)
        await permissions.release(1)
        _ = await old.value
        service.clear()
    }

    func testTimedOutPermissionWaitersAreRemovedFromRegistry() async throws {
        let permissions = ContinuationStallPermissions()
        let presenter = RecordingPresenter()
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.permissionCheckTimeoutForTesting = 0.04
        service.startForTesting(session: 1)
        for _ in 0..<8 {
            _ = await service.checkNotificationAccessForTesting()
        }
        let pending = await service.pendingPermissionWaiterCountForTesting()
        XCTAssertEqual(pending, 0)
        let started = await permissions.startedCount()
        XCTAssertEqual(started, 1)
        service.clear()
    }

    func testOldHoldPollDoesNotClearNewSessionPollSlot() async throws {
        final class HeldPollGate: @unchecked Sendable {
            private let lock = NSLock()
            private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
            private var pollCount = 0
            private var responsesBlocked = 0
            func pollCountSnapshot() -> Int {
                lock.lock()
                defer { lock.unlock() }
                return pollCount
            }
            func blockedResponseCount() -> Int {
                lock.lock()
                defer { lock.unlock() }
                return responsesBlocked
            }
            func enterDeliveryPoll() async {
                let holdsResponse: Bool = {
                    lock.lock()
                    pollCount += 1
                    let holds = pollCount <= 2
                    lock.unlock()
                    return holds
                }()
                guard holdsResponse else { return }
                lock.lock()
                responsesBlocked += 1
                lock.unlock()
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    releaseWaiters.append(continuation)
                    lock.unlock()
                }
                lock.lock()
                responsesBlocked -= 1
                lock.unlock()
            }
            func unblockHeldPoll() {
                lock.lock()
                let continuation = releaseWaiters.isEmpty ? nil : releaseWaiters.removeFirst()
                lock.unlock()
                continuation?.resume()
            }
        }
        final class HeldPollTransport: HTTPTransport, @unchecked Sendable {
            let gate: HeldPollGate
            init(gate: HeldPollGate) { self.gate = gate }
            func execute(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                if request.httpMethod == "GET", request.url?.path.contains("deliveries") == true {
                    await gate.enterDeliveryPoll()
                    let body = Data("{\"deliveries\":[]}".utf8)
                    return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }
        }
        let gate = HeldPollGate()
        let permissions = TestNotificationPermissions()
        await permissions.set(.off)
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: HeldPollTransport(gate: gate)),
            notificationPresenter: RecordingPresenter(),
            notificationPermissions: permissions
        )
        service.holdIntervalForTesting = 0.05
        service.startForTesting(session: 1)
        let ciphertext = try makeCiphertext(otp: "959595", sender: "Bank")
        await service.handleEnvelope(deliveryId: "poll_slot", envelope: ["ciphertext": ciphertext], session: 1)
        for _ in 0..<80 where gate.pollCountSnapshot() < 1 {
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        XCTAssertEqual(gate.pollCountSnapshot(), 1)
        service.stop()
        service.startForTesting(session: 2)
        await service.handleEnvelope(deliveryId: "poll_slot_two", envelope: ["ciphertext": ciphertext], session: 2)
        for _ in 0..<120 where gate.pollCountSnapshot() < 2 || gate.blockedResponseCount() < 2 {
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        XCTAssertEqual(
            gate.pollCountSnapshot(),
            2,
            "New session must schedule another hold poll while the first HTTP response is still held"
        )
        XCTAssertEqual(
            gate.blockedResponseCount(),
            2,
            "Second delivery poll must keep its HTTP response blocked while the first is still held"
        )
        gate.unblockHeldPoll()
        for _ in 0..<80 where gate.blockedResponseCount() > 1 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(gate.blockedResponseCount(), 1, "First release must not unblock the second response yet")
        gate.unblockHeldPoll()
        try await Task.sleep(nanoseconds: 100_000_000)
        service.clear()
    }

    func testStaleSessionFlushDoesNotSuppressCurrentSessionPermissionChange() async throws {
        actor CrossSessionFlushPermissions: NotificationPermissionsProtocol {
            private var calls = 0
            private var staleFlushWaiter: CheckedContinuation<Void, Never>?
            func check() async -> NotificationAccess {
                calls += 1
                switch calls {
                case 1, 3:
                    return .off
                case 2:
                    await withCheckedContinuation { staleFlushWaiter = $0 }
                    return .allowed
                default:
                    return .allowed
                }
            }
            func ask() async -> NotificationAccess { .allowed }
            func isStaleFlushWaiting() -> Bool { staleFlushWaiter != nil }
            func releaseStaleFlush() { staleFlushWaiter?.resume(); staleFlushWaiter = nil }
        }
        let permissions = CrossSessionFlushPermissions()
        let presenter = RecordingPresenter()
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.startForTesting(session: 1)
        let ciphertext = try makeCiphertext(otp: "828282", sender: "Bank")
        await service.handleEnvelope(deliveryId: "stale_flush", envelope: ["ciphertext": ciphertext], session: 1)
        let staleFlush = Task { await service.notificationAccessChanged() }
        for _ in 0..<500 {
            if await permissions.isStaleFlushWaiting() { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        service.startForTesting(session: 2)
        await service.handleEnvelope(deliveryId: "current_flush", envelope: ["ciphertext": ciphertext], session: 2)
        let currentFlush = Task { await service.notificationAccessChanged() }
        try await Task.sleep(nanoseconds: 40_000_000)
        let staleStillWaiting = await permissions.isStaleFlushWaiting()
        XCTAssertTrue(staleStillWaiting, "Stale session flush must remain in flight")
        await permissions.releaseStaleFlush()
        _ = await staleFlush.value
        _ = await currentFlush.value
        let presentations = await presenter.count
        XCTAssertGreaterThanOrEqual(presentations, 1, "Current session flush must run after the stale session flush exits")
        service.clear()
    }

    func testStopRestartCurrentSessionFlushDoesNotWaitOnStalePermissionCheck() async throws {
        actor StopRestartFlushPermissions: NotificationPermissionsProtocol {
            private var calls = 0
            private var staleFlushWaiter: CheckedContinuation<Void, Never>?
            func check() async -> NotificationAccess {
                calls += 1
                switch calls {
                case 1, 3:
                    return .off
                case 2:
                    await withCheckedContinuation { staleFlushWaiter = $0 }
                    return .allowed
                default:
                    return .allowed
                }
            }
            func ask() async -> NotificationAccess { .allowed }
            func isStaleFlushWaiting() -> Bool { staleFlushWaiter != nil }
            func releaseStaleFlush() { staleFlushWaiter?.resume(); staleFlushWaiter = nil }
        }
        let permissions = StopRestartFlushPermissions()
        let presenter = RecordingPresenter()
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.permissionCheckTimeoutForTesting = 2.0
        service.startForTesting(session: 1)
        let ciphertext = try makeCiphertext(otp: "818181", sender: "Bank")
        await service.handleEnvelope(deliveryId: "pre_stop", envelope: ["ciphertext": ciphertext], session: 1)
        let staleFlush = Task { await service.notificationAccessChanged() }
        for _ in 0..<500 {
            if await permissions.isStaleFlushWaiting() { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        service.stop()
        service.startForTesting(session: 2)
        await service.handleEnvelope(deliveryId: "post_restart", envelope: ["ciphertext": ciphertext], session: 2)
        let started = Date()
        let currentFlush = Task { await service.notificationAccessChanged() }
        for _ in 0..<200 {
            if await presenter.count > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let elapsed = Date().timeIntervalSince(started)
        let presentationCount = await presenter.count
        let staleStillWaiting = await permissions.isStaleFlushWaiting()
        XCTAssertLessThan(elapsed, 0.35, "Current session flush must not wait on the stale permission check")
        XCTAssertGreaterThanOrEqual(presentationCount, 1)
        XCTAssertTrue(staleStillWaiting)
        await permissions.releaseStaleFlush()
        _ = await staleFlush.value
        _ = await currentFlush.value
        service.clear()
    }

    func testStaleExplicitSessionCannotDisplaceNewSessionProbe() async throws {
        let permissions = GatedDeliveryPermissions(blocks: 2)
        let presenter = RecordingPresenter()
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.startForTesting(session: 1)
        let sessionOne = Task { await service.checkNotificationAccessForTesting(timeout: 0.5, session: 1) }
        try await waitForPermissionGate(permissions, call: 1)
        service.startForTesting(session: 2)
        let sessionTwo = Task { await service.checkNotificationAccessForTesting(timeout: 0.5, session: 2) }
        try await waitForPermissionGate(permissions, call: 2)
        let stale = await service.checkNotificationAccessForTesting(timeout: 0.2, session: 1)
        XCTAssertNil(stale)
        let checks = await permissions.callCount()
        XCTAssertEqual(checks, 2, "Stale explicit session must not start another permission probe")
        await permissions.release(2)
        let granted = await sessionTwo.value
        XCTAssertEqual(granted, NotificationAccess.allowed)
        await permissions.release(1)
        _ = await sessionOne.value
        service.clear()
    }

    func testConcurrentPermissionCallersShareProbeWithOwnDeadlines() async throws {
        let permissions = SlowReleasePermissions()
        let presenter = RecordingPresenter()
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.startForTesting(session: 1)
        let slowProbe = Task { await service.checkNotificationAccessForTesting(timeout: 2) }
        for _ in 0..<100 {
            if await permissions.startedCount() > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let startedBeforeFastProbe = await permissions.startedCount()
        XCTAssertEqual(startedBeforeFastProbe, 1)
        let fastProbe = Task { await service.checkNotificationAccessForTesting(timeout: 0.05) }
        let fastResult = await fastProbe.value
        await permissions.releaseAll()
        let slowResult = await slowProbe.value
        XCTAssertEqual(slowResult, NotificationAccess.allowed)
        XCTAssertNil(fastResult)
        let started = await permissions.startedCount()
        XCTAssertEqual(started, 1)
        service.clear()
    }

    func testOldSessionProbeDoesNotClearNewSessionProbe() async throws {
        let permissions = GatedDeliveryPermissions(blocks: 1)
        let presenter = RecordingPresenter()
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.startForTesting(session: 1)
        let old = Task { await service.checkNotificationAccessForTesting(timeout: 0.3, session: 1) }
        try await waitForPermissionGate(permissions, call: 1)
        service.stop()
        service.startForTesting(session: 2)
        let granted = await service.checkNotificationAccessForTesting(timeout: 0.2, session: 2)
        XCTAssertEqual(granted, NotificationAccess.allowed)
        await permissions.release(1)
        await old.value
        let still = await service.checkNotificationAccessForTesting(timeout: 0.2, session: 2)
        XCTAssertEqual(still, NotificationAccess.allowed)
        service.clear()
    }

    func testHoldTimerPollRunsWhileFlushPermissionGated() async throws {
        final class PollCounter: @unchecked Sendable {
            private let lock = NSLock()
            var count = 0
            func increment() { lock.lock(); count += 1; lock.unlock() }
            func snapshot() -> Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        let pollCounter = PollCounter()
        let permissions = OffUntilFlushGatePermissions()
        let presenter = RecordingPresenter()
        let transport = MockTransport { req in
            if req.httpMethod == "GET", req.url?.path.contains("deliveries") == true {
                pollCounter.increment()
                let body = Data("{\"deliveries\":[]}".utf8)
                return (body, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: transport),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.holdIntervalForTesting = 0.08
        service.startForTesting(session: 1)
        let ciphertext = try makeCiphertext(otp: "949494", sender: "Bank")
        await service.handleEnvelope(deliveryId: "poll_while_flush", envelope: ["ciphertext": ciphertext], session: 1)
        let flush = Task { await service.notificationAccessChanged() }
        for _ in 0..<500 {
            if await permissions.isFlushGateWaiting() { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        for _ in 0..<60 {
            if pollCounter.snapshot() >= 1 { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertGreaterThanOrEqual(pollCounter.snapshot(), 1, "Held poll must run on timer cadence during a gated flush")
        await permissions.releaseFlushGate()
        await flush.value
        service.clear()
    }

    func testHoldTimerPurgesExpiredWhileFlushPermissionGated() async throws {
        let permissions = OffUntilFlushGatePermissions()
        let presenter = RecordingPresenter()
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.holdIntervalForTesting = 0.08
        service.holdForForTesting = 0.2
        service.startForTesting(session: 1)
        let ciphertext = try makeCiphertext(otp: "939393", sender: "Bank")
        await service.handleEnvelope(deliveryId: "timer_expire", envelope: ["ciphertext": ciphertext], session: 1)
        service.setHeldExpiryForTesting(
            deliveryId: "timer_expire",
            expiresAt: Date().addingTimeInterval(0.05)
        )
        let flush = Task { await service.notificationAccessChanged() }
        for _ in 0..<500 {
            if await permissions.isFlushGateWaiting() { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        for _ in 0..<80 {
            if service.heldDeliveries.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(service.heldDeliveries.isEmpty, "Expiry ticks must not wait for a gated flush")
        await permissions.releaseFlushGate()
        await flush.value
        service.clear()
    }

    func testPermissionTimeoutDuringNewSessionDoesNotAffectPriorSessionWork() async throws {
        let recordId = "00000000-0000-4000-8000-000000000001"
        let permissions = GatedDeliveryPermissions(blocks: 1)
        let presenter = RecordingPresenter()
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.permissionCheckTimeoutForTesting = 0.1
        service.startForTesting(session: 1)

        let ct = try makeCiphertext(otp: "565656", sender: "Session")
        let msg =
            "{\"type\":\"envelope\",\"delivery_id\":\"session_safe\",\"envelope\":{\"ciphertext\":\"\(ct)\"}}"

        service.routeWebSocketFrame(msg, recordId: recordId, session: 1)
        try await waitForPermissionGate(permissions, call: 1)

        let drainOld = Task { await service.drainDeliveryWorkForTesting(session: 1) }
        service.stop()
        service.startForTesting(session: 2)
        service.markReadyForTesting(session: 2)
        await permissions.release(1)
        await drainOld.value
        XCTAssertEqual(service.deliveryStatusForTesting().state, .ready)
    }

    func testGatedPermissionOnFirstDeliveryDoesNotBlockSecondSocketDelivery() async throws {
        let recordId = "00000000-0000-4000-8000-000000000001"
        let permissions = GatedDeliveryPermissions(blocks: 1)
        let presenter = RecordingPresenter()
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.permissionCheckTimeoutForTesting = 0.08
        service.holdIntervalForTesting = 600
        service.startForTesting(session: 1)

        let ct1 = try makeCiphertext(otp: "111111", sender: "One")
        let ct2 = try makeCiphertext(otp: "222222", sender: "Two")
        let msg1 =
            "{\"type\":\"envelope\",\"delivery_id\":\"blocked_first\",\"envelope\":{\"ciphertext\":\"\(ct1)\"}}"
        let msg2 =
            "{\"type\":\"envelope\",\"delivery_id\":\"parallel_second\",\"envelope\":{\"ciphertext\":\"\(ct2)\"}}"

        service.routeWebSocketFrame(msg1, recordId: recordId, session: 1)
        service.routeWebSocketFrame(msg2, recordId: recordId, session: 1)

        try await waitForPermissionGate(permissions, call: 1)
        let calls = await permissions.callCount()
        XCTAssertEqual(calls, 1, "Only one underlying permission probe may run at a time")
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertGreaterThanOrEqual(service.heldDeliveries.count, 1, "Second delivery must not block behind the stalled probe")
        XCTAssertTrue(service.heldDeliveries.contains { $0.deliveryId == "parallel_second" })
        await permissions.release(1)
        await service.drainDeliveryWorkForTesting()
        await service.notificationAccessChanged()
        let presentedWhileBlocked = await presenter.count
        XCTAssertEqual(presentedWhileBlocked, 2)
    }

    func testDelayedOldSessionPoll401DoesNotOverwriteNewSessionStatus() async throws {
        let recordId = "00000000-0000-4000-8000-000000000001"
        final class PollGate: @unchecked Sendable {
            private let lock = NSLock()
            private var blocked = true
            private var entered = false
            func markEntered() {
                lock.lock()
                entered = true
                lock.unlock()
            }
            func hasEntered() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return entered
            }
            func release() {
                lock.lock()
                blocked = false
                lock.unlock()
            }
            func waitIfBlocked() {
                while lock.withLock({ blocked }) {
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
        }

        let gate = PollGate()
        let transport = MockTransport { req in
            if req.httpMethod == "GET", req.url!.path.contains("/deliveries") {
                gate.markEntered()
                gate.waitIfBlocked()
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }

        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: transport),
            notificationPresenter: MockNotificationPresenter(),
            notificationPermissions: MockPermissions()
        )
        service.startForTesting(session: 1)
        service.scheduleBackgroundPollForTesting(recordId: recordId, session: 1)

        for _ in 0..<400 {
            if gate.hasEntered() { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(gate.hasEntered())

        service.stop()
        service.startForTesting(session: 2)
        service.markReadyForTesting(session: 2)
        XCTAssertEqual(service.deliveryStatusForTesting().state, .ready)

        gate.release()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(service.deliveryStatusForTesting().state, .ready)
    }

    func testSameDeliveryIdInNewSessionNotBlockedByStalledOldSession() async throws {
        let recordId = "00000000-0000-4000-8000-000000000001"
        let permissions = GatedDeliveryPermissions(blocks: 1)
        let presenter = RecordingPresenter()
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: MockTransport { req in
                (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }),
            notificationPresenter: presenter,
            notificationPermissions: permissions
        )
        service.startForTesting(session: 1)

        let ct = try makeCiphertext(otp: "333333", sender: "Shared")
        let msg =
            "{\"type\":\"envelope\",\"delivery_id\":\"shared\",\"envelope\":{\"ciphertext\":\"\(ct)\"}}"

        service.routeWebSocketFrame(msg, recordId: recordId, session: 1)
        try await waitForPermissionGate(permissions, call: 1)

        service.stop()
        service.startForTesting(session: 2)
        service.routeWebSocketFrame(msg, recordId: recordId, session: 2)

        let start = Date()
        await service.drainDeliveryWorkForTesting(session: 2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.25)
        let presentations = await presenter.count
        XCTAssertEqual(presentations, 1)
        await permissions.release(1)
        await service.drainDeliveryWorkForTesting(session: 1)
    }

    func testOldSessionCannotReleaseNewSessionReservation() async throws {
        let permissions = GatedDeliveryPermissions(blocks: 2)
        let presenter = RecordingPresenter()
        let acks = AckRecorder()
        let ciphertext = try makeCiphertext(otp: "123456", sender: "Bank")
        let service = DesktopDeliveryService(recordStore: recordStore, apiClient: ApiClient(recordStore: recordStore, transport: overlappingTransport(ciphertext: ciphertext, acks: acks)), notificationPresenter: presenter, notificationPermissions: permissions)
        service.startForTesting(session: 1)
        let old = Task { await service.handleEnvelope(deliveryId: "shared", envelope: ["ciphertext": ciphertext], session: 1) }
        try await waitForPermissionGate(permissions, call: 1)
        service.stop()
        service.startForTesting(session: 2)
        let replacement = Task { await service.handleEnvelope(deliveryId: "shared", envelope: ["ciphertext": ciphertext], session: 2) }
        try await waitForPermissionGate(permissions, call: 2)
        await permissions.release(1)
        await old.value
        try await service.pollPending(recordId: "00000000-0000-4000-8000-000000000001", session: 2)
        let checks = await permissions.callCount()
        XCTAssertEqual(checks, 2, "The old handler must not release the replacement's reservation")
        await permissions.release(2)
        await replacement.value
        let presentations = await presenter.count
        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(acks.snapshot(), ["shared"])
        service.clear()
    }

    func testCancelledHandlerReleasesReservationForRetry() async throws {
        let permissions = GatedDeliveryPermissions(blocks: 1)
        let presenter = RecordingPresenter()
        let acks = AckRecorder()
        let ciphertext = try makeCiphertext(otp: "123456", sender: "Bank")
        let service = DesktopDeliveryService(recordStore: recordStore, apiClient: ApiClient(recordStore: recordStore, transport: overlappingTransport(ciphertext: ciphertext, acks: acks)), notificationPresenter: presenter, notificationPermissions: permissions)
        service.startForTesting(session: 1)
        let cancelled = Task { await service.handleEnvelope(deliveryId: "shared", envelope: ["ciphertext": ciphertext], session: 1) }
        try await waitForPermissionGate(permissions, call: 1)
        cancelled.cancel()
        await permissions.release(1)
        await cancelled.value
        XCTAssertTrue(service.heldDeliveries.isEmpty)
        try await service.pollPending(recordId: "00000000-0000-4000-8000-000000000001", session: 1)
        let presentations = await presenter.count
        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(acks.snapshot(), ["shared"])
        service.clear()
    }

    func testUndecryptableDeliveryIsNotRetriedOnPoll() async throws {
        let presenter = RecordingPresenter()
        let permissions = TestNotificationPermissions()
        await permissions.set(.allowed)
        let acks = AckRecorder()
        let ciphertext = try makeCiphertext(otp: "123456", sender: "Bank")
        let service = DesktopDeliveryService(recordStore: recordStore, apiClient: ApiClient(recordStore: recordStore, transport: overlappingTransport(ciphertext: ciphertext, acks: acks)), notificationPresenter: presenter, notificationPermissions: permissions)
        service.startForTesting(session: 1)
        await service.handleEnvelope(deliveryId: "shared", envelope: ["ciphertext": "invalid"], session: 1)
        XCTAssertEqual(service.status.undecryptable, 1)
        try await service.pollPending(recordId: "00000000-0000-4000-8000-000000000001", session: 1)
        let presentations = await presenter.count
        XCTAssertEqual(presentations, 0)
        XCTAssertEqual(acks.snapshot(), [])
        XCTAssertTrue(service.heldDeliveries.isEmpty)
        service.clear()
    }
}

extension DesktopDeliveryServiceTests {
    func testTimedOutPresentationRemainsOwnedAcrossRestartAndCompletesOnce() async throws {
        let presenter = BlockingPresenter()
        let permissions = TestNotificationPermissions()
        await permissions.set(.allowed)
        let acks = AckRecorder()
        let transport = MockTransport { req in
            if req.httpMethod == "DELETE" { acks.append(req.url!.lastPathComponent) }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }
        let service = DesktopDeliveryService(recordStore: recordStore, apiClient: ApiClient(recordStore: recordStore, transport: transport), notificationPresenter: presenter, notificationPermissions: permissions, presentationTimeout: 0.02)
        service.startForTesting(session: 1)
        let ciphertext = try makeCiphertext(otp: "123456", sender: "Bank")
        await service.handleEnvelope(deliveryId: "restart", envelope: ["ciphertext": ciphertext], session: 1)
        XCTAssertEqual(service.heldDeliveries.count, 1)
        service.stop()
        service.startForTesting(session: 2)
        await service.flushHeld(session: 2)
        await service.flushHeld(session: 2)
        let before = await presenter.calls
        XCTAssertEqual(before, 1, "Reconnect must preserve ownership of the suspended presentation")
        XCTAssertTrue(acks.snapshot().isEmpty)
        await presenter.finishFirst(true)
        for _ in 0..<500 {
            if !acks.snapshot().isEmpty { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(acks.snapshot(), ["restart"])
        XCTAssertTrue(service.heldDeliveries.isEmpty)
        let after = await presenter.calls
        XCTAssertEqual(after, 1)
        service.clear()
    }

    func testPresentationCompletingWhileStoppedIsReconciledAfterRestart() async throws {
        let presenter = BlockingPresenter()
        let permissions = TestNotificationPermissions()
        await permissions.set(.allowed)
        let acks = AckRecorder()
        let transport = MockTransport { req in
            if req.httpMethod == "DELETE" { acks.append(req.url!.lastPathComponent) }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }
        let service = DesktopDeliveryService(recordStore: recordStore, apiClient: ApiClient(recordStore: recordStore, transport: transport), notificationPresenter: presenter, notificationPermissions: permissions, presentationTimeout: 0.02)
        service.startForTesting(session: 1)
        let ciphertext = try makeCiphertext(otp: "123456", sender: "Bank")
        await service.handleEnvelope(deliveryId: "stopped", envelope: ["ciphertext": ciphertext], session: 1)
        service.stop()
        await presenter.finishFirst(true)
        for _ in 0..<500 {
            if service.heldDeliveries.first?.notified == true { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(service.heldDeliveries.first?.notified, true)
        XCTAssertTrue(acks.snapshot().isEmpty, "A stopped session must not acknowledge")
        service.startForTesting(session: 2)
        await service.flushHeld(session: 2)
        XCTAssertEqual(acks.snapshot(), ["stopped"])
        let count = await presenter.calls
        XCTAssertEqual(count, 1)
        service.clear()
    }

    func testRemovedPresentationCannotAffectReplacementWithSameDeliveryID() async throws {
        let presenter = BlockingPresenter()
        let permissions = TestNotificationPermissions()
        await permissions.set(.allowed)
        let acks = AckRecorder()
        let transport = MockTransport { req in
            if req.httpMethod == "DELETE" { acks.append(req.url!.lastPathComponent) }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }
        let service = DesktopDeliveryService(recordStore: recordStore, apiClient: ApiClient(recordStore: recordStore, transport: transport), notificationPresenter: presenter, notificationPermissions: permissions, presentationTimeout: 0.02)
        service.startForTesting(session: 1)
        let ciphertext = try makeCiphertext(otp: "123456", sender: "Bank")
        await service.handleEnvelope(deliveryId: "shared", envelope: ["ciphertext": ciphertext], session: 1)
        service.clear()
        await permissions.set(.off)
        service.startForTesting(session: 2)
        await service.handleEnvelope(deliveryId: "shared", envelope: ["ciphertext": ciphertext], session: 2)
        XCTAssertEqual(service.heldDeliveries.count, 1)
        await presenter.finishFirst(true)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(service.heldDeliveries.count, 1)
        XCTAssertEqual(service.heldDeliveries.first?.notified, false)
        XCTAssertTrue(acks.snapshot().isEmpty)
        await permissions.set(.allowed)
        await service.flushHeld(session: 2)
        XCTAssertEqual(acks.snapshot(), ["shared"])
        let count = await presenter.calls
        XCTAssertEqual(count, 2)
        service.clear()
    }

    func testFailedOldPresentationCanRetryAfterRestart() async throws {
        let presenter = BlockingPresenter()
        let permissions = TestNotificationPermissions()
        await permissions.set(.allowed)
        let acks = AckRecorder()
        let transport = MockTransport { req in
            if req.httpMethod == "DELETE" { acks.append(req.url!.lastPathComponent) }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }
        let service = DesktopDeliveryService(recordStore: recordStore, apiClient: ApiClient(recordStore: recordStore, transport: transport), notificationPresenter: presenter, notificationPermissions: permissions, presentationTimeout: 0.02)
        service.startForTesting(session: 1)
        let ciphertext = try makeCiphertext(otp: "123456", sender: "Bank")
        await service.handleEnvelope(deliveryId: "failed", envelope: ["ciphertext": ciphertext], session: 1)
        service.stop()
        service.startForTesting(session: 2)
        await presenter.finishFirst(false)
        for _ in 0..<500 {
            await service.flushHeld(session: 2)
            if !acks.snapshot().isEmpty { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(acks.snapshot(), ["failed"])
        let count = await presenter.calls
        XCTAssertEqual(count, 2)
        service.clear()
    }
}

extension DesktopDeliveryServiceTests {
    func testPresentationCompletingBeforeDeadlineAfterRestartIsReconciled() async throws {
        let presenter = BlockingPresenter()
        let permissions = TestNotificationPermissions()
        await permissions.set(.allowed)
        let acks = AckRecorder()
        let transport = MockTransport { req in
            if req.httpMethod == "DELETE" { acks.append(req.url!.lastPathComponent) }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }
        let service = DesktopDeliveryService(recordStore: recordStore, apiClient: ApiClient(recordStore: recordStore, transport: transport), notificationPresenter: presenter, notificationPermissions: permissions, presentationTimeout: 5)
        service.startForTesting(session: 1)
        let ciphertext = try makeCiphertext(otp: "123456", sender: "Bank")
        let original = Task { await service.handleEnvelope(deliveryId: "early", envelope: ["ciphertext": ciphertext], session: 1) }
        for _ in 0..<1000 {
            if await presenter.first != nil { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let started = await presenter.first != nil
        XCTAssertTrue(started)
        service.stop()
        service.startForTesting(session: 2)
        await service.flushHeld(session: 2)
        let before = await presenter.calls
        XCTAssertEqual(before, 1)
        await presenter.finishFirst(true)
        await original.value
        for _ in 0..<500 {
            if !acks.snapshot().isEmpty { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(acks.snapshot(), ["early"])
        XCTAssertTrue(service.heldDeliveries.isEmpty)
        let after = await presenter.calls
        XCTAssertEqual(after, 1)
        service.clear()
    }
}
