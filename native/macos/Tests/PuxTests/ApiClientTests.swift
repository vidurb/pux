import XCTest
@testable import PuxCore

final class MockTransport: HTTPTransport, @unchecked Sendable {
    var handler: (URLRequest) throws -> (Data, HTTPURLResponse)

    init(handler: @escaping (URLRequest) throws -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    func execute(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        return try handler(request)
    }
}

final class ApiClientTests: PuxTestCase {
    private var recordStore: RecordStore!
    private var inMemoryStorage: InMemoryStorage!

    override func setUp() {
        super.setUp()
        inMemoryStorage = InMemoryStorage()
        recordStore = RecordStore(storage: inMemoryStorage, defaultServerUrl: "https://pux.test")
    }

    private func httpResponse(status: Int, body: [String: Any]? = nil) -> (Data, HTTPURLResponse) {
        let data = body != nil ? (try! JSONSerialization.data(withJSONObject: body!)) : Data()
        let resp = HTTPURLResponse(url: URL(string: "https://pux.test")!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, resp)
    }

    func testCreateRecord() async throws {
        let transport = MockTransport { req in
            XCTAssertEqual(req.url?.path, "/api/v1/records")
            XCTAssertEqual(req.httpMethod, "POST")
            return self.httpResponse(status: 201, body: [
                "record_id": "rec_123",
                "inbox_address": "test@pux.test"
            ])
        }

        let client = ApiClient(recordStore: recordStore, transport: transport)
        let res = try await client.createRecord(publicKey: "pub_key")
        XCTAssertEqual(res.recordId, "rec_123")
        XCTAssertEqual(res.inboxAddress, "test@pux.test")
    }

    func testRegisterDevice() async throws {
        let transport = MockTransport { req in
            XCTAssertEqual(req.url?.path, "/api/v1/record/devices")
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer rec_123")
            return self.httpResponse(status: 201, body: ["device_id": "dev_456"])
        }

        let client = ApiClient(recordStore: recordStore, transport: transport)
        let devId = try await client.registerDevice(
            recordId: "rec_123",
            pushToken: "tok_abc",
            platform: "desktop",
            replacesDeviceId: "old_dev"
        )
        XCTAssertEqual(devId, "dev_456")
    }

    func testRegistrationRequiresDeviceId() async throws {
        let transport = MockTransport { req in
            (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        }
        let client = ApiClient(recordStore: recordStore, transport: transport)
        do {
            _ = try await client.registerDevice(recordId: "record", pushToken: "stable-token")
            XCTFail("A successful response without a device ID must not be accepted")
        } catch let error as ApiError {
            guard case .incompleteResponse = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testRegisterDeviceTooManyDevicesError() async throws {
        let transport = MockTransport { _ in
            return self.httpResponse(status: 422, body: ["error": "too_many_devices"])
        }

        let client = ApiClient(recordStore: recordStore, transport: transport)
        do {
            _ = try await client.registerDevice(recordId: "rec_123", pushToken: "tok", platform: "desktop")
            XCTFail("Expected tooManyDevices error")
        } catch let err as ApiError {
            XCTAssertEqual(err, .tooManyDevices)
        }
    }

    func testPollPending() async throws {
        let transport = MockTransport { req in
            XCTAssertEqual(req.url?.path, "/api/v1/record/deliveries")
            XCTAssertEqual(req.httpMethod, "GET")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer rec_123")
            return self.httpResponse(status: 200, body: [
                "deliveries": [
                    [
                        "delivery_id": "del_1",
                        "envelope": ["ciphertext": "ct_1"]
                    ]
                ]
            ])
        }

        let client = ApiClient(recordStore: recordStore, transport: transport)
        let list = try await client.pollPending(recordId: "rec_123")
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.deliveryId, "del_1")
    }

    func testAckDelivery() async throws {
        var ackedId: String?
        let transport = MockTransport { req in
            ackedId = req.url?.lastPathComponent
            XCTAssertEqual(req.httpMethod, "DELETE")
            return self.httpResponse(status: 204)
        }

        let client = ApiClient(recordStore: recordStore, transport: transport)
        try await client.ackDelivery(recordId: "rec_123", deliveryId: "del_999")
        XCTAssertEqual(ackedId, "del_999")
    }

    func testSendTestCode() async throws {
        let transport = MockTransport { req in
            XCTAssertEqual(req.url?.path, "/api/v1/record/test")
            XCTAssertEqual(req.httpMethod, "POST")
            return self.httpResponse(status: 200, body: ["otp": "987654", "devices": 2])
        }

        let client = ApiClient(recordStore: recordStore, transport: transport)
        let sent = try await client.sendTestCode(recordId: "rec_123")
        XCTAssertEqual(sent.otp, "987654")
        XCTAssertEqual(sent.devices, 2)
    }

    func testCheckHealthReachable() async {
        let transport = MockTransport { _ in
            return self.httpResponse(status: 200, body: ["status": "ok"])
        }

        let client = ApiClient(recordStore: recordStore, transport: transport)
        let health = await client.checkHealth()
        XCTAssertEqual(health.state, .reachable)
    }

    func testCheckHealthServerError() async {
        let transport = MockTransport { _ in
            return self.httpResponse(status: 503, body: ["status": "db_down"])
        }

        let client = ApiClient(recordStore: recordStore, transport: transport)
        let health = await client.checkHealth()
        XCTAssertEqual(health.state, .serverError)
        XCTAssertEqual(health.reason, "its database is unavailable")
    }

    func testWebSocketUrl() {
        let client = ApiClient(recordStore: recordStore)
        let url = client.deliveryWebSocketUrl()
        XCTAssertEqual(url?.absoluteString, "wss://pux.test/ws/delivery")
        XCTAssertNil(url?.query)
    }
}
