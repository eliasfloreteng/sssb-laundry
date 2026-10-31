package se.floreteng.sssblaundry.ui

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import se.floreteng.sssblaundry.SssbLaundryApplication
import se.floreteng.sssblaundry.data.ActionResult
import se.floreteng.sssblaundry.data.ActiveHours
import se.floreteng.sssblaundry.data.ApiError
import se.floreteng.sssblaundry.data.AppSettings
import se.floreteng.sssblaundry.data.BookingRules
import se.floreteng.sssblaundry.data.GroupStatus
import se.floreteng.sssblaundry.data.LaundryGroup
import se.floreteng.sssblaundry.data.LaundryTime
import se.floreteng.sssblaundry.data.OverallStatus
import se.floreteng.sssblaundry.data.Timeslot
import se.floreteng.sssblaundry.data.WeekResponse
import se.floreteng.sssblaundry.data.actionableGroups
import se.floreteng.sssblaundry.data.end
import se.floreteng.sssblaundry.data.freePastLimitGroups
import se.floreteng.sssblaundry.data.hasDibs
import se.floreteng.sssblaundry.data.hasOwnGroup
import se.floreteng.sssblaundry.data.hasStarted
import se.floreteng.sssblaundry.data.start
import java.time.Instant
import kotlin.coroutines.cancellation.CancellationException

sealed interface LoadState {
    data object Idle : LoadState
    data object Loading : LoadState
    data object Loaded : LoadState
    data class Failed(val error: ApiError) : LoadState
}

enum class BookingAction { Book, Cancel }

/** One group's answer, tagged with what was asked of it so failures read right. */
data class GroupOutcome(val result: ActionResult, val action: BookingAction) {
    val groupId: Int get() = result.groupId
    val isSuccessful: Boolean get() = result.isSuccessful
}

data class ActionOutcome(
    val id: Long,
    val timeslotId: String,
    val overallStatus: OverallStatus,
    val results: List<GroupOutcome>,
    /** Set when the request never got as far as a per-group answer. */
    val requestError: ApiError?,
) {
    val failures: List<GroupOutcome> get() = results.filter { !it.isSuccessful }
    val isFullSuccess: Boolean get() = requestError == null && failures.isEmpty() && overallStatus != OverallStatus.Failed
    val isPartial: Boolean get() = !isFullSuccess && results.any { it.isSuccessful }
    val didBook: Boolean get() = results.any { it.result.status == "booked" }
}

sealed interface DibsOutcome {
    data object Success : DibsOutcome
    data class Failure(val error: ApiError) : DibsOutcome
}

/** A booking the user holds, one per group — what is booked and cancelled upstream. */
data class HeldBooking(
    val timeslotId: String,
    val groupId: Int,
    val start: Instant,
    val end: Instant,
    val startTime: String,
    val endTime: String,
) {
    val id: String get() = "$timeslotId#$groupId"
}

/** A held timeslot with its groups folded together: the unit SSSB counts as one session. */
data class BookedSlot(
    val id: String,
    val start: Instant,
    val end: Instant,
    val startTime: String,
    val endTime: String,
    val groupIds: List<Int>,
)

/** A timeslot still ahead that the user holds, waits for, or both. */
data class PriorityItem(val timeslot: Timeslot) {
    val id: String get() = timeslot.id
    val isBooked: Boolean get() = timeslot.groups.any { it.status == GroupStatus.Own }
    val dibsGroups get() = timeslot.groups.filter { it.hasDibs }
}

/** Why the list has nothing to show — three different nothings. */
enum class EmptyReason { BeyondBookingWindow, NothingFree, NoTimeslots }

data class Day(val date: String, val slots: List<Timeslot>)

/**
 * The week list and every action on it — the Android twin of the iOS app's
 * `LaundryStore`, and deliberately the same rules: Stockholm days, an anchor that
 * a jump moves, bookings remembered apart from the browsing list, and an end to
 * paging found by barren weeks rather than empty ones.
 */
class LaundryViewModel(application: Application) : AndroidViewModel(application) {
    private val app = application as SssbLaundryApplication
    private val api = app.api
    val settingsRepository = app.settings

