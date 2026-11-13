import XCTest
@testable import PuxCore

/// Fake relay transport for acknowledgement tests. Delivery DELETEs are decided per attempt
/// number (1-based): succeed, fail with a transient transport error, or hold until released.
/// Nothing here touches a socket, the network, a real keychain or a real relay.
private final class AckTransport: HTTPTransport, @unchecked Sendable {
    enum Outcome { case succeed, fail, hold }

    private let lock = NSLock()
    private var outcome: @Sendable (Int) -> Outcome
    private var ackAttempts = 0
    private var polls = 0
    private var recordDeletes = 0
    private var held: [CheckedContinuation<Bool, Never>] = []

    init(outcome: @escaping @Sendable (Int) -> Outcome) { self.outcome = outcome }

    var ackCount: Int { lock.withLock { ackAttempts } }
    var pollCount: Int { lock.withLock { polls } }
    var recordDeleteCount: Int { lock.withLock { recordDeletes } }
    var heldCount: Int { lock.withLock { held.count } }

    func setOutcome(_ outcome: @escaping @Sendable (Int) -> Outcome) {
        lock.withLock { self.outcome = outcome }
    }

    /// Completes the oldest held acknowledgement request.
    func releaseHeld(success: Bool) {
        let continuation = lock.withLock { held.isEmpty ? nil : held.removeFirst() }
        continuation?.resume(returning: success)
    }

    func execute(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        func response(_ status: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
        if request.httpMethod == "DELETE", url.path.hasPrefix("/api/v1/record/deliveries/") {
            let decision = lock.withLock { () -> Outcome in
                ackAttempts += 1
                return outcome(ackAttempts)
            }
            switch decision {
            case .succeed:
                return (Data(), response(204))
            case .fail:
                throw URLError(.networkConnectionLost)
            case .hold:
                let succeed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    lock.withLock { held.append(continuation) }
                }
                if succeed { return (Data(), response(204)) }
                throw URLError(.networkConnectionLost)
            }
        }
        if request.httpMethod == "DELETE", url.path == "/api/v1/record" {
            lock.withLock { recordDeletes += 1 }
            return (Data(), response(204))
        }
        if request.httpMethod == "GET", url.path == "/api/v1/record/deliveries" {
            lock.withLock { polls += 1 }
            return (Data("{\"deliveries\":[]}".utf8), response(200))
        }
        return (Data(), response(200))
    }
}

private final class CountingPresenter: NotificationPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var shown = 0
    var count: Int { lock.withLock { shown } }
    func show(notification: RelayNotification) async throws -> Bool {
        lock.withLock { shown += 1 }
        return true
    }
}

private struct AllowedPermissions: NotificationPermissionsProtocol {
    func check() async -> NotificationAccess { .allowed }
    func ask() async -> NotificationAccess { .allowed }
}

/// A presented delivery leaves the held list before its DELETE finishes, so after a transient
/// DELETE failure nothing but the pending-acknowledgement set remembers it. These tests pin the
/// bounded, session-owned retry that keeps that case from depending on a later poll.
final class AckRetryTests: PuxTestCase {
    private static let recordId = "00000000-0000-4000-8000-000000000001"
    private static let deliveryId = "ack-retry"

    private var recordStore: RecordStore!
    private var keyPair: (publicKey: String, privateKey: String)!

    override func setUp() async throws {
        try await super.setUp()
        executionTimeAllowance = 60
        recordStore = RecordStore(storage: InMemoryStorage(), defaultServerUrl: "https://pux.test")
        keyPair = try SodiumCrypto.shared.generateKeyPair()
        try recordStore.saveEnrollment(EnrollmentPayload(
            version: 1,
            recordId: Self.recordId,
            privateKey: keyPair.privateKey,
            publicKey: keyPair.publicKey,
            inbox: "inbox@pux.test",
            server: "https://pux.test"
        ))
    }

    private func makeEnvelope() throws -> [String: Any] {
        let message = Data("{\"type\":\"otp\",\"otp\":\"424242\",\"sender\":\"Bank\"}".utf8)
        let ciphertext = try SodiumCrypto.shared.seal(message: message, recipientPublicKeyB64: keyPair.publicKey)
        return ["ciphertext": ciphertext]
    }

