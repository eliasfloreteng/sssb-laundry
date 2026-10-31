package se.floreteng.sssblaundry.ui.week

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import se.floreteng.sssblaundry.R
import se.floreteng.sssblaundry.data.GroupStatus
import se.floreteng.sssblaundry.data.LaundryGroup
import se.floreteng.sssblaundry.data.Timeslot
import se.floreteng.sssblaundry.data.TimeslotGroup
import se.floreteng.sssblaundry.data.actionableGroups
import se.floreteng.sssblaundry.data.canCallDibs
import se.floreteng.sssblaundry.data.freePastLimitGroups
import se.floreteng.sssblaundry.data.isFreePastLimit
import se.floreteng.sssblaundry.data.restriction
import se.floreteng.sssblaundry.data.visibleGroups
import java.time.Instant

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TimeslotRow(
    timeslot: Timeslot,
    groups: Map<Int, LaundryGroup>,
    hidden: Set<Int>,
    dibsEnabled: Boolean,
    now: Instant,
    shape: Shape,
    isBusy: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val visible = timeslot.visibleGroups(hidden)
    val hasOwn = visible.any { it.status == GroupStatus.Own }
    val hasDibs = visible.any { it.hasDibs }
    val hasBookable = timeslot.actionableGroups(hidden, now).isNotEmpty() ||
        (dibsEnabled && timeslot.freePastLimitGroups(hidden, now).isNotEmpty())
    // Nothing to book and nothing of yours: a row that is only there for context.
    val isSpent = !hasOwn && !hasBookable && !hasDibs

    // Your own groups plus whatever can still be booked. A free group that is no
    // longer bookable is left off rather than shown as an invitation.
    val chips = visible.filter { group ->
        group.status == GroupStatus.Own || group.hasDibs || group.restriction(timeslot, now) == null ||
            (dibsEnabled && group.isFreePastLimit && group.canCallDibs(timeslot, now))
    }
    val sharesOneLocation = visible.mapNotNull { groups[it.groupId]?.place }.toSet().size <= 1

    Surface(
        shape = shape,
        color = MaterialTheme.colorScheme.surfaceBright,
        modifier = modifier
            .fillMaxWidth()
            .combinedClickable(
                enabled = enabled,
                role = Role.Button,
                onClick = onClick,
                onLongClick = onLongClick,
            ),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier
                .padding(start = 16.dp, end = 12.dp, top = 12.dp, bottom = 12.dp)
                .alpha(if (isSpent) 0.5f else 1f),
        ) {
            Column(Modifier.width(52.dp)) {
                Text(
                    timeslot.startTime,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    timeslot.endTime,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            ChipStrip(
                chips = chips,
                label = { group ->
                    val info = groups[group.groupId]
                    when {
                        info == null -> stringResource(R.string.group_fallback, group.groupId)
                        !sharesOneLocation && info.place.isNotEmpty() -> "${info.place} · ${info.name}"
                        else -> info.name
                    }
                },
                modifier = Modifier.weight(1f),
            )

            Box(contentAlignment = Alignment.Center, modifier = Modifier.size(32.dp)) {
                when {
                    isBusy -> LoadingIndicator(Modifier.size(32.dp))
                    hasOwn -> Icon(
                        painterResource(R.drawable.ic_check_circle_filled),
                        stringResource(R.string.status_booked),
                        tint = MaterialTheme.colorScheme.primary,
                    )
                    hasDibs -> Icon(
                        painterResource(R.drawable.ic_hand_filled),
                        stringResource(R.string.status_dibs),
                        tint = MaterialTheme.colorScheme.tertiary,
                    )
                    hasBookable -> Icon(
                        painterResource(R.drawable.ic_chevron_right),
                        null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

/** One line of chips that scrolls sideways and fades out at the end rather than wrapping. */
@Composable
private fun ChipStrip(
    chips: List<TimeslotGroup>,
    label: @Composable (TimeslotGroup) -> String,
    modifier: Modifier = Modifier,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = modifier
            .graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen)
            .drawWithContent {
                drawContent()
                drawRect(
                    brush = Brush.horizontalGradient(
                        0.85f to Color.Black,
                        1f to Color.Transparent,
                    ),
                    blendMode = BlendMode.DstIn,
                )
            }
            .horizontalScroll(rememberScrollState()),
    ) {
        chips.forEach { group ->
            GroupChip(name = label(group), status = group.status, dibs = group.hasDibs)
        }
    }
}

/** A group's state at a glance: yours filled, free outlined, in line tonal with a hand. */
@Composable
fun GroupChip(name: String, status: GroupStatus, dibs: Boolean, modifier: Modifier = Modifier) {
    val colors = MaterialTheme.colorScheme
    val (container, content) = when {
        dibs -> colors.tertiaryContainer to colors.onTertiaryContainer
        status == GroupStatus.Own -> colors.primary to colors.onPrimary
        status == GroupStatus.Bookable -> Color.Transparent to colors.onSurface
        else -> colors.surfaceContainerHighest to colors.onSurfaceVariant
    }
    Surface(
        shape = CircleShape,
        color = container,
        contentColor = content,
        border = if (status == GroupStatus.Bookable && !dibs) BorderStroke(1.dp, colors.outlineVariant) else null,
        modifier = modifier,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
        ) {
            if (dibs) Icon(painterResource(R.drawable.ic_hand_filled), null, Modifier.size(14.dp))
            Text(
                name,
                style = MaterialTheme.typography.labelMedium,
                maxLines = 1,
                overflow = TextOverflow.Visible,
                softWrap = false,
            )
        }
    }
}
