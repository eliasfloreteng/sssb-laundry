package se.floreteng.sssblaundry.ui.week

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeFlexibleTopAppBar
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SelectableDates
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TooltipAnchorPosition
import androidx.compose.material3.TooltipBox
import androidx.compose.material3.TooltipDefaults
import androidx.compose.material3.PlainTooltip
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.pulltorefresh.PullToRefreshDefaults
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberTooltipState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import se.floreteng.sssblaundry.R
import se.floreteng.sssblaundry.data.AppSettings
import se.floreteng.sssblaundry.data.BookingRules
import se.floreteng.sssblaundry.data.GroupStatus
import se.floreteng.sssblaundry.data.LaundryTime
import se.floreteng.sssblaundry.data.Timeslot
import se.floreteng.sssblaundry.data.actionableGroups
import se.floreteng.sssblaundry.data.dayAndTime
import se.floreteng.sssblaundry.data.dibsableGroups
import se.floreteng.sssblaundry.data.hasDibs
import se.floreteng.sssblaundry.data.hasOwnGroup
import se.floreteng.sssblaundry.data.visibleGroups
import se.floreteng.sssblaundry.ui.DibsOutcome
import se.floreteng.sssblaundry.ui.EmptyReason
import se.floreteng.sssblaundry.ui.ErrorPresenter
import se.floreteng.sssblaundry.ui.LaundryViewModel
import se.floreteng.sssblaundry.ui.LoadState
import se.floreteng.sssblaundry.ui.booking.BookingSheet
import se.floreteng.sssblaundry.ui.components.MessageState
import se.floreteng.sssblaundry.ui.components.addToCalendar
import se.floreteng.sssblaundry.ui.components.copyToClipboard
import se.floreteng.sssblaundry.ui.components.segmentShape
import se.floreteng.sssblaundry.ui.failure
import se.floreteng.sssblaundry.ui.feedback.FeedbackSheet
import se.floreteng.sssblaundry.ui.groupName
import se.floreteng.sssblaundry.ui.groupNames
import se.floreteng.sssblaundry.ui.invite.InviteSheet
import se.floreteng.sssblaundry.ui.notifications.NotificationOfferDialog
import se.floreteng.sssblaundry.ui.notifications.rememberNotificationAccess
import se.floreteng.sssblaundry.ui.notifications.shouldOfferNotifications
import se.floreteng.sssblaundry.ui.timer.SessionTimerCard
import se.floreteng.sssblaundry.ui.timer.TimerSheet

/** A release a long press asked for, held until the confirmation comes back. */
private data class PendingCancel(val timeslot: Timeslot, val groupIds: List<Int>, val message: String)

