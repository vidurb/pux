import Foundation

public struct PendingDelivery: Equatable, @unchecked Sendable {
    public let deliveryId: String
    public let envelope: [String: Any]

    public init(deliveryId: String, envelope: [String: Any]) {
        self.deliveryId = deliveryId
        self.envelope = envelope
    }

    public static func == (lhs: PendingDelivery, rhs: PendingDelivery) -> Bool {
        lhs.deliveryId == rhs.deliveryId &&
        NSDictionary(dictionary: lhs.envelope).isEqual(to: rhs.envelope)
    }
}

public final class ApiClient {
    public static let shared = ApiClient()

    private let session: URLSession
    private let recordStore: RecordStore
    public var timeout: TimeInterval = 15.0
    public var healthTimeout: TimeInterval = 10.0

    public init(
        session: URLSession = .shared,
        recordStore: RecordStore = .shared
    ) {
        self.session = session
        self.recordStore = recordStore
    }

    public func createRecord(publicKey: String) async throws -> (recordId: String, inboxAddress: String) {
        guard let url = URL(string: "\(recordStore.serverUrl)/api/v1/records") else {
            throw PuxError.invalidServerUrl(recordStore.serverUrl)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        let body: [String: String] = ["public_key": publicKey]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data, action: "Record creation")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recordId = json["record_id"] as? String,
              let inboxAddress = json["inbox_address"] as? String
        else {
            throw PuxError.serverError(statusCode: 200, message: "Record creation returned an incomplete response")
        }

        return (recordId: recordId, inboxAddress: inboxAddress)
    }

