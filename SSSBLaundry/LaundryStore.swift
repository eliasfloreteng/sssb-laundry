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
}

@Observable
final class LaundryStore {
    var week: WeekResponse?
    var loadState: LoadState = .idle
    var lastOutcome: ActionOutcome?
    var authFailed = false

    private let api: APIClient
    private var cursorDate: String

    init() {
        self.api = APIClient(objectIdProvider: { ObjectIdStore.get() })
        self.cursorDate = Self.todayInStockholm()
    }

    var groupsById: [Int: LaundryGroup] {
        guard let groups = week?.groups else { return [:] }
        return Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
    }

    var weekLabel: String {
        guard let week = week?.week else { return " " }
        return "\(formatHumanDate(week.fromDate)) – \(formatHumanDate(week.toDate))"
    }

    var timeslotsByDay: [(date: String, slots: [Timeslot])] {
        guard let timeslots = week?.timeslots else { return [] }
        let grouped = Dictionary(grouping: timeslots, by: { $0.localDate })
        return grouped.keys.sorted().map { date in
            (date, grouped[date]!.sorted { $0.startAt < $1.startAt })
        }
    }

    func loadInitial() async {
        await load(date: cursorDate)
    }

    func refresh() async {
        await load(date: cursorDate)
    }

    func nextWeek() async {
        guard let to = week?.week.toDate, let next = addDays(to: to, days: 1) else { return }
        cursorDate = next
        await load(date: cursorDate)
    }

    func prevWeek() async {
        guard let from = week?.week.fromDate, let prev = addDays(to: from, days: -1) else { return }
        cursorDate = prev
        await load(date: cursorDate)
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
                fatalError = APIError.local(code: "UNKNOWN_ERROR", message: error.localizedDescription)
            }
        }

        if let err = fatalError {
            handleError(err)
            return
        }

        lastOutcome = ActionOutcome(timeslot: timeslotId, overallStatus: overall, results: results)
        await refresh()
    }

    private func load(date: String) async {
        loadState = .loading
        do {
            let resp = try await api.getWeek(date: date)
            self.week = resp
            self.cursorDate = resp.week.fromDate
            self.loadState = .loaded
        } catch let err as APIError {
            handleError(err)
        } catch {
            handleError(APIError.local(code: "UNKNOWN_ERROR", message: error.localizedDescription))
        }
    }

    private func handleError(_ err: APIError) {
        loadState = .error(err)
        if err.code == "AUTH_FAILED" || err.code == "MISSING_OBJECT_ID" {
            authFailed = true
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

    private func formatHumanDate(_ dateString: String) -> String {
        let parser = DateFormatter()
        parser.timeZone = TimeZone(identifier: "Europe/Stockholm")
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: dateString) else { return dateString }
        let printer = DateFormatter()
        printer.timeZone = TimeZone(identifier: "Europe/Stockholm")
        printer.dateFormat = "d MMM"
        return printer.string(from: date)
    }
}
