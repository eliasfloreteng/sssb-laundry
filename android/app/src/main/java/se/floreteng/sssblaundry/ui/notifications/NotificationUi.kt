package se.floreteng.sssblaundry.ui.notifications

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Resources
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LifecycleResumeEffect
import se.floreteng.sssblaundry.R
import se.floreteng.sssblaundry.SssbLaundryApplication
import se.floreteng.sssblaundry.data.AppSettings
import se.floreteng.sssblaundry.data.BookingAlert
import se.floreteng.sssblaundry.data.Lead
import se.floreteng.sssblaundry.data.LeadUnit

/** The picker row: "Before" is part of each phrase, not glued on, as on iOS. */
fun Resources.alertLabel(alert: BookingAlert): String {
    val lead = alert.lead ?: return getString(if (alert == BookingAlert.Off) R.string.none else R.string.alert_at_start)
    return quantity(lead, R.plurals.alert_minutes_before, R.plurals.alert_hours_before, R.plurals.alert_days_before, R.plurals.alert_weeks_before)
}

/** Just the span, "10 minutes", for a sentence of its own. */
fun Resources.leadLabel(lead: Lead): String =
    quantity(lead, R.plurals.lead_minutes, R.plurals.lead_hours, R.plurals.lead_days, R.plurals.lead_weeks)

private fun Resources.quantity(lead: Lead, minutes: Int, hours: Int, days: Int, weeks: Int): String {
    val id = when (lead.unit) {
        LeadUnit.Minute -> minutes
        LeadUnit.Hour -> hours
        LeadUnit.Day -> days
        LeadUnit.Week -> weeks
    }
    return getQuantityString(id, lead.count, lead.count)
}

/** Whether Android lets the app post at all: the permission on 13+, the app's switch on every version. */
fun Context.notificationsAllowed(): Boolean = NotificationManagerCompat.from(this).areNotificationsEnabled()

private fun Context.permissionGranted(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
    ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

/** The app's page in the system's notification settings. */
fun Context.openNotificationSettings() {
    startActivity(
        Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
    )
}

/** [allowed] follows the system setting, re-read whenever the screen comes back. */
class NotificationAccess(allowed: Boolean, val request: () -> Unit) {
    var allowed by mutableStateOf(allowed)
        internal set
}

/**
 * Turning notifications on is what asks for the permission, as the toggle does
 * on iOS. Granted, they are switched on and the token fetched; denied, they
 * stay off and the caller hears `false`, so it can point at system settings.
 */
@Composable
fun rememberNotificationAccess(onResult: (enabled: Boolean) -> Unit = {}): NotificationAccess {
    val context = LocalContext.current
    val app = context.applicationContext as SssbLaundryApplication
    val currentOnResult by rememberUpdatedState(onResult)

    fun finish(granted: Boolean) {
        val enabled = granted && context.notificationsAllowed()
        if (enabled) {
            app.push.enable()
        } else {
            app.push.markPrompted()
        }
        currentOnResult(enabled)
    }

    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        finish(granted)
    }
    val access = remember {
        NotificationAccess(context.notificationsAllowed()) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !context.permissionGranted()) {
                launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
            } else {
                finish(true)
            }
        }
    }
    LifecycleResumeEffect(Unit) {
        access.allowed = context.notificationsAllowed()
        onPauseOrDispose { }
    }
    return access
}

/**
 * The ask iOS raises right after a booking lands, while the answer is still
 * open: that is when a reminder is worth something.
 */
fun Context.shouldOfferNotifications(settings: AppSettings): Boolean =
    !settings.notificationsEnabled && !settings.notificationsPrompted &&
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) !permissionGranted() else notificationsAllowed()

@Composable
fun NotificationOfferDialog(alert: BookingAlert, onAccept: () -> Unit, onDismiss: () -> Unit) {
    val res = LocalResources.current
    // Whole sentences rather than a span slotted into one: how the offset joins
    // the sentence around it differs per language.
    val body = alert.lead?.let { res.getString(R.string.offer_body, res.leadLabel(it)) }
        ?: res.getString(R.string.offer_body_at_start)
    AlertDialog(
        onDismissRequest = onDismiss,
        icon = { Icon(painterResource(R.drawable.ic_notifications), null) },
        title = { Text(stringResource(R.string.offer_title)) },
        text = { Text(body) },
        confirmButton = {
            TextButton(onClick = {
                onDismiss()
                onAccept()
            }) { Text(stringResource(R.string.offer_accept)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.offer_decline)) } },
        containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
    )
}
