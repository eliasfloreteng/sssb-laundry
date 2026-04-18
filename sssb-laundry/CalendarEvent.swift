//
//  CalendarEvent.swift
//  sssb-laundry
//

import Foundation

enum CalendarEvent {
    static func icsFile(for booking: Booking) -> URL? {
        guard let start = booking.slot?.startsAt, let end = booking.slot?.endsAt else { return nil }
        let title = booking.group.map { "Laundry – \($0.name)" } ?? "Laundry booking"
        return icsFile(title: title, start: start, end: end, uid: "sssb-booking-\(booking.id)@sssb-laundry")
    }

    static func icsFile(for slot: Slot) -> URL? {
        let names = slot.groups.map(\.name).joined(separator: ", ")
        let title = names.isEmpty ? "Laundry booking" : "Laundry – \(names)"
        return icsFile(title: title, start: slot.startsAt, end: slot.endsAt, uid: "sssb-slot-\(slot.id)@sssb-laundry")
    }

    private static func icsFile(title: String, start: Date, end: Date, uid: String) -> URL? {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        let dtStamp = f.string(from: Date())
        let dtStart = f.string(from: start)
        let dtEnd = f.string(from: end)

        let content = """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//sssb-laundry//EN
        CALSCALE:GREGORIAN
        METHOD:PUBLISH
        BEGIN:VEVENT
        UID:\(uid)
        DTSTAMP:\(dtStamp)
        DTSTART:\(dtStart)
        DTEND:\(dtEnd)
        SUMMARY:\(escape(title))
        BEGIN:VALARM
        ACTION:DISPLAY
        DESCRIPTION:\(escape(title))
        TRIGGER:-PT30M
        END:VALARM
        END:VEVENT
        END:VCALENDAR
        """
        .replacingOccurrences(of: "\n", with: "\r\n")

        let fileName = "laundry-\(uid.prefix(32)).ics".replacingOccurrences(of: "@", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try content.data(using: .utf8)?.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
