package xyz.vidur.pux.storage

import android.util.Base64
import java.nio.charset.StandardCharsets
import java.security.Key
import java.security.SecureRandom
import java.util.Arrays
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.spec.GCMParameterSpec

/** Writes Flutter secure-storage v11 AES-GCM value blobs (IV + ciphertext, Base64.DEFAULT). */
object FlutterSecureStorageFixture {
    const val GCM_IV_SIZE = 12
    const val GCM_TAG_SIZE = 128

    fun generateAesKey(): Key {
        val generator = KeyGenerator.getInstance("AES")
        generator.init(256)
        return generator.generateKey()
    }

    fun encrypt(plaintext: String, aesKey: Key): String {
        val iv = ByteArray(GCM_IV_SIZE)
        SecureRandom().nextBytes(iv)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, aesKey, GCMParameterSpec(GCM_TAG_SIZE, iv))
        val ciphertext = cipher.doFinal(plaintext.toByteArray(StandardCharsets.UTF_8))
        val combined = Arrays.copyOf(iv, iv.size + ciphertext.size)
        System.arraycopy(ciphertext, 0, combined, iv.size, ciphertext.size)
        return Base64.encodeToString(combined, Base64.DEFAULT)
    }
}