@Composable
fun WeekScreen(
    vm: LaundryViewModel,
    settings: AppSettings,
    onOpenSettings: () -> Unit,
    onOpenDibsPriority: () -> Unit,
) {
    val context = LocalContext.current
    val res = LocalResources.current
    val haptics = LocalHapticFeedback.current
    val snackbar = remember { SnackbarHostState() }
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    val listState = rememberLazyListState()
    val hidden = settings.hiddenGroups

    var selectedTimeslot by remember { mutableStateOf<String?>(null) }
    var menuOpen by remember { mutableStateOf(false) }
    var rowMenuFor by remember { mutableStateOf<String?>(null) }
    var showDatePicker by remember { mutableStateOf(false) }
    var showInvite by remember { mutableStateOf(false) }
    var showFeedback by remember { mutableStateOf(false) }
    var showTimer by remember { mutableStateOf(false) }
    var pendingCancel by remember { mutableStateOf<PendingCancel?>(null) }
    var offeringNotifications by remember { mutableStateOf(false) }
    val notifications = rememberNotificationAccess()
    /** Timeslots with a long-press action in flight; the row is the only progress shown. */
    val busy = remember { mutableStateListOf<String>() }

    LaunchedEffect(Unit) { vm.loadInitial() }

    // A jump is a different list, not a scroll: the day picked goes to the top.
    LaunchedEffect(vm.anchorDate) { listState.scrollToItem(0) }

    // On the list rather than in the sheet: every action lands here, whether it
    // came from the sheet or a long press, and one place to fire means one haptic.
    LaunchedEffect(vm.lastOutcome?.id) {
        val outcome = vm.lastOutcome ?: return@LaunchedEffect
        haptics.performHapticFeedback(
            if (outcome.isFullSuccess) HapticFeedbackType.Confirm else HapticFeedbackType.Reject,
        )
        // Right after a booking is when a reminder is worth something, so that is
        // when to ask. A beat first, so the ask follows the confirmation.
        if (outcome.didBook && context.shouldOfferNotifications(settings)) {
            delay(700)
            offeringNotifications = true
        }
    }

    LaunchedEffect(vm.lastError) {
        val error = vm.lastError ?: return@LaunchedEffect
        val result = snackbar.showSnackbar(
            message = "${ErrorPresenter.headline(res, error)}. ${ErrorPresenter.explanation(res, error)}",
            actionLabel = res.getString(R.string.try_again),
            withDismissAction = true,
            duration = SnackbarDuration.Long,
        )
        if (result == SnackbarResult.ActionPerformed) vm.retry() else vm.lastError = null
    }

    fun groupName(id: Int) = res.groupName(id, vm.groupsById)

    fun act(ts: Timeslot, book: List<Int>, cancel: List<Int>) {
        busy += ts.id
        vm.launch {
            try {
                val outcome = vm.bookAndCancel(ts.id, book, cancel)
                outcome.failure(res, vm.groupsById, settings.laundryRoom)?.let { vm.lastError = it }
            } finally {
                busy -= ts.id
            }
        }
    }

    fun changeDibs(ts: Timeslot, add: List<Int>, remove: List<Int>) {
        busy += ts.id
        vm.launch {
            try {
                val outcome = vm.setDibs(ts.id, add, remove)
                if (outcome is DibsOutcome.Failure) vm.lastError = outcome.error
            } finally {
                busy -= ts.id
            }
        }
    }

    /** Names what is about to be released the way the menu named it. */
    fun askToCancel(ts: Timeslot, groupIds: List<Int>, named: Boolean) {
        val ids = groupIds.sorted()
        val subject = if (named) "${res.groupNames(ids, vm.groupsById)}, ${ts.dayAndTime}" else ts.dayAndTime
        pendingCancel = PendingCancel(
            ts,
            ids,
            res.getString(if (ids.size > 1) R.string.cancel_dialog_many else R.string.cancel_dialog_one, subject),
        )
    }

    /** A booking stays openable after it has started: the sheet still lists it. */
    fun canOpen(ts: Timeslot): Boolean = ts.hasOwnGroup(hidden) || ts.hasDibs(hidden) ||
        ts.actionableGroups(hidden, vm.now).isNotEmpty() ||
        (settings.dibsEnabled && ts.dibsableGroups(hidden, vm.now).isNotEmpty())

    Scaffold(
        modifier = Modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        containerColor = MaterialTheme.colorScheme.surfaceContainer,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            LargeFlexibleTopAppBar(
                title = { Text(stringResource(R.string.title_laundry)) },
                subtitle = {
                    val room = settings.laundryRoom
                    when {
                        !vm.isViewingToday -> Text(LaundryTime.dayLabel(vm.anchorDate))
                        room != null -> Text(room.room)
                    }
                },
                actions = {
                    IconTooltip(stringResource(R.string.action_jump_to_date)) {
                        IconButton(onClick = { showDatePicker = true }, enabled = !vm.isJumping) {
                            if (vm.isJumping) {
                                LoadingIndicator(Modifier.size(24.dp))
                            } else {
                                Icon(painterResource(R.drawable.ic_calendar), stringResource(R.string.action_jump_to_date))
                            }
                        }
                    }
                    Box {
                        IconTooltip(stringResource(R.string.menu)) {
                            IconButton(onClick = { menuOpen = true }) {
                                Icon(painterResource(R.drawable.ic_more_vert), stringResource(R.string.menu))
                            }
                        }
                        OverflowMenu(
                            expanded = menuOpen,
                            onDismiss = { menuOpen = false },
                            showAll = settings.showAllTimeslots,
                            dibsEnabled = settings.dibsEnabled,
                            onToggleShowAll = {
                                vm.launch { vm.settingsRepository.setShowAllTimeslots(!settings.showAllTimeslots) }
                            },
                            onDibsPriority = onOpenDibsPriority,
                            onInvite = { showInvite = true },
                            onFeedback = { showFeedback = true },
                            onSettings = onOpenSettings,
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surfaceContainer,
                    scrolledContainerColor = MaterialTheme.colorScheme.surfaceContainer,
                ),
                scrollBehavior = scrollBehavior,
            )
        },
        floatingActionButton = {
            // Without it the user is left on a list they cannot scroll out of —
            // there is nothing above the anchor to scroll to.
            AnimatedVisibility(visible = !vm.isViewingToday && vm.weeks.isNotEmpty()) {
                ExtendedFloatingActionButton(
                    onClick = { vm.jumpToToday() },
                    icon = { Icon(painterResource(R.drawable.ic_today), null) },
                    text = { Text(stringResource(R.string.action_back_to_today)) },
                )
            }
        },
    ) { padding ->
        val pullState = rememberPullToRefreshState()
        PullToRefreshBox(
            isRefreshing = vm.isRefreshing,
            onRefresh = vm::pullToRefresh,
            state = pullState,
            indicator = {
                PullToRefreshDefaults.LoadingIndicator(
                    state = pullState,
                    isRefreshing = vm.isRefreshing,
                    modifier = Modifier.align(Alignment.TopCenter),
                )
            },
            modifier = Modifier.fillMaxSize().padding(padding),
        ) {
            val days = vm.visibleDays(settings)
            val state = vm.loadState
            when {
                vm.weeks.isEmpty() && state is LoadState.Failed -> MessageState(
                    icon = R.drawable.ic_warning,
                    title = ErrorPresenter.headline(res, state.error),
                    body = ErrorPresenter.explanation(res, state.error),
                    action = { Button(onClick = vm::retry) { Text(stringResource(R.string.try_again)) } },
                )
                vm.weeks.isEmpty() -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    val label = stringResource(R.string.loading_timeslots)
                    LoadingIndicator(Modifier.size(64.dp).semantics { contentDescription = label })
                }
                days.isEmpty() && vm.reachedEnd -> EmptyState(vm)
                else -> LazyColumn(
                    state = listState,
                    contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 96.dp),
                    modifier = Modifier.fillMaxSize(),
                ) {
                    // Above the days: a session already running is not something to
                    // browse for — it is what the user is standing in front of.
                    vm.runningSession?.let { session ->
                        item(key = "timer") {
                            SessionTimerCard(session = session, onClick = { showTimer = true }, modifier = Modifier.padding(top = 8.dp))
                        }
                    }

                    days.forEach { day ->
                        stickyHeader(key = "header-${day.date}") {
                            Text(
                                LaundryTime.dayLabel(day.date),
                                style = MaterialTheme.typography.titleSmall,
                                color = MaterialTheme.colorScheme.primary,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .background(MaterialTheme.colorScheme.surfaceContainer)
                                    .padding(start = 8.dp, top = 20.dp, bottom = 8.dp),
                            )
                        }
                        itemsIndexed(day.slots, key = { _, ts -> ts.id }) { index, ts ->
                            val isBusy = ts.id in busy
                            Box(Modifier.animateItem().padding(bottom = 2.dp)) {
                                TimeslotRow(
                                    timeslot = ts,
                                    groups = vm.groupsById,
                                    hidden = hidden,
                                    dibsEnabled = settings.dibsEnabled,
                                    now = vm.now,
                                    shape = segmentShape(index, day.slots.size),
                                    isBusy = isBusy,
                                    enabled = !isBusy,
                                    onClick = { if (canOpen(ts)) selectedTimeslot = ts.id },
                                    onLongClick = {
                                        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                                        rowMenuFor = ts.id
                                    },
                                )
                                RowMenu(
                                    expanded = rowMenuFor == ts.id,
                                    onDismiss = { rowMenuFor = null },
                                    timeslot = ts,
                                    vm = vm,
                                    settings = settings,
                                    onBook = { act(ts, it, emptyList()) },
                                    onCancel = { ids, named -> askToCancel(ts, ids, named) },
                                    onDibs = { add, remove -> changeDibs(ts, add, remove) },
                                    onAddToCalendar = {
                                        val own = ts.visibleGroups(hidden).filter { it.status == GroupStatus.Own }.map { it.groupId }
                                        context.addToCalendar(ts, own, vm.groupsById)
                                    },
                                    onCopy = { context.copyToClipboard(ts.dayAndTime, ts.dayAndTime) },
                                    groupName = ::groupName,
                                )
                            }
                        }
                    }

                    item(key = "footer") {
                        if (vm.reachedEnd) {
                            Text(
                                stringResource(R.string.no_more_timeslots),
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
                                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                            )
                        } else {
                            // Composed only when scrolled into view, which is what
                            // pages in the next week.
                            LaunchedEffect(vm.weeks.size) { vm.loadMoreIfNeeded() }
                            Box(Modifier.fillMaxWidth().padding(vertical = 24.dp), contentAlignment = Alignment.Center) {
                                val label = stringResource(R.string.loading_more)
                                LoadingIndicator(Modifier.semantics { contentDescription = label })
                            }
                        }
                    }
                }
            }
        }
    }

    selectedTimeslot?.let { id ->
        BookingSheet(
            timeslotId = id,
            vm = vm,
            settings = settings,
            onDismiss = { selectedTimeslot = null },
        )
    }

    if (showDatePicker) {
        JumpToDateDialog(
            vm = vm,
            onDismiss = { showDatePicker = false },
        )
    }

    pendingCancel?.let { pending ->
        AlertDialog(
            onDismissRequest = { pendingCancel = null },
            icon = { Icon(painterResource(R.drawable.ic_cancel), null) },
            title = { Text(stringResource(R.string.cancel_dialog_title)) },
            text = { Text(pending.message) },
            confirmButton = {
                TextButton(onClick = {
                    pendingCancel = null
                    act(pending.timeslot, emptyList(), pending.groupIds)
                }) { Text(stringResource(R.string.cancel_dialog_confirm), color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { pendingCancel = null }) { Text(stringResource(R.string.cancel_dialog_keep)) }
            },
        )
    }

    if (showInvite) InviteSheet(settings = settings, vm = vm, onDismiss = { showInvite = false })
    if (showFeedback) FeedbackSheet(settings = settings, vm = vm, onDismiss = { showFeedback = false })
    if (showTimer) TimerSheet(session = vm.runningSession, onDismiss = { showTimer = false })
    if (offeringNotifications) {
        NotificationOfferDialog(
            alert = settings.alert,
            onAccept = notifications.request,
            onDismiss = { offeringNotifications = false },
        )
    }
}

