import Foundation
import Security

public enum KeychainReadStatus: Equatable, Sendable {
  case found(String)
  case missing
  case unavailable(OSStatus)
}

public protocol PuxKeychainBackend: Sendable {
  func readStatus(_ key: String) -> KeychainReadStatus
  @discardableResult func write(_ key: String, value: String) -> Bool
  @discardableResult func delete(_ key: String) -> Bool
  @discardableResult func deleteAll() -> Bool
  func migrateLegacyItems()
}

/// Keychain operations compatible with flutter_secure_storage (generic passwords,
/// service `flutter_secure_storage_service`, account = key).
public enum PuxKeychain {
  public static var serviceOverride: String? = nil
  public static var accessGroupOverride: String? = nil
  /// The process-wide backend. Production processes use the live Security-framework backend; XCTest
  /// processes (package tests and app-hosted tests) start on an in-memory one, so nothing in a test
  /// run can reach the real Keychain unless a test installs a live backend on purpose.
  public static var backend: PuxKeychainBackend = defaultBackend(for: .current)

  static func defaultBackend(for context: PuxLaunchContext) -> PuxKeychainBackend {
    switch context {
    case .production: return LivePuxKeychainBackend()
    case .test: return InMemoryPuxKeychainBackend()
    }
  }

  public static var service: String {
    serviceOverride ?? "flutter_secure_storage_service"
  }

  /// `$(AppIdentifierPrefix)xyz.vidur.pux.shared`, from Info.plist.
  public static var accessGroup: String? {
    if let override = accessGroupOverride { return override }
    guard let group = Bundle.main.object(forInfoDictionaryKey: "PuxKeychainAccessGroup") as? String,
      !group.isEmpty,
      !group.contains("$(")
    else { return nil }
    return group
  }

  public static func readStatus(_ key: String) -> KeychainReadStatus {
    backend.readStatus(key)
  }

  /// Reads a string item, or nil if missing. Other errors become nil for call-site compatibility.
  public static func read(_ key: String) -> String? {
    switch backend.readStatus(key) {
    case .found(let value): return value
    case .missing, .unavailable: return nil
    }
  }

  /// True when any enrollment key exists but read failed for a non-not-found reason.
  public static func storageUnavailable() -> Bool {
    for key in ["record_id", "private_key", "public_key"] {
      if case .unavailable = backend.readStatus(key) { return true }
    }
    return false
  }

  @discardableResult
  public static func write(_ key: String, value: String) -> Bool {
    backend.write(key, value: value)
  }

  @discardableResult
  public static func delete(_ key: String) -> Bool {
    backend.delete(key)
  }

  @discardableResult
  public static func deleteAll() -> Bool {
    backend.deleteAll()
  }

  public static func migrateLegacyItems() {
    backend.migrateLegacyItems()
  }
}

/// Keeps items in memory and never calls the Security framework.
public final class InMemoryPuxKeychainBackend: PuxKeychainBackend, @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String: String] = [:]

  public init() {}

  public func readStatus(_ key: String) -> KeychainReadStatus {
    lock.lock()
    defer { lock.unlock() }
    if let value = items[key] { return .found(value) }
    return .missing
  }

  @discardableResult
  public func write(_ key: String, value: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    items[key] = value
    return true
  }

  @discardableResult
  public func delete(_ key: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    items.removeValue(forKey: key)
    return true
  }

  @discardableResult
  public func deleteAll() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    items.removeAll()
    return true
  }

  public func migrateLegacyItems() {}
}

public struct LivePuxKeychainBackend: PuxKeychainBackend {
  public init() {}

  public func readStatus(_ key: String) -> KeychainReadStatus {
    var query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: PuxKeychain.service,
      kSecAttrAccount: key,
      kSecMatchLimit: kSecMatchLimitOne,
      kSecReturnData: true,
    ]
    if let accessGroup = PuxKeychain.accessGroup {
      query[kSecAttrAccessGroup] = accessGroup
    }

    var result: AnyObject?
    var status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound && PuxKeychain.accessGroup != nil {
      query.removeValue(forKey: kSecAttrAccessGroup)
      status = SecItemCopyMatching(query as CFDictionary, &result)
    }

    switch status {
    case errSecSuccess:
      guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
        return .unavailable(status)
      }
      return .found(value)
    case errSecItemNotFound:
      return .missing
    default:
      return .unavailable(status)
    }
  }

  @discardableResult
  public func write(_ key: String, value: String) -> Bool {
    guard let data = value.data(using: .utf8) else { return false }

    var query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: PuxKeychain.service,
      kSecAttrAccount: key,
    ]
    if let accessGroup = PuxKeychain.accessGroup {
      query[kSecAttrAccessGroup] = accessGroup
    }

    let attributes: [CFString: Any] = [kSecValueData: data]
    var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecSuccess { return true }
    if status != errSecItemNotFound { return false }

    var add: [CFString: Any] = query
    add[kSecValueData] = data
    add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    status = SecItemAdd(add as CFDictionary, nil)
    return status == errSecSuccess
  }

  @discardableResult
  public func delete(_ key: String) -> Bool {
    var success = true
    if let accessGroup = PuxKeychain.accessGroup {
      let groupQuery: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: PuxKeychain.service,
        kSecAttrAccount: key,
        kSecAttrAccessGroup: accessGroup,
      ]
      let status = SecItemDelete(groupQuery as CFDictionary)
      if status != errSecSuccess && status != errSecItemNotFound {
        success = false
      }
    }

    let legacyQuery: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: PuxKeychain.service,
      kSecAttrAccount: key,
    ]
    let status = SecItemDelete(legacyQuery as CFDictionary)
    if status != errSecSuccess && status != errSecItemNotFound {
      success = false
    }
    return success
  }

  @discardableResult
  public func deleteAll() -> Bool {
    var success = true
    if let accessGroup = PuxKeychain.accessGroup {
      let groupQuery: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: PuxKeychain.service,
        kSecAttrAccessGroup: accessGroup,
      ]
      let status = SecItemDelete(groupQuery as CFDictionary)
      if status != errSecSuccess && status != errSecItemNotFound {
        success = false
      }
    }

    let legacyQuery: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: PuxKeychain.service,
    ]
    let status = SecItemDelete(legacyQuery as CFDictionary)
    if status != errSecSuccess && status != errSecItemNotFound {
      success = false
    }
    return success
  }

  public func migrateLegacyItems() {
    guard let accessGroup = PuxKeychain.accessGroup else { return }

    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: PuxKeychain.service,
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
        group != accessGroup || (item[kSecAttrAccessible] as? String) != accessible
      else { continue }

      let match: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: PuxKeychain.service,
        kSecAttrAccount: account,
        kSecAttrAccessGroup: group,
      ]
      let update: [CFString: Any] = [
        kSecAttrAccessGroup: accessGroup,
        kSecAttrAccessible: accessible,
      ]
      if SecItemUpdate(match as CFDictionary, update as CFDictionary) == errSecDuplicateItem {
        SecItemDelete(match as CFDictionary)
      }
    }
  }
}