    public func registerDevice(
        recordId: String,
        pushToken: String,
        platform: String = "fcm",
        replacesDeviceId: String? = nil
    ) async throws -> String? {
        try recordStore.requireOperationalServerUrl()
        guard let url = URL(string: "\(recordStore.serverUrl)/api/v1/record/devices") else {
            throw PuxError.invalidServerUrl(recordStore.serverUrl)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(recordId)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout

        var body: [String: Any] = [
            "push_token": pushToken,
            "platform": platform
        ]
        if let replaces = replacesDeviceId, !replaces.isEmpty {
            body["device_id"] = replaces
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PuxError.serverError(statusCode: 0, message: "Invalid response")
        }

        if http.statusCode == 401 || http.statusCode == 404 {
            throw PuxError.recordNotFound
        }
        if http.statusCode == 422 {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if json?["error"] as? String == "too_many_devices" {
                throw PuxError.tooManyDevices
            }
        }
        try checkResponse(http, data: data, action: "Device registration")

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let deviceId = json?["device_id"] as? String, !deviceId.isEmpty else {
            throw PuxError.serverError(statusCode: http.statusCode, message: "Device registration returned no device ID")
        }
        return deviceId
    }

    public func deleteDevice(recordId: String, deviceId: String) async throws {
        try recordStore.requireOperationalServerUrl()
        guard let url = URL(string: "\(recordStore.serverUrl)/api/v1/record/devices/\(deviceId)") else {
            throw PuxError.invalidServerUrl(recordStore.serverUrl)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(recordId)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PuxError.serverError(statusCode: 0, message: "Invalid response")
        }
        if http.statusCode == 401 || http.statusCode == 404 { return }
        try checkResponse(http, data: data, action: "Device removal")
    }

    public func deleteRecord(recordId: String) async throws {
        try recordStore.requireOperationalServerUrl()
        guard let url = URL(string: "\(recordStore.serverUrl)/api/v1/record") else {
            throw PuxError.invalidServerUrl(recordStore.serverUrl)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(recordId)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PuxError.serverError(statusCode: 0, message: "Invalid response")
        }
        if http.statusCode == 401 || http.statusCode == 404 { return }
        try checkResponse(http, data: data, action: "Relay deletion")
    }

    public func listPendingDeliveries(recordId: String) async throws -> [PendingDelivery] {
        try recordStore.requireOperationalServerUrl()
        guard let url = URL(string: "\(recordStore.serverUrl)/api/v1/record/deliveries") else {
            throw PuxError.invalidServerUrl(recordStore.serverUrl)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(recordId)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PuxError.serverError(statusCode: 0, message: "Invalid response")
        }

        if http.statusCode == 401 || http.statusCode == 404 {
            throw PuxError.recordNotFound
        }
        try checkResponse(http, data: data, action: "Delivery poll")

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let deliveries = json["deliveries"] as? [[String: Any]]
        else {
            return []
        }

        return deliveries.compactMap { entry in
            guard let id = entry["delivery_id"] as? String,
                  let env = entry["envelope"] as? [String: Any]
            else { return nil }
            return PendingDelivery(deliveryId: id, envelope: env)
        }
    }

    public func ackDelivery(recordId: String, deliveryId: String) async throws {
        try recordStore.requireOperationalServerUrl()
        guard let url = URL(string: "\(recordStore.serverUrl)/api/v1/record/deliveries/\(deliveryId)") else {
            throw PuxError.invalidServerUrl(recordStore.serverUrl)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(recordId)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PuxError.serverError(statusCode: 0, message: "Invalid response")
        }
        if http.statusCode == 404 { return }
        try checkResponse(http, data: data, action: "Delivery ack")
    }

    public func sendTestCode(recordId: String) async throws -> TestCode {
        try recordStore.requireOperationalServerUrl()
        guard let url = URL(string: "\(recordStore.serverUrl)/api/v1/record/test") else {
            throw PuxError.invalidServerUrl(recordStore.serverUrl)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(recordId)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PuxError.serverError(statusCode: 0, message: "Invalid response")
        }

        if http.statusCode == 401 || http.statusCode == 404 {
            throw PuxError.recordNotFound
        }
        if http.statusCode == 409 {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if json?["error"] as? String == "no_devices" {
                throw PuxError.noDevices
            }
        }
        try checkResponse(http, data: data, action: "Test code")

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let otp = json["otp"] as? String,
              let devices = json["devices"] as? Int
        else {
            throw PuxError.serverError(statusCode: 200, message: "Test code returned an incomplete response")
        }

        return TestCode(otp: otp, devices: devices)
    }

    public func checkHealth() async -> ServerHealth {
        guard let url = URL(string: "\(recordStore.serverUrl)/health") else {
            return ServerHealth(state: .unreachable, reason: "invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = healthTimeout

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return ServerHealth(state: .unreachable, reason: "invalid response")
            }

            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let status = json?["status"] as? String

            if http.statusCode == 200 && status == "ok" {
                return ServerHealth(state: .reachable)
            }

            if http.statusCode == 503 && status != nil {
                return ServerHealth(state: .serverError, reason: "its database is unavailable")
            }
            if http.statusCode == 200 {
                return ServerHealth(state: .serverError, reason: "the answer isn't from a pux server")
            }
            return ServerHealth(state: .serverError, reason: "HTTP \(http.statusCode)")
        } catch let err as URLError {
            if err.code == .timedOut {
                return ServerHealth(state: .unreachable, reason: "no answer within \(Int(healthTimeout)) s")
            }
            return ServerHealth(state: .unreachable, reason: err.localizedDescription)
        } catch {
            return ServerHealth(state: .unreachable, reason: error.localizedDescription)
        }
    }

    private func checkResponse(_ response: URLResponse, data: Data, action: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PuxError.serverError(statusCode: 0, message: "\(action) failed: non-HTTP response")
        }

        if http.statusCode == 429 {
            throw PuxError.rateLimited
        }

        if http.statusCode < 200 || http.statusCode >= 300 {
            let body = String(data: data, encoding: .utf8) ?? "(binary body)"
            throw PuxError.serverError(statusCode: http.statusCode, message: "\(action) failed (\(http.statusCode)): \(body)")
        }
    }
}
