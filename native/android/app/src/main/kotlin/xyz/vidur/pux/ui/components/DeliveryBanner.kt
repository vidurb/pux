package xyz.vidur.pux.ui.components

import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import xyz.vidur.pux.R
import xyz.vidur.pux.model.DeliveryState
import xyz.vidur.pux.model.DeliveryStatus
import xyz.vidur.pux.ui.theme.puxSemantic

@Composable
fun DeliveryBanner(
    status: DeliveryStatus,
    onRetry: () -> Unit,
    onForget: () -> Unit,
    modifier: Modifier = Modifier
) {
    val undecryptableText = if (status.undecryptable > 0) {
        "${status.undecryptable} message(s) could not be decrypted with this device's key."
    } else {
        null
    }

    val warning = MaterialTheme.puxSemantic.warningOnSurfaceVariant
    val onSurfaceMuted = MaterialTheme.colorScheme.onSurfaceVariant
    val error = MaterialTheme.puxSemantic.errorOnSurface

    val (color, text, actionType) = when (status.state) {
        DeliveryState.IDLE, DeliveryState.READY -> Triple(warning, "", BannerAction.NONE)
        DeliveryState.CONNECTING -> Triple(onSurfaceMuted, stringResource(R.string.delivery_connecting), BannerAction.NONE)
        DeliveryState.RETRYING -> Triple(
            warning,
            stringResource(R.string.delivery_not_connected, status.message ?: "unknown error"),
            BannerAction.RETRY
        )
        DeliveryState.FIREBASE_UNCONFIGURED -> Triple(
            error,
            status.message ?: "Push notifications are not configured in this build.",
            BannerAction.NONE
        )
        DeliveryState.RECORD_UNKNOWN -> Triple(
            error,
            "The server no longer knows this relay. It may have expired after going " +
                "a long time with no registered devices. Forget it on this device and " +
                "create a new relay (then update your email forwarding).",
            BannerAction.FORGET
        )
        DeliveryState.TOO_MANY_DEVICES -> Triple(
            error,
            "This relay already has the maximum number of devices. On a device you " +
                "no longer use, choose \"Remove this device\", then retry here.",
            BannerAction.RETRY
        )
    }

    if (text.isEmpty() && undecryptableText == null) return

    Column(
        modifier = modifier
            .fillMaxWidth()
            .border(1.dp, color, RoundedCornerShape(8.dp))
            .padding(12.dp)
    ) {
        if (text.isNotEmpty()) {
            Text(
                text = text,
                color = color,
                style = MaterialTheme.typography.bodyMedium
            )
        }
        if (undecryptableText != null) {
            if (text.isNotEmpty()) Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = undecryptableText,
                color = warning,
                style = MaterialTheme.typography.bodyMedium
            )
        }
        when (actionType) {
            BannerAction.RETRY -> {
                Spacer(modifier = Modifier.height(8.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.End
                ) {
                    TextButton(onClick = onRetry) {
                        Text(stringResource(R.string.delivery_retry_now))
                    }
                }
            }
            BannerAction.FORGET -> {
                Spacer(modifier = Modifier.height(8.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.End
                ) {
                    Button(onClick = onForget) {
                        Text(stringResource(R.string.delivery_forget_relay))
                    }
                }
            }
            BannerAction.NONE -> Unit
        }
    }
}

private enum class BannerAction {
    NONE,
    RETRY,
    FORGET
}
