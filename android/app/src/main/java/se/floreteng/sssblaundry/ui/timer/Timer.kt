package se.floreteng.sssblaundry.ui.timer

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import se.floreteng.sssblaundry.R
import se.floreteng.sssblaundry.ui.BookedSlot
import se.floreteng.sssblaundry.ui.components.startLaundryTimer

/** The session under way, at the top of the week list, with the timer one tap away. */
@Composable
fun SessionTimerCard(session: BookedSlot, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(24.dp),
        color = MaterialTheme.colorScheme.primaryContainer,
        contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
        modifier = modifier.fillMaxWidth(),
    ) {
        ListItem(
            leadingContent = { Icon(painterResource(R.drawable.ic_timer), null) },
            headlineContent = { Text(stringResource(R.string.start_a_timer), fontWeight = FontWeight.Medium) },
            supportingContent = { Text(stringResource(R.string.timer_session_until, session.endTime)) },
            trailingContent = { Icon(painterResource(R.drawable.ic_chevron_right), null) },
            colors = ListItemDefaults.colors(
                containerColor = Color.Transparent,
                headlineColor = MaterialTheme.colorScheme.onPrimaryContainer,
                supportingColor = MaterialTheme.colorScheme.onPrimaryContainer,
                leadingIconColor = MaterialTheme.colorScheme.onPrimaryContainer,
                trailingIconColor = MaterialTheme.colorScheme.onPrimaryContainer,
            ),
        )
    }
}

private val presets = listOf(30, 45, 60, 90, 120)

/**
 * How long the machine is going to take: a length and the button that starts
 * counting. The Clock app keeps and rings the timer, so it works with the app
 * closed and the phone on silent.
 */
@Composable
fun TimerSheet(session: BookedSlot?, onDismiss: () -> Unit) {
    val context = LocalContext.current
    // Opens on nothing, so the length is always one dialled in for the programme running.
    var minutes by rememberSaveable { mutableIntStateOf(0) }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(20.dp),
            modifier = Modifier.navigationBarsPadding().padding(horizontal = 24.dp).padding(bottom = 16.dp),
        ) {
            Text(stringResource(R.string.timer), style = MaterialTheme.typography.headlineSmall)

            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Stepper(onMinus = { minutes = (minutes - 60).coerceAtLeast(0) }, onPlus = { minutes = (minutes + 60).coerceAtMost(9 * 60) }) {
                    Value(minutes / 60, stringResource(R.string.hours_short))
                }
                Stepper(onMinus = { minutes = (minutes - 5).coerceAtLeast(0) }, onPlus = { minutes = (minutes + 5).coerceAtMost(9 * 60 + 55) }) {
                    Value(minutes % 60, stringResource(R.string.minutes_short))
                }
            }

            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally)) {
                presets.forEach { preset ->
                    FilterChip(
                        selected = minutes == preset,
                        onClick = { minutes = preset },
                        label = { Text(durationLabel(preset)) },
                    )
                }
            }

            Text(
                stringResource(R.string.timer_body),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            Button(
                onClick = { if (context.startLaundryTimer(minutes * 60)) onDismiss() },
                enabled = minutes >= 1,
                contentPadding = ButtonDefaults.contentPaddingFor(ButtonDefaults.MediumContainerHeight),
                modifier = Modifier.fillMaxWidth().height(ButtonDefaults.MediumContainerHeight),
            ) {
                Text(stringResource(R.string.start), style = ButtonDefaults.textStyleFor(ButtonDefaults.MediumContainerHeight))
            }
        }
    }
}

@Composable
private fun Stepper(onMinus: () -> Unit, onPlus: () -> Unit, value: @Composable () -> Unit) {
    Surface(shape = RoundedCornerShape(28.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.padding(12.dp)) {
            FilledTonalIconButton(onClick = onPlus) { Icon(painterResource(R.drawable.ic_add), null) }
            Box(Modifier.width(96.dp).padding(vertical = 8.dp), contentAlignment = Alignment.Center) { value() }
            FilledTonalIconButton(onClick = onMinus) { Icon(painterResource(R.drawable.ic_remove), null) }
        }
    }
}

@Composable
private fun Value(number: Int, unit: String) {
    Row(verticalAlignment = Alignment.Bottom) {
        Text("$number", style = MaterialTheme.typography.displayMedium, fontWeight = FontWeight.Medium)
        Text(" $unit", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(bottom = 8.dp))
    }
}

/** "45 min", "1 h", "1 h 30 min". */
@Composable
private fun durationLabel(minutes: Int): String {
    val h = minutes / 60
    val m = minutes % 60
    val hours = stringResource(R.string.hours_short)
    val mins = stringResource(R.string.minutes_short)
    return when {
        h == 0 -> "$m $mins"
        m == 0 -> "$h $hours"
        else -> "$h $hours $m $mins"
    }
}
