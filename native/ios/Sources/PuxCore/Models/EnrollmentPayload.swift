import Foundation

public struct EnrollmentPayload: Equatable, Codable {
    public let v: Int
    public let recordId: String
    public let privateKey: String
    public let publicKey: String
    public let inbox: String
    public let server: String?

    public init(
        v: Int = 1,
        recordId: String,
        privateKey: String,
        publicKey: String,
        inbox: String,
        server: String? = nil
    ) {
        self.v = v
        self.recordId = recordId
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.inbox = inbox
        self.server = server
    }

    enum CodingKeys: String, CodingKey {
        case v
        case recordId = "record_id"
        case privateKey = "private_key"
        case publicKey = "public_key"
        case inbox
        case server
    }

    /// Converts into a dictionary representation for storage and export
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "v": v,
            "record_id": recordId,
            "private_key": privateKey,
            "public_key": publicKey,
            "inbox": inbox
        ]
        if let server = server {
            dict["server"] = server
        }
        return dict
    }

    /// Serializes to JSON string
    public func toJSONString() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw PuxError.invalidQRPayload("Failed to encode UTF-8 JSON")
        }
        return string
    }

    /// Validates the `v` field from a JSON object (`1` only; rejects booleans including JSON `true`).
    public static func parseVersionField(_ raw: Any) throws -> Int {
        if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            throw PuxError.invalidQRPayload("Invalid version 'v'")
        }
        if let intVersion = raw as? Int {
            return intVersion
        }
        if let number = raw as? NSNumber {
            let value = number.doubleValue
            guard value.rounded() == value, value >= 1, value <= Double(Int.max) else {
                throw PuxError.invalidQRPayload("Missing version 'v'")
            }
            return number.intValue
        }
        throw PuxError.invalidQRPayload("Missing version 'v'")
    }

    /// Parses raw JSON string (e.g. from QR code or pasteboard) and validates all constraints.
    public static func parse(raw: String) throws -> EnrollmentPayload {
        guard let data = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else {
            throw PuxError.invalidQRPayload("Invalid string data")
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PuxError.invalidQRPayload("JSON must be an object")
        }

        guard let rawVersion = jsonObject["v"] else {
            throw PuxError.invalidQRPayload("Missing version 'v'")
        }
        let version = try Self.parseVersionField(rawVersion)
        guard version == 1 else {
            throw PuxError.unsupportedQRVersion(version)
        }

        for requiredKey in ["record_id", "private_key", "public_key", "inbox"] {
            guard let val = jsonObject[requiredKey] as? String, !val.isEmpty else {
                throw PuxError.missingQRField(requiredKey)
            }
        }

        let recordId = jsonObject["record_id"] as! String
        guard recordId.isValidUUID else {
            throw PuxError.invalidRecordId(recordId)
        }

        let privateKey = jsonObject["private_key"] as! String
        _ = try Base64URL.decodeKey(privateKey, fieldName: "private_key")

        let publicKey = jsonObject["public_key"] as! String
        _ = try Base64URL.decodeKey(publicKey, fieldName: "public_key")

        let inbox = jsonObject["inbox"] as! String
        let server = jsonObject["server"] as? String

        return EnrollmentPayload(
            v: version,
            recordId: recordId,
            privateKey: privateKey,
            publicKey: publicKey,
            inbox: inbox,
            server: server
        )
    }
}
