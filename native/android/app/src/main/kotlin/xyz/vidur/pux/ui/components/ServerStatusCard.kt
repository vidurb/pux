package xyz.vidur.pux.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import xyz.vidur.pux.ui.theme.puxSemantic
import kotlinx.coroutines.launch
import xyz.vidur.pux.api.ApiClient
import xyz.vidur.pux.model.DeliveryState
import xyz.vidur.pux.model.ServerHealthState
import xyz.vidur.pux.service.DeliveryController
import xyz.vidur.pux.storage.RecordStore
import java.net.URI

enum class ServerReachability {
    CHECKING,
    REACHABLE,
    UNREACHABLE,
    SERVER_ERROR
}

@Composable
fun ServerStatusCard(
    modifier: Modifier = Modifier
) {
    var state by remember { mutableStateOf(ServerReachability.CHECKING) }
    var reason by remember { mutableStateOf<String?>(null) }
    var checkCount by remember { mutableIntStateOf(0) }
    val scope = rememberCoroutineScope()

    val serverUrl = RecordStore.instance.serverUrl
    val host = remember(serverUrl) {
        try {
            val uri = URI(serverUrl)
            if (uri.port != -1 && uri.port != 80 && uri.port != 443) {
                "${uri.host}:${uri.port}"
            } else {
                uri.host ?: serverUrl
            }
        } catch (_: Exception) {
            serverUrl
        }
    }

    fun checkHealth(userAsked: Boolean = false) {
        scope.launch {
            state = ServerReachability.CHECKING
            reason = null
            val health = ApiClient.instance.checkHealth()
            state = when (health.state) {
                ServerHealthState.REACHABLE -> ServerReachability.REACHABLE
                ServerHealthState.UNREACHABLE -> ServerReachability.UNREACHABLE
                ServerHealthState.SERVER_ERROR -> ServerReachability.SERVER_ERROR
            }
            reason = health.reason

            if (userAsked &&
                health.state == ServerHealthState.REACHABLE &&
                DeliveryController.instance.status.value.state == DeliveryState.RETRYING
            ) {
                DeliveryController.instance.start()
            }
        }
    }

    LaunchedEffect(checkCount) {
        checkHealth(userAsked = false)
    }

    val successColor = MaterialTheme.puxSemantic.successOnSurfaceVariant
    val warningColor = MaterialTheme.puxSemantic.warningOnSurfaceVariant

    Card(
        modifier = modifier
            .fillMaxWidth()
            .clickable {
                checkHealth(userAsked = true)
            },
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant
        )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Start
        ) {
            when (state) {
                ServerReachability.CHECKING -> {
                    CircularProgressIndicator(
                        modifier = Modifier.size(18.dp),
                        strokeWidth = 2.dp,
                        color = MaterialTheme.colorScheme.primary
                    )
                    Spacer(modifier = Modifier.width(12.dp))
                    Text(
                        text = "Checking server ($host)…",
                        style = MaterialTheme.typography.bodyMedium
                    )
                }
                ServerReachability.REACHABLE -> {
                    Icon(
                        imageVector = Icons.Default.CheckCircle,
                        contentDescription = "Server reachable",
                        tint = successColor,
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(modifier = Modifier.width(12.dp))
                    Text(
                        text = "Server connected ($host)",
                        style = MaterialTheme.typography.bodyMedium,
                        color = successColor
                    )
                }
                ServerReachability.UNREACHABLE -> {
                    Icon(
                        imageVector = Icons.Default.Warning,
                        contentDescription = "Server unreachable",
                        tint = warningColor,
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(modifier = Modifier.width(12.dp))
                    Text(
                        text = "Server unreachable ($host)${if (reason != null) ": $reason" else ""}",
                        style = MaterialTheme.typography.bodyMedium,
                        color = warningColor
                    )
                }
                ServerReachability.SERVER_ERROR -> {
                    Icon(
                        imageVector = Icons.Default.Error,
                        contentDescription = "Server error",
                        tint = MaterialTheme.puxSemantic.errorOnSurface,
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(modifier = Modifier.width(12.dp))
                    Text(
                        text = "Server error ($host)${if (reason != null) ": $reason" else ""}",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.puxSemantic.errorOnSurface
                    )
                }
            }
        }
    }
}
