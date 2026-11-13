// Writes, reads and deletes one item in the data protection keychain, the way
// flutter_secure_storage does on macOS. See release_keychain_probe.sh.
import Foundation
import Security

let query: [CFString: Any] = [
  kSecClass: kSecClassGenericPassword,
  kSecAttrService: "pux-keychain-probe",
  kSecAttrAccount: "probe",
  kSecUseDataProtectionKeychain: true,
]
SecItemDelete(query as CFDictionary)

var add = query
add[kSecValueData] = Data("probe".utf8)
let added = SecItemAdd(add as CFDictionary, nil)

var read = query
read[kSecReturnData] = true
var result: AnyObject?
let found = SecItemCopyMatching(read as CFDictionary, &result)
SecItemDelete(query as CFDictionary)

func describe(_ status: OSStatus) -> String {
  let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
  return "\(status) (\(message))"
}
print("write: \(describe(added)), read: \(describe(found))")
exit(added == errSecSuccess && found == errSecSuccess ? 0 : 1)
