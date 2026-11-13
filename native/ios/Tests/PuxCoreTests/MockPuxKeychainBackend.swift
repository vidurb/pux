import Foundation
import Security
@testable import PuxCore

/// In-memory keychain simulation with optional legacy vs shared-group split for migration tests.
final class MockPuxKeychainBackend: PuxKeychainBackend, @unchecked Sendable {
  var groupStorage: [String: String] = [:]
  var legacyStorage: [String: String] = [:]
  var simulateUnavailable = false

  func reset() {
    groupStorage.removeAll()
    legacyStorage.removeAll()
    simulateUnavailable = false
  }

  func readStatus(_ key: String) -> KeychainReadStatus {
    if simulateUnavailable { return .unavailable(errSecInteractionNotAllowed) }
    if PuxKeychain.accessGroup != nil {
      if let value = groupStorage[key] { return .found(value) }
      if let value = legacyStorage[key] { return .found(value) }
    } else if let value = legacyStorage[key] {
      return .found(value)
    }
    return .missing
  }

  @discardableResult
  func write(_ key: String, value: String) -> Bool {
    if simulateUnavailable { return false }
    if PuxKeychain.accessGroup != nil {
      groupStorage[key] = value
    } else {
      legacyStorage[key] = value
    }
    return true
  }

  @discardableResult
  func delete(_ key: String) -> Bool {
    groupStorage.removeValue(forKey: key)
    legacyStorage.removeValue(forKey: key)
    return true
  }

  @discardableResult
  func deleteAll() -> Bool {
    groupStorage.removeAll()
    legacyStorage.removeAll()
    return true
  }

  func migrateLegacyItems() {
    guard PuxKeychain.accessGroup != nil else { return }
    for (key, val) in legacyStorage where groupStorage[key] == nil {
      groupStorage[key] = val
    }
    legacyStorage.removeAll()
  }
}
