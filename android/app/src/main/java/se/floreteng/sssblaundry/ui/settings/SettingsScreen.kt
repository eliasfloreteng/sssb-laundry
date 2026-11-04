package se.floreteng.sssblaundry.ui.settings

import android.content.res.Resources
import android.os.Build
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.Row as LayoutRow
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.RadioButton
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeFlexibleTopAppBar
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import se.floreteng.sssblaundry.R
import se.floreteng.sssblaundry.SssbLaundryApplication
import se.floreteng.sssblaundry.data.ApiError
import se.floreteng.sssblaundry.data.AppSettings
import se.floreteng.sssblaundry.data.BookingAlert
import se.floreteng.sssblaundry.data.LaundryRoom
import se.floreteng.sssblaundry.ui.ErrorPresenter
import se.floreteng.sssblaundry.ui.LaundryViewModel
import se.floreteng.sssblaundry.ui.components.copyToClipboard
import se.floreteng.sssblaundry.ui.components.segmentShape
import se.floreteng.sssblaundry.ui.feedback.FeedbackSheet
import se.floreteng.sssblaundry.ui.notifications.alertLabel
import se.floreteng.sssblaundry.ui.notifications.openNotificationSettings
import se.floreteng.sssblaundry.ui.notifications.rememberNotificationAccess

/** One settings row in a segmented group. */
private data class Row(
    val key: String,
    val content: @Composable (Shape) -> Unit,
)

