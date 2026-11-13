package xyz.vidur.pux.ui.components

import androidx.compose.foundation.border
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import xyz.vidur.pux.R
import xyz.vidur.pux.ui.theme.puxSemantic

@Composable
fun PendingRemoteRemovalBanner(
    pendingAction: String?,
    serverUnreachable: Boolean,
    modifier: Modifier = Modifier
) {
    if (pendingAction.isNullOrEmpty()) return
    val text = when (pendingAction) {
        "delete_relay" -> if (serverUnreachable) {
            stringResource(R.string.pending_delete_relay_unreachable)
        } else {
            stringResource(R.string.pending_delete_relay_in_flight)
        }
        "remove_device" -> stringResource(R.string.pending_remove_device_in_flight)
        else -> return
    }
    val color = MaterialTheme.puxSemantic.warningOnSurfaceVariant
    Text(
        text = text,
        color = color,
        style = MaterialTheme.typography.bodyMedium,
        modifier = modifier
            .fillMaxWidth()
            .border(1.dp, color, RoundedCornerShape(8.dp))
            .padding(12.dp)
    )
}
