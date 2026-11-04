package se.floreteng.sssblaundry.data

import java.time.Instant

/**
 * Which notification titles this build knows, as the server counts them
 * (`PUSH_VERSION` in `api/src/notifications.ts`, `NotificationSetting.pushVersion`
 * on iOS). The server sends no title newer than this. Bump all three together
 * when a title is added.
 */
const val PUSH_VERSION = 1

/**
 * How far ahead of a timeslot a reminder fires — the same choices as
 * `BookingAlert` in NotificationSettings.swift. [minutes] is exactly what the
 * server stores as `alertMinutes`, so no mapping table is needed on either side.
 */
enum class BookingAlert(val minutes: Int) {
    Off(-1),
    AtStart(0),
    FiveMinutes(5),
    TenMinutes(10),
    FifteenMinutes(15),
    ThirtyMinutes(30),
    OneHour(60),
    TwoHours(120),
    OneDay(1440),
    OneWeek(10080),
    ;

    /** Minutes before the start, or `null` when nothing should fire. */
    val minutesBefore: Int? get() = if (this == Off) null else minutes

    /** The span in whole units, for the labels; `null` for [Off] and [AtStart]. */
    val lead: Lead? get() = if (minutes > 0) leadUnit(minutes) else null

    companion object {
        val DEFAULT_FIRST = TenMinutes
        val DEFAULT_SECOND = Off

        fun of(minutes: Int?, fallback: BookingAlert): BookingAlert =
            entries.firstOrNull { it.minutes == minutes } ?: fallback
    }
}

enum class LeadUnit { Minute, Hour, Day, Week }

data class Lead(val count: Int, val unit: LeadUnit)

/** The offset as a whole number of the largest unit that divides it, as `leadUnit` on the server. */
fun leadUnit(minutes: Int): Lead = when {
    minutes % 10080 == 0 -> Lead(minutes / 10080, LeadUnit.Week)
    minutes % 1440 == 0 -> Lead(minutes / 1440, LeadUnit.Day)
    minutes % 60 == 0 -> Lead(minutes / 60, LeadUnit.Hour)
    else -> Lead(minutes, LeadUnit.Minute)
}

enum class PushKind(val wire: String) {
    Reminder("reminder"),
    NewBooking("new_booking"),
    DibsWon("dibs_won"),
    Cancelled("cancelled"),
    ;

    companion object {
        fun of(wire: String?): PushKind? = entries.firstOrNull { it.wire == wire }
    }
}

/** What the title says, decided the way `reminderTitle` and `dibsWonTitle` decide on the server. */
sealed interface PushTitle {
    data object StartsNow : PushTitle
    data class StartsIn(val lead: Lead) : PushTitle
    data object NewBooking : PushTitle
    data object DibsWon : PushTitle
    data class DibsSwapped(val replacedStart: Instant) : PushTitle
}

/**
 * The words a notification is assembled from. Resources on the phone; a fixed
 * English table in the unit tests, which is why this is an interface.
 */
interface NotificationWording {
    fun title(title: PushTitle): String
    /** Day and time span of a booking, in the phone's language. */
    fun span(start: Instant, end: Instant?): String
    /** "%1$s · %2$s": the span, then the machines. */
    fun withMachines(span: String, machines: String): String
    val activateWarning: String
}

/**
 * One FCM data message. The server sends the booking rather than finished
 * sentences (`buildFcmData` in `api/src/notifications.ts`), so the wording and
 * the time formats are the app's own.
 */
data class PushMessage(
    val kind: PushKind,
    val start: Instant,
    val end: Instant?,
    val timeslotId: String?,
    val groupIds: List<Int>,
    val machines: String,
    val location: String,
    /** Minutes before the start a reminder fires (0 = starts now), or a dibs' lead when won. */
    val offsetMinutes: Int?,
    /** The booking a dibs gave up, if it cost one. */
    val replacedStart: Instant?,
) {
    /** One notification per booking: every push about it replaces the last one, and a cancellation finds it. */
    val tag: String get() = tagFor(start)

    val title: PushTitle
        get() = when (kind) {
            PushKind.Reminder -> offsetMinutes?.takeIf { it > 0 }?.let { PushTitle.StartsIn(leadUnit(it)) } ?: PushTitle.StartsNow
            PushKind.DibsWon -> replacedStart?.let(PushTitle::DibsSwapped) ?: PushTitle.DibsWon
            PushKind.NewBooking, PushKind.Cancelled -> PushTitle.NewBooking
        }

    /**
     * Close to the start, the grace period is the part worth reading: a session
     * not tagged into within 15 minutes is released. A new booking is news, not a
     * nudge, so it never carries it.
     */
    val warnsToActivate: Boolean
        get() = when (kind) {
            PushKind.Reminder, PushKind.DibsWon -> offsetMinutes == null || offsetMinutes <= 15
            PushKind.NewBooking, PushKind.Cancelled -> false
        }

    fun title(wording: NotificationWording): String = wording.title(title)

    fun body(wording: NotificationWording): String {
        val span = wording.span(start, end)
        val line = if (machines.isNotBlank()) wording.withMachines(span, machines) else span
        return if (warnsToActivate) "$line\n${wording.activateWarning}" else line
    }

    companion object {
        fun tagFor(start: Instant): String = "booking.${start.epochSecond}"

        /** `null` for a kind this build doesn't know, or a message without a usable start. */
        fun parse(data: Map<String, String>): PushMessage? {
            val kind = PushKind.of(data["kind"]) ?: return null
            val start = data["startAt"]?.let(LaundryTime::parseInstant) ?: return null
            return PushMessage(
                kind = kind,
                start = start,
                end = data["endAt"]?.let(LaundryTime::parseInstant),
                timeslotId = data["timeslotId"]?.takeIf { it.isNotEmpty() },
                groupIds = data["groupIds"].orEmpty().split(",").mapNotNull { it.trim().toIntOrNull() },
                machines = data["machines"].orEmpty().trim(),
                location = data["location"].orEmpty().trim(),
                offsetMinutes = data["offsetMinutes"]?.trim()?.toIntOrNull(),
                replacedStart = data["replacedStartAt"]?.let(LaundryTime::parseInstant),
            )
        }
    }
}
