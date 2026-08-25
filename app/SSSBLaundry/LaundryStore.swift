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

    private let api: APIClient
    private let today: String

    init() {
        self.api = APIClient(objectIdProvider: { ObjectIdStore.get() })
        self.today = Self.todayInStockholm()
    }

    var groupsById: [Int: LaundryGroup] {
        var map: [Int: LaundryGroup] = [:]
        for week in weeks {
            for group in week.groups where map[group.id] == nil {
                map[group.id] = group
            }
        }
        return map
    }

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

    /// Bookings the user still holds, one per group, across every loaded week.
    /// Hidden groups count: hiding is a display filter, and the booking is still
    /// real upstream.
    var heldBookings: [HeldBooking] {
        let now = Date()
        var seen: Set<String> = []
        var held: [HeldBooking] = []
        for week in weeks {
            for timeslot in week.timeslots {
                guard let start = Self.parseISO8601(timeslot.startAt) else { continue }
                let releasesAt = start.addingTimeInterval(TimeInterval(Self.activationGraceMinutes * 60))
                guard releasesAt > now else { continue }
                for group in timeslot.groups where group.status == .own {
                    let id = "\(timeslot.id)#\(group.groupId)"
                    guard seen.insert(id).inserted else { continue }
                    held.append(
                        HeldBooking(
                            id: id,
                            timeslotId: timeslot.id,
                            groupId: group.groupId,
                            start: start,
                            startTime: timeslot.startTime,
                            endTime: timeslot.endTime
                        )
                    )
                }
            }
        }
        return held.sorted { $0.start < $1.start }
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
                machines: ids.map { groups[$0]?.name ?? "Group \($0)" }.joined(separator: ", "),
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
            for timeslot in week.timeslots where Self.belongsInList(timeslot, today: today, now: now) {
                grouped[timeslot.localDate, default: []].append(timeslot)
            }
        }
        return grouped.keys.sorted().map { date in
            (date, grouped[date]!.sorted { $0.startAt < $1.startAt })
        }
    }

    /// Today onwards — plus a booking from yesterday that is still running. A
    /// slot that crosses midnight belongs to the day it started on, so cutting
    /// the list at today would take a session off the screen at midnight with
    /// the machines still going.
    private static func belongsInList(_ timeslot: Timeslot, today: String, now: Date) -> Bool {
        if timeslot.localDate >= today { return true }
        guard timeslot.groups.contains(where: { $0.status == .own }),
              let end = parseISO8601(timeslot.endAt) else { return false }
        return end > now
    }

    func loadInitial() async {
        guard weeks.isEmpty else { return }
        loadState = .loading
        await fetchWeek(date: today, replaceAll: true)
    }

    func refresh() async {
        if weeks.isEmpty {
            loadState = .loading
        }
        reachedEnd = false
        await fetchWeek(date: today, replaceAll: true)
    }

    func loadMoreIfNeeded() async {
        guard !isLoadingMore, !reachedEnd, let last = weeks.last else { return }
        guard let next = addDays(to: last.week.toDate, days: 1) else { return }
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
        }
        return outcome
    }

    private func fetchWeek(date: String, replaceAll: Bool) async {
        do {
            let resp = try await api.getWeek(date: date)
            if replaceAll {
                weeks = [resp]
            } else if let existingIndex = weeks.firstIndex(where: { $0.week.fromDate == resp.week.fromDate }) {
                weeks[existingIndex] = resp
            } else {
                weeks.append(resp)
                if resp.timeslots.isEmpty {
                    reachedEnd = true
                }
            }
            loadState = .loaded
            await syncLiveActivity()
        } catch {
            if Self.isCancellation(error) { return }
            handleError(Self.apiError(from: error))
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

    static func todayInStockholm() -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Europe/Stockholm")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
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

    private func addDays(to dateString: String, days: Int) -> String? {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Europe/Stockholm")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = formatter.date(from: dateString) else { return nil }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        guard let new = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return formatter.string(from: new)
    }
}
