import XCTest
@testable import PuxCore

final class RelayNotificationTests: XCTestCase {
    func testRendersOtp() {
        let n = RelayNotification.fromPayload([
            "type": "otp",
            "otp": "482913",
            "sender": "HDFC Bank"
        ])
        XCTAssertEqual(n.title, "OTP from HDFC Bank")
        XCTAssertEqual(n.body, "482913")
        XCTAssertEqual(n.code, "482913")
        XCTAssertNil(n.url)
    }

    func testTreatsPayloadWithoutTypeAsOtp() {
        let n = RelayNotification.fromPayload([
            "otp": "123456",
            "sender": "ICICI"
        ])
        XCTAssertEqual(n.title, "OTP from ICICI")
        XCTAssertEqual(n.body, "123456")
        XCTAssertEqual(n.code, "123456")
    }

    func testMarksUnverifiedSenders() {
        let n = RelayNotification.fromPayload([
            "type": "otp",
            "otp": "482913",
            "sender": "hdfcbank.example",
            "verified": false
        ])
        XCTAssertEqual(n.title, "OTP from hdfcbank.example (unverified)")
    }

    func testVerifiedSendersCarryNoMarker() {
        let n = RelayNotification.fromPayload([
            "type": "otp",
            "otp": "482913",
            "sender": "HDFC Bank",
            "verified": true
        ])
        XCTAssertEqual(n.title, "OTP from HDFC Bank")
    }

    func testDefaultsMatchDartClient() {
        let n = RelayNotification.fromPayload([:])
        XCTAssertEqual(n.title, "OTP from Unknown sender")
        XCTAssertEqual(n.body, "??????")
        XCTAssertEqual(n.code, "??????")
    }

    func testRendersForwardingConfirmation() {
        let n = RelayNotification.fromPayload([
            "type": "forward_confirm",
            "code": "816235124",
            "url": "https://mail.google.com/mail/vf-abc",
            "sender": "forwarding-noreply@google.com",
            "forwarding_from": "someone@example.com"
        ])
        XCTAssertEqual(n.title, "Email forwarding confirmation")
        XCTAssertTrue(n.body.contains("Forwarding from someone@example.com"))
        XCTAssertTrue(n.body.contains("Code: 816235124"))
        XCTAssertTrue(n.body.contains("https://mail.google.com/mail/vf-abc"))
        XCTAssertEqual(n.code, "816235124")
        XCTAssertEqual(n.url?.absoluteString, "https://mail.google.com/mail/vf-abc")
    }

    func testConfirmationUrlAllowlist() {
        let allowed = [
            "https://mail.google.com/mail/vf-abc",
            "https://mail-settings.google.com/mail/vf-123"
        ]
        for url in allowed {
            XCTAssertNotNil(RelayNotification.confirmationUri(url), "Should allow \(url)")
        }

        let disallowed = [
            "http://mail.google.com/mail/vf-abc",
            "https://evil.example/mail.google.com",
            "https://mail.google.com.example.com/vf-abc",
            "https://user@mail.google.com/vf-abc",
            "https://mail.google.com:8443/vf-abc",
            "javascript:alert(1)",
            "not a url"
        ]
        for url in disallowed {
            XCTAssertNil(RelayNotification.confirmationUri(url), "Should reject \(url)")
        }
    }
}
