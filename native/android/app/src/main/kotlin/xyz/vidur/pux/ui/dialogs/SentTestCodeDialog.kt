package xyz.vidur.pux.ui.dialogs

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import xyz.vidur.pux.model.TestCode

@Composable
fun SentTestCodeDialog(
    sent: TestCode,
    inbox: String,
    onDismiss: () -> Unit
) {
    val where = "On this phone it arrives as a notification within a few seconds."
    val others = if (sent.devices > 1) " It went to all ${sent.devices} devices on this relay." else ""

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Test code sent") },
        text = {
            Column {
                Text("Look for \"OTP from pux test\" with the code")
                Spacer(modifier = Modifier.height(8.dp))
                SelectionContainer {
                    Text(
                        text = sent.otp,
                        fontWeight = FontWeight.Bold,
                        style = MaterialTheme.typography.headlineMedium
                    )
                }
                Spacer(modifier = Modifier.height(8.dp))
                Text(where + others)
                Spacer(modifier = Modifier.height(16.dp))
                Text("To test email forwarding too, send an email to:")
                Spacer(modifier = Modifier.height(4.dp))
                SelectionContainer {
                    Text(
                        text = inbox,
                        fontWeight = FontWeight.SemiBold,
                        style = MaterialTheme.typography.bodyMedium
                    )
                }
                Spacer(modifier = Modifier.height(4.dp))
                Text("with the subject or body \"Your OTP is 123456\".")
            }
        },
        confirmButton = {
            Button(onClick = onDismiss) {
                Text("OK")
            }
        }
    )
}
