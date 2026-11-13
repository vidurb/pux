import Foundation
import Security

/// Verifies Data Protection generic-password access using the same query shape as `KeychainStorage`,
/// without touching the production `flutter_secure_storage_service`.
public enum KeychainAppProbe {
    public static let service = "xyz.vidur.pux.native_macos_probe"

    public static func run() throws {
        let account = "probe"
        let value = Data("probe-value".utf8)
        var deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        var addQuery = deleteQuery
        addQuery[kSecValueData as String] = value
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(addStatus),
                userInfo: [NSLocalizedDescriptionKey: "Keychain add failed with status \(addStatus)"]
            )
        }
        defer { SecItemDelete(deleteQuery as CFDictionary) }

        var matchQuery = deleteQuery
        matchQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        matchQuery[kSecReturnData as String] = true

        var result: AnyObject?
        let readStatus = SecItemCopyMatching(matchQuery as CFDictionary, &result)
        guard readStatus == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8),
              string == "probe-value" else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(readStatus),
                userInfo: [NSLocalizedDescriptionKey: "Keychain read-back failed"]
            )
        }
    }
}