@Composable
private fun IconTooltip(text: String, content: @Composable () -> Unit) {
    TooltipBox(
        positionProvider = TooltipDefaults.rememberTooltipPositionProvider(TooltipAnchorPosition.Below),
        tooltip = { PlainTooltip { Text(text) } },
        state = rememberTooltipState(),
        content = content,
    )
}

@Composable
private fun OverflowMenu(
    expanded: Boolean,
    onDismiss: () -> Unit,
    showAll: Boolean,
    dibsEnabled: Boolean,
    onToggleShowAll: () -> Unit,
    onDibsPriority: () -> Unit,
    onInvite: () -> Unit,
    onFeedback: () -> Unit,
    onSettings: () -> Unit,
) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss, shape = RoundedCornerShape(16.dp)) {
        // Named, not a bare eye icon to decode; off means free timeslots within
        // the active hours only.
        DropdownMenuItem(
            text = { Text(stringResource(R.string.menu_show_hidden)) },
            leadingIcon = { Icon(painterResource(R.drawable.ic_visibility), null) },
            trailingIcon = { Checkbox(checked = showAll, onCheckedChange = null) },
            onClick = { onToggleShowAll(); onDismiss() },
        )
        if (dibsEnabled) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.menu_dibs_priority)) },
                leadingIcon = { Icon(painterResource(R.drawable.ic_list_numbered), null) },
                onClick = { onDismiss(); onDibsPriority() },
            )
        }
        HorizontalDivider()
        DropdownMenuItem(
            text = { Text(stringResource(R.string.menu_invite)) },
            leadingIcon = { Icon(painterResource(R.drawable.ic_group_add), null) },
            onClick = { onDismiss(); onInvite() },
        )
        DropdownMenuItem(
            text = { Text(stringResource(R.string.menu_send_feedback)) },
            leadingIcon = { Icon(painterResource(R.drawable.ic_feedback), null) },
            onClick = { onDismiss(); onFeedback() },
        )
        DropdownMenuItem(
            text = { Text(stringResource(R.string.menu_settings)) },
            leadingIcon = { Icon(painterResource(R.drawable.ic_settings), null) },
            onClick = { onDismiss(); onSettings() },
        )
    }
}

