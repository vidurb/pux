import Foundation

public enum EnrollmentError: LocalizedError {
    case invalidJson
    case unsupportedVersion(Int)
    case missingField(String)
    case invalidRecordId
    case invalidInbox
    case invalidKey(String)
    case invalidServerUrl(String)
    case invalidField(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJson:
            return "Invalid QR / enrollment JSON payload"
        case .unsupportedVersion(let v):
            return "Unsupported enrollment version: \(v)"
        case .missingField(let f):
            return "Missing required field '\(f)' in enrollment"
        case .invalidRecordId:
            return "Invalid record_id in enrollment: must be a valid UUID"
        case .invalidInbox:
            return "Invalid inbox address in enrollment"
        case .invalidKey(let k):
            return "Invalid \(k): expected 32-byte unpadded base64url key"
        case .invalidServerUrl(let msg):
            return msg
        case .invalidField(let f):
            return "Invalid \(f) in enrollment"
        }
    }
}

public struct EnrollmentPayload: Equatable, Sendable {
    public let version: Int
    public let recordId: String
    public let privateKey: String
    public let publicKey: String
    public let inbox: String
    public let server: String?

    private static let uuidRegex = try! NSRegularExpression(
        pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
        options: .caseInsensitive
    )

    private static let cleartextHosts: Set<String> = [
        "localhost", "127.0.0.1", "10.0.2.2"
    ]

    public init(
        version: Int = 1,
        recordId: String,
        privateKey: String,
        publicKey: String,
        inbox: String,
        server: String? = nil
    ) {
        self.version = version
        self.recordId = recordId
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.inbox = inbox
        self.server = server
    }

    public static func validateServerUrl(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            throw EnrollmentError.invalidServerUrl("Invalid server URL in enrollment")
        }

        let secure = url.scheme == "https"
        let local = url.scheme == "http" && cleartextHosts.contains(host)
        if !secure && !local {
            throw EnrollmentError.invalidServerUrl(
                "Refusing insecure server \(url.scheme ?? "")://\(host): https is required"
            )
        }

        if url.user != nil || url.password != nil || url.query != nil || url.fragment != nil {
            throw EnrollmentError.invalidServerUrl("Server URL must not have a path, query or credentials")
        }

        let path = url.path
        if !path.isEmpty && path != "/" {
            throw EnrollmentError.invalidServerUrl("Server URL must not have a path, query or credentials")
        }

        // Return without trailing slash
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.path = ""
        return components.string ?? trimmed
    }

    public static func parse(jsonString: String) throws -> EnrollmentPayload {
        guard let data = jsonString.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw EnrollmentError.invalidJson
        }
        return try parse(dictionary: dict)
    }

    public static func parse(dictionary dict: [String: Any]) throws -> EnrollmentPayload {
        guard let v = dict["v"] as? Int else {
            throw EnrollmentError.missingField("v")
        }
        guard v == 1 else {
            throw EnrollmentError.unsupportedVersion(v)
        }

        guard let recordId = dict["record_id"] as? String, !recordId.isEmpty else {
            throw EnrollmentError.missingField("record_id")
        }
        let range = NSRange(location: 0, length: recordId.utf16.count)
        guard uuidRegex.firstMatch(in: recordId, options: [], range: range) != nil else {
            throw EnrollmentError.invalidRecordId
        }

        guard let inbox = dict["inbox"] as? String, !inbox.isEmpty else {
            throw EnrollmentError.missingField("inbox")
        }

        guard let pubKey = dict["public_key"] as? String, !pubKey.isEmpty else {
            throw EnrollmentError.missingField("public_key")
        }
        guard let pubKeyData = Base64URL.decode(pubKey), pubKeyData.count == 32 else {
            throw EnrollmentError.invalidKey("public_key")
        }

        guard let privKey = dict["private_key"] as? String, !privKey.isEmpty else {
            throw EnrollmentError.missingField("private_key")
        }
        guard let privKeyData = Base64URL.decode(privKey), privKeyData.count == 32 else {
            throw EnrollmentError.invalidKey("private_key")
        }

        var validatedServer: String? = nil
        if let serverValue = dict["server"] {
            if serverValue is NSNull {
                validatedServer = nil
            } else if let server = serverValue as? String {
                if !server.isEmpty {
                    validatedServer = try validateServerUrl(server)
                }
            } else {
                throw EnrollmentError.invalidField("server")
            }
        }

        return EnrollmentPayload(
            version: v,
            recordId: recordId,
            privateKey: privKey,
            publicKey: pubKey,
            inbox: inbox,
            server: validatedServer
        )
    }

    public func asDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "v": version,
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

    public func asJsonString() -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: asDictionary(), options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
