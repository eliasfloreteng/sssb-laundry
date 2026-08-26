//
//  LaundryStore.swift
//  SSSBLaundry
//

import Foundation
import Observation

enum LoadState {
    case idle
    case loading
    case loaded
    case error(APIError)
}

/// One group's answer, tagged with what was asked of it so failures can be
/// explained in the right words.
struct GroupOutcome: Identifiable {
    let result: ActionResult
    let action: BookingAction

    var id: Int { result.groupId }
    var groupId: Int { result.groupId }
    var isSuccessful: Bool { result.isSuccessful }
}

struct ActionOutcome: Identifiable {
    let id = UUID()
    let timeslot: String
    let overallStatus: OverallStatus
    let results: [GroupOutcome]
    /// Set when the request never got as far as a per-group answer
    /// (offline, auth rejected, timeslot gone).
    let requestError: APIError?

    var failures: [GroupOutcome] {
        results.filter { !$0.isSuccessful }
    }

    var isFullSuccess: Bool {
        requestError == nil && failures.isEmpty && overallStatus != .failed
    }

    /// A group was newly booked (as opposed to cancelled or already held).
    var didBook: Bool {
        results.contains { $0.result.status == "booked" }
    }
}

/// A timeslot the user currently holds, one entry per group. Drives the
/// "2 bookings at a time" limit; reminders are scheduled by the server.
struct HeldBooking: Identifiable, Hashable {
    let id: String
    let timeslotId: String
    let groupId: Int
    let start: Date
    let startTime: String
    let endTime: String
}

/// A held timeslot with every group it covers folded into one entry. This is
/// the unit SSSB counts as a laundry session — one per booked time, however
/// many groups it covers — and it is what the Live Activity counts down.
/// `HeldBooking` stays one row per group, because that is what gets booked and
/// cancelled upstream.
struct BookedSlot: Identifiable, Hashable {
    let id: String
    let start: Date
    let startTime: String
    let endTime: String
    /// Aptus group names, already joined for display.
    let machines: String
    /// Empty unless every group in the slot shares one laundry room.
    let location: String

    /// When Aptus releases the session again if it has not been activated.
    var deadline: Date { start.addingTimeInterval(laundryGracePeriod) }
}

@Observable
final class LaundryStore {
    var weeks: [WeekResponse] = []
    var loadState: LoadState = .idle
    var isLoadingMore = false
    var reachedEnd = false
    var lastOutcome: ActionOutcome?
    var lastError: APIError?
    var authFailed = false

    /// The first day the list shows. Today until the user jumps somewhere else,
    /// and back to today when they jump home.
    private(set) var anchorDate: String
    /// A jump is a whole new list, so it gets its own flag rather than borrowing
    /// `isLoadingMore` (which the footer spinner is bound to).
    var isJumping = false

    private let api: APIClient
    let today: String

    /// Group metadata, accumulated. The same groups come back with every week,
    /// and a jump that lands past the end of the availability window brings back
    /// none at all — names for already-held bookings must not disappear with it.
    private var knownGroups: [Int: LaundryGroup] = [:]

    /// Every booking the user holds, keyed by the week it arrived in. A week
    /// response is the authority on its own dates, so refetching one replaces
    /// its entry and a cancelled booking drops out. Kept apart from `weeks`,
    /// which a jump throws away: the session limit and the Live Activity have to
    /// keep counting bookings the browsing list no longer shows.
    private var ownBookingsByWeek: [String: [HeldBooking]] = [:]

    /// Bumped whenever the list is re-anchored, so a page request that was
    /// already in flight cannot append its week to the list that replaced it.
    private var generation = 0

    /// How many weeks in a row have come back with nothing to act on. Aptus
    /// keeps rendering its weekly grid long past the last date it will actually
    /// book, so the end of the list does not look like an empty response — it
    /// looks like a full week of slots with no book button on any of them.
    private var barrenWeeks = 0

