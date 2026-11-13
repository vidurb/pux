import Foundation
@testable import PuxCore

/// Records every call that reaches the process-wide Keychain backend, and never touches Security.
final class SpyPuxKeychainBackend: PuxKeychainBackend, @unchecked Sendable {
  enum Call: Equatable {
    case read(String)
    case write(String)
    case delete(String)
    case deleteAll
    case migrate
  }

  private let lock = NSLock()
  private var recorded: [Call] = []
  private var items: [String: String] = [:]
  private var forcedStatus: KeychainReadStatus?

  var calls: [Call] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  var storedItems: [String: String] {
    lock.lock()
    defer { lock.unlock() }
    return items
  }

  /// Makes every read report `status` regardless of stored items; nil goes back to the stored items.
  func forceReadStatus(_ status: KeychainReadStatus?) {
    lock.lock()
    defer { lock.unlock() }
    forcedStatus = status
  }

  func seed(_ key: String, _ value: String) {
    lock.lock()
    defer { lock.unlock() }
    items[key] = value
  }

  func readStatus(_ key: String) -> KeychainReadStatus {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(.read(key))
    if let forcedStatus { return forcedStatus }
    if let value = items[key] { return .found(value) }
    return .missing
  }

  @discardableResult
  func write(_ key: String, value: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(.write(key))
    items[key] = value
    return true
  }

  @discardableResult
  func delete(_ key: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(.delete(key))
    items.removeValue(forKey: key)
    return true
  }

  @discardableResult
  func deleteAll() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(.deleteAll)
    items.removeAll()
    return true
  }

  func migrateLegacyItems() {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(.migrate)
  }
}
