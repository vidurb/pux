import XCTest
@testable import PuxCore

final class PuxKeychainDefaultBackendTests: XCTestCase {
  func testTestContextStartsOnAnInMemoryBackend() {
    XCTAssertTrue(PuxKeychain.defaultBackend(for: .test) is InMemoryPuxKeychainBackend)
  }

  func testProductionContextStartsOnTheLiveBackend() {
    XCTAssertTrue(PuxKeychain.defaultBackend(for: .production) is LivePuxKeychainBackend)
  }

  /// Every test that swaps the backend restores it, so nothing in this process may leave the live one.
  func testBackendInThisTestProcessIsNotTheLiveBackend() {
    XCTAssertFalse(PuxKeychain.backend is LivePuxKeychainBackend)
  }

  func testInMemoryBackendRoundTripsWithoutSecurity() {
    let backend = InMemoryPuxKeychainBackend()
    XCTAssertEqual(backend.readStatus("record_id"), .missing)

    XCTAssertTrue(backend.write("record_id", value: "r1"))
    XCTAssertTrue(backend.write("private_key", value: "k1"))
    XCTAssertEqual(backend.readStatus("record_id"), .found("r1"))

    XCTAssertTrue(backend.delete("record_id"))
    XCTAssertEqual(backend.readStatus("record_id"), .missing)
    XCTAssertEqual(backend.readStatus("private_key"), .found("k1"))

    backend.migrateLegacyItems()
    XCTAssertEqual(backend.readStatus("private_key"), .found("k1"))

    XCTAssertTrue(backend.deleteAll())
    XCTAssertEqual(backend.readStatus("private_key"), .missing)
  }
}
