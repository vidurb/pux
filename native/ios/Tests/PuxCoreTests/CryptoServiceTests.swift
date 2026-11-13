import XCTest
@testable import PuxCore

final class CryptoServiceTests: XCTestCase {
    // Official test fixtures from server and Flutter client tests
    private let fixturePublicKey = "oVaRfoaaBI7h10MCUauxYiPWaLQaAjN_oklwaOO682M"
    private let fixturePrivateKey = "3h7LhAw9e7EtYS5TeRJsQqYI8v4LtpH49buqnScv9qU"
    private let fixtureCiphertext =
        "-h4t5FOku-OWtLBcg4jo8jCNDVhdUtGyVWDk4z_FmFAI46lEoMhWZkF76pcW6lcgJI9UJ8a8JQM-"
        + "K3WA0vt7dXtlqXAKJwQfJ17REgKjSEVqOSjmmBpTmUcPtt_qHLCpMdk"

    private let serverPrPublicKey = "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw"
    private let serverPrSecretKey = "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI"
    private let serverPrCiphertext =
        "Xso7kEp1NhYtxtQC5hMfioNb2Q3_Y3KadFsVXxDtJRJ3KVUY_KqedKRIW-w4kMKf8SHpQ3FYbIJ7T8cM5LM-"
        + "tCLJrk6Dyqe1J60Fu13SM6Ci1fISV_VAN9fI0WxPAdzUOBLSqhoVNlmvDg60KTX6k-ubO7gtRDmh8Jit8g3O"
        + "MYhKV_KLn45FJKGjqF5ERXM6cmyCouvd2feDRw"

    func testOpensServerSealedBox() throws {
        let payload = try CryptoService.shared.openSealed(
            ciphertextB64: fixtureCiphertext,
            publicKeyB64: fixturePublicKey,
            privateKeyB64: fixturePrivateKey
        )

        XCTAssertEqual(payload["type"] as? String, "otp")
        XCTAssertEqual(payload["otp"] as? String, "482913")
        XCTAssertEqual(payload["sender"] as? String, "HDFC Bank")
    }

    func testOpensTypedPayloadFixtureFromServer() throws {
        let payload = try CryptoService.shared.openSealed(
            ciphertextB64: serverPrCiphertext,
            publicKeyB64: serverPrPublicKey,
            privateKeyB64: serverPrSecretKey
        )

        XCTAssertEqual(payload["type"] as? String, "otp")
        XCTAssertEqual(payload["otp"] as? String, "123456")
        XCTAssertEqual(payload["sender"] as? String, "Test Bank")
        XCTAssertEqual(payload["received_at"] as? String, "2026-10-06T00:00:00Z")
        XCTAssertEqual(payload["parser"] as? String, "generic")
    }

    func testRejectsWrongKeyAndGarbage() {
        XCTAssertThrowsError(
            try CryptoService.shared.openSealed(
                ciphertextB64: fixtureCiphertext,
                publicKeyB64: fixturePrivateKey,
                privateKeyB64: fixturePrivateKey
            )
        )

        XCTAssertThrowsError(
            try CryptoService.shared.openSealed(
                ciphertextB64: "not valid base64!",
                publicKeyB64: fixturePublicKey,
                privateKeyB64: fixturePrivateKey
            )
        )

        XCTAssertThrowsError(
            try CryptoService.shared.openSealed(
                ciphertextB64: fixtureCiphertext,
                publicKeyB64: "AAAA",
                privateKeyB64: fixturePrivateKey
            )
        )
    }

    func testGeneratesValidKeypairsAndRoundtrips() throws {
        let keyPair = try CryptoService.shared.generateKeyPair()
        XCTAssertFalse(keyPair.publicKey.contains("="))
        XCTAssertFalse(keyPair.privateKey.contains("="))

        let pubData = try Base64URL.decodeKey(keyPair.publicKey)
        let privData = try Base64URL.decodeKey(keyPair.privateKey)
        XCTAssertEqual(pubData.count, 32)
        XCTAssertEqual(privData.count, 32)

        let message = try JSONSerialization.data(withJSONObject: ["otp": "987654", "sender": "Roundtrip Bank"])
        let sealed = try CryptoService.shared.seal(message: message, recipientPublicKeyB64: keyPair.publicKey)

        let opened = try CryptoService.shared.openSealed(
            ciphertextB64: sealed,
            publicKeyB64: keyPair.publicKey,
            privateKeyB64: keyPair.privateKey
        )
        XCTAssertEqual(opened["otp"] as? String, "987654")
        XCTAssertEqual(opened["sender"] as? String, "Roundtrip Bank")
    }
}
