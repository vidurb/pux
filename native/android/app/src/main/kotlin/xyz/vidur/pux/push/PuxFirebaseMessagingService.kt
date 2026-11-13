package xyz.vidur.pux.push

import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import xyz.vidur.pux.PuxApplication
import xyz.vidur.pux.crypto.PuxCrypto
import xyz.vidur.pux.model.RelayNotification

/**
 * Handles incoming FCM data messages from pux server and token refresh events.
 */
class PuxFirebaseMessagingService : FirebaseMessagingService() {

    override fun onMessageReceived(remoteMessage: RemoteMessage) {
        super.onMessageReceived(remoteMessage)

        val data = remoteMessage.data
        val ciphertext = data["ciphertext"]
        if (ciphertext.isNullOrEmpty()) {
            Log.d(TAG, "Ignoring push message without ciphertext")
            return
        }

        val app = application as? PuxApplication ?: return
        val recordStore = app.recordStore
        val privateKey = recordStore.privateKey()
        val publicKey = recordStore.publicKey()

        if (privateKey.isNullOrEmpty() || publicKey.isNullOrEmpty()) {
            Log.w(TAG, "Received message but device is not enrolled")
            return
        }

        try {
            val jsonPayload = PuxCrypto.openSealed(
                ciphertextB64 = ciphertext,
                publicKeyB64 = publicKey,
                privateKeyB64 = privateKey
            )
            val notification = RelayNotification.fromPayload(jsonPayload)
            NotificationHelper.getInstance(this).showNotification(notification)
            Log.i(TAG, "Successfully decrypted and posted push notification")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to decrypt push payload: ${e.message}", e)
            app.deliveryController.reportUndecryptable()
        }
    }

    override fun onRegistered(installationId: String) {
        super.onRegistered(installationId)
        Log.i(TAG, "FCM onRegistered")
        val app = application as? PuxApplication ?: return
        app.deliveryController.onRegistered(installationId)
    }

    override fun onUnregistered(installationId: String) {
        super.onUnregistered(installationId)
        Log.i(TAG, "FCM onUnregistered")
        val app = application as? PuxApplication ?: return
        app.deliveryController.onUnregistered(installationId)
    }

    @Suppress("DEPRECATION")
    @Deprecated("Superseded by onRegistered in firebase-messaging 26.0.0+")
    override fun onNewToken(token: String) {
        super.onNewToken(token)
        Log.i(TAG, "FCM token refreshed.")
        val app = application as? PuxApplication ?: return
        app.deliveryController.start()
    }

    companion object {
        private const val TAG = "PuxFCM"
    }
}
