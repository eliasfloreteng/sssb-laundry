package se.floreteng.sssblaundry.ui.booking

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconToggleButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import se.floreteng.sssblaundry.R
import se.floreteng.sssblaundry.data.AppSettings
import se.floreteng.sssblaundry.data.BookingRules
import se.floreteng.sssblaundry.data.GroupStatus
import se.floreteng.sssblaundry.data.LaundryTime
import se.floreteng.sssblaundry.data.Timeslot
import se.floreteng.sssblaundry.data.TimeslotGroup
import se.floreteng.sssblaundry.data.canCallDibs
import se.floreteng.sssblaundry.data.hasStarted
import se.floreteng.sssblaundry.data.isFreePastLimit
import se.floreteng.sssblaundry.data.restriction
import se.floreteng.sssblaundry.data.timeRange
import se.floreteng.sssblaundry.data.visibleGroups
import se.floreteng.sssblaundry.ui.ActionOutcome
import se.floreteng.sssblaundry.ui.DibsOutcome
import se.floreteng.sssblaundry.ui.ErrorPresenter
import se.floreteng.sssblaundry.ui.LaundryViewModel
import se.floreteng.sssblaundry.ui.components.addToCalendar
import se.floreteng.sssblaundry.ui.groupName
import se.floreteng.sssblaundry.ui.groupNames
import se.floreteng.sssblaundry.ui.restrictionLabel

/** How an action landed: one headline, one reason, and a line per group when they disagreed. */
private data class Receipt(val success: Boolean, val title: String, val message: String, val details: List<String> = emptyList())

/**
 * Book, cancel or line up for the groups of one timeslot. The sheet stays open
 * after every action and reads the timeslot back out of the store, so once the
 * refresh lands it *is* the confirmation.
 */