@Composable
fun SettingsScreen(
    vm: LaundryViewModel,
    settings: AppSettings,
    onBack: () -> Unit,
    onPickLaundryRoom: () -> Unit,
    onOpenDibsPriority: () -> Unit,
) {
    val context = LocalContext.current
    val res = LocalResources.current
    val repo = vm.settingsRepository
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    var confirmingSignOut by remember { mutableStateOf(false) }
    var editingTime by remember { mutableStateOf<TimeField?>(null) }
    var leavingLines by remember { mutableStateOf(false) }
    var dibsError by remember { mutableStateOf<ApiError?>(null) }
    var showFeedback by remember { mutableStateOf(false) }
    var choosingAlert by remember { mutableStateOf<AlertField?>(null) }
    var requestingNotifications by remember { mutableStateOf(false) }
    val notifications = rememberNotificationAccess { requestingNotifications = false }
    // Asked before and still not allowed: the switch can't fix that, only Android's
    // settings can. Never asked (13+), it is just off, and the switch asks.
    val updater = (context.applicationContext as SssbLaundryApplication).updater
    val update by updater.available.collectAsStateWithLifecycle()
    val notificationsBlocked = !notifications.allowed &&
        (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || settings.notificationsPrompted)

    Scaffold(
        modifier = Modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        containerColor = MaterialTheme.colorScheme.surfaceContainer,
        topBar = {
            LargeFlexibleTopAppBar(
                title = { Text(stringResource(R.string.settings)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(painterResource(R.drawable.ic_arrow_back), stringResource(R.string.back))
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surfaceContainer,
                    scrolledContainerColor = MaterialTheme.colorScheme.surfaceContainer,
                ),
                scrollBehavior = scrollBehavior,
            )
        },
    ) { padding ->
        LazyColumn(
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding() + 24.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            update?.let { release ->
                section(
                    header = null,
                    footer = null,
                    rows = listOf(
                        Row("update") { shape ->
                            SettingsItem(
                                shape = shape,
                                leading = { Icon(painterResource(R.drawable.ic_download), null) },
                                headline = { Text(stringResource(R.string.update_title)) },
                                supporting = { Text(stringResource(R.string.update_row, release.label)) },
                                onClick = { updater.download(context) },
                            )
                        },
                    ),
                    key = "update",
                )
            }

            // The object number is deliberately not editable: copy it, or sign out.
            section(
                header = res.getString(R.string.object_number),
                footer = res.getString(R.string.object_number_footer),
                rows = listOf(
                    Row("objectId") { shape ->
                        SettingsItem(
                            shape = shape,
                            headline = { Text(settings.objectId, fontFamily = FontFamily.Monospace) },
                            trailing = {
                                IconButton(onClick = { context.copyToClipboard(res.getString(R.string.object_number), settings.objectId) }) {
                                    Icon(painterResource(R.drawable.ic_copy), stringResource(R.string.copy_object_number))
                                }
                            },
                        )
                    },
                    Row("signOut") { shape ->
                        SettingsItem(
                            shape = shape,
                            headline = { Text(stringResource(R.string.sign_out), color = MaterialTheme.colorScheme.error) },
                            leading = { Icon(painterResource(R.drawable.ic_logout), null, tint = MaterialTheme.colorScheme.error) },
                            onClick = { confirmingSignOut = true },
                        )
                    },
                ),
            )

            val groups = vm.allGroups
            if (groups.isEmpty()) {
                section(
                    header = res.getString(R.string.visible_groups),
                    footer = res.getString(R.string.hidden_groups_footer),
                    rows = listOf(
                        Row("noGroups") { shape ->
                            SettingsItem(shape = shape, headline = {
                                Text(stringResource(R.string.no_groups_yet), color = MaterialTheme.colorScheme.onSurfaceVariant)
                            })
                        },
                    ),
                )
            } else {
                val byLocation = groups.groupBy { it.place }.entries.toList()
                byLocation.forEachIndexed { index, (location, inLocation) ->
                    val isLast = index == byLocation.lastIndex
                    val rows = inLocation.map { group ->
                        Row("group-${group.id}") { shape ->
                            val visible = group.id !in settings.hiddenGroups
                            SettingsItem(
                                shape = shape,
                                headline = { Text(group.name) },
                                trailing = {
                                    Switch(checked = visible, onCheckedChange = { isVisible ->
                                        val updated = if (isVisible) settings.hiddenGroups - group.id else settings.hiddenGroups + group.id
                                        vm.launch { repo.setHiddenGroups(updated) }
                                    })
                                },
                            )
                        }
                    } + if (isLast && settings.hiddenGroups.isNotEmpty()) {
                        listOf(Row("showAll") { shape ->
                            SettingsItem(
                                shape = shape,
                                headline = { Text(stringResource(R.string.show_all_groups), color = MaterialTheme.colorScheme.primary) },
                                onClick = { vm.launch { repo.setHiddenGroups(emptySet()) } },
                            )
                        })
                    } else {
                        emptyList()
                    }
                    section(
                        header = location.ifEmpty { res.getString(R.string.visible_groups) },
                        footer = if (isLast) res.getString(R.string.hidden_groups_footer) else null,
                        rows = rows,
                        key = "groups-$location",
                    )
                }
            }

            section(
                header = res.getString(R.string.active_hours),
                footer = res.getString(R.string.active_hours_footer),
                rows = buildList {
                    add(Row("activeHours") { shape ->
                        SettingsItem(
                            shape = shape,
                            headline = { Text(stringResource(R.string.filter_timeslots)) },
                            trailing = {
                                Switch(checked = settings.activeHoursEnabled, onCheckedChange = { vm.launch { repo.setActiveHoursEnabled(it) } })
                            },
                        )
                    })
                    if (settings.activeHoursEnabled) {
                        add(Row("from") { shape ->
                            SettingsItem(
                                shape = shape,
                                headline = { Text(stringResource(R.string.from)) },
                                trailing = { Text(formatMinutes(settings.activeHoursStart), style = MaterialTheme.typography.titleMedium) },
                                onClick = { editingTime = TimeField.Start },
                            )
                        })
                        add(Row("to") { shape ->
                            SettingsItem(
                                shape = shape,
                                headline = { Text(stringResource(R.string.to)) },
                                trailing = { Text(formatMinutes(settings.activeHoursEnd), style = MaterialTheme.typography.titleMedium) },
                                onClick = { editingTime = TimeField.End },
                            )
                        })
                    }
                },
            )

            section(
                header = res.getString(R.string.notifications),
                footer = res.getString(if (notificationsBlocked) R.string.notifications_blocked_footer else R.string.notifications_footer),
                rows = buildList {
                    add(Row("reminders") { shape ->
                        SettingsItem(
                            shape = shape,
                            leading = { Icon(painterResource(R.drawable.ic_notifications), null) },
                            headline = { Text(stringResource(R.string.booking_reminders)) },
                            trailing = {
                                Switch(
                                    checked = settings.notificationsEnabled,
                                    enabled = !requestingNotifications,
                                    onCheckedChange = { wantsEnabled ->
                                        if (wantsEnabled) {
                                            requestingNotifications = true
                                            notifications.request()
                                        } else {
                                            // The registrar sees it and takes this phone off the server.
                                            vm.launch { repo.setNotificationsEnabled(false) }
                                        }
                                    },
                                )
                            },
                        )
                    })
                    if (settings.notificationsEnabled) {
                        add(Row("alert") { shape ->
                            SettingsItem(
                                shape = shape,
                                headline = { Text(stringResource(R.string.alert)) },
                                supporting = { Text(res.alertLabel(settings.alert)) },
                                onClick = { choosingAlert = AlertField.First },
                            )
                        })
                        add(Row("secondAlert") { shape ->
                            SettingsItem(
                                shape = shape,
                                headline = { Text(stringResource(R.string.second_alert)) },
                                supporting = { Text(res.alertLabel(settings.secondAlert)) },
                                onClick = { choosingAlert = AlertField.Second },
                            )
                        })
                    }
                    if (notificationsBlocked) {
                        add(Row("systemSettings") { shape ->
                            SettingsItem(
                                shape = shape,
                                headline = { Text(stringResource(R.string.open_notification_settings), color = MaterialTheme.colorScheme.primary) },
                                trailing = { Icon(painterResource(R.drawable.ic_chevron_right), null) },
                                onClick = { context.openNotificationSettings() },
                            )
                        })
                    }
                },
            )

            // Optional on purpose: nothing identifies an object number's room, and
            // an unset room shows no limits rather than asserting a wrong one.
            val room = settings.laundryRoom
            section(
                header = res.getString(R.string.your_laundry_room),
                footer = if (room == null) res.getString(R.string.set_address_footer) else null,
                rows = buildList {
                    add(Row("address") { shape ->
                        SettingsItem(
                            shape = shape,
                            leading = { Icon(painterResource(R.drawable.ic_location), null) },
                            headline = { Text(stringResource(R.string.your_address)) },
                            supporting = { Text(room?.address ?: stringResource(R.string.not_set)) },
                            trailing = { Icon(painterResource(R.drawable.ic_chevron_right), null) },
                            onClick = onPickLaundryRoom,
                        )
                    })
                    room?.let { addAll(roomRows(it, res)) }
                },
            )

            // Last, and off until asked for: dibs lets the server book — and, for
            // a dibs ranked above a booking, cancel — on the user's behalf.
            section(
                header = res.getString(R.string.dibs),
                footer = res.getString(R.string.dibs_footer),
                rows = buildList {
                    add(Row("dibs") { shape ->
                        SettingsItem(
                            shape = shape,
                            leading = { Icon(painterResource(R.drawable.ic_hand), null) },
                            headline = { Text(stringResource(R.string.dibs)) },
                            trailing = {
                                if (leavingLines) {
                                    LoadingIndicator(Modifier.size(32.dp))
                                } else {
                                    Switch(checked = settings.dibsEnabled, onCheckedChange = { wantsEnabled ->
                                        // Off only once the server has let go: a dibs left
                                        // standing could still book behind the user's back.
                                        vm.launch {
                                            if (wantsEnabled) {
                                                repo.setDibsEnabled(true)
                                            } else {
                                                leavingLines = true
                                                val error = vm.dropAllDibs()
                                                if (error == null) repo.setDibsEnabled(false) else dibsError = error
                                                leavingLines = false
                                            }
                                        }
                                    })
                                }
                            },
                        )
                    })
                    if (settings.dibsEnabled) {
                        add(Row("priority") { shape ->
                            SettingsItem(
                                shape = shape,
                                leading = { Icon(painterResource(R.drawable.ic_list_numbered), null) },
                                headline = { Text(stringResource(R.string.priority)) },
                                trailing = { Icon(painterResource(R.drawable.ic_chevron_right), null) },
                                onClick = onOpenDibsPriority,
                            )
                        })
                    }
                },
            )

            section(
                header = null,
                footer = res.getString(R.string.feedback_footer),
                rows = listOf(
                    Row("feedback") { shape ->
                        SettingsItem(
                            shape = shape,
                            leading = { Icon(painterResource(R.drawable.ic_feedback), null) },
                            headline = { Text(stringResource(R.string.menu_send_feedback)) },
                            onClick = { showFeedback = true },
                        )
                    },
                ),
                key = "feedback",
            )
        }
    }

    if (confirmingSignOut) {
        AlertDialog(
            onDismissRequest = { confirmingSignOut = false },
            icon = { Icon(painterResource(R.drawable.ic_logout), null) },
            title = { Text(stringResource(R.string.sign_out_title)) },
            text = { Text(stringResource(R.string.sign_out_body)) },
            confirmButton = {
                TextButton(onClick = {
                    confirmingSignOut = false
                    vm.launch { repo.setObjectId(null) }
                }) { Text(stringResource(R.string.sign_out), color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { confirmingSignOut = false }) { Text(stringResource(R.string.dialog_cancel)) }
            },
        )
    }

    dibsError?.let { error ->
        AlertDialog(
            onDismissRequest = { dibsError = null },
            title = { Text(ErrorPresenter.headline(res, error)) },
            text = { Text(ErrorPresenter.explanation(res, error)) },
            confirmButton = { TextButton(onClick = { dibsError = null }) { Text(stringResource(R.string.ok)) } },
        )
    }

    editingTime?.let { field ->
        val initial = if (field == TimeField.Start) settings.activeHoursStart else settings.activeHoursEnd
        val state = rememberTimePickerState(initialHour = initial / 60, initialMinute = initial % 60, is24Hour = true)
        AlertDialog(
            onDismissRequest = { editingTime = null },
            title = { Text(stringResource(if (field == TimeField.Start) R.string.from else R.string.to)) },
            text = { TimePicker(state = state) },
            confirmButton = {
                TextButton(onClick = {
                    val minutes = state.hour * 60 + state.minute
                    vm.launch { if (field == TimeField.Start) repo.setActiveHoursStart(minutes) else repo.setActiveHoursEnd(minutes) }
                    editingTime = null
                }) { Text(stringResource(R.string.ok)) }
            },
            dismissButton = { TextButton(onClick = { editingTime = null }) { Text(stringResource(R.string.dialog_cancel)) } },
        )
    }

    choosingAlert?.let { field ->
        AlertPickerDialog(
            title = stringResource(if (field == AlertField.First) R.string.alert else R.string.second_alert),
            selected = if (field == AlertField.First) settings.alert else settings.secondAlert,
            onSelect = { alert ->
                choosingAlert = null
                vm.launch { if (field == AlertField.First) repo.setAlert(alert) else repo.setSecondAlert(alert) }
            },
            onDismiss = { choosingAlert = null },
        )
    }

    if (showFeedback) FeedbackSheet(settings = settings, vm = vm, onDismiss = { showFeedback = false })
}

private enum class TimeField { Start, End }

private enum class AlertField { First, Second }

/** A single-choice list that applies on tap, as Android's own settings do. */
@Composable
private fun AlertPickerDialog(
    title: String,
    selected: BookingAlert,
    onSelect: (BookingAlert) -> Unit,
    onDismiss: () -> Unit,
) {
    val res = LocalResources.current
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(Modifier.selectableGroup().verticalScroll(rememberScrollState())) {
                BookingAlert.entries.forEach { alert ->
                    LayoutRow(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 48.dp)
                            .clip(MaterialTheme.shapes.medium)
                            .selectable(selected = alert == selected, role = Role.RadioButton, onClick = { onSelect(alert) }),
                    ) {
                        RadioButton(selected = alert == selected, onClick = null, modifier = Modifier.padding(horizontal = 12.dp))
                        Text(res.alertLabel(alert), style = MaterialTheme.typography.bodyLarge)
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.dialog_cancel)) } },
    )
}

