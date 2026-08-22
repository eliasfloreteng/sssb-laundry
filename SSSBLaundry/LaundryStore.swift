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

struct ActionOutcome: Identifiable {
    let id = UUID()
    let timeslot: String
    let overallStatus: OverallStatus
    let results: [ActionResult]

    /// A group was newly booked (as opposed to cancelled or already held).
    var didBook: Bool {
        results.contains { $0.status == "booked" }
    }
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

    var timeslotsByDay: [(date: String, slots: [Timeslot])] {
        var grouped: [String: [Timeslot]] = [:]
        for week in weeks {
            for timeslot in week.timeslots where timeslot.localDate >= today {
                grouped[timeslot.localDate, default: []].append(timeslot)
            }
        }
        return grouped.keys.sorted().map { date in
            (date, grouped[date]!.sorted { $0.startAt < $1.startAt })
        }
    }

    /// Every loaded timeslot the user has booked, flattened for notification
    /// scheduling. Hidden groups are deliberately included: hiding is a display
    /// filter, and a booking is still a booking the user must show up for.
    var bookingReminders: [BookingReminder] {
        let groups = groupsById
        var seen: Set<String> = []
        var reminders: [BookingReminder] = []
        for week in weeks {
            for timeslot in week.timeslots {
                let ownIds = timeslot.groups.filter { $0.status == .own }.map(\.groupId).sorted()
                guard !ownIds.isEmpty, let start = Self.parseISO8601(timeslot.startAt) else { continue }
                let id = "\(Int(start.timeIntervalSince1970))-" + ownIds.map(String.init).joined(separator: "_")
                guard seen.insert(id).inserted else { continue }
                reminders.append(
                    BookingReminder(
                        id: id,
                        start: start,
                        dayLabel: Self.dayLabel(for: timeslot.localDate),
                        startTime: timeslot.startTime,
                        endTime: timeslot.endTime,
                        machines: ownIds.map { groups[$0]?.name ?? "Group \($0)" }
                    )
                )
            }
        }
        return reminders
    }

    /// End of the last week that has been paged in; bookings beyond it keep the
    /// reminders they already have.
    private var remindersCoveredThrough: Date? {
        guard let last = weeks.last, let next = addDays(to: last.week.toDate, days: 1) else { return nil }
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Europe/Stockholm")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: next)
    }

    func syncNotifications() async {
        await NotificationService.sync(reminders: bookingReminders, coveredThrough: remindersCoveredThrough)
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

    func bookAndCancel(timeslotId: String, toBook: [Int], toCancel: [Int]) async {
        var results: [ActionResult] = []
        var overall: OverallStatus = .success
        var fatalError: APIError?

        if !toBook.isEmpty {
            do {
                let resp = try await api.book(timeslotId: timeslotId, groupIds: toBook)
                results.append(contentsOf: resp.results)
                overall = combine(overall, resp.overallStatus)
            } catch let err as APIError {
                fatalError = err
            } catch {
                if Self.isCancellation(error) { return }
                fatalError = APIError.local(code: "UNKNOWN_ERROR", message: error.localizedDescription)
            }
        }
        if fatalError == nil, !toCancel.isEmpty {
            do {
                let resp = try await api.cancel(timeslotId: timeslotId, groupIds: toCancel)
                results.append(contentsOf: resp.results)
                overall = combine(overall, resp.overallStatus)
            } catch let err as APIError {
                fatalError = err
            } catch {
                if Self.isCancellation(error) { return }
                fatalError = APIError.local(code: "UNKNOWN_ERROR", message: error.localizedDescription)
            }
        }

        if let err = fatalError {
            handleError(err)
            return
        }

        lastOutcome = ActionOutcome(timeslot: timeslotId, overallStatus: overall, results: results)
        await refreshWeekContaining(timeslotId: timeslotId)
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
            await syncNotifications()
        } catch let err as APIError {
            handleError(err)
        } catch {
            if Self.isCancellation(error) { return }
            handleError(APIError.local(code: "UNKNOWN_ERROR", message: error.localizedDescription))
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

    private func combine(_ a: OverallStatus, _ b: OverallStatus) -> OverallStatus {
        switch (a, b) {
        case (.failed, .failed): return .failed
        case (.success, .success): return .success
        default: return .partial_success
        }
    }

    static func todayInStockholm() -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Europe/Stockholm")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    /// `startAt`/`endAt` may or may not carry fractional seconds, so retry without them.
    static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func dayLabel(for localDate: String) -> String {
        let parser = DateFormatter()
        parser.timeZone = TimeZone(identifier: "Europe/Stockholm")
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: localDate) else { return localDate }
        let printer = DateFormatter()
        printer.timeZone = TimeZone(identifier: "Europe/Stockholm")
        printer.dateFormat = "EEE d MMM"
        return printer.string(from: date)
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
