package se.floreteng.sssblaundry.ui.components

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.AlarmClock
import android.provider.CalendarContract
import android.widget.Toast
import androidx.annotation.DrawableRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CornerSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.toShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.Box
import se.floreteng.sssblaundry.R
import se.floreteng.sssblaundry.data.LaundryGroup
import se.floreteng.sssblaundry.data.Timeslot
import se.floreteng.sssblaundry.data.end
import se.floreteng.sssblaundry.data.start

/**
 * The segmented list look of Android 16's own settings: rows in one group share
 * small inner corners and the ends round off, with a hairline gap between.
 */
fun segmentShape(index: Int, count: Int): Shape {
    val large = CornerSize(20.dp)
    val small = CornerSize(4.dp)
    return RoundedCornerShape(
        topStart = if (index == 0) large else small,
        topEnd = if (index == 0) large else small,
        bottomStart = if (index == count - 1) large else small,
        bottomEnd = if (index == count - 1) large else small,
    )
}

/** An expressive empty or error state: a shaped glyph, a headline and a line of help. */
@Composable
fun MessageState(
    @DrawableRes icon: Int,
    title: String,
    body: String,
    modifier: Modifier = Modifier,
    action: (@Composable () -> Unit)? = null,
) {
    Box(contentAlignment = Alignment.Center, modifier = modifier.fillMaxSize().padding(32.dp)) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
            modifier = Modifier.widthIn(max = 420.dp),
        ) {
            Surface(
                shape = MaterialShapes.Sunny.toShape(),
                color = MaterialTheme.colorScheme.secondaryContainer,
                contentColor = MaterialTheme.colorScheme.onSecondaryContainer,
                modifier = Modifier.size(96.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(painterResource(icon), null, Modifier.size(40.dp))
                }
            }
            Text(title, style = MaterialTheme.typography.headlineSmall, textAlign = TextAlign.Center)
            Text(
                body,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
            action?.invoke()
        }
    }
}

fun Context.copyToClipboard(label: String, text: String) {
    getSystemService(ClipboardManager::class.java)?.setPrimaryClip(ClipData.newPlainText(label, text))
    // Android 13 and later confirm a copy themselves.
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
        Toast.makeText(this, R.string.copied, Toast.LENGTH_SHORT).show()
    }
}

fun Context.share(text: String) {
    val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
    startActivity(Intent.createChooser(send, null))
}

/**
 * Hands the booking to whichever calendar app the phone has. No permission is
 * needed: the user reviews and saves the event there.
 */
fun Context.addToCalendar(timeslot: Timeslot, groupIds: List<Int>, groups: Map<Int, LaundryGroup>): Boolean {
    val start = timeslot.start ?: return false
    val end = timeslot.end ?: return false
    val names = groupIds.map { groups[it]?.name ?: getString(R.string.group_fallback, it) }
    val locations = groupIds.mapNotNull { groups[it]?.place?.takeIf(String::isNotEmpty) }.distinct()
    val intent = Intent(Intent.ACTION_INSERT)
        .setData(CalendarContract.Events.CONTENT_URI)
        .putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, start.toEpochMilli())
        .putExtra(CalendarContract.EXTRA_EVENT_END_TIME, end.toEpochMilli())
        .putExtra(CalendarContract.Events.TITLE, "${getString(R.string.calendar_event_title)} · ${names.joinToString(", ")}")
        .putExtra(CalendarContract.Events.DESCRIPTION, getString(R.string.calendar_event_description))
        .putExtra(CalendarContract.Events.EVENT_TIMEZONE, "Europe/Stockholm")
    if (locations.size == 1) intent.putExtra(CalendarContract.Events.EVENT_LOCATION, locations.first())
    return try {
        startActivity(intent)
        true
    } catch (_: ActivityNotFoundException) {
        Toast.makeText(this, R.string.calendar_unavailable, Toast.LENGTH_SHORT).show()
        false
    }
}

/**
 * Starts a countdown in the Clock app, which is what rings in another room with
 * the phone on silent. The app keeps no copy: the Clock app owns the timer.
 */
fun Context.startLaundryTimer(seconds: Int): Boolean {
    val intent = Intent(AlarmClock.ACTION_SET_TIMER)
        .putExtra(AlarmClock.EXTRA_LENGTH, seconds)
        .putExtra(AlarmClock.EXTRA_MESSAGE, getString(R.string.calendar_event_title))
        .putExtra(AlarmClock.EXTRA_SKIP_UI, false)
    return try {
        startActivity(intent)
        true
    } catch (_: ActivityNotFoundException) {
        Toast.makeText(this, R.string.timer_unavailable, Toast.LENGTH_SHORT).show()
        false
    }
}
