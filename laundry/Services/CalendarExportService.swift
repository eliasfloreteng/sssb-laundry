import EventKit
import Foundation

enum CalendarExportService {

    /// Adds a laundry booking to the device calendar.
    /// Returns a user-facing message describing the result.
    @discardableResult
    static func addToCalendar(date: Date?, time: String, groupName: String?) async -> String {
        guard let date else { return "Could not determine booking date." }
        guard let (start, end) = startAndEndDates(from: date, time: time) else {
            return "Could not parse booking time."
        }

        let store = EKEventStore()

        do {
            try await store.requestWriteOnlyAccessToEvents()
        } catch {
            return "Calendar access denied. Enable it in Settings."
        }

        let event = EKEvent(eventStore: store)
        event.title = "Laundry – \(groupName ?? "SSSB")"
        event.startDate = start
        event.endDate = end
        event.location = "SSSB Laundry Room"
        event.calendar = store.defaultCalendarForNewEvents

        // Add a 5-minute reminder
        event.addAlarm(EKAlarm(relativeOffset: -5 * 60))

        do {
            try store.save(event, span: .thisEvent)
            return "Added to calendar."
        } catch {
            return "Failed to save event: \(error.localizedDescription)"
        }
    }

    // MARK: - Private

    /// Parses "HH:MM - HH:MM" into start and end `Date` on the given day.
    private static func startAndEndDates(from date: Date, time: String) -> (start: Date, end: Date)? {
        let parts = time.components(separatedBy: " - ")
        guard parts.count == 2 else { return nil }

        func makeDate(_ hhmm: String) -> Date? {
            let comps = hhmm.trimmingCharacters(in: .whitespaces).split(separator: ":")
            guard comps.count == 2,
                  let hour = Int(comps[0]),
                  let minute = Int(comps[1]) else { return nil }
            var dc = Calendar.current.dateComponents([.year, .month, .day], from: date)
            dc.hour = hour
            dc.minute = minute
            return Calendar.current.date(from: dc)
        }

        guard let start = makeDate(parts[0]),
              let end = makeDate(parts[1]) else { return nil }
        return (start, end)
    }
}
