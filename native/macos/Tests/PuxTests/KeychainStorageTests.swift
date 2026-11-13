import XCTest
import Security
@testable import PuxCore

private final class FakeKeychain: KeychainBackend {
    var values: [String: Data] = [:]
    var queries: [[String: Any]] = []
    var failure: OSStatus?
    func inspect(_ query: CFDictionary) -> [String: Any] {
        let q = query as NSDictionary as! [String: Any]
        queries.append(q)
        return q
    }
    func read(_ query: CFDictionary, result: inout AnyObject?) -> OSStatus {
        let q = inspect(query)
        if let failure = failure { return failure }
        guard let value = values[q[kSecAttrAccount as String] as! String] else { return errSecItemNotFound }
        result = value as AnyObject
        return errSecSuccess
    }
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        let q = inspect(query)
        if let failure = failure { return failure }
        let key = q[kSecAttrAccount as String] as! String
        guard values[key] != nil else { return errSecItemNotFound }
        values[key] = (attributes as NSDictionary)[kSecValueData] as? Data
        return errSecSuccess
    }
    func add(_ query: CFDictionary) -> OSStatus {
        let q = inspect(query)
        if let failure = failure { return failure }
        values[q[kSecAttrAccount as String] as! String] = q[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func delete(_ query: CFDictionary) -> OSStatus {
        let q = inspect(query)
        if let failure = failure { return failure }
        if let key = q[kSecAttrAccount as String] as? String { values.removeValue(forKey: key) }
        else { values.removeAll() }
        return errSecSuccess
    }
}

final class KeychainStorageTests: PuxTestCase {
    func testQueriesUseDataProtectionKeychain() throws {
        let backend = FakeKeychain()
        let storage = KeychainStorage(accessGroup: "TEAM.xyz.vidur.pux", backend: backend)
        try storage.write(key: "k", value: "v")
        XCTAssertTrue(
            backend.queries.contains { $0[kSecUseDataProtectionKeychain as String] as? Bool == true }
        )
    }

    func testReadWriteDeleteUseSameExplicitGroup() throws {
        let backend = FakeKeychain()
        let storage = KeychainStorage(accessGroup: "TEAM.xyz.vidur.pux", backend: backend)
        XCTAssertNil(try storage.read(key: "key"))
        try storage.write(key: "key", value: "old")
        try storage.write(key: "key", value: "new")
        XCTAssertEqual(try storage.read(key: "key"), "new")
        try storage.delete(key: "key")
        XCTAssertNil(try storage.read(key: "key"))
        try storage.deleteAll()
        XCTAssertTrue(backend.queries.allSatisfy { $0[kSecAttrAccessGroup as String] as? String == "TEAM.xyz.vidur.pux" })
    }

    func testErrorsAndInvalidDataAreNotTreatedAsMissing() throws {
        let backend = FakeKeychain()
        let storage = KeychainStorage(accessGroup: "group", backend: backend)
        backend.failure = errSecNotAvailable
        XCTAssertThrowsError(try storage.read(key: "key"))
        XCTAssertThrowsError(try storage.write(key: "key", value: "value"))
        XCTAssertThrowsError(try storage.delete(key: "key"))
        XCTAssertThrowsError(try storage.deleteAll())
        backend.failure = nil
        backend.values["key"] = Data([0xff])
        XCTAssertThrowsError(try storage.read(key: "key"))
    }
}
