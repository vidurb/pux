import XCTest

// RelayNotificationContent.swift is compiled into this target as well; the
// fixture is the server-sealed one from test/crypto_service_test.dart.
final class NotificationServiceTests: XCTestCase {
  private let publicKey = "oVaRfoaaBI7h10MCUauxYiPWaLQaAjN_oklwaOO682M"
  private let secretKey = "3h7LhAw9e7EtYS5TeRJsQqYI8v4LtpH49buqnScv9qU"
  private let ciphertext =
    "-h4t5FOku-OWtLBcg4jo8jCNDVhdUtGyVWDk4z_FmFAI46lEoMhWZkF76pcW6lcgJI9UJ8a8JQM-"
    + "K3WA0vt7dXtlqXAKJwQfJ17REgKjSEVqOSjmmBpTmUcPtt_qHLCpMdk"

  func testOpensServerSealedBox() throws {
    let payload = try XCTUnwrap(
      SealedPayload.open(ciphertext: ciphertext, publicKey: publicKey, secretKey: secretKey))
    XCTAssertEqual(
      RelayNotificationContent(payload: payload),
      RelayNotificationContent(payload: ["type": "otp", "otp": "482913", "sender": "HDFC Bank"]))
    XCTAssertEqual(RelayNotificationContent(payload: payload).title, "OTP from HDFC Bank")
    XCTAssertEqual(RelayNotificationContent(payload: payload).body, "482913")
  }

  func testRejectsWrongKeyAndGarbage() {
    XCTAssertNil(SealedPayload.open(ciphertext: ciphertext, publicKey: secretKey, secretKey: secretKey))
    XCTAssertNil(SealedPayload.open(ciphertext: "not base64!", publicKey: publicKey, secretKey: secretKey))
    XCTAssertNil(SealedPayload.open(ciphertext: ciphertext, publicKey: "AAAA", secretKey: secretKey))
  }

  func testMarksOnlyExplicitlyUnverifiedSenders() {
    let base: [String: Any] = ["type": "otp", "otp": "1", "sender": "example.com"]
    XCTAssertEqual(RelayNotificationContent(payload: base).title, "OTP from example.com")
    XCTAssertEqual(
      RelayNotificationContent(payload: base.merging(["verified": true]) { $1 }).title,
      "OTP from example.com")
    XCTAssertEqual(
      RelayNotificationContent(payload: base.merging(["verified": false]) { $1 }).title,
      "OTP from example.com (unverified)")
  }

  func testDefaultsMatchTheDartClient() {
    let empty = RelayNotificationContent(payload: [:])
    XCTAssertEqual(empty.title, "OTP from Unknown sender")
    XCTAssertEqual(empty.body, "??????")
  }

  func testFormatsForwardConfirmations() {
    let full = RelayNotificationContent(payload: [
      "type": "forward_confirm", "code": "123", "url": "https://mail.google.com/x",
      "sender": "Gmail", "forwarding_from": "me@example.com",
    ])
    XCTAssertEqual(full.title, "Email forwarding confirmation")
    XCTAssertEqual(full.body, "Forwarding from me@example.com\nCode: 123\nhttps://mail.google.com/x")

    let bare = RelayNotificationContent(payload: [
      "type": "forward_confirm", "code": NSNull(), "url": NSNull(), "sender": "Gmail",
      "forwarding_from": NSNull(),
    ])
    XCTAssertEqual(bare.body, "From Gmail")
  }
}