private fun formatMinutes(minutes: Int) = "%02d:%02d".format(minutes / 60, minutes % 60)

private fun roomRows(room: LaundryRoom, res: Resources): List<Row> {
    fun value(key: String, title: String, value: String) = Row(key) { shape ->
        SettingsItem(
            shape = shape,
            headline = { Text(title) },
            trailing = { Text(value, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant) },
        )
    }
    val noMax = res.getString(R.string.no_maximum)
    val quota = room.quota
    return listOf(
        value("room", res.getString(R.string.laundry_room), room.room),
        value("max", res.getString(R.string.max_future_bookings), room.maxFutureBookings?.toString() ?: noMax),
        value(
            "after",
            res.getString(R.string.access_after_session),
            if (room.minutesAfterBooking > 0) res.getString(R.string.minutes_value, room.minutesAfterBooking) else res.getString(R.string.none),
        ),
        value(
            "quota",
            res.getString(
                when (quota?.period) {
                    LaundryRoom.Period.Week -> R.string.max_per_week
                    LaundryRoom.Period.Month -> R.string.max_per_month
                    null -> R.string.max_per_week_month
                },
            ),
            quota?.count?.toString() ?: noMax,
        ),
    )
}

/** A header, a segmented group of rows, and a footer — the shape of Android's own settings. */
private fun LazyListScope.section(header: String?, footer: String?, rows: List<Row>, key: String = header ?: "section") {
    item(key = "$key-header") {
        if (header != null) {
            Text(
                header,
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(start = 8.dp, top = 24.dp, bottom = 8.dp),
            )
        } else {
            androidx.compose.foundation.layout.Spacer(Modifier.size(24.dp))
        }
    }
    rows.forEachIndexed { index, row ->
        item(key = "$key-${row.key}") {
            Column(Modifier.padding(bottom = 2.dp)) { row.content(segmentShape(index, rows.size)) }
        }
    }
    if (footer != null) {
        item(key = "$key-footer") {
            Text(
                footer,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 8.dp, vertical = 8.dp),
            )
        }
    }
}

@Composable
private fun SettingsItem(
    shape: Shape,
    headline: @Composable () -> Unit,
    supporting: (@Composable () -> Unit)? = null,
    leading: (@Composable () -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
    onClick: (() -> Unit)? = null,
) {
    Surface(shape = shape, color = MaterialTheme.colorScheme.surfaceBright, modifier = Modifier.fillMaxWidth()) {
        ListItem(
            headlineContent = headline,
            supportingContent = supporting,
            leadingContent = leading,
            trailingContent = trailing,
            colors = ListItemDefaults.colors(containerColor = Color.Transparent),
            modifier = if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier,
        )
    }
}
