package xyz.vidur.pux.ui.screens

/** All calls are made on the main thread, including the camera provider callback. */
internal class CameraBinding {
    @Volatile private var disposed = false
    @Volatile private var paused = false
    private var unbind: (() -> Unit)? = null

    fun bind(bind: () -> Unit, unbind: () -> Unit) {
        if (disposed || paused) return
        this.unbind = unbind
        try {
            bind()
        } catch (e: Exception) {
            this.unbind = null
            unbind()
            throw e
        }
    }

    fun pause() {
        if (disposed || paused) return
        paused = true
        unbind?.invoke()
        unbind = null
    }

    fun resume(bind: () -> Unit, unbind: () -> Unit) {
        if (disposed || !paused) return
        paused = false
        bind(bind, unbind)
    }

    /** Clears [paused] so a new view can [bind] after [pause] without an in-place [resume]. */
    fun unpauseForRebind() {
        if (disposed) return
        paused = false
        unbind = null
    }

    fun close() {
        if (disposed) return
        disposed = true
        paused = false
        unbind?.invoke()
        unbind = null
    }

    fun isDisposed(): Boolean = disposed

    fun isPaused(): Boolean = paused
}
