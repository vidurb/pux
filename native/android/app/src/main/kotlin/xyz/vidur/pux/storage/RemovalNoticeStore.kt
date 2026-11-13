package xyz.vidur.pux.storage

import android.content.Context

/** Survives [RecordStore.clear] so a stale-registration warning can be shown after device removal. */
object RemovalNoticeStore {
    private const val PREFS_NAME = "pux_removal_state"
    private const val KEY_NOTICE = "pending_stale_registration_notice"

    fun save(context: Context, message: String) {
        check(
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_NOTICE, message)
                .commit()
        ) { "Could not persist removal notice" }
    }

    fun peek(context: Context): String? =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(KEY_NOTICE, null)
            ?.takeIf { it.isNotEmpty() }

    fun clear(context: Context) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .remove(KEY_NOTICE)
            .commit()
    }
}