/**
 * Long press: the things the booking sheet exists for, without the sheet, plus
 * the time on the clipboard. Only what Aptus would accept is offered, and a group
 * is named only where the row covers more than one.
 */
@Composable
private fun RowMenu(
    expanded: Boolean,
    onDismiss: () -> Unit,
    timeslot: Timeslot,
    vm: LaundryViewModel,
    settings: AppSettings,
    onBook: (List<Int>) -> Unit,
    onCancel: (List<Int>, Boolean) -> Unit,
    onDibs: (List<Int>, List<Int>) -> Unit,
    onAddToCalendar: () -> Unit,
    onCopy: () -> Unit,
    groupName: (Int) -> String,
) {
    val hidden = settings.hiddenGroups
    val actionable = timeslot.actionableGroups(hidden, vm.now)
    val named = timeslot.visibleGroups(hidden).size > 1
    val bookable = actionable.filter { it.status == GroupStatus.Bookable }
    val cancellable = actionable.filter { it.status == GroupStatus.Own }
    val dibsGroups = timeslot.visibleGroups(hidden).filter { it.hasDibs }

    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss, shape = RoundedCornerShape(16.dp)) {
        // Aptus takes at most two groups in one action, and both groups of one
        // time still count as a single session against the quota.
        if (bookable.size == BookingRules.MAX_GROUPS_PER_BOOKING) {
            MenuItem(stringResource(R.string.row_book_both), R.drawable.ic_add_circle, onDismiss) { onBook(bookable.map { it.groupId }.sorted()) }
        }
        bookable.forEach { group ->
            val text = if (named) stringResource(R.string.row_book_named, groupName(group.groupId)) else stringResource(R.string.row_book)
            MenuItem(text, R.drawable.ic_add_circle, onDismiss) { onBook(listOf(group.groupId)) }
        }
        // Only while nothing of the slot is the user's: holding one group and
        // queueing for the other is the sheet's business.
        if (settings.dibsEnabled && !timeslot.hasOwnGroup(hidden)) {
            timeslot.dibsableGroups(hidden, vm.now).forEach { group ->
                val text = if (named) stringResource(R.string.row_call_dibs_named, groupName(group.groupId)) else stringResource(R.string.row_call_dibs)
                MenuItem(text, R.drawable.ic_hand, onDismiss) { onDibs(listOf(group.groupId), emptyList()) }
            }
        }
        if (dibsGroups.isNotEmpty()) {
            MenuItem(stringResource(R.string.row_leave_line), R.drawable.ic_leave_line, onDismiss) { onDibs(emptyList(), dibsGroups.map { it.groupId }) }
        }
        if (timeslot.hasOwnGroup(hidden)) {
            MenuItem(stringResource(R.string.row_add_to_calendar), R.drawable.ic_calendar_add, onDismiss, onClick = onAddToCalendar)
        }
        MenuItem(stringResource(R.string.row_copy_time), R.drawable.ic_copy, onDismiss, onClick = onCopy)
        if (cancellable.isNotEmpty()) HorizontalDivider()
        if (cancellable.size == BookingRules.MAX_GROUPS_PER_BOOKING) {
            MenuItem(stringResource(R.string.row_cancel_both), R.drawable.ic_cancel, onDismiss, destructive = true) {
                onCancel(cancellable.map { it.groupId }, named)
            }
        }
        cancellable.forEach { group ->
            val text = if (named) stringResource(R.string.row_cancel_named, groupName(group.groupId)) else stringResource(R.string.row_cancel_booking)
            MenuItem(text, R.drawable.ic_cancel, onDismiss, destructive = true) { onCancel(listOf(group.groupId), named) }
        }
    }
}