@Composable
fun BookingSheet(
    timeslotId: String,
    vm: LaundryViewModel,
    settings: AppSettings,
    onDismiss: () -> Unit,
) {
    val res = LocalResources.current
    val context = LocalContext.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val current: Timeslot = vm.timeslot(timeslotId) ?: run {
        LaunchedEffect(Unit) { onDismiss() }
        return
    }
    val now = vm.now
    val hidden = settings.hiddenGroups
    val visible = current.visibleGroups(hidden)

    val ownIds = visible.filter { it.status == GroupStatus.Own }.map { it.groupId }.toSet()
    val dibsIds = visible.filter { it.hasDibs }.map { it.groupId }.toSet()
    /** What the user holds or waits for — the state the boxes start from and return to. */
    val heldIds = ownIds + dibsIds

    var selection by remember { mutableStateOf(heldIds) }
    var submitting by remember { mutableStateOf(false) }
    var receipt by remember { mutableStateOf<Receipt?>(null) }

    // A refresh landed — show what the server actually holds rather than the
    // selection that was attempted.
    LaunchedEffect(heldIds) { selection = heldIds }

    /** With dibs off a taken group is just taken — unless already in line, so it can be left. */
    fun isDibsable(group: TimeslotGroup) = group.canCallDibs(current, now) && (settings.dibsEnabled || group.hasDibs)

    val dibsableIds = visible.filter(::isDibsable).map { it.groupId }.toSet()
    val toCallDibs = (selection intersect dibsableIds) - dibsIds
    /** Leaving a line is always allowed, even once the slot has started. */
    val toDropDibs = dibsIds - selection
    val hasDibsChanges = toCallDibs.isNotEmpty() || toDropDibs.isNotEmpty()
    val toBook = (selection - ownIds).filter { id ->
        val group = visible.firstOrNull { it.groupId == id } ?: return@filter false
        group.status == GroupStatus.Bookable && group.restriction(current, now) == null
    }.sorted()
    // A booking whose slot started while the sheet sat open drops out here.
    val toCancel = (ownIds - selection).filter { id ->
        visible.firstOrNull { it.groupId == id }?.restriction(current, now) == null
    }.sorted()
    val hasChanges = toBook.isNotEmpty() || toCancel.isNotEmpty() || hasDibsChanges
    val overSlotLimit = toBook.size > BookingRules.MAX_GROUPS_PER_BOOKING || toCancel.size > BookingRules.MAX_GROUPS_PER_BOOKING

    // The per-room quota only informs: a local count of what the portal last
    // reported must never be what stops a booking.
    val maxSessions = settings.laundryRoom?.maxFutureBookings
    val ownCountInSlot = current.groups.count { it.status == GroupStatus.Own }
    val stillHeldHere = ownCountInSlot - toCancel.size + toBook.size > 0
    val projectedTotal = vm.futureSessions(excludingTimeslot = current.id).size +
        if (stillHeldHere && !current.hasStarted(now)) 1 else 0
    val limitHint = when {
        overSlotLimit -> stringResource(R.string.limit_groups, BookingRules.MAX_GROUPS_PER_BOOKING)
        maxSessions != null && projectedTotal > maxSessions -> stringResource(R.string.limit_sessions, projectedTotal, maxSessions)
        else -> null
    }

    val actionTitle = when {
        hasDibsChanges && (toBook.isNotEmpty() || toCancel.isNotEmpty() || (toCallDibs.isNotEmpty() && toDropDibs.isNotEmpty())) ->
            stringResource(R.string.action_apply)
        hasDibsChanges -> stringResource(if (toCallDibs.isEmpty()) R.string.action_leave_line else R.string.action_call_dibs)
        toBook.isNotEmpty() && toCancel.isEmpty() ->
            if (toBook.size > 1) stringResource(R.string.action_book_n, toBook.size) else stringResource(R.string.action_book)
        toBook.isEmpty() && toCancel.isNotEmpty() ->
            if (toCancel.size > 1) stringResource(R.string.action_cancel_n, toCancel.size) else stringResource(R.string.action_cancel)
        toBook.isNotEmpty() -> stringResource(R.string.action_apply)
        else -> stringResource(R.string.action_no_changes)
    }

    fun names(ids: Collection<Int>) = res.groupNames(ids.sorted(), vm.groupsById)

    fun failureReceipt(outcome: ActionOutcome): Receipt {
        outcome.requestError?.let {
            return Receipt(false, ErrorPresenter.headline(res, it), ErrorPresenter.explanation(res, it))
        }
        val succeeded = outcome.results.count { it.isSuccessful }
        // Every group gets a line: after a partial failure, knowing exactly where
        // things landed is the only thing that helps.
        val details = outcome.results.map {
            ErrorPresenter.summary(res, it.result, it.action, res.groupName(it.groupId, vm.groupsById), settings.laundryRoom)
        }
        return if (succeeded == 0) {
            val onlyCancelling = toBook.isEmpty()
            Receipt(
                false,
                res.getString(if (onlyCancelling) R.string.err_headline_cancellation_failed else R.string.err_headline_booking_failed),
                res.getString(if (onlyCancelling) R.string.receipt_nothing_cancelled else R.string.receipt_nothing_booked),
                details,
            )
        } else {
            Receipt(
                false,
                res.getString(R.string.receipt_partial_title),
                res.getString(R.string.receipt_partial_body, succeeded, outcome.results.size),
                details,
            )
        }
    }

    fun successReceipt(book: List<Int>, cancel: List<Int>): Receipt = when {
        book.isNotEmpty() && cancel.isEmpty() -> Receipt(
            true,
            res.getString(R.string.receipt_booked_title),
            res.getString(if (book.size > 1) R.string.receipt_booked_many else R.string.receipt_booked_one, names(book)),
        )
        book.isEmpty() && cancel.isNotEmpty() -> Receipt(
            true,
            res.getString(R.string.receipt_cancelled_title),
            res.getString(if (cancel.size > 1) R.string.receipt_cancelled_many else R.string.receipt_cancelled_one, names(cancel)),
        )
        else -> Receipt(
            true,
            res.getString(R.string.receipt_changes_title),
            res.getString(R.string.receipt_changes_body, names(book), names(cancel)),
        )
    }

    fun dibsReceipt(add: Set<Int>, remove: Set<Int>): Receipt {
        if (add.isEmpty()) {
            return Receipt(true, res.getString(R.string.receipt_left_line_title), res.getString(R.string.receipt_left_line_body, names(remove)))
        }
        val free = current.groups.filter { it.groupId in add }.all { it.isFreePastLimit }
        val base = res.getString(if (free) R.string.receipt_dibs_free_body else R.string.receipt_dibs_taken_body, names(add))
        // The booking happens either way; only hearing about it needs notifications.
        val hint = res.getString(if (settings.notificationsEnabled) R.string.receipt_dibs_notified else R.string.receipt_dibs_notify_off)
        return Receipt(true, res.getString(R.string.receipt_in_line_title), "$base $hint")
    }

    fun submit() {
        if (!hasChanges || overSlotLimit) return
        receipt = null
        submitting = true
        val book = toBook
        val cancel = toCancel
        val add = toCallDibs
        val remove = toDropDibs
        vm.launch {
            try {
                var booked = false
                if (book.isNotEmpty() || cancel.isNotEmpty()) {
                    val outcome = vm.bookAndCancel(current.id, book, cancel)
                    if (!outcome.isFullSuccess) {
                        receipt = failureReceipt(outcome)
                        return@launch
                    }
                    booked = true
                }
                if (add.isNotEmpty() || remove.isNotEmpty()) {
                    when (val result = vm.setDibs(current.id, add.sorted(), remove.sorted())) {
                        is DibsOutcome.Failure -> {
                            receipt = Receipt(false, ErrorPresenter.headline(res, result.error), ErrorPresenter.explanation(res, result.error))
                            return@launch
                        }
                        DibsOutcome.Success -> if (!booked) {
                            receipt = dibsReceipt(add, remove)
                            return@launch
                        }
                    }
                }
                receipt = successReceipt(book, cancel)
            } finally {
                submitting = false
            }
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            Modifier
                .verticalScroll(rememberScrollState())
                .navigationBarsPadding()
                .padding(horizontal = 24.dp)
                .padding(bottom = 16.dp),
        ) {
            // Header: the day, the time big, and the one action that needs no selection.
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(
                        LaundryTime.dayLabel(current.localDate),
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(current.timeRange, style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Medium)
                }
                if (ownIds.isNotEmpty()) {
                    FilledTonalIconButton(
                        onClick = { context.addToCalendar(current, ownIds.sorted(), vm.groupsById) },
                        enabled = !submitting,
                    ) {
                        Icon(painterResource(R.drawable.ic_calendar_add), stringResource(R.string.row_add_to_calendar))
                    }
                }
            }
            if (current.spansMidnight) {
                AssistChip(
                    onClick = {},
                    label = { Text(stringResource(R.string.overnight)) },
                    leadingIcon = { Icon(painterResource(R.drawable.ic_bedtime), null, Modifier.size(AssistChipDefaults.IconSize)) },
                    modifier = Modifier.padding(top = 8.dp),
                )
            }

            Spacer(Modifier.height(16.dp))

            // One segmented group per laundry room, in the order the groups came.
            val sections = visible.groupBy { vm.groupsById[it.groupId]?.place.orEmpty() }
            sections.forEach { (location, items) ->
                if (location.isNotEmpty()) {
                    Text(
                        location,
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.padding(start = 8.dp, top = 8.dp, bottom = 8.dp),
                    )
                }
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    items.forEachIndexed { index, item ->
                        GroupRow(
                            item = item,
                            name = res.groupName(item.groupId, vm.groupsById),
                            selected = item.groupId in selection,
                            restriction = item.restriction(current, now),
                            dibsable = isDibsable(item),
                            enabled = !submitting,
                            shape = se.floreteng.sssblaundry.ui.components.segmentShape(index, items.size),
                            onToggle = {
                                receipt = null
                                selection = if (item.groupId in selection) selection - item.groupId else selection + item.groupId
                            },
                        )
                    }
                }
                Spacer(Modifier.height(8.dp))
            }

            Spacer(Modifier.height(8.dp))

            Column(verticalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.animateContentSize()) {
                AnimatedVisibility(visible = receipt != null) {
                    receipt?.let { ReceiptCard(it) }
                }

                Button(
                    onClick = ::submit,
                    enabled = hasChanges && !submitting && !overSlotLimit,
                    contentPadding = ButtonDefaults.contentPaddingFor(ButtonDefaults.MediumContainerHeight),
                    modifier = Modifier.fillMaxWidth().height(ButtonDefaults.MediumContainerHeight),
                ) {
                    if (submitting) {
                        LoadingIndicator(Modifier.size(28.dp), color = MaterialTheme.colorScheme.onPrimary)
                    } else {
                        Text(actionTitle, style = ButtonDefaults.textStyleFor(ButtonDefaults.MediumContainerHeight))
                    }
                }

                if (receipt == null && dibsableIds.isNotEmpty() && dibsIds.isEmpty()) {
                    val allFree = visible.filter { it.groupId in dibsableIds }.all { it.isFreePastLimit }
                    Hint(stringResource(if (allFree) R.string.hint_dibs_free else R.string.hint_dibs_taken))
                }
                limitHint?.let { Hint(it) }
            }
        }
    }
}

