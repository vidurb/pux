import XCTest
@testable import PuxCore

final class ApiClientTests: XCTestCase {
    private var inMemoryStore: InMemoryKeyValueStore!
    private var recordStore: RecordStore!
    private var session: URLSession!
    private var apiClient: ApiClient!

    override func setUp() {
        super.setUp()
        inMemoryStore = InMemoryKeyValueStore()
        recordStore = RecordStore(storage: inMemoryStore, defaultServerUrl: "https://pux.test")
        session = MockURLProtocol.makeSession()
        apiClient = ApiClient(session: session, recordStore: recordStore)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testCreateRecordSuccess() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/records")
            XCTAssertEqual(request.httpMethod, "POST")

            let body = try JSONSerialization.jsonObject(with: request.bodyData!) as? [String: Any]
            XCTAssertEqual(body?["public_key"] as? String, "pub_123")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = try JSONSerialization.data(withJSONObject: [
                "record_id": "rec_abc",
                "inbox_address": "inbox_xyz@pux.test"
            ])
            return (response, data)
        }

        let result = try await apiClient.createRecord(publicKey: "pub_123")
        XCTAssertEqual(result.recordId, "rec_abc")
        XCTAssertEqual(result.inboxAddress, "inbox_xyz@pux.test")
    }

    func testRegisterDeviceSuccessAndReplacesDeviceId() async throws {
        var recordedBody: [String: Any]?

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/record/devices")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer rec_test")

            recordedBody = try? JSONSerialization.jsonObject(with: request.bodyData!) as? [String: Any]

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = try! JSONSerialization.data(withJSONObject: [
                "device_id": "dev_new",
                "platform": "fcm"
            ])
            return (response, data)
        }

        let devId = try await apiClient.registerDevice(
            recordId: "rec_test",
            pushToken: "tok_123",
            platform: "fcm",
            replacesDeviceId: "dev_old"
        )
        XCTAssertEqual(devId, "dev_new")
        XCTAssertEqual(recordedBody?["push_token"] as? String, "tok_123")
        XCTAssertEqual(recordedBody?["device_id"] as? String, "dev_old")
    }

    func testRegisterDeviceRecordNotFound() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        do {
            _ = try await apiClient.registerDevice(recordId: "rec_unknown", pushToken: "token")
            XCTFail("Expected recordNotFound error")
        } catch let err as PuxError {
            XCTAssertEqual(err, .recordNotFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRegisterDeviceTooManyDevices() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 422,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = try! JSONSerialization.data(withJSONObject: ["error": "too_many_devices"])
            return (response, data)
        }

        do {
            _ = try await apiClient.registerDevice(recordId: "rec_max", pushToken: "token")
            XCTFail("Expected tooManyDevices error")
        } catch let err as PuxError {
            XCTAssertEqual(err, .tooManyDevices)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRateLimited() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        do {
            _ = try await apiClient.createRecord(publicKey: "key")
            XCTFail("Expected rateLimited error")
        } catch let err as PuxError {
            XCTAssertEqual(err, .rateLimited)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSendTestCodeSuccessAndNoDevices() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/record/test")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = try! JSONSerialization.data(withJSONObject: [
                "otp": "456789",
                "devices": 2
            ])
            return (response, data)
        }

        let test = try await apiClient.sendTestCode(recordId: "rec_123")
        XCTAssertEqual(test.otp, "456789")
        XCTAssertEqual(test.devices, 2)

        // Now test 409 no_devices
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 409,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = try! JSONSerialization.data(withJSONObject: ["error": "no_devices"])
            return (response, data)
        }

        do {
            _ = try await apiClient.sendTestCode(recordId: "rec_123")
            XCTFail("Expected noDevices error")
        } catch let err as PuxError {
            XCTAssertEqual(err, .noDevices)
        }
    }

    func testDeleteDeviceAndRecordTreat401And404AsSuccess() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        try await apiClient.deleteDevice(recordId: "rec", deviceId: "dev")

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        try await apiClient.deleteRecord(recordId: "rec")
    }

    func testCheckHealthReachableAndServerError() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = try! JSONSerialization.data(withJSONObject: ["status": "ok"])
            return (response, data)
        }

        let health1 = await apiClient.checkHealth()
        XCTAssertEqual(health1.state, .reachable)

        // 503 database unavailable
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = try! JSONSerialization.data(withJSONObject: ["status": "error"])
            return (response, data)
        }

        let health2 = await apiClient.checkHealth()
        XCTAssertEqual(health2.state, .serverError)
        XCTAssertEqual(health2.reason, "its database is unavailable")
    }

    func testAuthenticatedRequestsBlockedWhenServerUrlUnreadable() async throws {
        try recordStore.saveEnrollment([
            "v": 1,
            "record_id": "00000000-0000-4000-8000-000000000001",
            "private_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "public_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "inbox": "inbox@pux.test",
            "server": "https://pux.test"
        ])
        inMemoryStore.unavailableKeys.insert(RecordStore.serverKey)
        recordStore.reloadServerUrl()
        XCTAssertTrue(recordStore.serverUrlUnreadable)

        MockURLProtocol.requestHandler = { _ in
            XCTFail("No network when server URL is unreadable")
            throw URLError(.badURL)
        }

        do {
            _ = try await apiClient.sendTestCode(recordId: "rec")
            XCTFail("Expected keychain unavailable")
        } catch let err as PuxError {
            XCTAssertEqual(err, .keychainUnavailable)
        }
    }
}
