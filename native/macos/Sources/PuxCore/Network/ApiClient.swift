import Foundation

public enum ApiError: LocalizedError, Equatable {
    case recordNotFound
    case tooManyDevices
    case rateLimited
    case noDevices
    case serverError(Int, String)
    case incompleteResponse(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .recordNotFound:
            return "Relay not found on the server"
        case .tooManyDevices:
            return "This relay already has the maximum number of devices"
        case .rateLimited:
            return "The server is rate limiting requests"
        case .noDevices:
            return "No device is registered on this relay yet"
        case .serverError(let code, let body):
            return "Server request failed (\(code)): \(body)"
        case .incompleteResponse(let msg):
            return "Incomplete response: \(msg)"
        case .networkError(let msg):
            return "Network error: \(msg)"
        }
    }
}

public protocol HTTPTransport: Sendable {
    func execute(request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func execute(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ApiError.networkError("Non-HTTP response received")
        }
        return (data, httpResponse)
    }
}

public final class ApiClient: @unchecked Sendable {
    public static let pendingPageSize = 50

    private let transport: HTTPTransport
    private let recordStore: RecordStore
    private let timeout: TimeInterval = 15.0

    public init(
        recordStore: RecordStore,
        transport: HTTPTransport = URLSessionTransport()
    ) {
        self.recordStore = recordStore
        self.transport = transport
    }

    private var serverUrl: String {
        return recordStore.serverUrl
    }

    public func createRecord(publicKey: String) async throws -> (recordId: String, inboxAddress: String) {
        guard let url = URL(string: "\(serverUrl)/api/v1/records") else {
            throw ApiError.networkError("Invalid server URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout

        let body = ["public_key": publicKey]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await transport.execute(request: req)
        try checkResponse(response, data: data, action: "Record creation")

        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let recordId = dict["record_id"] as? String,
              let inbox = dict["inbox_address"] as? String else {
            throw ApiError.incompleteResponse("Record creation returned an incomplete response")
        }

        return (recordId: recordId, inboxAddress: inbox)
    }

    public func registerDevice(
        recordId: String,
        pushToken: String,
        platform: String = "desktop",
        replacesDeviceId: String? = nil
    ) async throws -> String? {
        guard let url = URL(string: "\(serverUrl)/api/v1/record/devices") else {
            throw ApiError.networkError("Invalid server URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(recordId)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout

        var body: [String: Any] = [
            "push_token": pushToken,
            "platform": platform
        ]
        if let replaces = replacesDeviceId {
            body["device_id"] = replaces
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await transport.execute(request: req)

        if response.statusCode == 401 || response.statusCode == 404 {
            throw ApiError.recordNotFound
        }
        if response.statusCode == 422 {
            let code = errorCode(from: data)
            if code == "too_many_devices" {
                throw ApiError.tooManyDevices
            }
        }
        try checkResponse(response, data: data, action: "Device registration")

        let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let deviceId = dict?["device_id"] as? String, !deviceId.isEmpty else {
            throw ApiError.incompleteResponse("Device registration returned no device ID")
        }
        return deviceId
    }

    public func deleteDevice(recordId: String, deviceId: String) async throws {
        guard let url = URL(string: "\(serverUrl)/api/v1/record/devices/\(deviceId)") else {
            throw ApiError.networkError("Invalid server URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(recordId)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = timeout

        let (data, response) = try await transport.execute(request: req)
        if response.statusCode == 401 || response.statusCode == 404 {
            return
        }
        try checkResponse(response, data: data, action: "Device deletion")
    }

    public func deleteRecord(recordId: String) async throws {
        guard let url = URL(string: "\(serverUrl)/api/v1/record") else {
            throw ApiError.networkError("Invalid server URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(recordId)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = timeout

        let (data, response) = try await transport.execute(request: req)
        if response.statusCode == 401 || response.statusCode == 404 {
            return
        }
        try checkResponse(response, data: data, action: "Record deletion")
    }

    public func pollPending(recordId: String) async throws -> [PendingDelivery] {
        guard let url = URL(string: "\(serverUrl)/api/v1/record/deliveries") else {
            throw ApiError.networkError("Invalid server URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(recordId)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = timeout

        let (data, response) = try await transport.execute(request: req)
        if response.statusCode == 401 || response.statusCode == 404 {
            throw ApiError.recordNotFound
        }
        try checkResponse(response, data: data, action: "Delivery poll")

        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = dict["deliveries"] as? [[String: Any]] else {
            return []
        }

        return list.compactMap { item in
            guard let deliveryId = item["delivery_id"] as? String,
                  let envelope = item["envelope"] as? [String: Any] else {
                return nil
            }
            return PendingDelivery(deliveryId: deliveryId, envelope: envelope)
        }
    }

    public func ackDelivery(recordId: String, deliveryId: String) async throws {
        guard let url = URL(string: "\(serverUrl)/api/v1/record/deliveries/\(deliveryId)") else {
            throw ApiError.networkError("Invalid server URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(recordId)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = timeout

        let (data, response) = try await transport.execute(request: req)
        if response.statusCode == 401 || response.statusCode == 404 {
            return
        }
        try checkResponse(response, data: data, action: "Delivery ack")
    }

    public func sendTestCode(recordId: String) async throws -> TestCodeResponse {
        guard let url = URL(string: "\(serverUrl)/api/v1/record/test") else {
            throw ApiError.networkError("Invalid server URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(recordId)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = timeout

        let (data, response) = try await transport.execute(request: req)

        if response.statusCode == 401 || response.statusCode == 404 {
            throw ApiError.recordNotFound
        }
        if response.statusCode == 409 && errorCode(from: data) == "no_devices" {
            throw ApiError.noDevices
        }
        try checkResponse(response, data: data, action: "Test code")

        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let otp = dict["otp"] as? String,
              let devices = dict["devices"] as? Int else {
            throw ApiError.incompleteResponse("Test code returned an incomplete response")
        }

        return TestCodeResponse(otp: otp, devices: devices)
    }

    public func checkHealth() async -> ServerHealth {
        guard let url = URL(string: "\(serverUrl)/health") else {
            return ServerHealth(state: .unreachable, reason: "invalid URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10.0

        do {
            let (data, response) = try await transport.execute(request: req)
            let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let status = dict?["status"] as? String

            if response.statusCode == 200 && status == "ok" {
                return ServerHealth(state: .reachable)
            }

            let reason: String
            switch response.statusCode {
            case 503 where status != nil:
                reason = "its database is unavailable"
            case 200:
                reason = "the answer isn't from a pux server"
            default:
                reason = "HTTP \(response.statusCode)"
            }
            return ServerHealth(state: .serverError, reason: reason)
        } catch {
            return ServerHealth(state: .unreachable, reason: error.localizedDescription)
        }
    }

    public func deliveryWebSocketUrl() -> URL? {
        guard let base = URL(string: serverUrl) else { return nil }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.scheme = base.scheme == "https" ? "wss" : "ws"
        components?.path = "/ws/delivery"
        return components?.url
    }

    private func checkResponse(_ response: HTTPURLResponse, data: Data, action: String) throws {
        if response.statusCode == 429 {
            throw ApiError.rateLimited
        }
        guard response.statusCode >= 200 && response.statusCode < 300 else {
            let body = String(data: data, encoding: .utf8) ?? "(empty body)"
            throw ApiError.serverError(response.statusCode, "\(action) failed (\(response.statusCode)): \(body)")
        }
    }

    private func errorCode(from data: Data) -> String? {
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return dict["error"] as? String
    }
}
