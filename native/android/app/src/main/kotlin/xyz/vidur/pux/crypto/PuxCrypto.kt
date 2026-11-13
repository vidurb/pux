package xyz.vidur.pux.crypto

import org.bouncycastle.crypto.digests.Blake2bDigest
import org.bouncycastle.crypto.engines.XSalsa20Engine
import org.bouncycastle.crypto.macs.Poly1305
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.crypto.params.ParametersWithIV
import org.bouncycastle.math.ec.rfc7748.X25519
import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import java.util.Arrays
import java.util.Base64
import org.json.JSONObject

/**
 * Libsodium sealed-box compatible cryptography.
 *
 * Implements wire-compatible Curve25519 keypair generation and sealed box
 * encryption/decryption matching the server's `:enacl.box_seal` and the Flutter
 * client's `CryptoService`.
 *
 * Wire formats:
 * - Public & private keys: 32 bytes, unpadded base64url.
 * - Ciphertext: unpadded base64url encoding of [ephemeral_pk (32 bytes) || MAC (16 bytes) || encrypted_payload].
 * - Plaintext: UTF-8 encoded JSON.
 */
object PuxCrypto {

    const val KEY_BYTES = 32
    const val EPHEMERAL_KEY_BYTES = 32
    const val MAC_BYTES = 16
    const val NONCE_BYTES = 24
    const val MIN_CIPHERTEXT_BYTES = EPHEMERAL_KEY_BYTES + MAC_BYTES // 48 bytes