@Composable
private fun GroupRow(
    item: TimeslotGroup,
    name: String,
    selected: Boolean,
    restriction: se.floreteng.sssblaundry.data.GroupRestriction?,
    dibsable: Boolean,
    enabled: Boolean,
    shape: androidx.compose.ui.graphics.Shape,
    onToggle: () -> Unit,
) {
    val res = LocalResources.current
    // Everything upstream would refuse is off the table here, and the row says
    // why. A group somebody else holds is the exception: ticking it calls dibs.
    val blocked = restriction != null && !dibsable
    val supporting: String? = when {
        dibsable -> when {
            item.hasDibs && selected && item.dibsQueue != null ->
                if (item.dibsQueue == 1) stringResource(R.string.dibs_next_in_line) else stringResource(R.string.dibs_place, item.dibsQueue)
            selected -> stringResource(R.string.status_dibs)
            item.isFreePastLimit -> stringResource(R.string.dibs_at_limit_tick)
            else -> stringResource(R.string.dibs_taken_tick)
        }
        restriction != null -> res.restrictionLabel(restriction, item.status)
        item.status == GroupStatus.Own -> stringResource(R.string.status_booked)
        else -> null
    }
    val highlight = (dibsable && selected) || (restriction == null && item.status == GroupStatus.Own)

    Surface(shape = shape, color = MaterialTheme.colorScheme.surfaceContainerHigh) {
        ListItem(
            headlineContent = { Text(name) },
            supportingContent = supporting?.let {
                {
                    Text(
                        it,
                        color = if (highlight) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                        fontWeight = if (highlight) FontWeight.SemiBold else null,
                    )
                }
            },
            leadingContent = {
                if (dibsable) {
                    // A hand rather than a box: ticking it waits for the group rather than booking it.
                    Icon(
                        painterResource(if (selected) R.drawable.ic_hand_filled else R.drawable.ic_hand),
                        null,
                        tint = if (selected) MaterialTheme.colorScheme.tertiary else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(24.dp),
                    )
                } else {
                    Checkbox(checked = selected, onCheckedChange = null, enabled = !blocked && enabled)
                }
            },
            colors = ListItemDefaults.colors(containerColor = Color.Transparent),
            modifier = Modifier
                .alpha(if (blocked) 0.5f else 1f)
                .toggleable(
                    value = selected,
                    enabled = !blocked && enabled,
                    role = if (dibsable) Role.Switch else Role.Checkbox,
                    onValueChange = { onToggle() },
                ),
        )
    }
}

@Composable
private fun ReceiptCard(receipt: Receipt) {
    val colors = MaterialTheme.colorScheme
    val container = if (receipt.success) colors.primaryContainer else colors.errorContainer
    val content = if (receipt.success) colors.onPrimaryContainer else colors.onErrorContainer
    Surface(shape = RoundedCornerShape(20.dp), color = container, contentColor = content, modifier = Modifier.fillMaxWidth()) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.padding(16.dp)) {
            Icon(
                painterResource(if (receipt.success) R.drawable.ic_check_circle_filled else R.drawable.ic_error_filled),
                null,
            )
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(receipt.title, style = MaterialTheme.typography.titleSmall)
                Text(receipt.message, style = MaterialTheme.typography.bodyMedium)
                receipt.details.forEach { Text("• $it", style = MaterialTheme.typography.bodySmall) }
            }
        }
    }
}

@Composable
private fun Hint(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp),
    )
}
