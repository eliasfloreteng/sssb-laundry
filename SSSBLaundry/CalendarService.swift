//
//  CalendarService.swift
//  SSSBLaundry
//

import EventKit
import Foundation

enum CalendarServiceError: LocalizedError {
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Calendar access was denied. Enable it for SSSB Laundry in Settings to add bookings."
        }
    }
}

struct PreparedEvent {
    let store: EKEventStore
    let event: EKEvent
}

enum CalendarService {
    static func prepareEvent(for timeslot: Timeslot, machineNames: [String]) async throws -> PreparedEvent {
        let store = EKEventStore()
        let granted = try await store.requestWriteOnlyAccessToEvents()
        guard granted else { throw CalendarServiceError.accessDenied }

        let event = EKEvent(eventStore: store)
        event.calendar = store.defaultCalendarForNewEvents
        event.title = eventTitle(machineNames: machineNames)
        event.startDate = parseISO8601(timeslot.startAt) ?? Date()
        event.endDate = parseISO8601(timeslot.endAt) ?? event.startDate.addingTimeInterval(3 * 3600)
        event.addAlarm(EKAlarm(relativeOffset: 0))
        return PreparedEvent(store: store, event: event)
    }

    private static func eventTitle(machineNames: [String]) -> String {
        if machineNames.isEmpty { return "Tvätt" }
        return "Tvätt \(machineNames.joined(separator: ", "))"
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
