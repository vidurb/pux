import XCTest
@testable import PuxCore

final class EnrollmentPayloadVersionTests: XCTestCase {
  private let key = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  private let recordId = "00000000-0000-4000-8000-000000000001"

  private func payload(v: Any) throws -> String {
    let dict: [String: Any] = [
      "v": v,
      "record_id": recordId,
      "private_key": key,
      "public_key": key,
      "inbox": "inbox@pux.test",
    ]
    let data = try JSONSerialization.data(withJSONObject: dict)
    return String(data: data, encoding: .utf8)!
  }

  func testRejectsBooleanVersionTrue() {
    XCTAssertThrowsError(try EnrollmentPayload.parse(raw: try payload(v: true))) { error in
      XCTAssertEqual(error as? PuxError, .invalidQRPayload("Invalid version 'v'"))
    }
  }

  func testRejectsBooleanVersionFalse() {
    XCTAssertThrowsError(try EnrollmentPayload.parse(raw: try payload(v: false))) { error in
      XCTAssertEqual(error as? PuxError, .invalidQRPayload("Invalid version 'v'"))
    }
  }

  func testAcceptsIntegerVersionOne() throws {
    _ = try EnrollmentPayload.parse(raw: try payload(v: 1))
  }
}
