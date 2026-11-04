import Foundation
import Security

/// The keychain items RecordStore writes through flutter_secure_storage
/// (generic passwords, service `flutter_secure_storage_service`, account = key),
/// shared between Runner and the notification service extension.
enum PuxKeychain {
  static let service = "flutter_secure_storage_service"

  /// `$(AppIdentifierPrefix)xyz.vidur.pux.shared`, from Info.plist. It is the
  /// first keychain-access-groups entry of both targets, so it is also the
  /// group items land in when the plugin writes them without one.
  static var accessGroup: String? {
    guard let group = Bundle.main.object(forInfoDictionaryKey: "PuxKeychainAccessGroup") as? String,
      !group.isEmpty, !group.contains("$(")
    else { return nil }
    return group
  }

  /// Searches every group the calling target can access.
  static func read(_ key: String) -> String? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: key,
      kSecMatchLimit: kSecMatchLimitOne,
      kSecReturnData: true,
    ]

    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// Builds before the shared group stored items in the app's own group,
  /// readable only while unlocked. Moves them into the shared group, readable
  /// after first unlock, which is what RecordStore now reads and writes.
  /// Best effort and idempotent: it runs on every launch and does nothing once
  /// every item has moved.
  static func migrateLegacyItems() {
    guard let accessGroup else { return }

    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecMatchLimit: kSecMatchLimitAll,
      kSecReturnAttributes: true,
    ]
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let items = result as? [[CFString: Any]]
    else { return }

    let accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    for item in items {
      guard let account = item[kSecAttrAccount] as? String,
        let group = item[kSecAttrAccessGroup] as? String,
        group != accessGroup || item[kSecAttrAccessible] as? String != accessible
      else { continue }

      let match: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
        kSecAttrAccessGroup: group,
      ]
      let update: [CFString: Any] = [
        kSecAttrAccessGroup: accessGroup,
        kSecAttrAccessible: accessible,
      ]
      if SecItemUpdate(match as CFDictionary, update as CFDictionary) == errSecDuplicateItem {
        // The app already wrote a newer value to the shared group.
        SecItemDelete(match as CFDictionary)
      }
    }
  }
}
