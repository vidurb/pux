package xyz.vidur.pux.storage

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import xyz.vidur.pux.crypto.PuxCrypto
import xyz.vidur.pux.testutil.FakeSharedPreferences

class RecordStoreTest {

    private lateinit var store: RecordStore

    @Before
    fun setUp() {
        val prefs = FakeSharedPreferences()
        store = RecordStore(prefs, defaultServerUrl = "https://pux.vidur.xyz")
    }

    @Test
    fun isNotEnrolledInitially() {
        assertFalse(store.isEnrolled())
        assertNull(store.recordId())
        assertNull(store.publicKey())
        assertNull(store.privateKey())
        assertNull(store.inbox())
    }

    @Test
    fun savesAndLoadsValidEnrollment() {
        val keys = PuxCrypto.generateKeyPair()
        val recordId = "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d"
        val inbox = "test-inbox-123@pux.vidur.xyz"

        val payload = mapOf(
            "v" to 1,
            "record_id" to recordId,
            "public_key" to keys.publicKeyB64,
            "private_key" to keys.privateKeyB64,
            "inbox" to inbox,
            "server" to "https://pux.vidur.xyz"
        )

        store.saveEnrollment(payload)

        assertTrue(store.isEnrolled())
        assertEquals(recordId, store.recordId())
        assertEquals(keys.publicKeyB64, store.publicKey())
        assertEquals(keys.privateKeyB64, store.privateKey())
        assertEquals(inbox, store.inbox())
        assertEquals("https://pux.vidur.xyz", store.serverUrl)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsInvalidUuid() {
        val keys = PuxCrypto.generateKeyPair()
        val payload = mapOf(
            "v" to 1,
            "record_id" to "not-a-valid-uuid",
            "public_key" to keys.publicKeyB64,
            "private_key" to keys.privateKeyB64,
            "inbox" to "inbox@example.com"
        )
        store.saveEnrollment(payload)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsInsecureServerUrl() {
        val keys = PuxCrypto.generateKeyPair()
        val payload = mapOf(
            "v" to 1,
            "record_id" to "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d",
            "public_key" to keys.publicKeyB64,
            "private_key" to keys.privateKeyB64,
            "inbox" to "inbox@example.com",
            "server" to "http://insecure.example.com"
        )
        store.saveEnrollment(payload)
    }

    @Test
    fun allowsLocalDevelopmentHttpServers() {
        assertEquals("http://localhost:4000", RecordStore.validateServerUrl("http://localhost:4000/"))
        assertEquals("http://127.0.0.1:4000", RecordStore.validateServerUrl("http://127.0.0.1:4000"))
        assertEquals("http://10.0.2.2:4000", RecordStore.validateServerUrl("http://10.0.2.2:4000/"))
    }

    @Test
    fun stripsTrailingSlashFromHttpsServer() {
        assertEquals("https://relay.example.com", RecordStore.validateServerUrl("https://relay.example.com/"))
        assertEquals("https://relay.example.com:8443", RecordStore.validateServerUrl("https://relay.example.com:8443/"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsServerUrlWithPathOrQuery() {
        RecordStore.validateServerUrl("https://relay.example.com/some/path")
    }

    @Test
    fun clearPreservesNotificationPermissionAsked() {
        store.saveNotificationPermissionAsked()
        assertTrue(store.notificationPermissionAsked())

        val keys = PuxCrypto.generateKeyPair()
        store.saveEnrollment(mapOf(
            "record_id" to "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d",
            "public_key" to keys.publicKeyB64,
            "private_key" to keys.privateKeyB64,
            "inbox" to "inbox@example.com"
        ))
        assertTrue(store.isEnrolled())

        store.clear()

        assertFalse(store.isEnrolled())
        assertNull(store.recordId())
        assertTrue("Notification permission asked must be preserved across clear", store.notificationPermissionAsked())
    }

    @Test
    fun parseQrValidatesAndParsesSuccessfully() {
        val keys = PuxCrypto.generateKeyPair()
        val rawJson = """
            {
                "v": 1,
                "record_id": "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d",
                "public_key": "${keys.publicKeyB64}",
                "private_key": "${keys.privateKeyB64}",
                "inbox": "inbox@example.com",
                "server": "https://custom.server.com"
            }
        """.trimIndent()

        val parsed = store.parseQr(rawJson)
        assertEquals("a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d", parsed["record_id"])
        assertEquals(keys.publicKeyB64, parsed["public_key"])
        assertEquals("https://custom.server.com", parsed["server"])
    }

    @Test(expected = IllegalArgumentException::class)
    fun parseQrRejectsUnsupportedVersion() {
        val rawJson = """{"v": 2, "record_id": "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d"}"""
        store.parseQr(rawJson)
    }
    @Test
    fun interruptedRegistrationRemainsUncertainAfterStoreRecreation() {
        val prefs = xyz.vidur.pux.testutil.FakeSharedPreferences()
        val original = RecordStore(prefs)
        assertFalse(original.beginDeviceRegistration())
        val restarted = RecordStore(prefs)
        assertTrue(restarted.registrationUncertain())
        val wasUncertain = restarted.beginDeviceRegistration()
        restarted.finishDeviceRegistration("recovered", wasUncertain)
        assertEquals("recovered", RecordStore(prefs).deviceId())
        assertFalse(RecordStore(prefs).registrationUncertain())
        assertTrue(RecordStore(prefs).staleRegistrationPossible())
    }

    @Test
    fun successfulFirstRegistrationClearsUncertaintyAtomically() {
        val prefs = xyz.vidur.pux.testutil.FakeSharedPreferences()
        val store = RecordStore(prefs)
        val wasUncertain = store.beginDeviceRegistration()
        store.finishDeviceRegistration("device", wasUncertain)
        assertEquals("device", RecordStore(prefs).deviceId())
        assertFalse(RecordStore(prefs).registrationUncertain())
    }

    @Test
    fun pendingRemovalUnreachableFlagClearsWithPending() {
        store.beginRemoteRemoval("delete_relay")
        store.markPendingRemovalServerUnreachable()
        assertTrue(store.pendingRemovalServerUnreachable())
        store.clearPendingRemoteRemoval()
        assertNull(store.pendingRemoteRemoval())
        assertFalse(store.pendingRemovalServerUnreachable())
        store.beginRemoteRemoval("delete_relay")
        assertFalse(store.pendingRemovalServerUnreachable())
    }

    @Test
    fun completeForgetClearsPendingRemovalInSameCommitAsEnrollment() {
        store.saveEnrollment(
            mapOf(
                "v" to 1,
                "record_id" to "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d",
                "public_key" to "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw",
                "private_key" to "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI",
                "inbox" to "inbox@example.com"
            )
        )
        store.beginRemoteRemoval("delete_relay")
        store.completeForget(null)
        assertNull(store.pendingRemoteRemoval())
        assertFalse(store.isEnrolled())
    }

}
