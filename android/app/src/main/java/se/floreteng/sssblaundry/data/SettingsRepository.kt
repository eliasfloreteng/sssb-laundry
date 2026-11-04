package se.floreteng.sssblaundry.data

import android.content.Context
import androidx.datastore.preferences.core.MutablePreferences
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.serialization.Serializable

/** Everything the app remembers. The object number is excluded from backups. */
data class AppSettings(
    val objectId: String = "",
    val activeHoursEnabled: Boolean = true,
    val activeHoursStart: Int = ActiveHours.DEFAULT_START,
    val activeHoursEnd: Int = ActiveHours.DEFAULT_END,
    val hiddenGroups: Set<Int> = emptySet(),
    val showAllTimeslots: Boolean = false,
    /** `null` until the user has set it either way — see [SettingsRepository.adoptExistingDibs]. */
    val dibsSetting: Boolean? = null,
    val laundryRoomId: String = "",
    val inviteIncludesObjectId: Boolean = true,
    val feedbackDraft: String = "",
    /** Booking reminders, new-booking and dibs pushes; off until asked for, as on iOS. */
    val notificationsEnabled: Boolean = false,
    val alert: BookingAlert = BookingAlert.DEFAULT_FIRST,
    val secondAlert: BookingAlert = BookingAlert.DEFAULT_SECOND,
    /** Set once the app has asked for the permission, so the one-time offer stays one-time. */
    val notificationsPrompted: Boolean = false,
    /** The last FCM token handed to us, sent as `X-Device-Token` and registered with the server. */
    val deviceToken: String? = null,
    /** What the server was last told, so a change knows what to replace. */
    val pushRegistration: PushRegistration? = null,
    /** Epoch millis before which an available update is not offered again. */
    val updateSnoozedUntil: Long = 0,
) {
    /** Dibs is opt-in: with it off, a taken group is just taken. */
    val dibsEnabled: Boolean get() = dibsSetting ?: false
    val laundryRoom: LaundryRoom? get() = LaundryRooms.room(laundryRoomId)
}

/** This phone as the server knows it: registered for [objectId] under [token]. */
@Serializable
data class PushRegistration(
    val objectId: String,
    val token: String,
    val alertMinutes: Int?,
    val secondAlertMinutes: Int?,
)

private val Context.dataStore by preferencesDataStore(name = "settings")

class SettingsRepository(context: Context, scope: CoroutineScope) {
    private val store = context.dataStore

    private object Keys {
        val objectId = stringPreferencesKey("objectId")
        val activeHoursEnabled = booleanPreferencesKey("activeHours.enabled")
        val activeHoursStart = intPreferencesKey("activeHours.startMinutes")
        val activeHoursEnd = intPreferencesKey("activeHours.endMinutes")
        /** Comma-separated ids; go through [encode] and [parse]. */
        val hiddenGroups = stringPreferencesKey("activeGroups.hiddenIds")
        val showAllTimeslots = booleanPreferencesKey("showAllTimeslots")
        val dibsEnabled = booleanPreferencesKey("dibs.enabled")
        val laundryRoomId = stringPreferencesKey("laundryRoom.id")
        val inviteIncludesObjectId = booleanPreferencesKey("invite.includeObjectId")
        val feedbackDraft = stringPreferencesKey("feedback.draft")
        val notificationsEnabled = booleanPreferencesKey("notifications.enabled")
        val alert = intPreferencesKey("notifications.alert")
        val secondAlert = intPreferencesKey("notifications.secondAlert")
        val notificationsPrompted = booleanPreferencesKey("notifications.prompted")
        val deviceToken = stringPreferencesKey("notifications.deviceToken")
        /** JSON of [PushRegistration]. Android only: iOS re-sends on every launch instead. */
        val pushRegistration = stringPreferencesKey("notifications.registration")
        val updateSnoozedUntil = longPreferencesKey("update.snoozedUntil")
    }

    /** `null` until the store has been read once, so the splash screen can wait for it. */
    val settings: StateFlow<AppSettings?> = store.data
        .map { it.toSettings() }
        .stateIn(scope, SharingStarted.Eagerly, null)

    /** For code without a flow to collect — the API's object id provider. */
    val current: AppSettings get() = settings.value ?: AppSettings()

