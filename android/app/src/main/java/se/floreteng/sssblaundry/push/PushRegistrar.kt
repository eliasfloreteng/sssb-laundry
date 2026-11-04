package se.floreteng.sssblaundry.push

import android.content.Context
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.tasks.await
import se.floreteng.sssblaundry.data.ApiClient
import se.floreteng.sssblaundry.data.ApiError
import se.floreteng.sssblaundry.data.AppSettings
import se.floreteng.sssblaundry.data.PushRegistration
import se.floreteng.sssblaundry.data.SettingsRepository
import kotlin.coroutines.cancellation.CancellationException

/**
 * Keeps the server's copy of this phone's push preferences in step with the
 * settings, the way PushService.swift does on iOS.
 *
 * The settings stay the source of truth — they have to feel instant and work
 * offline — and the server is a mirror. Instead of every screen remembering to
 * sync, this watches the settings: whatever the server should hold is compared
 * with what it was last told ([AppSettings.pushRegistration]), so a toggle, a
 * new alert time, a fresh FCM token, a sign-out or another object number all
 * end up here, and a request that failed is simply retried on the next change
 * or launch.
 */
class PushRegistrar(
    private val context: Context,
    private val settings: SettingsRepository,
    private val api: ApiClient,
    private val scope: CoroutineScope,
) {
    /** A deregistration has to land before the registration that follows it, or it undoes it. */
    private val mutex = Mutex()

    fun start() {
        scope.launch {
            settings.settings.filterNotNull()
                .map { it.desiredRegistration() to it.pushRegistration }
                .distinctUntilChanged()
                .collect { (desired, current) -> if (desired != current) sync(force = false) }
        }
    }

    /**
     * On every return to the app: a token can be reissued at any time, and a
     * registration the server lost (a reset database, a token it dropped) is put
     * back, as iOS does by syncing at each launch.
     */
    fun refresh() {
        scope.launch {
            val current = settings.settings.filterNotNull().first()
            if (!current.notificationsEnabled) return@launch
            // Blocked in system settings behind the app's back: the switch follows,
            // and the server stops sending (the change deregisters).
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) {
                settings.setNotificationsEnabled(false)
                return@launch
            }
            fetchToken()
            sync(force = true)
        }
    }

    /** After the user turns notifications on and Android has allowed them. */
    fun enable() {
        scope.launch {
            settings.setNotificationsPrompted()
            settings.setNotificationsEnabled(true)
            fetchToken()
        }
    }

    /** Asked and refused: Settings now points at the system's switch instead of asking again. */
    fun markPrompted() {
        scope.launch { settings.setNotificationsPrompted() }
    }

    /**
     * FCM is not started until notifications are wanted (auto-init is off in
     * the manifest), so a phone that never turns them on never gets a token.
     */
    private suspend fun fetchToken() {
        val messaging = FirebaseMessaging.getInstance()
        messaging.isAutoInitEnabled = true
        val token = try {
            messaging.token.await()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // No Play services, or offline: the switch stays on and the next launch retries.
            Log.w(TAG, "Couldn't get an FCM token", e)
            return
        }
        if (token != settings.current.deviceToken) settings.setDeviceToken(token)
    }

    private suspend fun sync(force: Boolean) = mutex.withLock {
        val current = settings.settings.filterNotNull().first()
        val desired = current.desiredRegistration()
        var registered = current.pushRegistration
        if (desired == registered && !force) return@withLock

        // Leaving: another object number, a sign-out, notifications off, or a
        // token FCM has replaced.
        val leaving = registered?.takeIf { desired == null || it.objectId != desired.objectId || it.token != desired.token }
        if (leaving != null) {
            if (attempt { api.forObjectId(leaving.objectId).deregisterDevice(leaving.token) }) {
                registered = null
                settings.setPushRegistration(null)
            } else if (desired == null) {
                // Retried on the next change or launch. Until then the messaging
                // service drops whatever still arrives for an object number left.
                return@withLock
            }
        }

        if (desired != null && (desired != registered || force)) {
            val ok = attempt {
                api.forObjectId(desired.objectId).registerDevice(
                    deviceToken = desired.token,
                    enabled = true,
                    alertMinutes = desired.alertMinutes,
                    secondAlertMinutes = desired.secondAlertMinutes,
                )
            }
            if (ok) settings.setPushRegistration(desired)
        }
    }

    /**
     * `false` only when the request should be retried. A server without push
     * (`PUSH_DISABLED`, which is also the demo number's answer) or one refusing
     * the request outright is not worth asking again until something changes.
     */
    private suspend fun attempt(request: suspend () -> Unit): Boolean = try {
        request()
        true
    } catch (e: CancellationException) {
        throw e
    } catch (e: ApiError) {
        if (e.code == "PUSH_DISABLED") Log.i(TAG, "The server doesn't send pushes")
        else Log.w(TAG, "Push registration failed: ${e.code}")
        e.code !in RETRYABLE
    }

    private fun AppSettings.desiredRegistration(): PushRegistration? {
        val token = deviceToken ?: return null
        if (objectId.isEmpty() || !notificationsEnabled) return null
        return PushRegistration(objectId, token, alert.minutesBefore, secondAlert.minutesBefore)
    }

    private companion object {
        const val TAG = "PushRegistrar"
        val RETRYABLE = setOf("NO_INTERNET", "TIMEOUT", "NETWORK_ERROR", "SERVICE_ERROR", "BAD_RESPONSE")
    }
}
