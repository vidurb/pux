import XCTest
@testable import PuxCore

final class KeychainMigrationTests: XCTestCase {
  private var mockBackend: MockPuxKeychainBackend!
  private var originalBackend: PuxKeychainBackend!

  override func setUp() {
    super.setUp()
    originalBackend = PuxKeychain.backend
    mockBackend = MockPuxKeychainBackend()
    PuxKeychain.backend = mockBackend
    mockBackend.reset()
    PuxKeychain.serviceOverride = "pux_test_migration_service"
    PuxKeychain.accessGroupOverride = "xyz.vidur.pux.shared"
  }

  override func tearDown() {
    mockBackend.deleteAll()
    mockBackend.reset()
    // Restore what was installed before, never the live backend: the test process default is inert.
    PuxKeychain.backend = originalBackend
    PuxKeychain.serviceOverride = nil
    PuxKeychain.accessGroupOverride = nil
    super.tearDown()
  }

  func testPuxKeychainDefaults() {
    PuxKeychain.serviceOverride = nil
    PuxKeychain.accessGroupOverride = nil
    XCTAssertEqual(PuxKeychain.service, "flutter_secure_storage_service")
    if let group = PuxKeychain.accessGroup {
      XCTAssertFalse(group.contains("$("))
    }
  }

  func testWriteReadAndDeleteSingleItem() {
    let key = "test_key_1"
    let val = "super_secret_value"

    XCTAssertTrue(PuxKeychain.write(key, value: val))
    XCTAssertEqual(PuxKeychain.read(key), val)

    XCTAssertTrue(PuxKeychain.delete(key))
    XCTAssertEqual(PuxKeychain.readStatus(key), .missing)
  }

  func testUnavailableStatusDistinctFromMissing() {
    mockBackend.simulateUnavailable = true
    XCTAssertEqual(PuxKeychain.readStatus("record_id"), .unavailable(errSecInteractionNotAllowed))
    XCTAssertTrue(PuxKeychain.storageUnavailable())
  }

  func testDeleteAllRemovesMultipleItems() {
    PuxKeychain.write("key1", value: "val1")
    PuxKeychain.write("key2", value: "val2")

    XCTAssertEqual(PuxKeychain.read("key1"), "val1")
    XCTAssertEqual(PuxKeychain.read("key2"), "val2")

    XCTAssertTrue(PuxKeychain.deleteAll())
    XCTAssertNil(PuxKeychain.read("key1"))
    XCTAssertNil(PuxKeychain.read("key2"))
  }

  func testDeleteCleansUpBothGroupAndLegacyCopies() {
    mockBackend.legacyStorage["legacy_key"] = "legacy_value"
    mockBackend.groupStorage["legacy_key"] = "group_value"

    XCTAssertTrue(PuxKeychain.delete("legacy_key"))
    XCTAssertNil(mockBackend.groupStorage["legacy_key"])
    XCTAssertNil(mockBackend.legacyStorage["legacy_key"])
    XCTAssertNil(PuxKeychain.read("legacy_key"))
  }

  func testMigrateLegacyItemsCopiesToGroupAndPurgesLegacy() {
    mockBackend.legacyStorage["record_id"] = "old_rec_123"
    mockBackend.legacyStorage["private_key"] = "old_key_456"

    XCTAssertEqual(PuxKeychain.read("record_id"), "old_rec_123")
    XCTAssertNil(mockBackend.groupStorage["record_id"])

    PuxKeychain.migrateLegacyItems()

    XCTAssertEqual(mockBackend.groupStorage["record_id"], "old_rec_123")
    XCTAssertEqual(mockBackend.groupStorage["private_key"], "old_key_456")
    XCTAssertNil(mockBackend.legacyStorage["record_id"])
    XCTAssertNil(mockBackend.legacyStorage["private_key"])
  }
}
