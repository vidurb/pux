package xyz.vidur.pux.ui.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import xyz.vidur.pux.R

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EnrollChooserScreen(
    onCreateRelay: () -> Unit,
    onAddToRelay: () -> Unit,
    migrationRecoveryRequired: Boolean = false,
    forgetCleanupRequired: Boolean = false,
    modifier: Modifier = Modifier
) {
    val scrollState = rememberScrollState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.setup_title)) }
            )
        },
        modifier = modifier
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .verticalScroll(scrollState)
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(
                text = stringResource(R.string.setup_chooser_intro),
                textAlign = TextAlign.Center,
                style = MaterialTheme.typography.bodyLarge
            )
            if (forgetCleanupRequired) {
                Spacer(modifier = Modifier.height(16.dp))
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer)
                ) {
                    Text(
                        text = stringResource(R.string.setup_blocked_forget_cleanup),
                        modifier = Modifier.padding(16.dp),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onErrorContainer
                    )
                }
            } else if (migrationRecoveryRequired) {
                Spacer(modifier = Modifier.height(16.dp))
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer)
                ) {
                    Text(
                        text = stringResource(R.string.setup_blocked_migration),
                        modifier = Modifier.padding(16.dp),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onErrorContainer
                    )
                }
            }
            Spacer(modifier = Modifier.height(32.dp))
            Button(
                onClick = onCreateRelay,
                enabled = !migrationRecoveryRequired && !forgetCleanupRequired,
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(stringResource(R.string.setup_create_relay))
            }
            Spacer(modifier = Modifier.height(16.dp))
            OutlinedButton(
                onClick = onAddToRelay,
                enabled = !migrationRecoveryRequired && !forgetCleanupRequired,
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(stringResource(R.string.setup_add_existing_relay))
            }
            Spacer(modifier = Modifier.height(24.dp))
            Text(
                text = stringResource(R.string.setup_keys_stay_on_phone),
                textAlign = TextAlign.Center,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}
