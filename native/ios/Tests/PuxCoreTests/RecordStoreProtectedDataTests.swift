import XCTest
@testable import PuxCore

final class RecordStoreProtectedDataTests: XCTestCase {
  func testRefreshFromStorageReloadsCustomServerAfterKeychainUnlock() throws {
    let storage = InMemoryKeyValueStore()
    let custom = "https://relay.example:8443"
    let store = RecordStore(storage: storage, defaultServerUrl: "https://pux.default")
    XCTAssertEqual(store.serverUrl, "https://pux.default")

    try storage.write(RecordStore.serverKey, value: custom)
    XCTAssertEqual(store.serverUrl, "https://pux.default")

    store.refreshFromStorage()
    XCTAssertEqual(store.serverUrl, custom)
  }
}
