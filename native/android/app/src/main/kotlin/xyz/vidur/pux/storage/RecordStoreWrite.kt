package xyz.vidur.pux.storage

/** Catches checked storage failures from UI-triggered preference writes. */
object RecordStoreWrite {
    fun run(onFailure: (Exception) -> Unit = {}, block: () -> Unit): Boolean {
        return try {
            block()
            true
        } catch (e: Exception) {
            onFailure(e)
            false
        }
    }
}