    private func makeService(
        _ transport: AckTransport,
        presenter: CountingPresenter = CountingPresenter(),
        retryDelay: TimeInterval = 0.02,
        maxAttempts: Int? = nil
    ) -> DesktopDeliveryService {
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: ApiClient(recordStore: recordStore, transport: transport),
            notificationPresenter: presenter,
            notificationPermissions: AllowedPermissions()
        )
        service.ackRetryDelayForTesting = retryDelay
        service.ackRetryMaxAttemptsForTesting = maxAttempts
        // A hold timer period far longer than any test: it must play no part in recovery.
        service.holdIntervalForTesting = 3600
        return service
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func settle(_ seconds: TimeInterval = 0.2) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - Recovery

    func testFailedDeleteRetriesAutomaticallyWithoutAPoll() async throws {
        let transport = AckTransport { $0 == 1 ? .fail : .succeed }
        let presenter = CountingPresenter()
        let service = makeService(transport, presenter: presenter, retryDelay: 0.15)
        service.startForTesting(session: 1)
        defer { service.clear() }

        await service.handleEnvelope(deliveryId: Self.deliveryId, envelope: try makeEnvelope(), session: 1)

        // The first DELETE failed. The delivery is out of the held list, so only the pending set
        // remembers it.
        XCTAssertEqual(transport.ackCount, 1)
        XCTAssertTrue(service.heldDeliveries.isEmpty)
        XCTAssertEqual(service.pendingAckIdsForTesting(), [Self.deliveryId])

        try await waitUntil { transport.ackCount >= 2 && service.pendingAckIdsForTesting().isEmpty }

        XCTAssertEqual(transport.ackCount, 2, "Exactly one automatic retry succeeds")
        XCTAssertTrue(service.pendingAckIdsForTesting().isEmpty)
        XCTAssertEqual(transport.pollCount, 0, "Recovery must not depend on a poll")
        XCTAssertEqual(presenter.count, 1, "A retried acknowledgement must not present the code again")

        try await settle()
        XCTAssertEqual(transport.ackCount, 2, "No further attempts once acknowledged")
        XCTAssertFalse(service.hasAckRetryTaskForTesting(), "The retry task ends when nothing is pending")
    }

    func testLaterRetryAfterSeveralFailuresStillRecovers() async throws {
        let transport = AckTransport { $0 <= 3 ? .fail : .succeed }
        let service = makeService(transport)
        service.startForTesting(session: 1)
        defer { service.clear() }

        await service.handleEnvelope(deliveryId: Self.deliveryId, envelope: try makeEnvelope(), session: 1)
        try await waitUntil { service.pendingAckIdsForTesting().isEmpty }

        XCTAssertEqual(transport.ackCount, 4)
        XCTAssertEqual(transport.pollCount, 0)
    }

    // MARK: - Bounds

    func testRetryBackoffDoublesToACapAndIsBounded() {
        let service = makeService(AckTransport { _ in .succeed })
        service.ackRetryDelayForTesting = nil
        service.ackRetryMaxAttemptsForTesting = nil
        defer { service.clear() }

        let delays = (0..<DesktopDeliveryService.ackRetryMaxAttempts).map { service.ackRetryDelay(forAttempt: $0) }
        XCTAssertEqual(delays.prefix(6).compactMap { $0 }, [2, 4, 8, 16, 32, 60])
        XCTAssertTrue(delays.allSatisfy { ($0 ?? .infinity) <= DesktopDeliveryService.ackRetryMaxDelay })
        XCTAssertNil(service.ackRetryDelay(forAttempt: DesktopDeliveryService.ackRetryMaxAttempts))
        let totalSeconds = delays.compactMap { $0 }.reduce(0, +)
        XCTAssertLessThan(totalSeconds, 10 * 60, "A series must end before the server prunes the delivery")
    }

