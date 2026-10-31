package se.floreteng.sssblaundry.ui.invite

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.toShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import se.floreteng.sssblaundry.R
import se.floreteng.sssblaundry.data.AppSettings
import se.floreteng.sssblaundry.data.InviteLink
import se.floreteng.sssblaundry.ui.LaundryViewModel
import se.floreteng.sssblaundry.ui.components.share

/**
 * Hands the link to someone else. The link itself is the description — it
 * changes as the switch does — and the one thing worth a sentence is what the
 * number in it lets the other person do.
 */
@Composable
fun InviteSheet(settings: AppSettings, vm: LaundryViewModel, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val url = InviteLink.url(if (settings.inviteIncludesObjectId) settings.objectId else null)

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(20.dp),
            modifier = Modifier.navigationBarsPadding().padding(horizontal = 24.dp).padding(bottom = 16.dp),
        ) {
            Surface(
                shape = MaterialShapes.Clover4Leaf.toShape(),
                color = MaterialTheme.colorScheme.tertiaryContainer,
                contentColor = MaterialTheme.colorScheme.onTertiaryContainer,
                modifier = Modifier.size(80.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(painterResource(R.drawable.ic_group_add), null, Modifier.size(36.dp))
                }
            }
            Text(stringResource(R.string.invite), style = MaterialTheme.typography.headlineSmall)

            SelectionContainer {
                Text(
                    url,
                    style = MaterialTheme.typography.bodyMedium,
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
            }

            Surface(shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh) {
                Column {
                    ListItem(
                        headlineContent = { Text(stringResource(R.string.include_object_number)) },
                        trailingContent = {
                            Switch(
                                checked = settings.inviteIncludesObjectId,
                                onCheckedChange = { vm.launch { vm.settingsRepository.setInviteIncludesObjectId(it) } },
                            )
                        },
                        supportingContent = {
                            AnimatedVisibility(settings.inviteIncludesObjectId) {
                                Text(stringResource(R.string.invite_includes_footer))
                            }
                        },
                        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                    )
                }
            }

            Button(
                onClick = { context.share(url) },
                contentPadding = ButtonDefaults.contentPaddingFor(ButtonDefaults.MediumContainerHeight),
                modifier = Modifier.fillMaxWidth().height(ButtonDefaults.MediumContainerHeight),
            ) {
                Icon(painterResource(R.drawable.ic_share), null, Modifier.size(ButtonDefaults.iconSizeFor(ButtonDefaults.MediumContainerHeight)))
                Spacer(Modifier.size(ButtonDefaults.iconSpacingFor(ButtonDefaults.MediumContainerHeight)))
                Text(stringResource(R.string.share_link), style = ButtonDefaults.textStyleFor(ButtonDefaults.MediumContainerHeight))
            }
        }
    }
}