    val settings: AppSettings get() = settingsRepository.settings.value ?: AppSettings()

    var weeks by mutableStateOf<List<WeekResponse>>(emptyList())
        private set
    var loadState by mutableStateOf<LoadState>(LoadState.Idle)
        private set
    var isLoadingMore by mutableStateOf(false)
        private set
    var reachedEnd by mutableStateOf(false)
        private set
    var isRefreshing by mutableStateOf(false)
        private set
    var isJumping by mutableStateOf(false)
        private set
    var lastOutcome by mutableStateOf<ActionOutcome?>(null)
        private set
    var lastError by mutableStateOf<ApiError?>(null)
    var authFailed by mutableStateOf(false)
        private set

    /** Ticks so "has started" and the running session follow the clock. */
    var now by mutableStateOf(Instant.now())
        private set

    var today by mutableStateOf(LaundryTime.today())
        private set

    /** The first day the list shows. Today until the user jumps somewhere else. */
    var anchorDate by mutableStateOf(today)
        private set

    /**
     * Group metadata, accumulated: a jump past the booking window brings back no
     * groups at all, and names for held bookings must not disappear with it.
     */
    var groupsById by mutableStateOf<Map<Int, LaundryGroup>>(emptyMap())
        private set

    /**
     * Every booking, keyed by the week it arrived in. Kept apart from [weeks],
     * which a jump throws away: the session limit has to keep counting bookings
     * the browsing list no longer shows.
     */
    private var ownBookingsByWeek by mutableStateOf<Map<String, List<HeldBooking>>>(emptyMap())

    /** Bumped on every re-anchor, so a page already in flight can't land on the new list. */
    private var generation = 0
    private var barrenWeeks = 0
    private var sawUsableWeek = false
    private var outcomeCounter = 0L

    init {
        viewModelScope.launch {
            while (true) {
                delay(30_000)
                now = Instant.now()
                today = LaundryTime.today(now)
            }
        }
    }

    val isViewingToday: Boolean get() = anchorDate == today

    val allGroups: List<LaundryGroup> get() = groupsById.values.sortedBy { it.id }

    val emptyReason: EmptyReason
        get() = when {
            !isViewingToday -> EmptyReason.BeyondBookingWindow
            weeks.any { it.timeslots.isNotEmpty() } -> EmptyReason.NothingFree
            else -> EmptyReason.NoTimeslots
        }

    fun groupName(id: Int): String? = groupsById[id]?.name

    /** Launches in the view model, so an action outlives the sheet that started it. */
    fun launch(block: suspend () -> Unit): Job = viewModelScope.launch { block() }

    // region Bookings and sessions

    private val ownBookings: List<HeldBooking>
        get() = ownBookingsByWeek.values.flatten().distinctBy { it.id }.sortedBy { it.start }

    /**
     * Bookings still held: a missed timeslot stops occupying the quota at
     * start + 15 minutes, when Aptus releases it, not at its end.
     */
    val heldBookings: List<HeldBooking>
        get() = ownBookings.filter { it.start.plusSeconds(BookingRules.ACTIVATION_GRACE_SECONDS).isAfter(now) }

    private fun slots(bookings: List<HeldBooking>): List<BookedSlot> =
        bookings.groupBy { it.timeslotId }.values.map { entries ->
            val first = entries.first()
            val ids = entries.map { it.groupId }.sorted()
            BookedSlot(
                id = "${first.start.epochSecond}-${ids.joinToString("_")}",
                start = first.start,
                end = first.end,
                startTime = first.startTime,
                endTime = first.endTime,
                groupIds = ids,
            )
        }.sortedBy { it.start }

    /**
     * The sessions SSSB counts against "max future bookings": one per booked
     * time however many groups, and only ones not yet started.
     */
    fun futureSessions(excludingTimeslot: String? = null): List<BookedSlot> {
        val excluded = heldBookings.filter { it.timeslotId == excludingTimeslot }.map { it.start }.toSet()
        return slots(heldBookings).filter { it.start.isAfter(now) && it.start !in excluded }
    }

