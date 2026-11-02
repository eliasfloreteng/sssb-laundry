package se.floreteng.sssblaundry.data

import java.time.Instant

/**
 * What Aptus refuses, and what SSSB merely publishes — two kinds of rule, treated
 * differently on purpose. `canBook` / `canCancel` mirror the portal's own book
 * button and unbook link, and the API refuses the action without them, so the app
 * blocks whatever they rule out. The per-room session quota in [LaundryRooms] only
 * warns: a booking Aptus has already released must never stop the user booking.
 */
object BookingRules {
    /** Aptus's own cap on groups in one booking action. */
    const val MAX_GROUPS_PER_BOOKING = 2

    /**
     * A booking not activated within 15 minutes of its start is released upstream.
     * Spelled again as `GRACE_SECONDS` in api/src/notifications.ts.
     */
    const val ACTIVATION_GRACE_SECONDS = 15L * 60

    /** How long past the end of a session a timer is still worth offering. */
    const val TIMER_OFFER_WINDOW_SECONDS = 30L * 60
}

/** Why one group of one timeslot can't be booked or released right now. */
enum class GroupRestriction {
    /** The timeslot has started: nothing in the past is booked, nothing running released. */
    Started,
    /** Someone else holds it. */
    Taken,
    /** Free, but Aptus offers no book button — most often the session limit. */
    NotBookable,
    /** Yours, but Aptus offers no way to release it. */
    NotCancellable,
}

fun Timeslot.hasStarted(now: Instant = Instant.now()): Boolean {
    // An unreadable timestamp must never be what silently blocks a booking.
    val start = start ?: return false
    return !start.isAfter(now)
}

/** What stops this group being booked or released, or `null` when nothing does. */
fun TimeslotGroup.restriction(timeslot: Timeslot, now: Instant = Instant.now()): GroupRestriction? {
    // "Taken" is the more useful half of a truth where both halves hold.
    if (status == GroupStatus.Unavailable) return GroupRestriction.Taken
    if (timeslot.hasStarted(now)) return GroupRestriction.Started
    return when (status) {
        GroupStatus.Unavailable -> GroupRestriction.Taken
        GroupStatus.Bookable -> if (canBook) null else GroupRestriction.NotBookable
        GroupStatus.Own -> if (canCancel) null else GroupRestriction.NotCancellable
    }
}

/** Free for everyone else, but Aptus offers this user no book button — their session limit. */
val TimeslotGroup.isFreePastLimit: Boolean get() = status == GroupStatus.Bookable && !canBook

/**
 * Not the user's to book yet and not started, so the server can still book it for
 * them: somebody else holds it and it may free up, or it is free but past the
 * user's session limit.
 */
fun TimeslotGroup.canCallDibs(timeslot: Timeslot, now: Instant = Instant.now()): Boolean {
    if (timeslot.hasStarted(now)) return false
    return status == GroupStatus.Unavailable || isFreePastLimit
}

fun Timeslot.visibleGroups(hidden: Set<Int>): List<TimeslotGroup> = groups.filter { it.groupId !in hidden }

/** Visible groups the user could join the line for and is not in yet. */
fun Timeslot.dibsableGroups(hidden: Set<Int>, now: Instant = Instant.now()): List<TimeslotGroup> =
    visibleGroups(hidden).filter { !it.hasDibs && it.canCallDibs(this, now) }

/** Visible free groups the user could line up for because of their session limit. */
fun Timeslot.freePastLimitGroups(hidden: Set<Int>, now: Instant = Instant.now()): List<TimeslotGroup> =
    dibsableGroups(hidden, now).filter { it.isFreePastLimit }

fun Timeslot.hasDibs(hidden: Set<Int>): Boolean = visibleGroups(hidden).any { it.hasDibs }

/** The groups the user could still act on, hidden ones left out. */
fun Timeslot.actionableGroups(hidden: Set<Int>, now: Instant = Instant.now()): List<TimeslotGroup> =
    visibleGroups(hidden).filter { it.restriction(this, now) == null }

/** A booking is never filtered out of the week list, however late it is. */
fun Timeslot.hasOwnGroup(hidden: Set<Int>): Boolean = visibleGroups(hidden).any { it.status == GroupStatus.Own }

/** Active hours can span midnight: `start > end` wraps, `start == end` is no filter. */
object ActiveHours {
    const val DEFAULT_START = 6 * 60
    const val DEFAULT_END = 0

    fun includes(timeslot: Timeslot, startMinutes: Int, endMinutes: Int): Boolean {
        val m = LaundryTime.minutes(timeslot.startTime) ?: return true
        if (startMinutes == endMinutes) return true
        return if (startMinutes < endMinutes) m in startMinutes until endMinutes
        else m >= startMinutes || m < endMinutes
    }
}
