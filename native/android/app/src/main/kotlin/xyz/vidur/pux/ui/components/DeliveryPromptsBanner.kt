package xyz.vidur.pux.ui.components

import android.content.Context
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
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import xyz.vidur.pux.ui.theme.puxSemantic
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.launch
import xyz.vidur.pux.model.DeliveryRestriction
import xyz.vidur.pux.model.NotificationAccess
import xyz.vidur.pux.storage.RecordStore
import xyz.vidur.pux.storage.RecordStoreWrite
import xyz.vidur.pux.system.BackgroundRestrictions
import xyz.vidur.pux.system.NotificationPermissions

@Composable
fun DeliveryPromptsBanner(
    onAskNotification: () -> Unit,
    refreshTrigger: Int = 0,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val scope = rememberCoroutineScope()

    var access by remember { mutableStateOf(NotificationAccess.ALLOWED) }
    var activeRestrictions by remember { mutableStateOf<Set<DeliveryRestriction>>(emptySet()) }
    var dismissedRestrictions by remember { mutableStateOf<Set<DeliveryRestriction>>(emptySet()) }

    fun refresh() {
        scope.launch {
            access = NotificationPermissions.check(context, RecordStore.instance)
            val backgroundStatus = BackgroundRestrictions.check(context)

            val dismissedNames = RecordStore.instance.dismissedRestrictionPrompts()
            val dismissed = DeliveryRestriction.entries.filter { dismissedNames.contains(it.name) }.toSet()
            dismissedRestrictions = dismissed

            val clear = backgroundStatus.clear
            val updatedDismissed = dismissed - clear
            if (updatedDismissed != dismissed) {
                val saved = RecordStoreWrite.run {
                    RecordStore.instance.saveDismissedRestrictionPrompts(updatedDismissed.map { it.name }.toSet())
                }
                if (saved) {
                    dismissedRestrictions = updatedDismissed
                }
            }

            activeRestrictions = backgroundStatus.active - updatedDismissed
        }
    }

    // Refresh immediately whenever returning from system settings or when trigger changes
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                refresh()
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
        }
    }

    LaunchedEffect(refreshTrigger) {
        refresh()
    }

    if (access != NotificationAccess.ALLOWED) {
        NotificationPrompt(
            access = access,
            onAsk = onAskNotification,
            onOpenSettings = { NotificationPermissions.openNotificationSettings(context, channelOff = access == NotificationAccess.CHANNEL_OFF) },
            modifier = modifier
        )
        return
    }

    val firstRestriction = DeliveryRestriction.entries.firstOrNull { activeRestrictions.contains(it) }
    if (firstRestriction != null) {
        RestrictionPrompt(
            restriction = firstRestriction,
            onOpenSettings = {
                when (firstRestriction) {
                    DeliveryRestriction.HIBERNATION -> BackgroundRestrictions.openHibernationSettings(context)
                    DeliveryRestriction.BACKGROUND_USE -> BackgroundRestrictions.openAppSettings(context)
                    DeliveryRestriction.QUIET_CHANNEL -> BackgroundRestrictions.openChannelSettings(context)
                }
            },
            onDismiss = {
                scope.launch {
                    val previousDismissed = dismissedRestrictions
                    val previousActive = activeRestrictions
                    val newDismissed = dismissedRestrictions + firstRestriction
                    dismissedRestrictions = newDismissed
                    activeRestrictions = activeRestrictions - firstRestriction
                    if (!RecordStoreWrite.run {
                            RecordStore.instance.saveDismissedRestrictionPrompts(newDismissed.map { it.name }.toSet())
                        }
                    ) {
                        dismissedRestrictions = previousDismissed
                        activeRestrictions = previousActive
                    }
                }
            },
            modifier = modifier
        )
    }
}

@Composable
private fun NotificationPrompt(
    access: NotificationAccess,
    onAsk: () -> Unit,
    onOpenSettings: () -> Unit,
    modifier: Modifier = Modifier
) {
    val lost = "Codes that arrive in the meantime are lost."
    val (title, body, isAsk) = when (access) {
        NotificationAccess.NOT_ASKED -> Triple(
            "Notifications are off",
            "pux can only show codes as notifications, so you won't see any until you allow them. $lost",
            true
        )
        NotificationAccess.CHANNEL_OFF -> Triple(
            "OTP code notifications are off",
            "The \"OTP codes\" notification category is turned off for pux, so you won't see any codes. $lost Open settings and turn it on.",
            false
        )
        NotificationAccess.QUIET -> Triple(
            "Codes may arrive without an alert",
            "pux's notifications are set to arrive quietly, with no banner or alert, so you could miss a code before it expires. Open settings and turn on alerts for pux.",
            false
        )
        else -> Triple(
            "Notifications are off",
            "pux can only show codes as notifications, so you won't see any until you allow them. $lost Open settings and allow notifications for pux.",
            false
        )
    }

    PromptBox(
        title = title,
        body = body,
        color = if (access == NotificationAccess.QUIET) {
            MaterialTheme.puxSemantic.warningOnSurfaceVariant
        } else {
            MaterialTheme.puxSemantic.errorOnSurface
        },
        actionLabel = if (isAsk) "Allow notifications" else "Open settings",
        onAction = if (isAsk) onAsk else onOpenSettings,
        onDismiss = null,
        modifier = modifier
    )
}

@Composable
private fun RestrictionPrompt(
    restriction: DeliveryRestriction,
    onOpenSettings: () -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier
) {
    val (title, body) = when (restriction) {
        DeliveryRestriction.HIBERNATION -> Pair(
            "Keep codes arriving when you rarely open pux",
            "If pux goes a few months without being opened, Android pauses it and " +
                "codes stop arriving until you open it again. Reading a notification " +
                "doesn't count as opening it. In App info, turn off \"Pause app " +
                "activity if unused\" (on Android 12, \"Remove permissions and free up space\")."
        )
        DeliveryRestriction.BACKGROUND_USE -> Pair(
            "Background use is restricted",
            "Android is restricting pux's battery use, so codes may not arrive. " +
                "In App info, open the battery or app battery usage page and allow background use."
        )
        DeliveryRestriction.QUIET_CHANNEL -> Pair(
            "Codes don't pop up on screen",
            "The \"OTP codes\" notification category is set not to pop up on " +
                "screen, so you could miss a code before it expires. Open settings " +
                "and let it make a sound and pop up on screen."
        )
    }

    PromptBox(
        title = title,
        body = body,
        color = if (restriction == DeliveryRestriction.QUIET_CHANNEL) {
            MaterialTheme.puxSemantic.warningOnSurfaceVariant
        } else {
            MaterialTheme.puxSemantic.errorOnSurface
        },
        actionLabel = "Open settings",
        onAction = onOpenSettings,
        onDismiss = onDismiss,
        modifier = modifier
    )
}

@Composable
private fun PromptBox(
    title: String,
    body: String,
    color: Color,
    actionLabel: String,
    onAction: () -> Unit,
    onDismiss: (() -> Unit)?,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .border(1.dp, color, RoundedCornerShape(8.dp))
            .padding(12.dp)
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.titleSmall,
            color = color
        )
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = body,
            style = MaterialTheme.typography.bodyMedium
        )
        Spacer(modifier = Modifier.height(8.dp))
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.End
        ) {
            if (onDismiss != null) {
                TextButton(onClick = onDismiss) {
                    Text("Dismiss")
                }
            }
            Button(onClick = onAction) {
                Text(actionLabel)
            }
        }
    }
}
