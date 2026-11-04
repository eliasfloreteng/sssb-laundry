package se.floreteng.sssblaundry.ui.update

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.launch
import se.floreteng.sssblaundry.R
import se.floreteng.sssblaundry.SssbLaundryApplication
import se.floreteng.sssblaundry.data.AppSettings

/** Days before "Later" asks again; settings keep offering it meanwhile. */
private const val LATER_MS = 3 * 24 * 60 * 60 * 1000L

/** After "Download", a day for the install to happen before it is offered again. */
private const val DOWNLOADED_MS = 24 * 60 * 60 * 1000L

/** Offers a newer APK when [se.floreteng.sssblaundry.update.AppUpdater] has found one. */
@Composable
fun UpdateDialog(settings: AppSettings) {
    val context = LocalContext.current
    val app = context.applicationContext as SssbLaundryApplication
    val scope = rememberCoroutineScope()
    val release by app.updater.available.collectAsStateWithLifecycle()
    val update = release ?: return
    if (System.currentTimeMillis() < settings.updateSnoozedUntil) return

    fun snooze(forMs: Long) {
        scope.launch { app.settings.snoozeUpdate(System.currentTimeMillis() + forMs) }
    }

    AlertDialog(
        onDismissRequest = { snooze(LATER_MS) },
        icon = { Icon(painterResource(R.drawable.ic_download), null) },
        title = { Text(stringResource(R.string.update_title)) },
        text = { Text(stringResource(R.string.update_body, update.label)) },
        confirmButton = {
            TextButton(onClick = {
                snooze(DOWNLOADED_MS)
                app.updater.download(context)
            }) { Text(stringResource(R.string.update_download)) }
        },
        dismissButton = {
            TextButton(onClick = { snooze(LATER_MS) }) { Text(stringResource(R.string.update_later)) }
        },
        containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
    )
}
