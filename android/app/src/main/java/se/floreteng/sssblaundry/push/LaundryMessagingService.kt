package se.floreteng.sssblaundry.push

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import se.floreteng.sssblaundry.SssbLaundryApplication
import se.floreteng.sssblaundry.data.PushKind
import se.floreteng.sssblaundry.data.PushMessage

/**
 * Every push is a data message (see `buildFcmData` on the server), so it lands
 * here whether the app is open, in the background or not running, and the app
 * writes the notification itself. Both callbacks run on a worker thread, which
 * is what makes blocking on the settings store acceptable.
 */
class LaundryMessagingService : FirebaseMessagingService() {
    private val app get() = application as SssbLaundryApplication

    /** The registrar notices the stored token change and registers it. */
    override fun onNewToken(token: String) {
        runBlocking { app.settings.setDeviceToken(token) }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val push = PushMessage.parse(message.data) ?: return
        // A take-down is always honoured; anything else only while this phone
        // still wants pushes for an object number — a deregistration that has
        // not reached the server yet must not keep the old apartment's coming.
        if (push.kind != PushKind.Cancelled) {
            val settings = runBlocking { app.settings.settings.filterNotNull().first() }
            if (settings.objectId.isEmpty() || !settings.notificationsEnabled) return
        }
        app.notifier.show(push)
    }
}
