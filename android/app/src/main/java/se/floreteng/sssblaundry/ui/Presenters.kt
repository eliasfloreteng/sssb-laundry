package se.floreteng.sssblaundry.ui

import android.content.res.Resources
import android.icu.text.ListFormatter
import se.floreteng.sssblaundry.R
import se.floreteng.sssblaundry.data.ActionResult
import se.floreteng.sssblaundry.data.ApiError
import se.floreteng.sssblaundry.data.BookingRules
import se.floreteng.sssblaundry.data.GroupRestriction
import se.floreteng.sssblaundry.data.GroupStatus
import se.floreteng.sssblaundry.data.LaundryGroup
import se.floreteng.sssblaundry.data.LaundryRoom
import java.util.Locale

/** Aptus's own label for a group, kept verbatim, or a stand-in for one not loaded. */
fun Resources.groupName(id: Int, groups: Map<Int, LaundryGroup>): String =
    groups[id]?.name ?: getString(R.string.group_fallback, id)

/** "Grupp 1 and Grupp 2" / "Grupp 1 och Grupp 2", the way the language joins a list. */
fun Resources.groupNames(ids: List<Int>, groups: Map<Int, LaundryGroup>): String =
    ListFormatter.getInstance(configuration.locales[0] ?: Locale.getDefault()).format(ids.map { groupName(it, groups) })

/** The one word or two beside a blocked group. A group with no restriction says nothing. */
fun Resources.restrictionLabel(restriction: GroupRestriction, status: GroupStatus): String = getString(
    when {
        status == GroupStatus.Own && restriction == GroupRestriction.Started -> R.string.status_in_progress
        status == GroupStatus.Own -> R.string.status_cant_be_cancelled
        restriction == GroupRestriction.Started -> R.string.status_too_late
        restriction == GroupRestriction.Taken -> R.string.status_unavailable
        else -> R.string.status_cant_be_booked
    },
)

/**
 * API and network failures in words a resident can act on. Error codes and HTTP
 * details never reach the UI; "Aptus" is what SSSB calls the booking system.
 */
object ErrorPresenter {
    fun headline(res: Resources, error: ApiError): String = res.getString(
        when (error.code) {
            "AUTH_FAILED", "MISSING_OBJECT_ID" -> R.string.err_headline_sign_in
            "NO_INTERNET", "TIMEOUT", "NETWORK_ERROR" -> R.string.err_headline_no_connection
            "INVALID_TIMESLOT_ID", "INVALID_DATE", "MISSING_DATE" -> R.string.err_headline_out_of_date
            "INVALID_GROUP_IDS" -> R.string.err_headline_too_many_groups
            "SERVICE_ERROR", "BAD_RESPONSE" -> R.string.err_headline_aptus
            "NOT_TAKEN" -> R.string.err_headline_free_now
            "TOO_LATE" -> R.string.err_headline_too_late
            "DIBS_LIMIT" -> R.string.err_headline_too_many_dibs
            "PUSH_DISABLED" -> R.string.err_headline_dibs_unavailable
            "FEEDBACK_FAILED", "FEEDBACK_DISABLED", "FEEDBACK_RATE_LIMITED" -> R.string.err_headline_feedback
            "BOOKING_FAILED" -> R.string.err_headline_booking_failed
            "CANCELLATION_FAILED" -> R.string.err_headline_cancellation_failed
            else -> R.string.err_headline_generic
        },
    )

    fun explanation(res: Resources, error: ApiError): String = when (error.code) {
        "AUTH_FAILED" -> res.getString(R.string.err_auth_failed)
        "MISSING_OBJECT_ID" -> res.getString(R.string.err_missing_object_id)
        "NO_INTERNET" -> res.getString(R.string.err_no_internet)
        "TIMEOUT" -> res.getString(R.string.err_timeout)
        "NETWORK_ERROR" -> res.getString(R.string.err_network)
        "INVALID_TIMESLOT_ID", "INVALID_DATE", "MISSING_DATE" -> res.getString(R.string.err_out_of_date)
        "INVALID_GROUP_IDS" -> res.getString(R.string.err_too_many_groups, BookingRules.MAX_GROUPS_PER_BOOKING)
        "NOT_TAKEN" -> res.getString(R.string.err_not_taken)
        "TOO_LATE" -> res.getString(R.string.err_too_late)
        // The server says how many; ten is what it has always been.
        "DIBS_LIMIT" -> res.getString(R.string.err_dibs_limit, error.limit ?: 10)
        "PUSH_DISABLED" -> res.getString(R.string.err_push_disabled)
        "FEEDBACK_FAILED", "FEEDBACK_DISABLED" -> res.getString(R.string.err_feedback_failed)
        "FEEDBACK_RATE_LIMITED" -> res.getString(R.string.err_feedback_rate_limited)
        "SERVICE_ERROR" -> res.getString(R.string.err_service)
        "BAD_RESPONSE" -> res.getString(R.string.err_bad_response)
        else -> error.message.ifEmpty { res.getString(R.string.err_fallback) }
    }

    /** "Grupp 1: couldn’t book — someone else took it first". */
    fun summary(res: Resources, result: ActionResult, action: BookingAction, group: String, room: LaundryRoom?): String {
        if (result.isSuccessful) {
            return res.getString(
                when (result.status) {
                    "booked" -> R.string.sum_booked
                    "already_booked" -> R.string.sum_already_yours
                    "cancelled" -> R.string.sum_cancelled
                    "not_booked" -> R.string.sum_not_booked
                    else -> R.string.sum_done
                },
                group,
            )
        }
        val reason = reason(res, result, action, room)
        return when (action) {
            BookingAction.Book -> res.getString(R.string.sum_couldnt_book, group, reason)
            BookingAction.Cancel -> res.getString(R.string.sum_couldnt_cancel, group, reason)
        }
    }

    /** Why one group didn't end up as asked — a clause appended to a line. */
    private fun reason(res: Resources, result: ActionResult, action: BookingAction, room: LaundryRoom?): String {
        if (result.status == "not_bookable") return res.getString(R.string.reason_not_offered)
        val max = room?.maxFutureBookings
        when (result.error?.code) {
            "SLOT_TAKEN", "ALREADY_BOOKED_BY_OTHER" -> return res.getString(R.string.reason_taken_first)
            "BOOKING_LIMIT", "TOO_MANY_BOOKINGS" ->
                return if (max == null) res.getString(R.string.reason_limit) else res.getString(R.string.reason_limit_max, max)
            "NOT_CANCELLABLE" -> return res.getString(R.string.reason_not_cancellable)
            "BOOK_SLOT_NOT_FOUND", "CANCEL_SLOT_NOT_FOUND" -> return res.getString(R.string.reason_slot_gone)
            "AUTH_FAILED" -> return res.getString(R.string.reason_auth)
        }
        return when (action) {
            BookingAction.Book ->
                if (max == null) res.getString(R.string.reason_refused_book) else res.getString(R.string.reason_refused_book_max, max)
            BookingAction.Cancel -> res.getString(R.string.reason_refused_cancel)
        }
    }
}

/** The failure to raise where there is no room for a per-group breakdown. `null` when nothing failed. */
fun ActionOutcome.failure(res: Resources, groups: Map<Int, LaundryGroup>, room: LaundryRoom?): ApiError? {
    requestError?.let { return it }
    val failed = failures.firstOrNull() ?: return null
    return ApiError.local(
        if (failed.action == BookingAction.Book) "BOOKING_FAILED" else "CANCELLATION_FAILED",
        ErrorPresenter.summary(res, failed.result, failed.action, res.groupName(failed.groupId, groups), room),
    )
}
