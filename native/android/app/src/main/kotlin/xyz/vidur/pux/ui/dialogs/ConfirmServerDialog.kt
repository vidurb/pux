package xyz.vidur.pux.ui.dialogs

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import xyz.vidur.pux.R
import java.net.URI

@Composable
fun ConfirmServerDialog(
    serverUrl: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit
) {
    val uri = try {
        URI(serverUrl)
    } catch (_: Exception) {
        null
    }
    val host = if (uri != null) {
        if (uri.port != -1 && uri.port != 80 && uri.port != 443) {
            "${uri.host}:${uri.port}"
        } else {
            uri.host ?: serverUrl
        }
    } else {
        serverUrl
    }
    val isHttp = uri?.scheme == "http"

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.dialog_confirm_server_title)) },
        text = {
            Column {
                Text(stringResource(R.string.dialog_confirm_server_body))
                Spacer(modifier = Modifier.height(8.dp))
                SelectionContainer {
                    Text(
                        text = host,
                        fontWeight = FontWeight.Bold,
                        style = MaterialTheme.typography.bodyLarge
                    )
                }
                if (isHttp) {
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        text = stringResource(R.string.dialog_confirm_server_http_warning),
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodyMedium
                    )
                }
                Spacer(modifier = Modifier.height(8.dp))
                Text(stringResource(R.string.dialog_confirm_server_warning))
            }
        },
        confirmButton = {
            Button(onClick = onConfirm) {
                Text(stringResource(R.string.action_connect))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.action_cancel))
            }
        }
    )
}