    func testRetrySeriesIsBoundedAndAPollStartsAFreshSeries() async throws {
        let transport = AckTransport { _ in .fail }
        let service = makeService(transport, maxAttempts: 3)
        service.startForTesting(session: 1)
        defer { service.clear() }

        await service.handleEnvelope(deliveryId: Self.deliveryId, envelope: try makeEnvelope(), session: 1)
        try await waitUntil { transport.ackCount >= 4 && !service.hasAckRetryTaskForTesting() }

        XCTAssertEqual(transport.ackCount, 4, "One initial attempt plus a bounded series of three")
        try await settle()
        XCTAssertEqual(transport.ackCount, 4, "An exhausted series must not keep retrying")
        XCTAssertFalse(service.hasAckRetryTaskForTesting())
        XCTAssertEqual(service.pendingAckIdsForTesting(), [Self.deliveryId], "The acknowledgement is not forgotten")

        // A later trigger (poll, reconnect) still works and arms a fresh bounded series.
        try await service.pollPending(recordId: Self.recordId, session: 1)
        XCTAssertGreaterThanOrEqual(transport.ackCount, 5, "The poll retries the acknowledgement itself")
        try await waitUntil { transport.ackCount >= 8 && !service.hasAckRetryTaskForTesting() }
        try await settle()
        XCTAssertEqual(transport.ackCount, 8, "The fresh series is bounded too")

        transport.setOutcome { _ in .succeed }
        try await service.pollPending(recordId: Self.recordId, session: 1)
        XCTAssertTrue(service.pendingAckIdsForTesting().isEmpty)
        XCTAssertEqual(transport.ackCount, 9)
    }

    // MARK: - Stop, clear, removal

    func testStopCancelsPendingRetryAndRestartResumesItInTheNewSession() async throws {
        let transport = AckTransport { $0 == 1 ? .fail : .succeed }
        let service = makeService(transport, retryDelay: 0.2)
        service.startForTesting(session: 1)
        defer { service.clear() }

        await service.handleEnvelope(deliveryId: Self.deliveryId, envelope: try makeEnvelope(), session: 1)
        XCTAssertEqual(transport.ackCount, 1)
        XCTAssertTrue(service.hasAckRetryTaskForTesting())

        service.stop()
        XCTAssertFalse(service.hasAckRetryTaskForTesting(), "stop() must cancel the retry task")
        try await settle(0.5)
        XCTAssertEqual(transport.ackCount, 1, "No DELETE may be sent while stopped")
        XCTAssertEqual(service.pendingAckIdsForTesting(), [Self.deliveryId], "A stop keeps the acknowledgement for the next session")

        service.startForTesting(session: 2)
        try await waitUntil { service.pendingAckIdsForTesting().isEmpty }
        XCTAssertEqual(transport.ackCount, 2, "The new session resumes the retry without a poll")
        XCTAssertEqual(transport.pollCount, 0)
    }

    func testClearCancelsRetryAndDropsPendingAcknowledgements() async throws {
        let transport = AckTransport { _ in .fail }
        let service = makeService(transport, retryDelay: 0.1)
        service.startForTesting(session: 1)

        await service.handleEnvelope(deliveryId: Self.deliveryId, envelope: try makeEnvelope(), session: 1)
        XCTAssertEqual(transport.ackCount, 1)
        XCTAssertTrue(service.hasAckRetryTaskForTesting())

        service.clear()
        XCTAssertFalse(service.hasAckRetryTaskForTesting())
        XCTAssertTrue(service.pendingAckIdsForTesting().isEmpty)
        try await settle(0.4)
        XCTAssertEqual(transport.ackCount, 1, "A cleared relay must not receive further acknowledgements")

        // The service is reusable for a replacement enrollment without inheriting the old retry.
        service.startForTesting(session: 3)
        try await settle(0.3)
        XCTAssertEqual(transport.ackCount, 1)
        XCTAssertFalse(service.hasAckRetryTaskForTesting())
        service.clear()
    }

    @MainActor func testRelayRemovalStopsRetryBeforeDeletingTheRecord() async throws {
        let transport = AckTransport { _ in .fail }
        let client = ApiClient(recordStore: recordStore, transport: transport)
        let service = DesktopDeliveryService(
            recordStore: recordStore,
            apiClient: client,
            notificationPresenter: CountingPresenter(),
            notificationPermissions: AllowedPermissions()
        )
        service.ackRetryDelayForTesting = 0.3
        service.holdIntervalForTesting = 3600
        let controller = DeliveryController(recordStore: recordStore, apiClient: client, service: service)
        service.startForTesting(session: 1)

        await service.handleEnvelope(deliveryId: Self.deliveryId, envelope: try makeEnvelope(), session: 1)
        XCTAssertEqual(transport.ackCount, 1)
        XCTAssertTrue(service.hasAckRetryTaskForTesting())

        try await controller.deleteRelayEverywhere()

        XCTAssertEqual(transport.recordDeleteCount, 1)
        XCTAssertNil(try recordStore.recordId(), "Removal clears the enrollment")
        XCTAssertFalse(service.hasAckRetryTaskForTesting())
        XCTAssertTrue(service.pendingAckIdsForTesting().isEmpty)
        try await settle(0.6)
        XCTAssertEqual(transport.ackCount, 1, "No acknowledgement is sent after removal begins")
    }

