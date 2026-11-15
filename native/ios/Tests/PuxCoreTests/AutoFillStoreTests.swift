import XCTest
@testable import PuxCore

final class AutoFillStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func payload(at date: Date, code: String = "012345", verified: Bool = true) -> [String: Any] {
        ["type": "otp", "otp": code, "sender": "Test Bank", "sender_domain": "mail.bank.example",
         "verified": verified, "received_at": ISO8601DateFormatter().string(from: date)]
    }

    private func fixture() throws -> (AutoFillStore, InMemoryPuxKeychainBackend, String) {
        let backend = InMemoryPuxKeychainBackend()
        let keys = try CryptoService.shared.generateKeyPair()
        backend.write("record_id", value: "test-relay")
        backend.write("public_key", value: keys.publicKey)
        backend.write("private_key", value: keys.privateKey)
        return (AutoFillStore(backend: backend), backend, keys.publicKey)
    }

    private func seal(_ payload: [String: Any], publicKey: String) throws -> String {
        try CryptoService.shared.seal(
            message: JSONSerialization.data(withJSONObject: payload), recipientPublicKeyB64: publicKey
        )
    }

    func testExpiryUsesServerTimestampAndRejectsFutureOrMissingTimestamp() {
        XCTAssertNotNil(AutoFillCode(payload: payload(at: now.addingTimeInterval(-299)), now: now))
        XCTAssertNil(AutoFillCode(payload: payload(at: now.addingTimeInterval(-300)), now: now))
        XCTAssertNil(AutoFillCode(payload: payload(at: now.addingTimeInterval(1)), now: now))
        var value = payload(at: now)
        value.removeValue(forKey: "received_at")
        XCTAssertNil(AutoFillCode(payload: value, now: now))
        value["received_at"] = "invalid"
        XCTAssertNil(AutoFillCode(payload: value, now: now))
        value["received_at"] = "2027-01-15T08:00:00.123456Z"
        XCTAssertNotNil(AutoFillCode(payload: value, now: now.addingTimeInterval(1)))
    }

    func testRejectsConfirmationsAndMalformedCodes() {
        var value = payload(at: now)
        value["type"] = "forward_confirm"
        XCTAssertNil(AutoFillCode(payload: value, now: now))
        for code in ["", "123", "1234567890123", "??????", "１２３４５６", "123 456", "abc123"] {
            XCTAssertNil(AutoFillCode(payload: payload(at: now, code: code), now: now))
        }
    }

    func testRequiresOptInAndStoresCiphertextWithoutCode() throws {
        let (store, backend, key) = try fixture()
        let value = payload(at: now)
        let cipher = try seal(value, publicKey: key)
        XCTAssertFalse(store.capture(ciphertext: cipher, payload: value, now: now))
        XCTAssertTrue(store.configure(enabled: true, mapping: nil))
        XCTAssertTrue(store.capture(ciphertext: cipher, payload: value, now: now))
        XCTAssertEqual(store.latest(now: now)?.code, "012345")
        guard case .found(let raw) = backend.readStatus(AutoFillStore.envelopeKey) else {
            return XCTFail("Missing envelope")
        }
        let envelope = try JSONDecoder().decode([String: String].self, from: Data(raw.utf8))
        XCTAssertEqual(Set(envelope.keys), ["ciphertext", "record_id"])
        XCTAssertEqual(envelope["ciphertext"], cipher)
        XCTAssertNil(store.latest(now: now.addingTimeInterval(300)))
    }

    func testDelayedPushDoesNotReplaceNewerCodeAndConfirmationIsIgnored() throws {
        let (store, _, key) = try fixture()
        XCTAssertTrue(store.configure(enabled: true, mapping: nil))
        let newest = payload(at: now, code: "222222")
        XCTAssertTrue(store.capture(ciphertext: try seal(newest, publicKey: key), payload: newest, now: now))
        let older = payload(at: now.addingTimeInterval(-10), code: "111111")
        XCTAssertFalse(store.capture(ciphertext: try seal(older, publicKey: key), payload: older, now: now))
        var confirmation = payload(at: now)
        confirmation["type"] = "forward_confirm"
        XCTAssertFalse(store.capture(ciphertext: "unused", payload: confirmation, now: now))
        XCTAssertEqual(store.latest(now: now)?.code, "222222")
    }

    func testDisableRemovalAndDifferentEnrollmentCannotFillOldCode() throws {
        let (store, backend, key) = try fixture()
        let value = payload(at: now)
        let cipher = try seal(value, publicKey: key)
        XCTAssertTrue(store.configure(enabled: true, mapping: nil))
        XCTAssertTrue(store.capture(ciphertext: cipher, payload: value, now: now))
        backend.write("record_id", value: "different-relay")
        XCTAssertNil(store.latest(now: now))
        backend.write("record_id", value: "test-relay")
        backend.delete("private_key")
        XCTAssertNil(store.latest(now: now))
        XCTAssertTrue(store.configure(enabled: false, mapping: nil))
        XCTAssertNil(store.latest(now: now))
        XCTAssertEqual(backend.readStatus(AutoFillStore.envelopeKey), .missing)
        backend.deleteAll()
        XCTAssertFalse(store.isEnabled)
    }

    func testMappingRequiresExactVerifiedSenderAndValidDomains() throws {
        let mapping = try XCTUnwrap(AutoFillMapping(senderDomain: " MAIL.Bank.Example ", websiteDomain: "checkout.example"))
        XCTAssertEqual(mapping.senderDomain, "mail.bank.example")
        XCTAssertTrue(mapping.matches(try XCTUnwrap(AutoFillCode(payload: payload(at: now), now: now))))
        XCTAssertFalse(mapping.matches(try XCTUnwrap(AutoFillCode(payload: payload(at: now, verified: false), now: now))))
        var value = payload(at: now)
        value["sender_domain"] = "evilmail.bank.example"
        XCTAssertFalse(mapping.matches(try XCTUnwrap(AutoFillCode(payload: value, now: now))))
        for domain in ["https://bank.example", "bank.example/path", "me@bank.example", "-bank.example", "bank..example", "bank.example:443"] {
            XCTAssertNil(AutoFillMapping(senderDomain: domain, websiteDomain: "checkout.example"))
        }
        let (store, _, _) = try fixture()
        XCTAssertTrue(store.configure(enabled: true, mapping: mapping))
        XCTAssertEqual(store.mapping, mapping)
    }

    func testCorruptEnvelopeAndWrongKeyFailClosed() throws {
        let (store, backend, key) = try fixture()
        XCTAssertTrue(store.configure(enabled: true, mapping: nil))
        backend.write(AutoFillStore.envelopeKey, value: "corrupt")
        XCTAssertNil(store.latest(now: now))
        let value = payload(at: now)
        XCTAssertTrue(store.capture(ciphertext: try seal(value, publicKey: key), payload: value, now: now))
        backend.write("private_key", value: try CryptoService.shared.generateKeyPair().privateKey)
        XCTAssertNil(store.latest(now: now))
    }
}
