package se.floreteng.sssblaundry.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive

// The wire format lives in api/src and is hand-mirrored here, as it is in the
// iOS app's Models.swift. A change to a DTO belongs in one commit across all three.

/** `GET /android/latest`: the newest APK, which an install from an APK compares itself with. */
@Serializable
data class AndroidRelease(
    val versionCode: Int,
    val versionName: String,
) {
    /** As the feedback form and Play show it: "1.0 (12)". */
    val label: String get() = "$versionName ($versionCode)"
}

@Serializable
data class WeekResponse(
    val week: Week,
    val groups: List<LaundryGroup>,
    val timeslots: List<Timeslot>,
)

@Serializable
data class Week(
    val fromDate: String,
    val toDate: String,
    val timezone: String,
)

@Serializable
data class LaundryGroup(
    val id: Int,
    /**
     * `null` upstream for a group whose Aptus label is a single line. Empty is
     * what the rest of the app reads as "no location to show"; making this
     * non-nullable fails the whole week's decode.
     */
    val location: String? = null,
    val name: String,
) {
    val place: String get() = location.orEmpty()
}

@Serializable
data class Timeslot(
    /** Opaque and content-derived: never construct, parse or persist one. */
    val id: String,
    val startAt: String,
    val endAt: String,
    val localDate: String,
    val startTime: String,
    val endTime: String,
    val spansMidnight: Boolean,
    val groups: List<TimeslotGroup>,
    /** Where the user ranks this among their dibs and bookings, 1 = most wanted. */
    val priority: Int? = null,
)

@Serializable
data class TimeslotGroup(
    val groupId: Int,
    val status: GroupStatus,
    val canBook: Boolean,
    val canCancel: Boolean,
    /** The user is in line for this group. The server leaves it out otherwise. */
    val dibs: Boolean? = null,
    /** Their place in that line, 1 being next. */
    val dibsQueue: Int? = null,
) {
    val hasDibs: Boolean get() = dibs == true
}

@Serializable
enum class GroupStatus {
    @SerialName("bookable") Bookable,
    @SerialName("own") Own,
    @SerialName("unavailable") Unavailable,
}

@Serializable
data class ActionResponse(
    val timeslotId: String,
    val overallStatus: OverallStatus,
    val results: List<ActionResult>,
)

@Serializable
enum class OverallStatus {
    @SerialName("success") Success,
    @SerialName("partial_success") PartialSuccess,
    @SerialName("failed") Failed,
}

@Serializable
data class ActionResult(
    val groupId: Int,
    val status: String,
    val message: String? = null,
    val error: ApiError? = null,
) {
    val isSuccessful: Boolean
        get() = status in setOf("booked", "already_booked", "cancelled", "not_booked")
}

@Serializable
data class ApiError(
    val code: String,
    override val message: String,
    val details: JsonObject? = null,
) : Exception(message) {
    val limit: Int? get() = details?.get("limit")?.jsonPrimitive?.intOrNull

    val isAuthFailure: Boolean get() = code == "AUTH_FAILED" || code == "MISSING_OBJECT_ID"

    companion object {
        fun local(code: String, message: String = "") = ApiError(code, message)
    }
}

@Serializable
data class ApiErrorEnvelope(val error: ApiError)

@Serializable
data class DibsResponse(val timeslotId: String, val groupIds: List<Int>)

@Serializable
data class OkResponse(val ok: Boolean)
