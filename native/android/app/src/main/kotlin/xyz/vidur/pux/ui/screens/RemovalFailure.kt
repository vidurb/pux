package xyz.vidur.pux.ui.screens

internal enum class RemovalAction { FORGET, REMOVE_DEVICE, DELETE_RELAY }

internal data class RemovalFailure(
    val action: RemovalAction,
    val title: String,
    val error: String,
    val warning: String,
    val serverUnreachable: Boolean = true,
    val keepRemovalIntentOnCancel: Boolean = false,
)

internal fun retryRemoval(action: RemovalAction, forget: () -> Unit, remove: () -> Unit, delete: () -> Unit) {
    when (action) {
        RemovalAction.FORGET -> forget()
        RemovalAction.REMOVE_DEVICE -> remove()
        RemovalAction.DELETE_RELAY -> delete()
    }
}