    /** The session under way: from its start until half an hour past its end. */
    val runningSession: BookedSlot?
        get() = slots(ownBookings).lastOrNull {
            !it.start.isAfter(now) && now.isBefore(it.end.plusSeconds(BookingRules.TIMER_OFFER_WINDOW_SECONDS))
        }

    // endregion

    /** The freshest copy of a timeslot, so an open sheet reflects the refresh. */
    fun timeslot(id: String): Timeslot? = weeks.firstNotNullOfOrNull { week -> week.timeslots.firstOrNull { it.id == id } }

    private val timeslotsByDay: List<Day>
        get() = weeks.asSequence()
            .flatMap { it.timeslots }
            .filter { belongsInList(it) }
            .groupBy { it.localDate }
            .toSortedMap()
            .map { (date, slots) -> Day(date, slots.sortedBy { it.startAt }) }

    /**
     * The anchor day onwards — plus, on the list that starts today, a booking
     * from yesterday that is still running across midnight.
     */
    private fun belongsInList(timeslot: Timeslot): Boolean {
        if (timeslot.localDate >= anchorDate) return true
        if (anchorDate != today) return false
        if (timeslot.groups.none { it.status == GroupStatus.Own }) return false
        val end = timeslot.end ?: return false
        return end.isAfter(now)
    }

    /**
     * The list as the user wants to browse it. A booking or a dibs is never
     * filtered away — active hours and the free-slots filter are about what is
     * worth browsing, and a time the user holds has to be findable.
     */
    fun visibleDays(settings: AppSettings): List<Day> {
        val hidden = settings.hiddenGroups
        val showAll = settings.showAllTimeslots
        val applyActiveHours = !showAll && settings.activeHoursEnabled &&
            settings.activeHoursStart != settings.activeHoursEnd
        return timeslotsByDay.mapNotNull { day ->
            val slots = day.slots.filter { ts ->
                if (ts.groups.none { it.groupId !in hidden }) return@filter false
                if (ts.hasOwnGroup(hidden) || ts.hasDibs(hidden)) return@filter true
                if (!showAll) {
                    val linable = settings.dibsEnabled && ts.freePastLimitGroups(hidden, now).isNotEmpty()
                    if (!linable && ts.actionableGroups(hidden, now).isEmpty()) return@filter false
                }
                if (applyActiveHours) {
                    ActiveHours.includes(ts, settings.activeHoursStart, settings.activeHoursEnd)
                } else {
                    true
                }
            }
            if (slots.isEmpty()) null else Day(day.date, slots)
        }
    }

    // region Loading

    fun loadInitial() {
        if (weeks.isNotEmpty() || loadState == LoadState.Loading) return
        loadState = LoadState.Loading
        viewModelScope.launch { reanchor(anchorDate) }
    }

    /** Stays where the user left it: a pull is easy to trigger by accident. */
    suspend fun refresh() {
        if (weeks.isEmpty()) loadState = LoadState.Loading
        reanchor(anchorDate)
    }

    fun pullToRefresh() {
        if (isRefreshing) return
        viewModelScope.launch {
            isRefreshing = true
            try {
                now = Instant.now()
                today = LaundryTime.today(now)
                refresh()
            } finally {
                isRefreshing = false
            }
        }
    }

    fun retry() {
        lastError = null
        viewModelScope.launch { refresh() }
    }

    /** Starts the list again at [date]. The anchor moves only once the week is on screen. */
    fun jump(date: String) {
        if (isJumping || date == anchorDate) return
        viewModelScope.launch {
            isJumping = true
            try {
                if (reanchor(date)) anchorDate = date
            } finally {
                isJumping = false
            }
        }
    }

    fun jumpToToday() = jump(today)

    private suspend fun reanchor(date: String): Boolean {
        generation += 1
        return fetchWeek(date, replaceAll = true)
    }

    fun loadMoreIfNeeded() {
        if (isLoadingMore || isJumping || reachedEnd) return
        val last = weeks.lastOrNull() ?: return
        val next = LaundryTime.addDays(last.week.toDate, 1) ?: return
        isLoadingMore = true
        viewModelScope.launch {
            try {
                fetchWeek(next, replaceAll = false)
            } finally {
                isLoadingMore = false
            }
        }
    }

