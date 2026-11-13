package xyz.vidur.pux.testutil

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import xyz.vidur.pux.storage.FlutterSecureStorageMigrator
import xyz.vidur.pux.storage.RecordStore

/** Resets process-wide enrollment gate state leaked across Robolectric tests. */
object RecordStoreTestIsolation {
    fun reset() {
        RecordStore.enrollmentBlocked = false
        val context = ApplicationProvider.getApplicationContext<Context>()
        if (FlutterSecureStorageMigrator.isForgetPending(context)) {
            FlutterSecureStorageMigrator.finishForget(context)
        }
    }
}
