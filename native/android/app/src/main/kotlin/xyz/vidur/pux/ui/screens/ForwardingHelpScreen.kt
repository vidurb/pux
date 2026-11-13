package xyz.vidur.pux.ui.screens

import android.widget.Toast
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import xyz.vidur.pux.R
import xyz.vidur.pux.push.SensitiveClipboard

data class KnownSender(
    val bank: String,
    val from: String,
    val subject: String
)

val KNOWN_OTP_SENDERS = listOf(
    KnownSender(
        bank = "HSBC (credit card)",
        from = "hsbc@hsbc.bank.in",
        subject = "Your HSBC Credit Card OTP"
    ),
    KnownSender(
        bank = "RBL Bank",
        from = "alerts@rbl.bank.in",
        subject = "One-Time Password for your online transaction"
    )
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ForwardingHelpScreen(
    inbox: String?,
    onBack: () -> Unit,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val scrollState = rememberScrollState()
    val address = inbox ?: "your inbox address"

    fun copyAddress() {
        if (inbox != null) {
            SensitiveClipboard.instance.copy(inbox)
            Toast.makeText(context, R.string.clipboard_inbox_copied, Toast.LENGTH_SHORT).show()
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Set up forwarding") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
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
                .padding(16.dp)
        ) {
            Text(
                text = "Forward only your bank's OTP emails, not your whole mailbox. Set up a filter in your " +
                    "email account that matches the sender and subject of those emails and forwards them to your inbox address.",
                style = MaterialTheme.typography.bodyMedium
            )

            if (inbox != null) {
                Spacer(modifier = Modifier.height(12.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    SelectionContainer(modifier = Modifier.weight(1f)) {
                        Text(
                            text = inbox,
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.SemiBold
                        )
                    }
                    IconButton(onClick = { copyAddress() }) {
                        Icon(Icons.Default.ContentCopy, contentDescription = "Copy inbox address")
                    }
                }
            }

            SectionHeading("Gmail")
            Text(
                text = "Filters can only be created on gmail.com in a browser, not in the Gmail app.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.height(8.dp))
            NumberedSteps(
                listOf(
                    "Open Settings → See all settings → Forwarding and POP/IMAP.",
                    "Choose \"Add a forwarding address\" and enter $address.",
                    "Gmail sends a confirmation to that address. It arrives in pux as a notification: " +
                        "tap it to open the confirmation link, or enter its code in Gmail. Leave forwarding itself disabled.",
                    "In the search bar, open the search options. Fill in From and Subject with the values for your bank (see below), " +
                        "then choose \"Create filter\".",
                    "Tick \"Forward it to\", pick your inbox address, and create the filter."
                )
            )

            SectionHeading("Outlook.com")
            NumberedSteps(
                listOf(
                    "Open Settings → Mail → Rules → Add new rule.",
                    "Add the conditions \"From\" and \"Subject includes\" with the values for your bank (see below).",
                    "Add the action \"Redirect to\" and enter $address. Use Redirect rather than Forward, " +
                        "so the bank stays the sender and its name can be verified."
                )
            )

            SectionHeading("Other providers")
            Text(
                text = "Most providers support rules or filters that forward matching mail. Prefer an option that keeps the original sender " +
                    "(often called redirect). If your bank appears as unverified in pux, the forwarding changed the message.",
                style = MaterialTheme.typography.bodyMedium
            )

            SectionHeading("Known bank OTP emails")
            Text(
                text = "Check an OTP email in your own inbox first: banks use different senders for different products and change them over time.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.height(8.dp))
            KNOWN_OTP_SENDERS.forEach { sender ->
                Card(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 4.dp),
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)
                ) {
                    Column(modifier = Modifier.padding(12.dp)) {
                        Text(
                            text = sender.bank,
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.Bold
                        )
                        Spacer(modifier = Modifier.height(4.dp))
                        SelectionContainer {
                            Text(text = "From: ${sender.from}", style = MaterialTheme.typography.bodyMedium)
                        }
                        SelectionContainer {
                            Text(text = "Subject: ${sender.subject}", style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                }
            }

            SectionHeading("Test it")
            Text(
                text = "To check the relay, email \"Your OTP is 123456\" straight to your inbox address; " +
                    "a notification should arrive within a few seconds. Your next bank OTP checks the filter itself.",
                style = MaterialTheme.typography.bodyMedium
            )
            Spacer(modifier = Modifier.height(16.dp))
        }
    }
}

@Composable
private fun SectionHeading(title: String) {
    Text(
        text = title,
        style = MaterialTheme.typography.titleMedium,
        fontWeight = FontWeight.Bold,
        modifier = Modifier.padding(top = 24.dp, bottom = 8.dp)
    )
}

@Composable
private fun NumberedSteps(items: List<String>) {
    Column {
        items.forEachIndexed { index, step ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(bottom = 6.dp),
                verticalAlignment = Alignment.Top
            ) {
                Text(
                    text = "${index + 1}.",
                    modifier = Modifier.width(24.dp),
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.Bold
                )
                Text(
                    text = step,
                    modifier = Modifier.weight(1f),
                    style = MaterialTheme.typography.bodyMedium
                )
            }
        }
    }
}
