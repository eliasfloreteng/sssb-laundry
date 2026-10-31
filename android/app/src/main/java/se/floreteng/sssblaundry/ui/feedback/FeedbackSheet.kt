package se.floreteng.sssblaundry.ui.feedback

import android.os.Build
import androidx.compose.animation.AnimatedContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import se.floreteng.sssblaundry.BuildConfig
import se.floreteng.sssblaundry.R
import se.floreteng.sssblaundry.data.ApiError
import se.floreteng.sssblaundry.data.AppSettings
import se.floreteng.sssblaundry.ui.ErrorPresenter
import se.floreteng.sssblaundry.ui.LaundryViewModel
import se.floreteng.sssblaundry.ui.asApiError
import java.util.Locale
import kotlin.coroutines.cancellation.CancellationException

/**
 * Feedback straight to the developer: the keyboard is up as soon as the sheet is,
 * and the version, device and laundry room go along without being asked for.
 * The draft is stored, so a swipe down or a failed send costs nothing typed.
 */
@Composable
fun FeedbackSheet(settings: AppSettings, vm: LaundryViewModel, onDismiss: () -> Unit) {
    val res = LocalResources.current
    val haptics = LocalHapticFeedback.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var draft by remember { mutableStateOf(settings.feedbackDraft) }
    var sending by remember { mutableStateOf(false) }
    var sent by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<ApiError?>(null) }
    val focus = remember { FocusRequester() }
    val message = draft.trim()

    LaunchedEffect(Unit) { focus.requestFocus() }
    LaunchedEffect(draft) { vm.settingsRepository.setFeedbackDraft(draft) }
    LaunchedEffect(sent) {
        if (sent) {
            haptics.performHapticFeedback(HapticFeedbackType.Confirm)
            delay(1200)
            onDismiss()
        }
    }

    fun send() {
        sending = true
        error = null
        vm.launch {
            try {
                vm.sendFeedback(message, feedbackContext(settings))
                draft = ""
                vm.settingsRepository.setFeedbackDraft("")
                sent = true
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val apiError = e.asApiError()
                error = if (apiError.code.startsWith("FEEDBACK")) apiError else ApiError.local("FEEDBACK_FAILED")
            } finally {
                sending = false
            }
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        AnimatedContent(targetState = sent, label = "sent") { isSent ->
            if (isSent) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                    modifier = Modifier.fillMaxWidth().padding(48.dp),
                ) {
                    Icon(
                        painterResource(R.drawable.ic_check_circle_filled),
                        null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(56.dp),
                    )
                    Text(stringResource(R.string.feedback_sent), style = MaterialTheme.typography.titleMedium)
                }
            } else {
                Column(
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                    modifier = Modifier.navigationBarsPadding().imePadding().padding(horizontal = 24.dp).padding(bottom = 16.dp),
                ) {
                    Text(stringResource(R.string.feedback), style = MaterialTheme.typography.headlineSmall)
                    OutlinedTextField(
                        value = draft,
                        onValueChange = { draft = it },
                        placeholder = { Text(stringResource(R.string.feedback_placeholder)) },
                        enabled = !sending,
                        minLines = 6,
                        modifier = Modifier.fillMaxWidth().heightIn(min = 160.dp).focusRequester(focus),
                    )
                    error?.let {
                        Text(
                            "${ErrorPresenter.headline(res, it)}. ${ErrorPresenter.explanation(res, it)}",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.error,
                        )
                    }
                    Row(Modifier.fillMaxWidth()) {
                        Text(
                            stringResource(R.string.feedback_footer),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.weight(1f).align(Alignment.CenterVertically),
                        )
                        Spacer(Modifier.size(16.dp))
                        Button(onClick = ::send, enabled = message.isNotEmpty() && !sending) {
                            Box(contentAlignment = Alignment.Center) {
                                if (sending) {
                                    LoadingIndicator(Modifier.size(20.dp), color = MaterialTheme.colorScheme.onPrimary)
                                } else {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Icon(painterResource(R.drawable.ic_send), null, Modifier.size(ButtonDefaults.IconSize))
                                        Spacer(Modifier.size(ButtonDefaults.IconSpacing))
                                        Text(stringResource(R.string.send))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/** What helps read a message without asking anything. The object number travels as a header. */
private fun feedbackContext(settings: AppSettings): Map<String, String> = buildMap {
    put("appVersion", "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE}) Android")
    put("osVersion", "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
    put("device", "${Build.MANUFACTURER} ${Build.MODEL}")
    put("locale", Locale.getDefault().toLanguageTag())
    settings.laundryRoom?.let { put("laundryRoom", it.address) }
}