    /** Pages to the end of what Aptus will book, so every booking and dibs can be ranked. */
    suspend fun loadToEnd() {
        if (weeks.isEmpty()) {
            loadState = LoadState.Loading
            reanchor(anchorDate)
        }
        repeat(8) {
            if (reachedEnd) return
            val last = weeks.lastOrNull() ?: return
            val next = LaundryTime.addDays(last.week.toDate, 1) ?: return
            val before = weeks.size
            fetchWeek(next, replaceAll = false)
            if (weeks.size == before) return
        }
    }

    /**
     * Aptus renders its grid long past the last date it will book, so the end
     * of the list looks like a full week with no book button on any slot.
     * Free is the status, not the button: a user at their limit must still page
     * ahead. Blind to hidden groups — where the list ends is not a display choice.
     */
    private fun isBarren(week: WeekResponse): Boolean = week.timeslots.none { ts ->
        ts.groups.any { it.status == GroupStatus.Own || (it.status == GroupStatus.Bookable && !ts.hasStarted(now)) }
    }

    /** Two barren weeks running until a usable one has been seen, then one. */
    private fun isEnded() = barrenWeeks >= (if (sawUsableWeek) 1 else 2)

    private fun ownBookings(week: WeekResponse): List<HeldBooking> = week.timeslots.flatMap { ts ->
        val start = ts.start ?: return@flatMap emptyList()
        val end = ts.end ?: return@flatMap emptyList()
        ts.groups.filter { it.status == GroupStatus.Own }.map {
            HeldBooking(ts.id, it.groupId, start, end, ts.startTime, ts.endTime)
        }
    }

    /** Whether the week landed. */
    private suspend fun fetchWeek(date: String, replaceAll: Boolean): Boolean {
        val token = generation
        return try {
            val resp = api.getWeek(date)
            // Re-anchored while in flight: a page of a list that no longer exists.
            if (token != generation) return false

            groupsById = groupsById + resp.groups.filter { it.id !in groupsById }.associateBy { it.id }
            ownBookingsByWeek = ownBookingsByWeek + (resp.week.fromDate to ownBookings(resp))
            settingsRepository.adoptExistingDibs(resp)

            val barren = isBarren(resp)
            val existing = weeks.indexOfFirst { it.week.fromDate == resp.week.fromDate }
            when {
                replaceAll -> {
                    weeks = listOf(resp)
                    barrenWeeks = if (barren) 1 else 0
                    sawUsableWeek = !barren
                    reachedEnd = isEnded()
                }
                // A week we already had, fetched again after an action — says nothing about the end.
                existing >= 0 -> weeks = weeks.toMutableList().also { it[existing] = resp }
                else -> {
                    weeks = weeks + resp
                    barrenWeeks = if (barren) barrenWeeks + 1 else 0
                    sawUsableWeek = sawUsableWeek || !barren
                    reachedEnd = isEnded()
                }
            }
            loadState = LoadState.Loaded
            true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            handleError(e.asApiError())
            false
        }
    }

    private fun handleError(error: ApiError) {
        loadState = LoadState.Failed(error)
        if (error.isAuthFailure) {
            authFailed = true
        } else if (weeks.isNotEmpty()) {
            lastError = error
        }
    }

    private suspend fun refreshWeekContaining(timeslotId: String) {
        val week = weeks.firstOrNull { w -> w.timeslots.any { it.id == timeslotId } }
        if (week == null) refresh() else fetchWeek(week.week.fromDate, replaceAll = false)
    }

    // endregion

    // region Actions