@Composable
private fun MenuItem(
    text: String,
    icon: Int,
    onDismiss: () -> Unit,
    destructive: Boolean = false,
    onClick: () -> Unit,
) {
    val color = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface
    DropdownMenuItem(
        text = { Text(text, color = color) },
        leadingIcon = {
            Icon(
                painterResource(icon),
                null,
                tint = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        },
        onClick = { onDismiss(); onClick() },
    )
}

@Composable
private fun JumpToDateDialog(vm: LaundryViewModel, onDismiss: () -> Unit) {
    val todayMillis = LaundryTime.epochMillis(vm.today) ?: 0L
    // The grid is a Stockholm calendar: the day tapped is the day the API is asked for.
    val state = rememberDatePickerState(
        initialSelectedDateMillis = LaundryTime.epochMillis(vm.anchorDate),
        selectableDates = object : SelectableDates {
            // Aptus books nothing in the past, so yesterday is not somewhere to go.
            override fun isSelectableDate(utcTimeMillis: Long) = utcTimeMillis >= todayMillis
            override fun isSelectableYear(year: Int) = year >= vm.today.take(4).toInt()
        },
    )
    DatePickerDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(
                onClick = {
                    state.selectedDateMillis?.let { vm.jump(LaundryTime.dayFromPickerMillis(it)) }
                    onDismiss()
                },
                enabled = state.selectedDateMillis != null,
            ) { Text(stringResource(R.string.ok)) }
        },
        dismissButton = {
            Row {
                if (!vm.isViewingToday) {
                    TextButton(onClick = { vm.jumpToToday(); onDismiss() }) {
                        Text(stringResource(R.string.action_today))
                    }
                }
                TextButton(onClick = onDismiss) { Text(stringResource(R.string.dialog_cancel)) }
            }
        },
    ) {
        DatePicker(state = state, showModeToggle = false)
    }
}

/** Three different nothings, said three different ways. */
@Composable
private fun EmptyState(vm: LaundryViewModel) {
    val reason = vm.emptyReason
    MessageState(
        icon = if (reason == EmptyReason.BeyondBookingWindow) R.drawable.ic_event_upcoming else R.drawable.ic_event_busy,
        title = stringResource(
            when (reason) {
                EmptyReason.BeyondBookingWindow -> R.string.empty_beyond_title
                EmptyReason.NothingFree -> R.string.empty_nothing_free_title
                EmptyReason.NoTimeslots -> R.string.empty_no_timeslots_title
            },
        ),
        body = when (reason) {
            EmptyReason.BeyondBookingWindow -> stringResource(R.string.empty_beyond_body, LaundryTime.dayLabel(vm.anchorDate))
            EmptyReason.NothingFree -> stringResource(R.string.empty_nothing_free_body)
            EmptyReason.NoTimeslots -> stringResource(R.string.empty_no_timeslots_body)
        },
    )
}
