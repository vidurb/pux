import Foundation
import Security

public protocol SecureStorage: Sendable {
    func read(key: String) throws -> String?
    func write(key: String, value: String) throws
    func delete(key: String) throws
    func deleteAll() throws
}

protocol KeychainBackend {
    func read(_ query: CFDictionary, result: inout AnyObject?) -> OSStatus
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus
    func add(_ query: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

private struct SecurityBackend: KeychainBackend {
    func read(_ query: CFDictionary, result: inout AnyObject?) -> OSStatus { SecItemCopyMatching(query, &result) }
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus { SecItemUpdate(query, attributes) }
    func add(_ query: CFDictionary) -> OSStatus { SecItemAdd(query, nil) }
    func delete(_ query: CFDictionary) -> OSStatus { SecItemDelete(query) }
}

public final class KeychainStorage: SecureStorage, @unchecked Sendable {
  /// True when the process is running XCTest (SwiftPM, Xcode, or xctest CLI).
  public static var isRunningUnderXCTest: Bool {
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
    if ProcessInfo.processInfo.environment["XCInjectBundleInto"] != nil { return true }
    if NSClassFromString("XCTestCase") != nil { return true }
    return false
  }

  public static let shared: KeychainStorage = {
    if isRunningUnderXCTest {
      preconditionFailure(
        "Production KeychainStorage (flutter_secure_storage_service) must not be used under XCTest; inject InMemoryStorage or KeychainStorage(accessGroup:backend:) with a test backend."
      )
    }
    return KeychainStorage(accessGroup: nil, backend: SecurityBackend())
  }()

    public static let service = "flutter_secure_storage_service"

    public let accessGroup: String?
    private let backend: KeychainBackend

    public convenience init(accessGroup: String? = nil) {
        if Self.isRunningUnderXCTest {
            preconditionFailure(
                "Production KeychainStorage must not be constructed under XCTest without a test backend; use KeychainStorage(accessGroup:backend:)."
            )
        }
        self.init(accessGroup: accessGroup, backend: SecurityBackend())
    }

    init(accessGroup: String?, backend: KeychainBackend) {
        self.backend = backend
        if let accessGroup = accessGroup {
            self.accessGroup = accessGroup
        } else if let group = Bundle.main.object(forInfoDictionaryKey: "PuxKeychainAccessGroup") as? String,
                  !group.isEmpty, !group.contains("$(") {
            self.accessGroup = group
        } else {
            self.accessGroup = nil
        }
    }

    private func baseQuery(key: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: key,
            kSecUseDataProtectionKeychain: true,
        ]
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        return query
    }

    public func read(key: String) throws -> String? {
        var query = baseQuery(key: key)
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true

        var result: AnyObject?
        let status = backend.read(query as CFDictionary, result: &result)

        // The released macOS app uses the app-ID group. All operations use the
        // same group; a group-less search can match a different accessible item.
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode))
        }
        return string
    }

    public func write(key: String, value: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(key: key)

        let updateQuery: [CFString: Any] = [
            kSecValueData: data
        ]

        let updateStatus = backend.update(query as CFDictionary, attributes: updateQuery as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = backend.add(addQuery as CFDictionary)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
            }
            return
        }

        throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
    }

    public func delete(key: String) throws {
        let query = baseQuery(key: key)
        let status = backend.delete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    public func deleteAll() throws {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecUseDataProtectionKeychain: true,
        ]
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        let status = backend.delete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

/// In-memory secure storage implementation for unit testing and offline development
public final class InMemoryStorage: SecureStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init(initialValues: [String: String] = [:]) {
        self.storage = initialValues
    }

    public func read(key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    public func write(key: String, value: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = value
    }

    public func delete(key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }

    public func deleteAll() throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}