    func testFailureArrivingAfterStopDoesNotRestartRetry() async throws {
        let transport = AckTransport { $0 == 1 ? .hold : .succeed }
        let service = makeService(transport)
        service.startForTesting(session: 1)
        defer { service.clear() }

        let envelope = try makeEnvelope()
        let handler = Task { await service.handleEnvelope(deliveryId: Self.deliveryId, envelope: envelope, session: 1) }
        try await waitUntil { transport.heldCount == 1 }
        XCTAssertEqual(transport.heldCount, 1, "The initial DELETE is in flight")

        service.stop()
        transport.releaseHeld(success: false)
        await handler.value

        try await settle(0.3)
        XCTAssertEqual(transport.ackCount, 1, "A late failure from a stopped session must not start a retry")
        XCTAssertFalse(service.hasAckRetryTaskForTesting())
        XCTAssertEqual(service.pendingAckIdsForTesting(), [Self.deliveryId])
    }

    // MARK: - Session ownership

    func testStaleSessionRetryCannotReleaseTheNewSessionsRetrySlot() async throws {
        // Attempt 1 (initial) fails; attempt 2 (old session's retry) and attempt 3 (new session's
        // retry) are both held in flight so their completion order can be controlled.
        let transport = AckTransport { $0 == 1 ? .fail : .hold }
        let service = makeService(transport)
        service.startForTesting(session: 1)
        defer { service.clear() }

        await service.handleEnvelope(deliveryId: Self.deliveryId, envelope: try makeEnvelope(), session: 1)
        try await waitUntil { transport.heldCount == 1 }
        XCTAssertEqual(transport.ackCount, 2, "The old session's retry is in flight")

        service.stop()
        service.startForTesting(session: 2)
        try await waitUntil { transport.heldCount == 2 }
        XCTAssertEqual(transport.ackCount, 3, "The new session starts its own retry")

        // The stale retry finishes first, with a failure. It must neither release the new
        // session's slot nor schedule anything of its own.
        transport.releaseHeld(success: false)
        try await settle(0.2)
        XCTAssertTrue(service.hasAckRetryTaskForTesting(), "The new session's retry must still be owned")
        XCTAssertEqual(transport.ackCount, 3)
        XCTAssertEqual(service.pendingAckIdsForTesting(), [Self.deliveryId])

        transport.releaseHeld(success: true)
        try await waitUntil { service.pendingAckIdsForTesting().isEmpty && !service.hasAckRetryTaskForTesting() }
        XCTAssertTrue(service.pendingAckIdsForTesting().isEmpty)
        XCTAssertEqual(transport.ackCount, 3, "Each session sent exactly one retry")
        XCTAssertFalse(service.hasAckRetryTaskForTesting())
    }

    func testNewSessionReplacesOldSessionRetryWithoutAStop() async throws {
        let transport = AckTransport { $0 == 1 ? .fail : .succeed }
        let service = makeService(transport, retryDelay: 0.3)
        service.startForTesting(session: 1)
        defer { service.clear() }

        await service.handleEnvelope(deliveryId: Self.deliveryId, envelope: try makeEnvelope(), session: 1)
        XCTAssertEqual(transport.ackCount, 1)

        // A restart that never passes through stop() must still take over from the old owner.
        service.startForTesting(session: 2)
        try await waitUntil { service.pendingAckIdsForTesting().isEmpty }
        try await settle(0.5)

        XCTAssertEqual(transport.ackCount, 2, "Only the current session's retry sends a DELETE")
        XCTAssertTrue(service.pendingAckIdsForTesting().isEmpty)
        XCTAssertFalse(service.hasAckRetryTaskForTesting())
    }
}