    private fun Preferences.toSettings() = AppSettings(
        objectId = this[Keys.objectId].orEmpty(),
        activeHoursEnabled = this[Keys.activeHoursEnabled] ?: true,
        activeHoursStart = this[Keys.activeHoursStart] ?: ActiveHours.DEFAULT_START,
        activeHoursEnd = this[Keys.activeHoursEnd] ?: ActiveHours.DEFAULT_END,
        hiddenGroups = parse(this[Keys.hiddenGroups].orEmpty()),
        showAllTimeslots = this[Keys.showAllTimeslots] ?: false,
        dibsSetting = this[Keys.dibsEnabled],
        laundryRoomId = this[Keys.laundryRoomId].orEmpty(),
        inviteIncludesObjectId = this[Keys.inviteIncludesObjectId] ?: true,
        feedbackDraft = this[Keys.feedbackDraft].orEmpty(),
        notificationsEnabled = this[Keys.notificationsEnabled] ?: false,
        alert = BookingAlert.of(this[Keys.alert], BookingAlert.DEFAULT_FIRST),
        secondAlert = BookingAlert.of(this[Keys.secondAlert], BookingAlert.DEFAULT_SECOND),
        notificationsPrompted = this[Keys.notificationsPrompted] ?: false,
        deviceToken = this[Keys.deviceToken]?.takeIf { it.isNotEmpty() },
        pushRegistration = this[Keys.pushRegistration]?.let {
            runCatching { ApiClient.json.decodeFromString<PushRegistration>(it) }.getOrNull()
        },
        updateSnoozedUntil = this[Keys.updateSnoozedUntil] ?: 0,
    )

    private suspend fun update(block: MutablePreferences.() -> Unit) {
        store.edit { it.block() }
    }

    suspend fun setObjectId(id: String?) = update {
        if (id.isNullOrBlank()) remove(Keys.objectId) else this[Keys.objectId] = id.trim()
    }

    suspend fun setActiveHoursEnabled(value: Boolean) = update { this[Keys.activeHoursEnabled] = value }
    suspend fun setActiveHoursStart(minutes: Int) = update { this[Keys.activeHoursStart] = minutes }
    suspend fun setActiveHoursEnd(minutes: Int) = update { this[Keys.activeHoursEnd] = minutes }
    suspend fun setHiddenGroups(ids: Set<Int>) = update { this[Keys.hiddenGroups] = encode(ids) }
    suspend fun setShowAllTimeslots(value: Boolean) = update { this[Keys.showAllTimeslots] = value }
    suspend fun setDibsEnabled(value: Boolean) = update { this[Keys.dibsEnabled] = value }
    suspend fun setLaundryRoomId(id: String) = update { this[Keys.laundryRoomId] = id }
    suspend fun setInviteIncludesObjectId(value: Boolean) = update { this[Keys.inviteIncludesObjectId] = value }
    suspend fun setFeedbackDraft(text: String) = update { this[Keys.feedbackDraft] = text }
    suspend fun setNotificationsEnabled(value: Boolean) = update { this[Keys.notificationsEnabled] = value }
    suspend fun setAlert(alert: BookingAlert) = update { this[Keys.alert] = alert.minutes }
    suspend fun setSecondAlert(alert: BookingAlert) = update { this[Keys.secondAlert] = alert.minutes }
    suspend fun setNotificationsPrompted() = update { this[Keys.notificationsPrompted] = true }
    suspend fun setDeviceToken(token: String) = update { this[Keys.deviceToken] = token }
    suspend fun snoozeUpdate(until: Long) = update { this[Keys.updateSnoozedUntil] = until }

    suspend fun setPushRegistration(registration: PushRegistration?) = update {
        if (registration == null) {
            remove(Keys.pushRegistration)
        } else {
            this[Keys.pushRegistration] = ApiClient.json.encodeToString(PushRegistration.serializer(), registration)
        }
    }

    /**
     * Dibs came before its setting did: a phone with lines already open on the
     * server would otherwise have them hidden behind a switch reading off. The
     * first week that shows one turns it on — only if never set either way.
     */
    suspend fun adoptExistingDibs(week: WeekResponse) {
        if (week.timeslots.none { ts -> ts.groups.any { it.hasDibs } }) return
        update { if (this[Keys.dibsEnabled] == null) this[Keys.dibsEnabled] = true }
    }

    companion object {
        fun parse(raw: String): Set<Int> = raw.split(",").mapNotNull { it.trim().toIntOrNull() }.toSet()
        fun encode(ids: Set<Int>): String = ids.sorted().joinToString(",")
    }
}
