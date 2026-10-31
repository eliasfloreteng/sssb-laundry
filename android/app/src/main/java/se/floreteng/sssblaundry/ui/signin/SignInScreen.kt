package se.floreteng.sssblaundry.ui.signin

import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.toShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import se.floreteng.sssblaundry.R
import se.floreteng.sssblaundry.data.InviteLink

private val rules = listOf(
    R.string.rule_tag_in,
    R.string.rule_released,
    R.string.rule_sessions,
    R.string.rule_groups,
    R.string.rule_cancel,
)

@Composable
fun SignInScreen(onSignIn: (String) -> Unit) {
    val context = LocalContext.current
    var draft by rememberSaveable { mutableStateOf("") }
    var pasteMissed by remember { mutableStateOf(false) }
    val focus = remember { FocusRequester() }
    // Asked by shape only — whether the clipboard holds text at all — so nothing is
    // read until the user taps Paste. Someone arriving from an invite page has the
    // link waiting there, and is not here to type.
    val clipboardHasText = remember { context.clipboardHasText() }

    fun save() {
        val value = InviteLink.objectIdFromPasted(draft) ?: draft.trim()
        if (value.isNotEmpty()) onSignIn(value)
    }

    LaunchedEffect(Unit) {
        if (!clipboardHasText) focus.requestFocus()
    }

    Surface(color = MaterialTheme.colorScheme.surface, modifier = Modifier.fillMaxSize()) {
        Box(contentAlignment = Alignment.TopCenter, modifier = Modifier.safeDrawingPadding().imePadding()) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(24.dp),
                modifier = Modifier
                    .widthIn(max = 480.dp)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 24.dp, vertical = 48.dp),
            ) {
                Surface(
                    shape = MaterialShapes.Cookie9Sided.toShape(),
                    color = MaterialTheme.colorScheme.primaryContainer,
                    contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                    modifier = Modifier.size(112.dp),
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Icon(painterResource(R.drawable.ic_laundry), null, Modifier.size(56.dp))
                    }
                }

                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.sign_in), style = MaterialTheme.typography.displaySmall)
                    Text(
                        stringResource(R.string.sign_in_body),
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                    )
                }

                if (clipboardHasText) {
                    Surface(
                        shape = RoundedCornerShape(28.dp),
                        color = MaterialTheme.colorScheme.secondaryContainer,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                            modifier = Modifier.padding(20.dp),
                        ) {
                            Text(stringResource(R.string.invited_title), style = MaterialTheme.typography.titleMedium)
                            Text(
                                stringResource(R.string.invited_body),
                                style = MaterialTheme.typography.bodyMedium,
                                textAlign = TextAlign.Center,
                            )
                            Button(onClick = {
                                val pasted = context.clipboardText()
                                val objectId = pasted?.let(InviteLink::objectIdFromPasted)
                                pasteMissed = objectId == null
                                if (objectId != null) onSignIn(objectId)
                            }) {
                                Icon(painterResource(R.drawable.ic_paste), null, Modifier.size(ButtonDefaults.IconSize))
                                Spacer(Modifier.size(ButtonDefaults.IconSpacing))
                                Text(stringResource(R.string.paste))
                            }
                            if (pasteMissed) {
                                Text(
                                    stringResource(R.string.paste_missed),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.error,
                                    textAlign = TextAlign.Center,
                                )
                            }
                        }
                    }
                }

                OutlinedTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    label = { Text(stringResource(R.string.object_number)) },
                    placeholder = { Text(stringResource(R.string.object_number_placeholder), fontFamily = FontFamily.Monospace) },
                    textStyle = MaterialTheme.typography.titleLarge.copy(fontFamily = FontFamily.Monospace),
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(
                        keyboardType = KeyboardType.Number,
                        autoCorrectEnabled = false,
                        imeAction = ImeAction.Done,
                    ),
                    keyboardActions = KeyboardActions(onDone = { save() }),
                    modifier = Modifier.fillMaxWidth().focusRequester(focus),
                )

                Button(
                    onClick = ::save,
                    enabled = draft.isNotBlank(),
                    contentPadding = ButtonDefaults.contentPaddingFor(ButtonDefaults.MediumContainerHeight),
                    modifier = Modifier.fillMaxWidth().height(ButtonDefaults.MediumContainerHeight),
                ) {
                    Text(stringResource(R.string.continue_action), style = ButtonDefaults.textStyleFor(ButtonDefaults.MediumContainerHeight))
                }

                // SSSB's rules, on the one screen every resident sees before their
                // first booking. The per-room numbers live in Settings.
                Column(verticalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.padding(top = 8.dp)) {
                    rules.forEach { rule ->
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            Text("•", color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text(
                                stringResource(rule),
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }
        }
    }
}

private fun Context.clipboard() = getSystemService(ClipboardManager::class.java)

private fun Context.clipboardHasText(): Boolean {
    val description = clipboard()?.primaryClipDescription ?: return false
    return description.hasMimeType(ClipDescription.MIMETYPE_TEXT_PLAIN) ||
        description.hasMimeType(ClipDescription.MIMETYPE_TEXT_URILIST) ||
        description.hasMimeType(ClipDescription.MIMETYPE_TEXT_HTML)
}

private fun Context.clipboardText(): String? =
    clipboard()?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(this)?.toString()