    /// Whether any week since the anchor has carried something to act on. Until
    /// one has, a barren week proves nothing: late on a Sunday every slot left
    /// in the current week has already started, and the list must still page
    /// into next week. Once a good week has been seen, the next barren one is
    /// the horizon — the alternative reading, a whole week every slot of which
    /// somebody else took while later weeks stayed free, does not happen.
    private var sawUsableWeek = false

    init() {
        self.api = APIClient(objectIdProvider: { ObjectIdStore.get() })
        let today = Self.todayInStockholm()
        self.today = today
        self.anchorDate = today
    }

    /// Whether the list is still the one that starts at today.
    var isViewingToday: Bool { anchorDate == today }

    /// Why the list has nothing to show, so the empty state can say which
    /// rather than giving one answer to three different questions.
    enum EmptyReason {
        /// A day past the end of what Aptus is prepared to book. The everyday
        /// case: SSSB opens the schedule a fixed distance ahead, and a jump can
        /// land beyond it. Two barren weeks running is the evidence — every slot
        /// on them free of any book button — and on a list the user went looking
        /// for, the horizon is the cause. "Every slot taken for a fortnight" is
        /// the alternative reading, and it does not happen.
        case beyondBookingWindow
        /// The schedule is there and today is on it, but there is nothing left
        /// to take: each timeslot is either someone else's or already running.
        case nothingFree
        /// No schedule at all for this object number.
        case noTimeslots
    }

    var emptyReason: EmptyReason {
        if !isViewingToday { return .beyondBookingWindow }
        return weeks.contains { !$0.timeslots.isEmpty } ? .nothingFree : .noTimeslots
    }

    var groupsById: [Int: LaundryGroup] { knownGroups }

    var allGroups: [LaundryGroup] {
        groupsById.values.sorted { $0.id < $1.id }
    }

    /// Aptus accepts at most two groups in one booking action. This is the
    /// portal's own hard limit and applies everywhere, unlike the per-room
    /// quota in `LaundryRooms`.
    static let maxGroupsPerBooking = 2

    /// Aptus releases a booking that was not activated within 15 minutes of its
    /// start, so a missed timeslot stops occupying the quota at start + 15 —
    /// not at the end of the slot. The portal gives no way to tell an activated
    /// booking from an auto-cancelled one once that window has passed, so the
    /// count errs towards freeing the quota: over-counting used to leave the
    /// user unable to book anything until the missed slot finally ended.
    static let activationGraceMinutes = Int(laundryGracePeriod / 60)

    /// Bookings the user still holds, one per group, across every week that has
    /// been loaded — including weeks a jump has since dropped from the list.
    /// Hidden groups count: hiding is a display filter, and the booking is still
    /// real upstream.
    var heldBookings: [HeldBooking] {
        let now = Date()
        var seen: Set<String> = []
        var held: [HeldBooking] = []
        for bookings in ownBookingsByWeek.values {
            for booking in bookings {
                let releasesAt = booking.start.addingTimeInterval(TimeInterval(Self.activationGraceMinutes * 60))
                guard releasesAt > now, seen.insert(booking.id).inserted else { continue }
                held.append(booking)
            }
        }
        return held.sorted { $0.start < $1.start }
    }

    private static func isEnded(barrenWeeks: Int, sawUsableWeek: Bool) -> Bool {
        barrenWeeks >= (sawUsableWeek ? 1 : 2)
    }

    /// Nothing in this week the user could act on: no slot they hold, and none
    /// still to come that Aptus offers a book button for. Deliberately blind to
    /// the hidden-groups setting — that is a display filter, and where the list
    /// ends is not a matter of what the user chose to look at.
    private static func isBarren(_ week: WeekResponse, now: Date) -> Bool {
        !week.timeslots.contains { timeslot in
            timeslot.groups.contains { group in
                group.status == .own || (group.canBook && !timeslot.hasStarted(asOf: now))
            }
        }
    }

