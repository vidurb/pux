package xyz.vidur.pux.crypto

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.json.JSONObject

class PuxCryptoTest {

    // Fixture from server test/pux/crypto_test.exs and mobile/test/crypto_service_test.dart
    private val serverPrPublicKey = "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw"
    private val serverPrSecretKey = "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI"
    private val serverPrCiphertext =
        "Xso7kEp1NhYtxtQC5hMfioNb2Q3_Y3KadFsVXxDtJRJ3KVUY_KqedKRIW-w4kMKf8SHpQ3FYbIJ7T8cM5LM-" +
        "tCLJrk6Dyqe1J60Fu13SM6Ci1fISV_VAN9fI0WxPAdzUOBLSqhoVNlmvDg60KTX6k-ubO7gtRDmh8Jit8g3O" +
        "MYhKV_KLn45FJKGjqF5ERXM6cmyCouvd2feDRw"

    // Fixture from mobile/test/crypto_service_test.dart
    private val mobileFixturePublicKey = "oVaRfoaaBI7h10MCUauxYiPWaLQaAjN_oklwaOO682M"
    private val mobileFixturePrivateKey = "3h7LhAw9e7EtYS5TeRJsQqYI8v4LtpH49buqnScv9qU"
    private val mobileFixtureCiphertext =
        "-h4t5FOku-OWtLBcg4jo8jCNDVhdUtGyVWDk4z_FmFAI46lEoMhWZkF76pcW6lcgJI9UJ8a8JQM-" +
        "K3WA0vt7dXtlqXAKJwQfJ17REgKjSEVqOSjmmBpTmUcPtt_qHLCpMdk"

    @Test
    fun opensServerTypedPayloadFixture() {
        val payload = PuxCrypto.openSealed(
            ciphertextB64 = serverPrCiphertext,
            publicKeyB64 = serverPrPublicKey,
            privateKeyB64 = serverPrSecretKey
        )

        assertEquals("otp", payload.getString("type"))
        assertEquals("123456", payload.getString("otp"))
        assertEquals("Test Bank", payload.getString("sender"))
        assertEquals("2026-10-06T00:00:00Z", payload.getString("received_at"))
        assertEquals("generic", payload.getString("parser"))
    }

    @Test
    fun opensMobileHdfcFixture() {
        val payload = PuxCrypto.openSealed(
            ciphertextB64 = mobileFixtureCiphertext,
            publicKeyB64 = mobileFixturePublicKey,
            privateKeyB64 = mobileFixturePrivateKey
        )

        assertEquals("otp", payload.getString("type"))
        assertEquals("482913", payload.getString("otp"))
        assertEquals("HDFC Bank", payload.getString("sender"))
    }

    @Test
    fun generatedKeyPairsAre32BytesUnpaddedBase64Url() {
        val keyPair = PuxCrypto.generateKeyPair()

        assertFalse(keyPair.publicKeyB64.contains("="))
        assertFalse(keyPair.privateKeyB64.contains("="))
        assertEquals(32, keyPair.publicKeyBytes.size)
        assertEquals(32, keyPair.privateKeyBytes.size)
        assertEquals(32, PuxCrypto.decodeBase64Url(keyPair.publicKeyB64).size)
        assertEquals(32, PuxCrypto.decodeBase64Url(keyPair.privateKeyB64).size)
    }

    @Test
    fun sealAndOpenSealedRoundtrip() {
        val keyPair = PuxCrypto.generateKeyPair()
        val originalJson = """{"type":"otp","otp":"654321","sender":"Roundtrip Test Bank"}"""

        val sealedBytes = PuxCrypto.seal(
            message = originalJson.toByteArray(Charsets.UTF_8),
            recipientPkBytes = keyPair.publicKeyBytes
        )
        val sealedB64 = PuxCrypto.encodeBase64Url(sealedBytes)

        val decrypted = PuxCrypto.openSealed(
            ciphertextB64 = sealedB64,
            publicKeyB64 = keyPair.publicKeyB64,
            privateKeyB64 = keyPair.privateKeyB64
        )

        assertEquals("otp", decrypted.getString("type"))
        assertEquals("654321", decrypted.getString("otp"))
        assertEquals("Roundtrip Test Bank", decrypted.getString("sender"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsCiphertextSealedForDifferentKey() {
        val otherKeyPair = PuxCrypto.generateKeyPair()

        // Attempt to decrypt serverPrCiphertext using unrelated keys
        PuxCrypto.openSealed(
            ciphertextB64 = serverPrCiphertext,
            publicKeyB64 = otherKeyPair.publicKeyB64,
            privateKeyB64 = otherKeyPair.privateKeyB64
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsShortKey() {
        PuxCrypto.decodeKey("shortKey")
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsShortCiphertext() {
        val keyPair = PuxCrypto.generateKeyPair()
        PuxCrypto.openSealed(
            ciphertextB64 = PuxCrypto.encodeBase64Url(ByteArray(10)),
            publicKeyB64 = keyPair.publicKeyB64,
            privateKeyB64 = keyPair.privateKeyB64
        )
    }
}
