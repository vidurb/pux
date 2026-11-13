import XCTest
@testable import PuxCore

/// Models the server's upsert by desktop token and DELETE by device ID.
private actor RelayTransport: HTTPTransport {
    var deviceId: String?
    var token: String?
    var relayFull = false
    var registrations = 0
    var deletions = 0
    var loseRegistrationResponse = false
    var loseDeletionResponse = false
    var relayExists = true
    var relayDeletes = 0
    var loseRelayDeletionResponse = false
    var holdHealth = false
    var holdDelete = false
    var healthStarted = false
    var deleteStarted = false
    var healthContinuation: CheckedContinuation<Void, Never>?
    var deleteContinuation: CheckedContinuation<Void, Never>?

    func configure(registrationLoss: Bool = false, deletionLoss: Bool = false, healthBarrier: Bool = false, deleteBarrier: Bool = false) {
        loseRegistrationResponse = registrationLoss
        loseDeletionResponse = deletionLoss
        holdHealth = healthBarrier
        holdDelete = deleteBarrier
    }
    func setRelayFull(_ full: Bool) { relayFull = full }
    func loseNextRelayDeletionResponse() { loseRelayDeletionResponse = true }
    func releaseHealth() { healthContinuation?.resume(); healthContinuation = nil }
    func releaseDelete() { deleteContinuation?.resume(); deleteContinuation = nil }

    func execute(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        func response(_ status: Int, _ data: String = "") -> (Data, HTTPURLResponse) {
            (Data(data.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        if url.path == "/health" {
            healthStarted = true
            if holdHealth { await withCheckedContinuation { healthContinuation = $0 } }
            return response(200, "{\"status\":\"ok\"}")
        }
        if request.httpMethod == "POST" && url.path == "/api/v1/record/devices" {
            registrations += 1
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let incomingToken = body["push_token"] as! String
            // The real server rejects only new tokens at the cap; existing
            // tokens can always be reconciled without consuming a new slot.
            if relayFull && deviceId == nil {
                return response(422, "{\"error\":\"too_many_devices\"}")
            }
            if deviceId == nil { deviceId = "server-device" }
            XCTAssertTrue(token == nil || token == incomingToken)
            token = incomingToken
            if loseRegistrationResponse {
                loseRegistrationResponse = false
                throw URLError(.networkConnectionLost)
            }
            return response(201, "{\"device_id\":\"\(deviceId!)\"}")
        }
        if request.httpMethod == "DELETE" && url.path == "/api/v1/record" {
            relayDeletes += 1
            let existed = relayExists
            relayExists = false
            deviceId = nil
            if loseRelayDeletionResponse {
                loseRelayDeletionResponse = false
                throw URLError(.networkConnectionLost)
            }
            return response(existed ? 204 : 404)
        }
        if request.httpMethod == "DELETE" && url.path.hasPrefix("/api/v1/record/devices/") {
            deletions += 1
            deleteStarted = true
            if holdDelete { await withCheckedContinuation { deleteContinuation = $0 } }
            let existed = deviceId != nil
            deviceId = nil
            if loseDeletionResponse {
                loseDeletionResponse = false
                throw URLError(.networkConnectionLost)
            }
            return response(existed ? 204 : 404)
        }
        return response(200, "{\"deliveries\":[]}")
    }
}

@MainActor
final class RemovalLifecycleTests: PuxTestCase {
    private func makeController(_ transport: RelayTransport) throws -> (DeliveryController, RecordStore) {
        let storage = InMemoryStorage(initialValues: [
            RecordStore.recordIdKey: "record",
            RecordStore.publicKeyKey: "public",
            RecordStore.privateKeyKey: "private",
            RecordStore.inboxKey: "inbox",
            RecordStore.desktopDeviceIdKey: "stable-desktop-token"
        ])
        let store = RecordStore(storage: storage, defaultServerUrl: "https://pux.test")
        let api = ApiClient(recordStore: store, transport: transport)
        return (DeliveryController(recordStore: store, apiClient: api), store)
    }

    func testCommittedRegistrationWithLostResponseIsReconciledBeforeRemoval() async throws {
        let transport = RelayTransport()
        await transport.configure(registrationLoss: true)
        let (controller, store) = try makeController(transport)
        let start = Task { await controller.start() }
        while await transport.registrations == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        try await controller.removeThisDevice()
        await start.value
        let registrations = await transport.registrations
        let deviceId = await transport.deviceId
        XCTAssertEqual(registrations, 2)
        XCTAssertNil(deviceId)
        XCTAssertNil(try store.recordId())
        XCTAssertNil(try store.pendingRemoval())
    }

    func testLostReconciliationResponsePersistsIntentAndRetriesAfterRestart() async throws {
        let transport = RelayTransport()
        await transport.configure(registrationLoss: true)
        let (controller, store) = try makeController(transport)
        do { try await controller.removeThisDevice(); XCTFail("expected lost response") } catch {}
        XCTAssertEqual(try store.pendingRemoval(), .deviceReconciling)
        let committed = await transport.deviceId
        XCTAssertEqual(committed, "server-device")
        let restarted = DeliveryController(recordStore: store, apiClient: ApiClient(recordStore: store, transport: transport))
        await restarted.initialize()
        await restarted.start()
        let before = await transport.registrations
        XCTAssertEqual(before, 1)
        try await restarted.removeThisDevice()
        let after = await transport.registrations
        let remaining = await transport.deviceId
        XCTAssertEqual(after, 2)
        XCTAssertNil(remaining)
        XCTAssertNil(try store.recordId())
    }

    func testCommittedDeletionWithLostResponseStaysStoppedAcrossRestartAndRetriesDelete() async throws {
        let transport = RelayTransport()
        await transport.configure(deletionLoss: true)
        let (controller, store) = try makeController(transport)
        do { try await controller.removeThisDevice(); XCTFail("expected lost response") } catch {}
        XCTAssertEqual(try store.pendingRemoval(), .deviceDeleting)
        XCTAssertNotNil(try store.recordId())
        let api = ApiClient(recordStore: store, transport: transport)
        let restarted = DeliveryController(recordStore: store, apiClient: api)
        await restarted.initialize()
        await restarted.start()
        await restarted.checkHealth(userAsked: true)
        let registrationsBeforeRetry = await transport.registrations
        XCTAssertEqual(registrationsBeforeRetry, 1)
        XCTAssertEqual(restarted.pendingRemoval, .deviceDeleting)
        try await restarted.removeThisDevice()
        let registrationsAfterRetry = await transport.registrations
        let deletions = await transport.deletions
        XCTAssertEqual(registrationsAfterRetry, 1)
        XCTAssertEqual(deletions, 2)
        XCTAssertNil(try store.recordId())
    }

    func testLostRelayDeletionStaysPausedAndRetriesAfterRestart() async throws {
        let transport = RelayTransport()
        await transport.loseNextRelayDeletionResponse()
        let (controller, store) = try makeController(transport)
        do { try await controller.deleteRelayEverywhere(); XCTFail("expected lost response") } catch {}
        XCTAssertEqual(try store.pendingRemoval(), .relay)
        let restarted = DeliveryController(recordStore: store, apiClient: ApiClient(recordStore: store, transport: transport))
        await restarted.initialize()
        await restarted.start()
        let registrations = await transport.registrations
        XCTAssertEqual(registrations, 0)
        try await restarted.deleteRelayEverywhere()
        let deletions = await transport.relayDeletes
        XCTAssertEqual(deletions, 2)
        XCTAssertNil(try store.recordId())
    }

    func testDeviceLimitAllowsExplicitLocalOnlyRecoveryAfterRestart() async throws {
        let transport = RelayTransport()
        await transport.setRelayFull(true)
        let (controller, store) = try makeController(transport)
        do { try await controller.removeThisDevice(); XCTFail("expected device limit") }
        catch let error as ApiError { XCTAssertEqual(error, .tooManyDevices) }
        XCTAssertEqual(try store.pendingRemoval(), .deviceLimit)
        XCTAssertNotNil(try store.recordId())
        let restarted = DeliveryController(recordStore: store, apiClient: ApiClient(recordStore: store, transport: transport))
        await restarted.initialize()
        XCTAssertEqual(restarted.pendingRemoval, .deviceLimit)
        await restarted.start()
        let before = await transport.registrations
        XCTAssertEqual(before, 1)
        try await restarted.forgetThisMacAfterDeviceLimit()
        XCTAssertNil(try store.recordId())
        XCTAssertNil(try store.pendingRemoval())
        let deletes = await transport.deletions
        XCTAssertEqual(deletes, 0, "Local-only recovery must not claim or attempt server deletion")
    }

    func testDeviceLimitCanRetryAfterSlotIsFreed() async throws {
        let transport = RelayTransport()
        await transport.setRelayFull(true)
        let (controller, store) = try makeController(transport)
        do { try await controller.removeThisDevice(); XCTFail("expected device limit") } catch {}
        XCTAssertEqual(try store.pendingRemoval(), .deviceLimit)
        await transport.setRelayFull(false)
        try await controller.removeThisDevice()
        let registrations = await transport.registrations
        let deletions = await transport.deletions
        XCTAssertEqual(registrations, 2)
        XCTAssertEqual(deletions, 1)
        XCTAssertNil(try store.recordId())
    }

    func testUncertainRetryDisablesLocalOnlyRecovery() async throws {
        let transport = RelayTransport()
        await transport.setRelayFull(true)
        let (controller, store) = try makeController(transport)
        do { try await controller.removeThisDevice(); XCTFail("expected device limit") } catch {}
        XCTAssertEqual(try store.pendingRemoval(), .deviceLimit)
        await transport.setRelayFull(false)
        await transport.configure(registrationLoss: true)
        do { try await controller.removeThisDevice(); XCTFail("expected lost response") } catch {}
        XCTAssertEqual(try store.pendingRemoval(), .deviceReconciling)
        do { try await controller.forgetThisMacAfterDeviceLimit(); XCTFail("uncertain outcome must not offer recovery") } catch {}
        XCTAssertNotNil(try store.recordId())
        let committed = await transport.deviceId
        XCTAssertEqual(committed, "server-device")
    }

    func testExistingTokenReconcilesEvenAtDeviceLimit() async throws {
        let transport = RelayTransport()
        await transport.configure(registrationLoss: true)
        let (controller, store) = try makeController(transport)
        do { try await controller.removeThisDevice(); XCTFail("expected lost response") } catch {}
        await transport.setRelayFull(true)
        try await controller.removeThisDevice()
        let deletions = await transport.deletions
        XCTAssertEqual(deletions, 1)
        XCTAssertNil(try store.recordId())
    }

    func testCancelPendingRemovalResumesDelivery() async throws {
        let transport = RelayTransport()
        await transport.configure(deletionLoss: true)
        let (controller, store) = try makeController(transport)
        do { try await controller.removeThisDevice(); XCTFail("expected lost response") } catch {}
        XCTAssertEqual(try store.pendingRemoval(), .deviceDeleting)
        try await controller.cancelPendingRemoval()
        XCTAssertNil(try store.pendingRemoval())
        XCTAssertNotNil(try store.recordId())
        await controller.start()
        let regs = await transport.registrations
        XCTAssertGreaterThanOrEqual(regs, 1)
    }

    func testHealthResponseDuringRemovalCannotRestartRegistration() async throws {
        let transport = RelayTransport()
        await transport.configure(healthBarrier: true, deleteBarrier: true)
        let (controller, store) = try makeController(transport)
        let health = Task { await controller.checkHealth(userAsked: true) }
        while !(await transport.healthStarted) { try await Task.sleep(nanoseconds: 1_000_000) }
        let removal = Task { try await controller.removeThisDevice() }
        while !(await transport.deleteStarted) { try await Task.sleep(nanoseconds: 1_000_000) }
        // Model an already queued retrying status arriving after stop. This makes
        // the health-check retry branch eligible while removal is suspended.
        controller.deliveryService(controller.deliveryService, didUpdateStatus: DeliveryStatus(state: .retrying))
        await transport.releaseHealth()
        await health.value
        await controller.start()
        let count = await transport.registrations
        XCTAssertEqual(count, 1)
        await transport.releaseDelete()
        try await removal.value
        XCTAssertNil(try store.recordId())
    }
}