    private static func ownBookings(in week: WeekResponse) -> [HeldBooking] {
        var bookings: [HeldBooking] = []
        for timeslot in week.timeslots {
            guard let start = parseISO8601(timeslot.startAt) else { continue }
            for group in timeslot.groups where group.status == .own {
                bookings.append(
                    HeldBooking(
                        id: "\(timeslot.id)#\(group.groupId)",
                        timeslotId: timeslot.id,
                        groupId: group.groupId,
                        start: start,
                        startTime: timeslot.startTime,
                        endTime: timeslot.endTime
                    )
                )
            }
        }
        return bookings
    }

    func heldBookings(excludingTimeslot timeslotId: String) -> [HeldBooking] {
        heldBookings.filter { $0.timeslotId != timeslotId }
    }

    /// The sessions SSSB counts against "max future bookings": one per booked
    /// timeslot, and only the ones that have not started yet. A session already
    /// under way is no longer a future booking — once the current slot starts,
    /// the next one can be booked again even though the machines are still
    /// running. Groups within a slot do not count separately.
    var futureSessions: [BookedSlot] {
        let now = Date()
        return bookedSlots.filter { $0.start > now }
    }

    /// `futureSessions` without the slot a sheet is currently editing, so the
    /// sheet can add its own pending outcome back in. Matched on the start
    /// instant, which is what `BookedSlot` is keyed by.
    func futureSessions(excludingTimeslot timeslotId: String) -> [BookedSlot] {
        let excluded = Set(heldBookings.filter { $0.timeslotId == timeslotId }.map(\.start))
        return futureSessions.filter { !excluded.contains($0.start) }
    }

    /// The held bookings collapsed to one entry per timeslot. Already limited to
    /// slots that haven't been released yet, since `heldBookings` drops those.
    var bookedSlots: [BookedSlot] {
        let groups = groupsById
        var byTimeslot: [String: [HeldBooking]] = [:]
        for booking in heldBookings {
            byTimeslot[booking.timeslotId, default: []].append(booking)
        }
        return byTimeslot.values.compactMap { entries -> BookedSlot? in
            guard let first = entries.first else { return nil }
            let ids = entries.map(\.groupId).sorted()
            let locations = Set(ids.compactMap { groups[$0]?.location }.filter { !$0.isEmpty })
            return BookedSlot(
                // Derived from the start and the groups rather than the opaque
                // timeslotId, which must not outlive a server change.
                id: "\(Int(first.start.timeIntervalSince1970))-" + ids.map(String.init).joined(separator: "_"),
                start: first.start,
                startTime: first.startTime,
                endTime: first.endTime,
                machines: ids.map { LaundryFormat.groupName($0, in: groups) }.joined(separator: ", "),
                location: locations.count == 1 ? locations.first! : ""
            )
        }
        .sorted { $0.start < $1.start }
    }

    func syncLiveActivity() async {
        await LiveActivityService.sync(slots: bookedSlots)
    }

    /// The freshest copy of a timeslot, so a sheet that stays open after a
    /// failure shows the state the refresh brought back rather than the copy it
    /// was opened with.
    func timeslot(id: String) -> Timeslot? {
        for week in weeks {
            if let match = week.timeslots.first(where: { $0.id == id }) { return match }
        }
        return nil
    }

    var timeslotsByDay: [(date: String, slots: [Timeslot])] {
        let now = Date()
        var grouped: [String: [Timeslot]] = [:]
        for week in weeks {
            for timeslot in week.timeslots where Self.belongsInList(timeslot, from: anchorDate, today: today, now: now) {
                grouped[timeslot.localDate, default: []].append(timeslot)
            }
        }
        return grouped.keys.sorted().map { date in
            (date, grouped[date]!.sorted { $0.startAt < $1.startAt })
        }
    }

    /// The anchor day onwards — plus, on the list that starts at today, a
    /// booking from yesterday that is still running. A slot that crosses
    /// midnight belongs to the day it started on, so cutting the list at today
    /// would take a session off the screen at midnight with the machines still
    /// going. A list the user jumped ahead to is a different question: last
    /// night's wash has no business at the top of it.
    private static func belongsInList(_ timeslot: Timeslot, from anchor: String, today: String, now: Date) -> Bool {
        if timeslot.localDate >= anchor { return true }
        guard anchor == today else { return false }
        guard timeslot.groups.contains(where: { $0.status == .own }),
              let end = parseISO8601(timeslot.endAt) else { return false }
        return end > now
    }