    data class KeyPair(
        val publicKeyB64: String,
        val privateKeyB64: String,
        val publicKeyBytes: ByteArray,
        val privateKeyBytes: ByteArray
    ) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is KeyPair) return false
            return publicKeyB64 == other.publicKeyB64 && privateKeyB64 == other.privateKeyB64
        }

        override fun hashCode(): Int = 31 * publicKeyB64.hashCode() + privateKeyB64.hashCode()
    }

    /**
     * Generates a new Curve25519 keypair with unpadded base64url strings.
     */
    fun generateKeyPair(random: SecureRandom = SecureRandom()): KeyPair {
        val sk = ByteArray(KEY_BYTES)
        X25519.generatePrivateKey(random, sk)
        val pk = ByteArray(KEY_BYTES)
        X25519.generatePublicKey(sk, 0, pk, 0)
        return KeyPair(
            publicKeyB64 = encodeBase64Url(pk),
            privateKeyB64 = encodeBase64Url(sk),
            publicKeyBytes = pk,
            privateKeyBytes = sk
        )
    }

    /**
     * Opens a libsodium sealed box produced by the server (`:enacl.box_seal`),
     * with keys and ciphertext in unpadded base64url.
     */
    fun openSealed(
        ciphertextB64: String,
        publicKeyB64: String,
        privateKeyB64: String
    ): JSONObject {
        val pkBytes = decodeKey(publicKeyB64)
        val skBytes = decodeKey(privateKeyB64)
        val ciphertextBytes = decodeBase64Url(ciphertextB64)
        val plaintextBytes = openSealedBytes(ciphertextBytes, pkBytes, skBytes)
        val jsonStr = String(plaintextBytes, StandardCharsets.UTF_8)
        return JSONObject(jsonStr)
    }

    /**
     * Raw byte-level open sealed box.
     */
    fun openSealedBytes(
        ciphertext: ByteArray,
        recipientPk: ByteArray,
        recipientSk: ByteArray
    ): ByteArray {
        require(ciphertext.size >= MIN_CIPHERTEXT_BYTES) {
            "Ciphertext too short: expected at least $MIN_CIPHERTEXT_BYTES bytes, got ${ciphertext.size}"
        }
        require(recipientPk.size == KEY_BYTES) { "Invalid recipient public key length" }
        require(recipientSk.size == KEY_BYTES) { "Invalid recipient secret key length" }

        val epk = Arrays.copyOfRange(ciphertext, 0, EPHEMERAL_KEY_BYTES)
        val boxCiphertext = Arrays.copyOfRange(ciphertext, EPHEMERAL_KEY_BYTES, ciphertext.size)

        // Nonce = Blake2b-24(epk || pk)
        val nonce = computeNonce(epk, recipientPk)

        // Shared secret q = X25519(sk, epk)
        val q = ByteArray(KEY_BYTES)
        X25519.scalarMult(recipientSk, 0, epk, 0, q, 0)

        // k = hsalsa20(q, 0_16)
        val k = hsalsa20(q, ByteArray(16))

        val mac = Arrays.copyOfRange(boxCiphertext, 0, MAC_BYTES)
        val payload = Arrays.copyOfRange(boxCiphertext, MAC_BYTES, boxCiphertext.size)

        val engine = XSalsa20Engine()
        engine.init(false, ParametersWithIV(KeyParameter(k), nonce))

        // First 32 bytes of XSalsa20(k, nonce) is the one-time Poly1305 key
        val polyKey = ByteArray(32)
        engine.processBytes(ByteArray(32), 0, 32, polyKey, 0)

        // Verify Poly1305 MAC over payload
        val poly = Poly1305()
        poly.init(KeyParameter(polyKey))
        poly.update(payload, 0, payload.size)
        val computedMac = ByteArray(MAC_BYTES)
        poly.doFinal(computedMac, 0)

        if (!java.security.MessageDigest.isEqual(mac, computedMac)) {
            throw IllegalArgumentException("MAC verification failed: ciphertext is invalid or sealed for another key")
        }

        // Decrypt payload
        val plaintext = ByteArray(payload.size)
        engine.processBytes(payload, 0, payload.size, plaintext, 0)
        return plaintext
    }

    /**
     * Seals a message with a recipient's public key (libsodium crypto_box_seal).
     */
    fun seal(
        message: ByteArray,
        recipientPkBytes: ByteArray,
        random: SecureRandom = SecureRandom()
    ): ByteArray {
        require(recipientPkBytes.size == KEY_BYTES) { "Invalid recipient public key length" }

        val esk = ByteArray(KEY_BYTES)
        X25519.generatePrivateKey(random, esk)
        val epk = ByteArray(KEY_BYTES)
        X25519.generatePublicKey(esk, 0, epk, 0)

        val nonce = computeNonce(epk, recipientPkBytes)

        val q = ByteArray(KEY_BYTES)
        X25519.scalarMult(esk, 0, recipientPkBytes, 0, q, 0)
        val k = hsalsa20(q, ByteArray(16))

        val engine = XSalsa20Engine()
        engine.init(true, ParametersWithIV(KeyParameter(k), nonce))

        val polyKey = ByteArray(32)
        engine.processBytes(ByteArray(32), 0, 32, polyKey, 0)

        val ciphertext = ByteArray(message.size)
        engine.processBytes(message, 0, message.size, ciphertext, 0)

        val poly = Poly1305()
        poly.init(KeyParameter(polyKey))
        poly.update(ciphertext, 0, ciphertext.size)
        val mac = ByteArray(MAC_BYTES)
        poly.doFinal(mac, 0)

        val result = ByteArray(EPHEMERAL_KEY_BYTES + MAC_BYTES + ciphertext.size)
        System.arraycopy(epk, 0, result, 0, EPHEMERAL_KEY_BYTES)
        System.arraycopy(mac, 0, result, EPHEMERAL_KEY_BYTES, MAC_BYTES)
        System.arraycopy(ciphertext, 0, result, EPHEMERAL_KEY_BYTES + MAC_BYTES, ciphertext.size)
        return result
    }

    fun decodeKey(b64: String): ByteArray {
        val decoded = decodeBase64Url(b64)
        if (decoded.size != KEY_BYTES) {
            throw IllegalArgumentException("Invalid key length: expected $KEY_BYTES bytes, got ${decoded.size}")
        }
        return decoded
    }

    fun encodeBase64Url(bytes: ByteArray): String {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }

    fun decodeBase64Url(value: String): ByteArray {
        val trimmed = value.trim()
        val mod = trimmed.length % 4
        val padded = if (mod == 0) trimmed else trimmed + "=".repeat(4 - mod)
        return Base64.getUrlDecoder().decode(padded)
    }

    private fun computeNonce(epk: ByteArray, pk: ByteArray): ByteArray {
        val blake2b = Blake2bDigest(NONCE_BYTES * 8)
        blake2b.update(epk, 0, epk.size)
        blake2b.update(pk, 0, pk.size)
        val nonce = ByteArray(NONCE_BYTES)
        blake2b.doFinal(nonce, 0)
        return nonce
    }

    private fun rotl(x: Int, b: Int): Int = (x shl b) or (x ushr (32 - b))

    private fun load32(x: ByteArray, offset: Int): Int =
        (x[offset].toInt() and 0xff) or
        ((x[offset + 1].toInt() and 0xff) shl 8) or
        ((x[offset + 2].toInt() and 0xff) shl 16) or
        ((x[offset + 3].toInt() and 0xff) shl 24)

    private fun store32(x: ByteArray, offset: Int, u: Int) {
        x[offset] = u.toByte()
        x[offset + 1] = (u ushr 8).toByte()
        x[offset + 2] = (u ushr 16).toByte()
        x[offset + 3] = (u ushr 24).toByte()
    }

    /**
     * crypto_core_hsalsa20
     */
    fun hsalsa20(inKey: ByteArray, inNonce: ByteArray): ByteArray {
        val x = IntArray(16)
        x[0] = 0x61707865
        x[1] = load32(inKey, 0)
        x[2] = load32(inKey, 4)
        x[3] = load32(inKey, 8)
        x[4] = load32(inKey, 12)
        x[5] = 0x3320646e
        x[6] = load32(inNonce, 0)
        x[7] = load32(inNonce, 4)
        x[8] = load32(inNonce, 8)
        x[9] = load32(inNonce, 12)
        x[10] = 0x79622d32
        x[11] = load32(inKey, 16)
        x[12] = load32(inKey, 20)
        x[13] = load32(inKey, 24)
        x[14] = load32(inKey, 28)
        x[15] = 0x6b206574

        var i = 0
        while (i < 20) {
            x[4] = x[4] xor rotl(x[0] + x[12], 7)
            x[8] = x[8] xor rotl(x[4] + x[0], 9)
            x[12] = x[12] xor rotl(x[8] + x[4], 13)
            x[0] = x[0] xor rotl(x[12] + x[8], 18)

            x[9] = x[9] xor rotl(x[5] + x[1], 7)
            x[13] = x[13] xor rotl(x[9] + x[5], 9)
            x[1] = x[1] xor rotl(x[13] + x[9], 13)
            x[5] = x[5] xor rotl(x[1] + x[13], 18)

            x[14] = x[14] xor rotl(x[10] + x[6], 7)
            x[2] = x[2] xor rotl(x[14] + x[10], 9)
            x[6] = x[6] xor rotl(x[2] + x[14], 13)
            x[10] = x[10] xor rotl(x[6] + x[2], 18)

            x[3] = x[3] xor rotl(x[15] + x[11], 7)
            x[7] = x[7] xor rotl(x[3] + x[15], 9)
            x[11] = x[11] xor rotl(x[7] + x[3], 13)
            x[15] = x[15] xor rotl(x[11] + x[7], 18)

            x[1] = x[1] xor rotl(x[0] + x[3], 7)
            x[2] = x[2] xor rotl(x[1] + x[0], 9)
            x[3] = x[3] xor rotl(x[2] + x[1], 13)
            x[0] = x[0] xor rotl(x[3] + x[2], 18)

            x[6] = x[6] xor rotl(x[5] + x[4], 7)
            x[7] = x[7] xor rotl(x[6] + x[5], 9)
            x[4] = x[4] xor rotl(x[7] + x[6], 13)
            x[5] = x[5] xor rotl(x[4] + x[7], 18)

            x[11] = x[11] xor rotl(x[10] + x[9], 7)
            x[8] = x[8] xor rotl(x[11] + x[10], 9)
            x[9] = x[9] xor rotl(x[8] + x[11], 13)
            x[10] = x[10] xor rotl(x[9] + x[8], 18)

            x[12] = x[12] xor rotl(x[15] + x[14], 7)
            x[13] = x[13] xor rotl(x[12] + x[15], 9)
            x[14] = x[14] xor rotl(x[13] + x[12], 13)
            x[15] = x[15] xor rotl(x[14] + x[13], 18)

            i += 2
        }

        val out = ByteArray(32)
        store32(out, 0, x[0])
        store32(out, 4, x[5])
        store32(out, 8, x[10])
        store32(out, 12, x[15])
        store32(out, 16, x[6])
        store32(out, 20, x[7])
        store32(out, 24, x[8])
        store32(out, 28, x[9])
        return out
    }
}
