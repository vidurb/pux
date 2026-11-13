import XCTest
@testable import PuxCore

final class NotificationPayloadTests: PuxTestCase {
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

    func testTreatsPayloadsWithoutTypeAsOtp() {
        let n = RelayNotification.fromPayload([
            "otp": "123456",
            "sender": "ICICI"
        ])
        XCTAssertEqual(n.title, "OTP from ICICI")
        XCTAssertEqual(n.code, "123456")
        XCTAssertNil(n.url)
    }

    func testMarksUnverifiedSenders() {
        let n = RelayNotification.fromPayload([
            "type": "otp",
            "otp": "482913",
            "sender": "hdfcbank.example",
            "verified": false
        ])
        XCTAssertEqual(n.title, "OTP from hdfcbank.example (unverified)")
        XCTAssertEqual(n.code, "482913")
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

    func testPayloadsWithoutVerifiedCarryNoMarker() {
        let n = RelayNotification.fromPayload([
            "type": "otp",
            "otp": "1",
            "sender": "ICICI"
        ])
        XCTAssertEqual(n.title, "OTP from ICICI")
    }

    func testRendersForwardingConfirmation() {
        let n = RelayNotification.fromPayload([
            "type": "forward_confirm",
            "code": "816235124",
            "url": "https://mail.google.com/mail/vf-abc",
            "sender": "forwarding-noreply@google.com"
        ])
        XCTAssertEqual(n.title, "Email forwarding confirmation")
        XCTAssertTrue(n.body.contains("Code: 816235124"))
        XCTAssertTrue(n.body.contains("https://mail.google.com/mail/vf-abc"))
        XCTAssertEqual(n.code, "816235124")
        XCTAssertEqual(n.url, URL(string: "https://mail.google.com/mail/vf-abc"))
    }

    func testForwardingConfirmationNamesForwardingAccount() {
        let n = RelayNotification.fromPayload([
            "type": "forward_confirm",
            "url": "https://mail-settings.google.com/mail/vf-abc",
            "sender": "Gmail",
            "forwarding_from": "someone@gmail.com"
        ])
        XCTAssertTrue(n.body.contains("Forwarding from someone@gmail.com"))
        XCTAssertTrue(n.body.contains("https://mail-settings.google.com/mail/vf-abc"))
        XCTAssertNil(n.code)
    }

    func testForwardingConfirmationWithoutCodeHasNoCode() {
        let n = RelayNotification.fromPayload([
            "type": "forward_confirm",
            "url": "https://example.test/confirm"
        ])
        XCTAssertNil(n.code)
        XCTAssertTrue(n.body.contains("https://example.test/confirm"))
        XCTAssertNil(n.url)
    }

    func testConfirmationUriOnlyAllowsHttpsGmail() {
        for valid in [
            "https://mail.google.com/mail/vf-abc",
            "https://mail-settings.google.com/mail/vf-%5BANGjdJ8%5D-abc"
        ] {
            XCTAssertEqual(RelayNotification.confirmationUri(valid), URL(string: valid))
        }

        for bad in [
            "http://mail.google.com/mail/vf-abc",
            "https://mail.google.com.evil.test/vf-abc",
            "https://evil.test/mail.google.com",
            "https://user@mail.google.com/vf-abc",
            "https://mail.google.com:8443/vf-abc",
            "javascript:alert(1)",
            "not a url"
        ] {
            XCTAssertNil(RelayNotification.confirmationUri(bad), "Expected nil for \(bad)")
        }
    }
}