    /**
     * Cancels run first: with a session limit, swapping groups in one submit can
     * only succeed if the old one is released before the new one is asked for.
     */
    suspend fun bookAndCancel(timeslotId: String, toBook: List<Int>, toCancel: List<Int>): ActionOutcome {
        val results = mutableListOf<GroupOutcome>()
        var overall: OverallStatus? = null
        var requestError: ApiError? = null

        if (toCancel.isNotEmpty()) {
            try {
                val resp = api.cancel(timeslotId, toCancel)
                results += resp.results.map { GroupOutcome(it, BookingAction.Cancel) }
                overall = combine(overall, resp.overallStatus)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                requestError = e.asApiError()
            }
        }
        if (requestError == null && toBook.isNotEmpty()) {
            try {
                val resp = api.book(timeslotId, toBook)
                results += resp.results.map { GroupOutcome(it, BookingAction.Book) }
                overall = combine(overall, resp.overallStatus)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                requestError = e.asApiError()
            }
        }

        val outcome = ActionOutcome(
            id = ++outcomeCounter,
            timeslotId = timeslotId,
            overallStatus = if (requestError == null) overall ?: OverallStatus.Success else OverallStatus.Failed,
            results = results,
            requestError = requestError,
        )
        lastOutcome = outcome
        if (requestError != null) {
            if (requestError.isAuthFailure) authFailed = true
        } else {
            refreshWeekContaining(timeslotId)
        }
        return outcome
    }

    /** Joins the line for [add] and leaves it for [remove], then refreshes the week. */
    suspend fun setDibs(timeslotId: String, add: List<Int>, remove: List<Int>): DibsOutcome {
        try {
            if (remove.isNotEmpty()) api.dropDibs(timeslotId, remove)
            if (add.isNotEmpty()) api.callDibs(timeslotId, add)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            val error = e.asApiError()
            if (error.isAuthFailure) authFailed = true
            // A NOT_TAKEN means the list is stale in the good direction: the
            // refresh is what shows the user it can simply be booked.
            refreshWeekContaining(timeslotId)
            return DibsOutcome.Failure(error)
        }
        refreshWeekContaining(timeslotId)
        return DibsOutcome.Success
    }

    /**
     * Every timeslot still ahead that the user holds or waits for, in the order
     * the server acts on: unranked bookings first (nothing is given up for a
     * dibs unless ranked below it), then the ranked ones, then unranked dibs.
     */
    val priorityItems: List<PriorityItem>
        get() {
            val items = weeks.asSequence()
                .flatMap { it.timeslots }
                .filter { !it.hasStarted(now) }
                .map(::PriorityItem)
                .filter { it.isBooked || it.dibsGroups.isNotEmpty() }
                .distinctBy { it.id }
                .toList()
            fun tier(item: PriorityItem) = when {
                item.timeslot.priority != null -> 1
                item.isBooked -> 0
                else -> 2
            }
            return items.sortedWith(
                compareBy<PriorityItem>({ tier(it) }, { it.timeslot.priority ?: 0 }, { it.timeslot.startAt }),
            )
        }

    /** Sends the whole order. Shown at once, put back if the server turns it down. */
    suspend fun setPriority(timeslotIds: List<String>): ApiError? {
        val previous = weeks.flatMap { it.timeslots }.associate { it.id to it.priority }
        val ranks = timeslotIds.withIndex().associate { (index, id) -> id to index + 1 }
        applyPriority { ranks[it] }
        return try {
            api.setDibsPriority(timeslotIds)
            null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            applyPriority { previous[it] }
            e.asApiError()
        }
    }

    private fun applyPriority(rank: (String) -> Int?) {
        weeks = weeks.map { week -> week.copy(timeslots = week.timeslots.map { it.copy(priority = rank(it.id)) }) }
    }

    /** Leaves every line — dibs was turned off. A server with dibs off has nothing to leave. */
    suspend fun dropAllDibs(): ApiError? {
        try {
            api.dropAllDibs()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            val error = e.asApiError()
            if (error.code != "PUSH_DISABLED") return error
        }
        refresh()
        return null
    }

    suspend fun sendFeedback(message: String, context: Map<String, String>) {
        api.sendFeedback(message, context)
    }

    private fun combine(a: OverallStatus?, b: OverallStatus): OverallStatus = when {
        a == null -> b
        a == OverallStatus.Failed && b == OverallStatus.Failed -> OverallStatus.Failed
        a == OverallStatus.Success && b == OverallStatus.Success -> OverallStatus.Success
        else -> OverallStatus.PartialSuccess
    }

    // endregion
}

fun Throwable.asApiError(): ApiError = this as? ApiError ?: ApiError.local("UNKNOWN_ERROR", message.orEmpty())
