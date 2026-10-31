package se.floreteng.sssblaundry

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import se.floreteng.sssblaundry.data.InviteLink
import se.floreteng.sssblaundry.ui.AppRoot
import se.floreteng.sssblaundry.ui.theme.SssbLaundryTheme

class MainActivity : ComponentActivity() {
    /** An object number from an invite link, until the UI has dealt with it. */
    private val incomingInvite = mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        val splash = installSplashScreen()
        super.onCreate(savedInstanceState)
        val app = application as SssbLaundryApplication
        // Held until the settings have been read once, so the first frame is
        // already the right screen rather than a flash of the sign-in.
        splash.setKeepOnScreenCondition { app.settings.settings.value == null }
        enableEdgeToEdge()
        if (savedInstanceState == null) handleIntent(intent)

        setContent {
            SssbLaundryTheme {
                val settings by app.settings.settings.collectAsStateWithLifecycle()
                settings?.let {
                    AppRoot(
                        settings = it,
                        incomingInvite = incomingInvite.value,
                        onInviteHandled = { incomingInvite.value = null },
                    )
                }
            }
        }
    }

    // A link opened with the app already running arrives here; one that launched
    // it arrives in onCreate. Wiring only one works right up until the other case.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        val url = intent?.takeIf { it.action == Intent.ACTION_VIEW }?.dataString ?: return
        InviteLink.objectIdFromUrl(url)?.let { incomingInvite.value = it }
    }
}
