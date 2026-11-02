package se.floreteng.sssblaundry.ui.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SearchBar
import androidx.compose.material3.SearchBarDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import se.floreteng.sssblaundry.R
import se.floreteng.sssblaundry.data.LaundryRooms
import se.floreteng.sssblaundry.ui.components.segmentShape

/**
 * Pick the street address SSSB lists you under. The rules that come with it are
 * informational — Aptus enforces them either way — so unset is a supported state.
 */
@Composable
fun LaundryRoomPickerScreen(selectedId: String, onSelect: (String) -> Unit, onBack: () -> Unit) {
    val query = rememberTextFieldState()
    val text = query.text.toString().trim()
    val matches = if (text.isEmpty()) LaundryRooms.all else LaundryRooms.all.filter {
        it.address.contains(text, ignoreCase = true) || it.room.contains(text, ignoreCase = true)
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.surfaceContainer,
        topBar = {
            Column {
                TopAppBar(
                    title = { Text(stringResource(R.string.your_address)) },
                    navigationIcon = {
                        IconButton(onClick = onBack) {
                            Icon(painterResource(R.drawable.ic_arrow_back), stringResource(R.string.back))
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
                )
                // Always collapsed: the list below is the results, filtered as
                // you type. SearchBar supplies the pill container the field lacks.
                SearchBar(
                    inputField = {
                        SearchBarDefaults.InputField(
                            state = query,
                            onSearch = {},
                            expanded = false,
                            onExpandedChange = {},
                            placeholder = { Text(stringResource(R.string.street_address)) },
                            leadingIcon = { Icon(painterResource(R.drawable.ic_search), null) },
                        )
                    },
                    expanded = false,
                    onExpandedChange = {},
                    colors = SearchBarDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceBright),
                    // The top app bar above already clears the status bar.
                    windowInsets = WindowInsets(0),
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 8.dp),
                ) {}
            }
        },
    ) { padding ->
        LazyColumn(
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = padding.calculateTopPadding() + 8.dp, bottom = padding.calculateBottomPadding() + 24.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            if (text.isEmpty()) {
                item(key = "none") {
                    Choice(
                        title = stringResource(R.string.not_set),
                        subtitle = stringResource(R.string.no_rules_shown),
                        selected = selectedId.isEmpty(),
                        index = 0,
                        count = 1,
                        onClick = { onSelect("") },
                    )
                }
                item(key = "gap") { Column(Modifier.padding(top = 16.dp)) {} }
            }
            itemsIndexed(matches, key = { _, room -> room.id }) { index, room ->
                // Two rooms serve the same Kungshamra address under different
                // rules, so the room is what tells them apart.
                Choice(
                    title = room.address,
                    subtitle = stringResource(R.string.laundry_room_value, room.room),
                    selected = room.id == selectedId,
                    index = index,
                    count = matches.size,
                    onClick = { onSelect(room.id) },
                )
            }
            item(key = "footer") {
                Text(
                    stringResource(R.string.from_sssb),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(8.dp),
                )
            }
        }
    }
}

@Composable
private fun Choice(title: String, subtitle: String, selected: Boolean, index: Int, count: Int, onClick: () -> Unit) {
    Surface(
        shape = segmentShape(index, count),
        color = if (selected) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surfaceBright,
        modifier = Modifier.fillMaxWidth().padding(bottom = 2.dp),
    ) {
        ListItem(
            headlineContent = { Text(title) },
            supportingContent = { Text(subtitle) },
            trailingContent = if (selected) {
                { Icon(painterResource(R.drawable.ic_check), null, tint = MaterialTheme.colorScheme.primary) }
            } else {
                null
            },
            colors = ListItemDefaults.colors(containerColor = Color.Transparent),
            modifier = Modifier.clickable(onClick = onClick),
        )
    }
}