    func loadInitial() async {
        guard weeks.isEmpty else { return }
        loadState = .loading
        await reanchor(to: anchorDate)
    }

    func refresh() async {
        if weeks.isEmpty {
            loadState = .loading
        }
        // Stays where the user left it: a pull is easy to trigger by accident
        // while browsing a week they went looking for.
        await reanchor(to: anchorDate)
    }

    /// Starts the list again at `date`, throwing away the pages either side of
    /// it. Bookings already seen survive in `ownBookingsByWeek`.
    func jump(to date: String) async {
        guard !isJumping else { return }
        isJumping = true
        defer { isJumping = false }
        // The anchor moves only once the week behind it is on screen, so a
        // failed jump leaves the list the user was reading intact.
        if await reanchor(to: date) {
            anchorDate = date
        }
    }

    func jumpToToday() async {
        await jump(to: today)
    }

    @discardableResult
    private func reanchor(to date: String) async -> Bool {
        generation &+= 1
        return await fetchWeek(date: date, replaceAll: true)
    }

    func loadMoreIfNeeded() async {
        guard !isLoadingMore, !isJumping, !reachedEnd, let last = weeks.last else { return }
        guard let next = Self.addDays(to: last.week.toDate, days: 1) else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await fetchWeek(date: next, replaceAll: false)
    }

    /// Returns what actually happened so the caller can show it. `nil` means the
    /// task was cancelled (view teardown), which is not something to report.
    @discardableResult
    func bookAndCancel(timeslotId: String, toBook: [Int], toCancel: [Int]) async -> ActionOutcome? {
        var results: [GroupOutcome] = []
        var overall: OverallStatus?
        var requestError: APIError?

        // Read before the action, because a cancelled slot is gone from the week
        // that comes back after it. The server retracts its own notifications on
        // every device, but the phone doing the cancelling should not have to
        // wait for that round trip to see its reminder go.
        let cancelledStart = toCancel.isEmpty
            ? nil
            : timeslot(id: timeslotId).flatMap { Self.parseISO8601($0.startAt) }

        // Cancels run first: with only two bookings allowed at a time, swapping
        // machines in one submit can only succeed if the old one is released
        // before the new one is asked for.
        if !toCancel.isEmpty {
            do {
                let resp = try await api.cancel(timeslotId: timeslotId, groupIds: toCancel)
                results.append(contentsOf: resp.results.map { GroupOutcome(result: $0, action: .cancel) })
                overall = combine(overall, resp.overallStatus)
            } catch {
                if Self.isCancellation(error) { return nil }
                requestError = Self.apiError(from: error)
            }
        }
        if requestError == nil, !toBook.isEmpty {
            do {
                let resp = try await api.book(timeslotId: timeslotId, groupIds: toBook)
                results.append(contentsOf: resp.results.map { GroupOutcome(result: $0, action: .book) })
                overall = combine(overall, resp.overallStatus)
            } catch {
                if Self.isCancellation(error) { return nil }
                requestError = Self.apiError(from: error)
            }
        }

        let outcome = ActionOutcome(
            timeslot: timeslotId,
            overallStatus: requestError == nil ? (overall ?? .success) : .failed,
            results: results,
            requestError: requestError
        )
        lastOutcome = outcome

        if let requestError {
            // Auth failures still have to bounce the user back to sign-in; every
            // other reason is reported where the user asked for the action.
            if requestError.code == "AUTH_FAILED" || requestError.code == "MISSING_OBJECT_ID" {
                authFailed = true
            }
        } else {
            await refreshWeekContaining(timeslotId: timeslotId)
            // Only once nothing is held there any more: cancelling one group of
            // a two-group slot leaves a booking the reminder still describes.
            if let cancelledStart, !heldBookings.contains(where: { $0.timeslotId == timeslotId }) {
                await PushService.removeDelivered(forBookingStartingAt: cancelledStart)
            }
        }
        return outcome
    }

