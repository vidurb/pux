package xyz.vidur.pux.storage

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import xyz.vidur.pux.testutil.FakeSharedPreferences

class RecordStoreWriteTest {
    @Test fun runCatchesCommitFailureFromUiWrite() {
        val prefs = FakeSharedPreferences()
        val store = RecordStore(prefs)
        var captured: Exception? = null
        prefs.failNextCommit = true
        val saved = RecordStoreWrite.run(onFailure = { captured = it }) {
            store.saveNotificationExplainerSkipped()
        }
        assertFalse(saved)
        assertFalse(store.notificationExplainerSkipped())
        assertTrue(captured is IllegalStateException)
        assertEquals("Could not save notification explainer preference", captured?.message)
    }
}
