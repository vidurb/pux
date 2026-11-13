package xyz.vidur.pux.ui.screens

import android.widget.Toast
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.QrCode
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import xyz.vidur.pux.R
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.json.JSONObject
import xyz.vidur.pux.api.ApiClient
import xyz.vidur.pux.api.NoDevicesException
import xyz.vidur.pux.api.RateLimitedException
import xyz.vidur.pux.api.RecordNotFoundException
import xyz.vidur.pux.model.TestCode
import xyz.vidur.pux.push.SensitiveClipboard
import xyz.vidur.pux.service.DeliveryController
import xyz.vidur.pux.service.RemovalState
import xyz.vidur.pux.PuxApplication
import xyz.vidur.pux.storage.RecordStore
import xyz.vidur.pux.ui.QrCodeUtil
import xyz.vidur.pux.storage.FlutterSecureStorageMigrator
import xyz.vidur.pux.ui.components.DeliveryBanner
import xyz.vidur.pux.ui.components.DeliveryPromptsBanner
import xyz.vidur.pux.ui.components.InterruptedLocalForgetBanner
import xyz.vidur.pux.ui.components.PendingRemoteRemovalBanner
import xyz.vidur.pux.ui.components.ServerStatusCard
import xyz.vidur.pux.ui.dialogs.DeleteRelayDialog
import xyz.vidur.pux.ui.dialogs.RemovalFailureChoice
import xyz.vidur.pux.ui.dialogs.RemovalFailureDialog
import xyz.vidur.pux.ui.dialogs.RemoveDeviceDialog
import xyz.vidur.pux.ui.dialogs.SentTestCodeDialog
import xyz.vidur.pux.ui.theme.puxSemantic

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    onNavigateToForwardingHelp: (String?) -> Unit,
    onAskNotification: () -> Unit,
    refreshTrigger: Int = 0,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val scrollState = rememberScrollState()
    val snackbarHostState = remember { SnackbarHostState() }

    var inbox by remember { mutableStateOf<String?>(null) }
    var enrollmentJson by remember { mutableStateOf<String?>(null) }
    var showQr by rememberSaveable { mutableStateOf(false) }
    var qrBitmap by remember { mutableStateOf<ImageBitmap?>(null) }
    val removalController = (context.applicationContext as PuxApplication).removalController
    val removalState by removalController.state.collectAsState()
    val removing = removalState == RemovalState.Running
    var menuExpanded by remember { mutableStateOf(false) }

    // Dialog state
    var showRemoveDeviceDialog by remember { mutableStateOf(false) }
    var showDeleteRelayDialog by remember { mutableStateOf(false) }
    var showCopyEnrollmentDialog by remember { mutableStateOf(false) }
    var sentTestCode by remember { mutableStateOf<TestCode?>(null) }
    var sendingTestCode by remember { mutableStateOf(false) }

    val deliveryStatus by DeliveryController.instance.status.collectAsState()
    val pendingRemoval = RecordStore.instance.pendingRemoteRemoval()
    val pendingRemovalUnreachable = RecordStore.instance.pendingRemovalServerUnreachable()
    val localForgetInterrupted = FlutterSecureStorageMigrator.isForgetPending(context)

    LaunchedEffect(Unit) {
        val ib = RecordStore.instance.inbox()
        val payload = RecordStore.instance.enrollmentPayload()
        val json = JSONObject(payload).toString()
        inbox = ib
        enrollmentJson = json
    }

    LaunchedEffect(showQr, enrollmentJson) {
        if (showQr) {
            qrBitmap = enrollmentJson?.let { QrCodeUtil.generateQrBitmapOrNull(it, 480) }
        }
    }

    fun removeDevice() = removalController.run(RemovalAction.REMOVE_DEVICE)
    fun deleteRelayEverywhere() = removalController.run(RemovalAction.DELETE_RELAY)
    fun forgetLocally() = removalController.run(RemovalAction.FORGET)

    fun handleCopyEnrollment() {
        val json = enrollmentJson ?: return
        SensitiveClipboard.instance.copy(json)
        scope.launch {
            snackbarHostState.showSnackbar(context.getString(R.string.clipboard_enrollment_copied))
        }
    }

    fun sendTestCode() {
        if (sendingTestCode) return
        val currentInbox = inbox ?: return
        sendingTestCode = true
        scope.launch {
            try {
                val recordId = RecordStore.instance.recordId() ?: throw RecordNotFoundException()
                val result = ApiClient.instance.sendTestCode(recordId)
                sentTestCode = result
            } catch (e: Exception) {
                val msg = when (e) {
                    is RateLimitedException -> "Too many test codes for now. Wait a minute, then try again."
                    is NoDevicesException -> "No device is registered on this relay yet. Wait until this device has connected, then try again."
                    is RecordNotFoundException -> "The server no longer knows this relay."
                    else -> "Couldn't send a test code: ${e.message}"
                }
                snackbarHostState.showSnackbar(msg)
            } finally {
                sendingTestCode = false
            }
        }
    }

    if (showCopyEnrollmentDialog) {
        AlertDialog(
            onDismissRequest = { showCopyEnrollmentDialog = false },
            title = { Text(stringResource(R.string.dialog_copy_enrollment_title)) },
            text = { Text(stringResource(R.string.dialog_copy_enrollment_body)) },
            confirmButton = {
                Button(onClick = {
                    showCopyEnrollmentDialog = false
                    handleCopyEnrollment()
                }) {
                    Text(stringResource(R.string.action_copy))
                }
            },
            dismissButton = {
                TextButton(onClick = { showCopyEnrollmentDialog = false }) {
                    Text(stringResource(R.string.action_cancel))
                }
            }
        )
    }

    if (showRemoveDeviceDialog) {
        RemoveDeviceDialog(
            onConfirm = {
                showRemoveDeviceDialog = false
                removeDevice()
            },
            onDismiss = {
                showRemoveDeviceDialog = false
            }
        )
    }

    if (showDeleteRelayDialog) {
        DeleteRelayDialog(
            onConfirm = {
                showDeleteRelayDialog = false
                deleteRelayEverywhere()
            },
            onDismiss = {
                showDeleteRelayDialog = false
            }
        )
    }

    if (sentTestCode != null && inbox != null) {
        SentTestCodeDialog(
            sent = sentTestCode!!,
            inbox = inbox!!,
            onDismiss = { sentTestCode = null }
        )
    }

    val removalFailureInfo = (removalState as? RemovalState.Failed)?.failure
    if (removalFailureInfo != null) {
        val (action, title, err, warn, serverUnreachable, keepRemovalIntentOnCancel) = removalFailureInfo
        RemovalFailureDialog(
            title = title,
            errorMessage = err,
            forgetWarning = warn,
            localFailure = action == RemovalAction.FORGET,
            serverUnreachable = serverUnreachable,
            allowCancel = !FlutterSecureStorageMigrator.isForgetPending(context),
            onChoice = { choice ->
                when (choice) {
                    RemovalFailureChoice.CANCEL -> removalController.cancelFailure(clearPendingRemoval = !keepRemovalIntentOnCancel)
                    RemovalFailureChoice.RETRY -> removalController.run(action)
                    RemovalFailureChoice.FORGET -> forgetLocally()
                }
            }
        )
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("pux") },
                actions = {
                    IconButton(onClick = { showQr = !showQr }) {
                        Icon(Icons.Default.QrCode, contentDescription = "Add device")
                    }
                    Box {
                        IconButton(onClick = { menuExpanded = true }, enabled = !removing) {
                            Icon(Icons.Default.MoreVert, contentDescription = "Menu")
                        }
                        DropdownMenu(
                            expanded = menuExpanded,
                            onDismissRequest = { menuExpanded = false }
                        ) {
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.menu_remove_device)) },
                                onClick = {
                                    menuExpanded = false
                                    showRemoveDeviceDialog = true
                                }
                            )
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.menu_delete_relay)) },
                                onClick = {
                                    menuExpanded = false
                                    showDeleteRelayDialog = true
                                }
                            )
                        }
                    }
                }
            )
        },
        snackbarHost = { SnackbarHost(snackbarHostState) },
        modifier = modifier
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .verticalScroll(scrollState)
                .padding(16.dp)
        ) {
            if (removing) {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                Spacer(modifier = Modifier.height(16.dp))
            }

            if (localForgetInterrupted && removalState !is RemovalState.Failed && removalState != RemovalState.Running) {
                InterruptedLocalForgetBanner(onRetry = { forgetLocally() })
                Spacer(modifier = Modifier.height(12.dp))
            } else if (removalState == RemovalState.Idle && pendingRemoval != null) {
                PendingRemoteRemovalBanner(
                    pendingAction = pendingRemoval,
                    serverUnreachable = pendingRemovalUnreachable
                )
                Spacer(modifier = Modifier.height(12.dp))
            }

            DeliveryPromptsBanner(
                onAskNotification = onAskNotification,
                refreshTrigger = refreshTrigger
            )
            Spacer(modifier = Modifier.height(12.dp))

            ServerStatusCard()
            Spacer(modifier = Modifier.height(12.dp))

            DeliveryBanner(
                status = deliveryStatus,
                onRetry = { DeliveryController.instance.start() },
                onForget = { forgetLocally() }
            )
            Spacer(modifier = Modifier.height(12.dp))

            Text(
                text = "Forward bank OTP emails to your inbox address. Codes arrive as encrypted push notifications.",
                style = MaterialTheme.typography.bodyMedium
            )
            Spacer(modifier = Modifier.height(16.dp))

            if (inbox != null) {
                Text(
                    text = stringResource(R.string.home_inbox_address),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Bold
                )
                Spacer(modifier = Modifier.height(4.dp))
                SelectionContainer {
                    Text(
                        text = inbox!!,
                        style = MaterialTheme.typography.bodyLarge
                    )
                }
                Spacer(modifier = Modifier.height(8.dp))
                Button(
                    onClick = {
                        SensitiveClipboard.instance.copy(inbox!!)
                        Toast.makeText(context, R.string.clipboard_inbox_copied, Toast.LENGTH_SHORT).show()
                    },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Icon(Icons.Default.ContentCopy, contentDescription = null)
                    Spacer(modifier = Modifier.size(8.dp))
                    Text(stringResource(R.string.home_copy_inbox))
                }
                Spacer(modifier = Modifier.height(8.dp))
                OutlinedButton(
                    onClick = { onNavigateToForwardingHelp(inbox) },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Icon(Icons.AutoMirrored.Filled.HelpOutline, contentDescription = null)
                    Spacer(modifier = Modifier.size(8.dp))
                    Text(stringResource(R.string.home_forwarding_help))
                }
                Spacer(modifier = Modifier.height(8.dp))
                OutlinedButton(
                    onClick = { sendTestCode() },
                    enabled = !sendingTestCode,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    if (sendingTestCode) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(18.dp),
                            strokeWidth = 2.dp
                        )
                    } else {
                        Icon(Icons.AutoMirrored.Filled.Send, contentDescription = null)
                    }
                    Spacer(modifier = Modifier.size(8.dp))
                    Text(stringResource(R.string.home_send_test_code))
                }
            }

            if (showQr && enrollmentJson != null) {
                Spacer(modifier = Modifier.height(24.dp))
                Text(
                    text = "Add another device",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold
                )
                Spacer(modifier = Modifier.height(8.dp))
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 8.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Box(
                        modifier = Modifier
                            .size(240.dp)
                            .clip(RoundedCornerShape(8.dp))
                            .background(Color.White)
                            .padding(8.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        val bitmap = qrBitmap
                        if (bitmap != null) {
                            Image(bitmap = bitmap, contentDescription = "Enrollment QR Code", modifier = Modifier.fillMaxSize())
                        } else {
                            Text("QR code unavailable. Copy the enrollment JSON below instead.")
                        }
                    }
                }
                Spacer(modifier = Modifier.height(8.dp))
                Text(
                    text = "Scan this QR on another phone, or copy the enrollment JSON and " +
                        "paste it into the desktop app. Both contain your private key: " +
                        "only use them with devices you trust.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.puxSemantic.warningOnSurface
                )
                Spacer(modifier = Modifier.height(8.dp))
                OutlinedButton(
                    onClick = { showCopyEnrollmentDialog = true },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Icon(Icons.Default.ContentCopy, contentDescription = null)
                    Spacer(modifier = Modifier.size(8.dp))
                    Text(stringResource(R.string.home_copy_enrollment_json))
                }
            }
        }
    }
}