    /// Returns whether the week landed. A cancelled request counts as a
    /// non-answer: it leaves the list exactly as it was.
    @discardableResult
    private func fetchWeek(date: String, replaceAll: Bool) async -> Bool {
        let token = generation
        do {
            let resp = try await api.getWeek(date: date)
            // The list was re-anchored while this was in flight, so it is a page
            // of a list that no longer exists.
            guard token == generation else { return false }

            for group in resp.groups where knownGroups[group.id] == nil {
                knownGroups[group.id] = group
            }
            ownBookingsByWeek[resp.week.fromDate] = Self.ownBookings(in: resp)

            let barren = Self.isBarren(resp, now: Date())
            if replaceAll {
                weeks = [resp]
                barrenWeeks = barren ? 1 : 0
                sawUsableWeek = !barren
                reachedEnd = Self.isEnded(barrenWeeks: barrenWeeks, sawUsableWeek: sawUsableWeek)
            } else if let existingIndex = weeks.firstIndex(where: { $0.week.fromDate == resp.week.fromDate }) {
                // A week we already had, fetched again after a booking — it says
                // nothing about where the list ends.
                weeks[existingIndex] = resp
            } else {
                weeks.append(resp)
                barrenWeeks = barren ? barrenWeeks + 1 : 0
                sawUsableWeek = sawUsableWeek || !barren
                reachedEnd = Self.isEnded(barrenWeeks: barrenWeeks, sawUsableWeek: sawUsableWeek)
            }
            loadState = .loaded
            await syncLiveActivity()
            return true
        } catch {
            if Self.isCancellation(error) { return false }
            handleError(Self.apiError(from: error))
            return false
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private func refreshWeekContaining(timeslotId: String) async {
        guard let week = weeks.first(where: { $0.timeslots.contains { $0.id == timeslotId } }) else {
            await refresh()
            return
        }
        await fetchWeek(date: week.week.fromDate, replaceAll: false)
    }

    private func handleError(_ err: APIError) {
        loadState = .error(err)
        if err.code == "AUTH_FAILED" || err.code == "MISSING_OBJECT_ID" {
            authFailed = true
        } else if !weeks.isEmpty {
            lastError = err
        }
    }

    private func combine(_ a: OverallStatus?, _ b: OverallStatus) -> OverallStatus {
        guard let a else { return b }
        switch (a, b) {
        case (.failed, .failed): return .failed
        case (.success, .success): return .success
        default: return .partial_success
        }
    }

    private static func apiError(from error: Error) -> APIError {
        if let apiError = error as? APIError { return apiError }
        return APIError.local(code: "UNKNOWN_ERROR", message: error.localizedDescription)
    }

    static let stockholm = TimeZone(identifier: "Europe/Stockholm")!

    /// Every date the app deals in is a Stockholm calendar day, whatever the
    /// device's own timezone says.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = stockholm
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func todayInStockholm() -> String {
        dayFormatter.string(from: Date())
    }

    /// The Stockholm day a `Date` falls on — how a date picker's answer becomes
    /// something the API will accept.
    static func day(from date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// Midnight in Stockholm on that day.
    static func date(from day: String) -> Date? {
        dayFormatter.date(from: day)
    }

    // Formatters are expensive to build and these run over every loaded timeslot
    // on each render (the booking limit is derived from them), so keep one each.
    private static let fractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// `startAt`/`endAt` may or may not carry fractional seconds, so retry without them.
    static func parseISO8601(_ string: String) -> Date? {
        if let date = fractionalISOFormatter.date(from: string) { return date }
        return plainISOFormatter.date(from: string)
    }

    static func addDays(to dateString: String, days: Int) -> String? {
        guard let date = date(from: dateString) else { return nil }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = stockholm
        guard let new = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return day(from: new)
    }
}
