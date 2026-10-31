package se.floreteng.sssblaundry.ui.dibs

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import se.floreteng.sssblaundry.R
import se.floreteng.sssblaundry.data.ApiError
import se.floreteng.sssblaundry.data.GroupStatus
import se.floreteng.sssblaundry.data.dayAndTime
import se.floreteng.sssblaundry.ui.ErrorPresenter
import se.floreteng.sssblaundry.ui.LaundryViewModel
import se.floreteng.sssblaundry.ui.PriorityItem
import se.floreteng.sssblaundry.ui.components.MessageState
import se.floreteng.sssblaundry.ui.components.segmentShape
import se.floreteng.sssblaundry.ui.groupNames

/**
 * Dibs and bookings in one list, most wanted first. The order is what the server
 * acts on: when a dibs frees up and the session limit is in the way, the booking
 * ranked lowest below it is cancelled to make room.
 */
@Composable
fun DibsPriorityScreen(vm: LaundryViewModel, onBack: () -> Unit) {
    val res = LocalResources.current
    var loading by remember { mutableStateOf(true) }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<ApiError?>(null) }
    val order = vm.priorityItems

    LaunchedEffect(Unit) {
        vm.loadToEnd()
        loading = false
    }

    fun move(from: Int, to: Int) {
        if (to !in order.indices || saving) return
        val ids = order.map { it.id }.toMutableList().apply { add(to, removeAt(from)) }
        saving = true
        vm.launch {
            vm.setPriority(ids)?.let { error = it }
            saving = false
        }
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.surfaceContainer,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.menu_dibs_priority)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(painterResource(R.drawable.ic_arrow_back), stringResource(R.string.back))
                    }
                },
                actions = { if (saving) LoadingIndicator(Modifier.padding(end = 12.dp).size(32.dp)) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
            )
        },
    ) { padding ->
        when {
            loading && order.isEmpty() -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                LoadingIndicator(Modifier.size(64.dp))
            }
            order.isEmpty() -> MessageState(
                icon = R.drawable.ic_hand,
                title = stringResource(R.string.nothing_to_rank),
                body = stringResource(R.string.nothing_to_rank_body),
                modifier = Modifier.padding(padding),
            )
            else -> LazyColumn(
                contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = padding.calculateTopPadding() + 8.dp, bottom = padding.calculateBottomPadding() + 24.dp),
                modifier = Modifier.fillMaxSize(),
            ) {
                itemsIndexed(order, key = { _, item -> item.id }) { index, item ->
                    Surface(
                        shape = segmentShape(index, order.size),
                        color = MaterialTheme.colorScheme.surfaceBright,
                        modifier = Modifier.animateItem().fillMaxWidth().padding(bottom = 2.dp),
                    ) {
                        ListItem(
                            leadingContent = {
                                Text(
                                    "${index + 1}",
                                    style = MaterialTheme.typography.titleMedium,
                                    fontWeight = FontWeight.SemiBold,
                                    color = MaterialTheme.colorScheme.primary,
                                    modifier = Modifier.widthIn(min = 20.dp),
                                )
                            },
                            headlineContent = { Text(item.timeslot.dayAndTime) },
                            supportingContent = { Text(status(item, vm, res)) },
                            trailingContent = {
                                Row(horizontalArrangement = Arrangement.spacedBy(0.dp), verticalAlignment = Alignment.CenterVertically) {
                                    Icon(
                                        painterResource(if (item.isBooked) R.drawable.ic_check_circle_filled else R.drawable.ic_hand_filled),
                                        null,
                                        tint = if (item.isBooked) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.tertiary,
                                        modifier = Modifier.padding(end = 4.dp),
                                    )
                                    IconButton(onClick = { move(index, index - 1) }, enabled = index > 0 && !saving) {
                                        Icon(painterResource(R.drawable.ic_arrow_up), stringResource(R.string.move_up))
                                    }
                                    IconButton(onClick = { move(index, index + 1) }, enabled = index < order.lastIndex && !saving) {
                                        Icon(painterResource(R.drawable.ic_arrow_down), stringResource(R.string.move_down))
                                    }
                                }
                            },
                            colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                        )
                    }
                }
                item(key = "footer") {
                    Text(
                        stringResource(R.string.priority_footer),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(8.dp),
                    )
                }
            }
        }
    }

    error?.let {
        AlertDialog(
            onDismissRequest = { error = null },
            title = { Text(ErrorPresenter.headline(res, it)) },
            text = { Text(ErrorPresenter.explanation(res, it)) },
            confirmButton = { TextButton(onClick = { error = null }) { Text(stringResource(R.string.ok)) } },
        )
    }
}

/** Which groups are booked, and which are still waited for and where in line. */
private fun status(item: PriorityItem, vm: LaundryViewModel, res: android.content.res.Resources): String {
    val own = item.timeslot.groups.filter { it.status == GroupStatus.Own }.map { it.groupId }
    val waiting = item.dibsGroups.map { it.groupId }
    return buildList {
        if (own.isNotEmpty()) add(res.getString(R.string.priority_booked, res.groupNames(own, vm.groupsById)))
        if (waiting.isNotEmpty()) {
            val names = res.groupNames(waiting, vm.groupsById)
            val place = item.dibsGroups.mapNotNull { it.dibsQueue }.minOrNull()
            add(if (place != null) res.getString(R.string.priority_dibs_place, names, place) else res.getString(R.string.priority_dibs, names))
        }
    }.joinToString(" · ")
}
