package xyz.vidur.pux.ui.dialogs

import androidx.compose.foundation.layout.Column
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import xyz.vidur.pux.R

@Composable
fun RemoveDeviceDialog(
    onConfirm: () -> Unit,
    onDismiss: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.dialog_remove_device_title)) },
        text = { Text(stringResource(R.string.dialog_remove_device_body)) },
        confirmButton = {
            Button(onClick = onConfirm) {
                Text(stringResource(R.string.action_remove))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.action_cancel))
            }
        }
    )
}

enum class RemovalFailureChoice {
    CANCEL,
    RETRY,
    FORGET
}

@Composable
fun RemovalFailureDialog(
    title: String,
    errorMessage: String,
    forgetWarning: String,
    localFailure: Boolean = false,
    serverUnreachable: Boolean = true,
    allowCancel: Boolean = true,
    onChoice: (RemovalFailureChoice) -> Unit
) {
    val body = when {
        localFailure -> stringResource(R.string.removal_failure_generic, errorMessage, forgetWarning)
        serverUnreachable -> stringResource(R.string.removal_failure_unreachable, errorMessage, forgetWarning)
        else -> stringResource(R.string.removal_failure_generic, errorMessage, forgetWarning)
    }
    AlertDialog(
        onDismissRequest = { if (!localFailure) onChoice(RemovalFailureChoice.CANCEL) },
        title = { Text(title) },
        text = { Text(body) },
        confirmButton = {
            Button(onClick = { onChoice(RemovalFailureChoice.RETRY) }) {
                Text(stringResource(R.string.action_try_again))
            }
        },
        dismissButton = {
            Column {
                if (allowCancel) {
                    TextButton(onClick = { onChoice(RemovalFailureChoice.CANCEL) }) {
                        Text(stringResource(R.string.action_cancel))
                    }
                }
                if (!localFailure) {
                    TextButton(onClick = { onChoice(RemovalFailureChoice.FORGET) }) {
                        Text(stringResource(R.string.action_forget_locally_anyway))
                    }
                }
            }
        }
    )
}
