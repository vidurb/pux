package xyz.vidur.pux.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
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
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import xyz.vidur.pux.service.CreateRelayController
import xyz.vidur.pux.service.CreateRelayState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CreateRelayScreen(
    controller: CreateRelayController,
    onBack: () -> Unit,
    modifier: Modifier = Modifier
) {
    val createState by controller.state.collectAsState()
    val committing = createState == CreateRelayState.Running
    val errorMessage = (createState as? CreateRelayState.Failed)?.message
    val scrollState = rememberScrollState()

    BackHandler(enabled = committing) {
        // Prevent back press while committing
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Create relay") },
                navigationIcon = {
                    if (!committing) {
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
                text = "A new encryption keypair will be generated on this device. " +
                    "Only the public key is sent to the server.",
                style = MaterialTheme.typography.bodyLarge
            )
            Spacer(modifier = Modifier.height(24.dp))
            if (committing) {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                Spacer(modifier = Modifier.height(16.dp))
            }
            Button(
                onClick = {
                    controller.clearFailure()
                    controller.start()
                },
                enabled = !committing,
                modifier = Modifier.fillMaxWidth()
            ) {
                Text("Generate keys and create relay")
            }
            if (errorMessage != null) {
                Spacer(modifier = Modifier.height(16.dp))
                Text(
                    text = errorMessage,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodyMedium
                )
            }
        }
    }
}
