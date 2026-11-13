import XCTest
@testable import PuxCore

final class CryptoTests: PuxTestCase {
    // Sealed by the server's own `:enacl.box_seal/2` (unpadded base64url).
    private let fixturePublicKey = "oVaRfoaaBI7h10MCUauxYiPWaLQaAjN_oklwaOO682M"
    private let fixturePrivateKey = "3h7LhAw9e7EtYS5TeRJsQqYI8v4LtpH49buqnScv9qU"
    private let fixtureCiphertext =
        "-h4t5FOku-OWtLBcg4jo8jCNDVhdUtGyVWDk4z_FmFAI46lEoMhWZkF76pcW6lcgJI9UJ8a8JQM-" +
        "K3WA0vt7dXtlqXAKJwQfJ17REgKjSEVqOSjmmBpTmUcPtt_qHLCpMdk"

    // Fixture published with the server's typed-payload change (vidurb/pux#2).
    private let serverPrPublicKey = "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw"
    private let serverPrSecretKey = "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI"
    private let serverPrCiphertext =
        "Xso7kEp1NhYtxtQC5hMfioNb2Q3_Y3KadFsVXxDtJRJ3KVUY_KqedKRIW-w4kMKf8SHpQ3FYbIJ7T8cM5LM-" +
        "tCLJrk6Dyqe1J60Fu13SM6Ci1fISV_VAN9fI0WxPAdzUOBLSqhoVNlmvDg60KTX6k-ubO7gtRDmh8Jit8g3O" +
        "MYhKV_KLn45FJKGjqF5ERXM6cmyCouvd2feDRw"

    func testOpensSealedBoxProducedByServer() throws {
        let payload = try SodiumCrypto.shared.openSealed(
            ciphertextB64: fixtureCiphertext,
            publicKeyB64: fixturePublicKey,
            privateKeyB64: fixturePrivateKey
        )

        XCTAssertEqual(payload["type"] as? String, "otp")
        XCTAssertEqual(payload["otp"] as? String, "482913")
        XCTAssertEqual(payload["sender"] as? String, "HDFC Bank")
    }

    func testOpensTypedPayloadFixtureFromServer() throws {
        let payload = try SodiumCrypto.shared.openSealed(
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

    func testRejectsCiphertextSealedForDifferentKey() throws {
        let other = try SodiumCrypto.shared.generateKeyPair()

        XCTAssertThrowsError(
            try SodiumCrypto.shared.openSealed(
                ciphertextB64: fixtureCiphertext,
                publicKeyB64: other.publicKey,
                privateKeyB64: other.privateKey
            )
        )
    }

    func testGeneratedKeypairsAreUnpaddedBase64UrlAndRoundtrip() throws {
        let keys = try SodiumCrypto.shared.generateKeyPair()
        XCTAssertFalse(keys.publicKey.contains("="))
        XCTAssertFalse(keys.privateKey.contains("="))
        XCTAssertFalse(keys.publicKey.contains("+"))
        XCTAssertFalse(keys.publicKey.contains("/"))

        let pkData = Base64URL.decode(keys.publicKey)
        let skData = Base64URL.decode(keys.privateKey)
        XCTAssertEqual(pkData?.count, 32)
        XCTAssertEqual(skData?.count, 32)

        let message = "{\"otp\":\"654321\",\"sender\":\"NativeMacTest\"}".data(using: .utf8)!
        let sealedB64 = try SodiumCrypto.shared.seal(message: message, recipientPublicKeyB64: keys.publicKey)

        let decrypted = try SodiumCrypto.shared.openSealed(
            ciphertextB64: sealedB64,
            publicKeyB64: keys.publicKey,
            privateKeyB64: keys.privateKey
        )

        XCTAssertEqual(decrypted["otp"] as? String, "654321")
        XCTAssertEqual(decrypted["sender"] as? String, "NativeMacTest")
    }

    func testRejectsMalformedCiphertext() throws {
        XCTAssertThrowsError(
            try SodiumCrypto.shared.openSealed(
                ciphertextB64: "short",
                publicKeyB64: fixturePublicKey,
                privateKeyB64: fixturePrivateKey
            )
        )
    }

    func testRejectsInvalidKeyLength() throws {
        XCTAssertThrowsError(
            try SodiumCrypto.shared.openSealed(
                ciphertextB64: fixtureCiphertext,
                publicKeyB64: "AAAA",
                privateKeyB64: fixturePrivateKey
            )
        )
    }
}
