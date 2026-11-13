import Foundation

public enum Base64URL {
    /// Encodes data into an unpadded base64url string.
    public static func encode(_ data: Data) -> String {
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes strict unpadded base64url (no `+/=` in input).
    public static func decode(_ string: String) -> Data? {
        guard !string.isEmpty else { return nil }
        if string.contains("+") || string.contains("/") || string.contains("=") { return nil }
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    /// Decodes a 32-byte key from an unpadded base64url string.
    public static func decodeKey(_ string: String, fieldName: String = "key") throws -> Data {
        guard let data = decode(string) else {
            throw PuxError.invalidKeyEncoding(fieldName)
        }
        guard data.count == 32 else {
            throw PuxError.invalidKeyLength(fieldName, actual: data.count, expected: 32)
        }
        return data
    }
}
