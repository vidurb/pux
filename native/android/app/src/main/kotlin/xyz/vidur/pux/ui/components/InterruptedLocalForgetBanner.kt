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
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import xyz.vidur.pux.R
import xyz.vidur.pux.ui.theme.puxSemantic

@Composable
fun InterruptedLocalForgetBanner(
    onRetry: () -> Unit,
    modifier: Modifier = Modifier
) {
    val color = MaterialTheme.puxSemantic.errorOnSurface
    Column(
        modifier = modifier
            .fillMaxWidth()
            .border(1.dp, color, RoundedCornerShape(8.dp))
            .padding(12.dp)
    ) {
        Text(
            text = stringResource(R.string.local_forget_interrupted),
            color = color,
            style = MaterialTheme.typography.bodyMedium
        )
        Spacer(modifier = Modifier.height(8.dp))
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            Button(onClick = onRetry) {
                Text(stringResource(R.string.local_forget_retry))
            }
        }
    }
}
