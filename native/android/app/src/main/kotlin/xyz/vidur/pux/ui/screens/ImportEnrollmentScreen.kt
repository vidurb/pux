package xyz.vidur.pux.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import xyz.vidur.pux.service.DeliveryController
import xyz.vidur.pux.storage.RecordStore
import xyz.vidur.pux.ui.dialogs.ConfirmServerDialog

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ImportEnrollmentScreen(
    onEnrolled: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier
) {
    val scope = rememberCoroutineScope()
    val scrollState = rememberScrollState()
    var rawText by rememberSaveable { mutableStateOf("") }
    var processing by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var pendingPayload by remember { mutableStateOf<Map<String, Any?>?>(null) }
    var pendingServerUrl by remember { mutableStateOf<String?>(null) }

    BackHandler(enabled = processing) {
        // Prevent back press while processing
    }

    fun proceedWithSave(payload: Map<String, Any?>) {
        processing = true
        errorMessage = null
        scope.launch {
            try {
                RecordStore.instance.saveEnrollment(payload)
                DeliveryController.instance.start()
                onEnrolled()
            } catch (e: Exception) {
                processing = false
                errorMessage = e.message ?: "Failed to save enrollment"
            }
        }
    }

    fun handleImport() {
        val trimmed = rawText.trim()
        if (trimmed.isEmpty()) return
        errorMessage = null
        try {
            val payload = RecordStore.instance.parseQr(trimmed)
            val server = RecordStore.instance.enrollmentServer(payload)
            pendingPayload = payload
            pendingServerUrl = server
        } catch (e: Exception) {
            errorMessage = e.message ?: "Invalid enrollment JSON"
        }
    }

    if (pendingPayload != null && pendingServerUrl != null) {
        ConfirmServerDialog(
            serverUrl = pendingServerUrl!!,
            onConfirm = {
                val payload = pendingPayload!!
                pendingPayload = null
                pendingServerUrl = null
                proceedWithSave(payload)
            },
            onDismiss = {
                pendingPayload = null
                pendingServerUrl = null
            }
        )
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Import enrollment") },
                navigationIcon = {
                    if (!processing) {
                        IconButton(onClick = onBack) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                        }
                    }
                }
            )
        },
        modifier = modifier
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .verticalScroll(scrollState)
                .padding(24.dp)
        ) {
            Text(
                text = "Paste the enrollment JSON exported from another device.",
                style = MaterialTheme.typography.bodyLarge
            )
            Spacer(modifier = Modifier.height(16.dp))
            OutlinedTextField(
                value = rawText,
                onValueChange = { rawText = it },
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 160.dp, max = 320.dp),
                placeholder = {
                    Text("{\"v\":1,\"record_id\":\"...\",\"private_key\":\"...\"}")
                }
            )
            Spacer(modifier = Modifier.height(16.dp))
            if (processing) {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                Spacer(modifier = Modifier.height(16.dp))
            }
            Button(
                onClick = { handleImport() },
                enabled = !processing && rawText.isNotBlank(),
                modifier = Modifier.fillMaxWidth()
            ) {
                Text("Import and connect")
            }
            if (errorMessage != null) {
                Spacer(modifier = Modifier.height(16.dp))
                Text(
                    text = errorMessage!!,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodyMedium
                )
            }
        }
    }
}
