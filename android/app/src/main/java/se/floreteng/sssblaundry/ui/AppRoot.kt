package se.floreteng.sssblaundry.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation3.runtime.NavKey
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.runtime.rememberNavBackStack
import androidx.navigation3.ui.NavDisplay
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import se.floreteng.sssblaundry.R
import se.floreteng.sssblaundry.SssbLaundryApplication
import se.floreteng.sssblaundry.data.AppSettings
import se.floreteng.sssblaundry.ui.dibs.DibsPriorityScreen
import se.floreteng.sssblaundry.ui.settings.LaundryRoomPickerScreen
import se.floreteng.sssblaundry.ui.settings.SettingsScreen
import se.floreteng.sssblaundry.ui.signin.SignInScreen
import se.floreteng.sssblaundry.ui.update.UpdateDialog
import se.floreteng.sssblaundry.ui.week.WeekScreen
import androidx.compose.ui.platform.LocalContext

@Serializable data object WeekRoute : NavKey
@Serializable data object SettingsRoute : NavKey
@Serializable data object LaundryRoomRoute : NavKey
@Serializable data object DibsPriorityRoute : NavKey

@Composable
fun AppRoot(
    settings: AppSettings,
    incomingInvite: String?,
    onInviteHandled: () -> Unit,
) {
    val repository = (LocalContext.current.applicationContext as SssbLaundryApplication).settings
    val scope = rememberCoroutineScope()
    /** An invite that arrived while another number was signed in, until the switch is confirmed. */
    var offeredObjectId by remember { mutableStateOf<String?>(null) }

    // Signed out, an invite simply *is* the sign-in. Signed in, it would silently
    // swap which apartment the app books for, and that is worth asking about.
    LaunchedEffect(incomingInvite) {
        val invited = incomingInvite ?: return@LaunchedEffect
        onInviteHandled()
        when {
            invited == settings.objectId -> Unit
            settings.objectId.isEmpty() -> repository.setObjectId(invited)
            else -> offeredObjectId = invited
        }
    }

    AnimatedContent(targetState = settings.objectId, label = "signedIn") { objectId ->
        if (objectId.isEmpty()) {
            SignInScreen(onSignIn = { scope.launch { repository.setObjectId(it) } })
        } else {
            SignedIn(objectId = objectId, settings = settings)
        }
    }

    offeredObjectId?.let { invited ->
        AlertDialog(
            onDismissRequest = { offeredObjectId = null },
            title = { Text(stringResource(R.string.switch_title)) },
            text = { Text(stringResource(R.string.switch_body, invited)) },
            confirmButton = {
                TextButton(onClick = {
                    offeredObjectId = null
                    scope.launch { repository.setObjectId(invited) }
                }) { Text(stringResource(R.string.switch_action)) }
            },
            dismissButton = {
                TextButton(onClick = { offeredObjectId = null }) { Text(stringResource(R.string.dialog_cancel)) }
            },
            containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
        )
    }

    UpdateDialog(settings = settings)
}

@Composable
private fun SignedIn(objectId: String, settings: AppSettings) {
    // One store per object number: switching apartments starts from nothing.
    val vm: LaundryViewModel = viewModel(key = objectId)
    val repository = vm.settingsRepository
    val backStack = rememberNavBackStack(WeekRoute)

    LaunchedEffect(vm.authFailed) {
        if (vm.authFailed) repository.setObjectId(null)
    }

    NavDisplay(
        backStack = backStack,
        onBack = { backStack.removeLastOrNull() },
        entryProvider = entryProvider {
            entry<WeekRoute> {
                WeekScreen(
                    vm = vm,
                    settings = settings,
                    onOpenSettings = { backStack.add(SettingsRoute) },
                    onOpenDibsPriority = { backStack.add(DibsPriorityRoute) },
                )
            }
            entry<SettingsRoute> {
                SettingsScreen(
                    vm = vm,
                    settings = settings,
                    onBack = { backStack.removeLastOrNull() },
                    onPickLaundryRoom = { backStack.add(LaundryRoomRoute) },
                    onOpenDibsPriority = { backStack.add(DibsPriorityRoute) },
                )
            }
            entry<LaundryRoomRoute> {
                LaundryRoomPickerScreen(
                    selectedId = settings.laundryRoomId,
                    onSelect = { id ->
                        backStack.removeLastOrNull()
                        vm.launch { repository.setLaundryRoomId(id) }
                    },
                    onBack = { backStack.removeLastOrNull() },
                )
            }
            entry<DibsPriorityRoute> {
                DibsPriorityScreen(vm = vm, onBack = { backStack.removeLastOrNull() })
            }
        },
    )
}
