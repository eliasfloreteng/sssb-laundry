//
//  LaundryRooms.swift
//  SSSBLaundry
//

import Foundation

/// The rules SSSB publishes per laundry room, mirrored from the table on
/// <https://www.sssb.se/en/book-a-laundry-room/>. That page fills its dropdown
/// from `wp-content/themes/sssb_pilot2/js/laundry.js`, and `LaundryRooms.all`
/// below is that array transcribed — addresses and room names verbatim, SSSB's
/// own typos included, so a diff against the source stays readable.
///
/// The rules genuinely differ between rooms: max future bookings is 1 for most
/// addresses, 2 for the inner-city ones and unlimited on Kammakargatan, and the
/// weekly/monthly quota ranges from none to 2/week. Nothing here is enforced by
/// the app — Aptus decides — these numbers only let the app say what the rules
/// are instead of guessing.
struct LaundryRoom: Identifiable, Hashable {
    /// The resident's street address, as SSSB lists it in the dropdown.
    let address: String
    /// Where the laundry room serving that address actually is.
    let room: String
    /// How many future laundry sessions may be held at once. `nil` is "no maximum".
    let maxFutureBookings: Int?
    /// SSSB's "Time after booking", in minutes. Their label, their semantics.
    let minutesAfterBooking: Int
    /// SSSB's "Max booking per week/month". `nil` is "no maximum value".
    let quota: Quota?

    struct Quota: Hashable {
        let count: Int
        let period: Period
    }

    enum Period: String, Hashable {
        case week
        case month
    }

    /// Two rooms serve Kungshamra 11-46 och 51-76 under different rules, so the
    /// address alone does not identify a row.
    var id: String { "\(address)|\(room)" }

    var maxFutureBookingsLabel: String {
        maxFutureBookings.map(String.init) ?? "No maximum"
    }

    var quotaLabel: String {
        guard let quota else { return "No maximum" }
        return "\(quota.count) per \(quota.period.rawValue)"
    }

    var timeAfterBookingLabel: String {
        "\(minutesAfterBooking) min"
    }
}

enum LaundryRooms {
    /// Persisted selection, by `LaundryRoom.id`. Empty means "not set", which is
    /// deliberately unconstrained: the app shows no quota rather than assuming one.
    static let selectedIdKey = "laundryRoom.id"

    static func room(id: String) -> LaundryRoom? {
        guard !id.isEmpty else { return nil }
        return all.first { $0.id == id }
    }

    /// For code with no view to hang `@AppStorage` off. Views should read the
    /// stored id through `@AppStorage` and call `room(id:)`, or a changed
    /// selection will not redraw them.
    static var selected: LaundryRoom? {
        room(id: UserDefaults.standard.string(forKey: selectedIdKey) ?? "")
    }

    /// The number of future sessions the selected room allows, or `nil` when no
    /// room is set or the room has no maximum. Callers must treat `nil` as "do
    /// not limit and do not mention a limit".
    static var maxFutureBookings: Int? {
        selected?.maxFutureBookings
    }

    static let all: [LaundryRoom] = [
        .init(address: "Amanuensvägen 1", room: "Forskarbacken 5 + 5 B", maxFutureBookings: 1, minutesAfterBooking: 60, quota: .init(count: 4, period: .month)),
        .init(address: "Amanuensvägen 2", room: "Professorsslingan 15", maxFutureBookings: 1, minutesAfterBooking: 60, quota: .init(count: 4, period: .month)),
        .init(address: "Amanuensvägen 3", room: "Forskarbacken 10", maxFutureBookings: 1, minutesAfterBooking: 60, quota: .init(count: 4, period: .month)),
        .init(address: "Amanuensvägen 4", room: "Professorsslingan 15", maxFutureBookings: 1, minutesAfterBooking: 60, quota: .init(count: 4, period: .month)),
        .init(address: "Amanuensvägen 5", room: "Forskarbacken 10", maxFutureBookings: 1, minutesAfterBooking: 60, quota: .init(count: 4, period: .month)),
        .init(address: "Amanuensvägen 6", room: "Professorsslingan 15", maxFutureBookings: 1, minutesAfterBooking: 60, quota: .init(count: 4, period: .month)),
        .init(address: "Amanuensvägen 8-14", room: "Professorsslingan 15", maxFutureBookings: 1, minutesAfterBooking: 60, quota: .init(count: 4, period: .month)),
        .init(address: "Apelbergsgatan 54", room: "Apelsbergsgatan 54", maxFutureBookings: 2, minutesAfterBooking: 60, quota: nil),
        .init(address: "Armégatan 32 A + 34", room: "Armégatan 32 A", maxFutureBookings: 2, minutesAfterBooking: 60, quota: nil),
        .init(address: "Armégatan 32 B+C", room: "Armégatan 32 C", maxFutureBookings: 2, minutesAfterBooking: 60, quota: .init(count: 4, period: .month)),
        .init(address: "David Bagares Gata 6", room: "David Bagares Gata 6", maxFutureBookings: 2, minutesAfterBooking: 60, quota: nil),
        .init(address: "Drottninggatan 67", room: "Apelsbergsgatan 54", maxFutureBookings: 2, minutesAfterBooking: 60, quota: nil),
        .init(address: "Edinsvägen 22 A+B", room: "Edinsvägen 22 A", maxFutureBookings: 1, minutesAfterBooking: 60, quota: nil),
        .init(address: "Emmylundsvägen 1-3", room: "Emmylundsvägen 1", maxFutureBookings: 1, minutesAfterBooking: 60, quota: nil),
        .init(address: "Emmylundsvägen 5", room: "Emmylundsvägen 5", maxFutureBookings: 1, minutesAfterBooking: 70, quota: nil),
        .init(address: "Forskarbacken 10-12", room: "Forskarbacken 10", maxFutureBookings: 1, minutesAfterBooking: 60, quota: .init(count: 4, period: .month)),
        .init(address: "Forskarbacken 11", room: "Forskarbacken 6", maxFutureBookings: 1, minutesAfterBooking: 60, quota: .init(count: 4, period: .month)),
        .init(address: "Forskarbacken 13", room: "Forskarbacken 6", maxFutureBookings: 1, minutesAfterBooking: 60, quota: .init(count: 4, period: .month)),
        .init(address: "Forskarbacken 1-3", room: "Forskarbacken 5 + 5 B", maxFutureBookings: 1, minutesAfterBooking: 60, quota: .init(count: 4, period: .month)),
        .init(address: "Forskarbacken 15", room: "Forskarbacken 10, Professorsslingan 15", maxFutureBookings: 1, minutesAfterBooking: 60, quota: .init(count: 4, period: .month)),
        .init(address: "Forskarbacken 15-19", room: "Forskarbacken 10", maxFutureBookings: 1, minutesAfterBooking: 60, quota: .init(count: 4, period: .month)),
        .init(address: "Forskarbacken 21", room: "Professorsslingan 39", maxFutureBookings: 2, minutesAfterBooking: 60, quota: .init(count: 8, period: .month)),
        .init(address: "Forskarbacken 4", room: "Forskarbacken 6", maxFutureBookings: 1, minutesAfterBooking: 60, quota: .init(count: 4, period: .month)),
        .init(address: "Forskarbacken 5", room: "Forskarbacken 5 + 5 B", maxFutureBookings: 1, minutesAfterBooking: 60, quota: .init(count: 4, period: .month)),
        .init(address: "Forskarbacken 6", room: "Forskarbacken 6", maxFutureBookings: 1, minutesAfterBooking: 60, quota: .init(count: 4, period: .month)),
        .init(address: "Forskarbacken 7", room: "Forskarbacken 5 + 5 B", maxFutureBookings: 1, minutesAfterBooking: 60, quota: .init(count: 4, period: .month)),
        .init(address: "Forskarbacken 8-9", room: "Forskarbacken 6", maxFutureBookings: 1, minutesAfterBooking: 60, quota: .init(count: 4, period: .month)),
        .init(address: "Gustav III:s Boulevard 2", room: "Gustav III:s Boulevard 2", maxFutureBookings: 1, minutesAfterBooking: 60, quota: nil),
        .init(address: "Gustav III:s Boulevard 4", room: "Gustav III:s Boulevard 4", maxFutureBookings: 1, minutesAfterBooking: 60, quota: nil),
        .init(address: "Gärdesvägen 2-10", room: "Gärdesvägen 10", maxFutureBookings: 1, minutesAfterBooking: 60, quota: nil),
        .init(address: "Holländargatan 21 B", room: "Holländargatan 21B", maxFutureBookings: 2, minutesAfterBooking: 60, quota: nil),
        .init(address: "Kammakargatan 36 A", room: "Kammarmakargatan 36 A", maxFutureBookings: nil, minutesAfterBooking: 60, quota: nil),
        .init(address: "Kammakargatan 36 B", room: "Kammarmakargatan 36 B", maxFutureBookings: nil, minutesAfterBooking: 60, quota: nil),
        .init(address: "Kungshamra 11-46 och 51-76", room: "Kungshamra 1", maxFutureBookings: 1, minutesAfterBooking: 60, quota: .init(count: 2, period: .week)),
        .init(address: "Kungshamra 11-46 och 51-76", room: "Kungshamra 12 C", maxFutureBookings: 2, minutesAfterBooking: 60, quota: .init(count: 3, period: .week)),
        .init(address: "Kungshamra 2", room: "Kungshamra 2", maxFutureBookings: 1, minutesAfterBooking: 60, quota: nil),
        .init(address: "Kungshamra 3", room: "Kungshamra 3", maxFutureBookings: 1, minutesAfterBooking: 60, quota: nil),
        .init(address: "Kungshamra 47", room: "Kungshamra 47", maxFutureBookings: 1, minutesAfterBooking: 60, quota: nil),
        .init(address: "Kungshamra 48", room: "Kungshamra 48", maxFutureBookings: 1, minutesAfterBooking: 60, quota: nil),
        .init(address: "Kungshamra 81", room: "Kungshamra 81", maxFutureBookings: 1, minutesAfterBooking: 60, quota: nil),
        .init(address: "Kungshamra 82", room: "Kungshamra 82", maxFutureBookings: 1, minutesAfterBooking: 60, quota: nil),
        .init(address: "Kungshamra 83", room: "Kungshamra 83", maxFutureBookings: 1, minutesAfterBooking: 60, quota: nil),
        .init(address: "Körsbärsvägen 2-4", room: "Körsbärsvägen 4 B (K1)", maxFutureBookings: 2, minutesAfterBooking: 60, quota: .init(count: 4, period: .month)),
        .init(address: "Körsbärsvägen 3", room: "Körsbärsvägen 5", maxFutureBookings: 1, minutesAfterBooking: 60, quota: nil),
        .init(address: "Körsbärsvägen 5", room: "Körsbärsvägen 5", maxFutureBookings: 1, minutesAfterBooking: 60, quota: nil),
        .init(address: "Körsbärsvägen 9", room: "Körsbärsvägen 9", maxFutureBookings: 1, minutesAfterBooking: 60, quota: .init(count: 2, period: .week)),
        .init(address: "Löjtnantsgatan 11-15", room: "Löjtnantsgatan 13", maxFutureBookings: 1, minutesAfterBooking: 60, quota: nil),
        .init(address: "Maltgatan 12", room: "Maltgatan 12", maxFutureBookings: 1, minutesAfterBooking: 60, quota: nil),
        .init(address: "Maltgatan 4", room: "Maltgatan 4", maxFutureBookings: 1, minutesAfterBooking: 60, quota: nil),
        .init(address: "Maltgatan 8", room: "Maltgatan 8", maxFutureBookings: 1, minutesAfterBooking: 60, quota: nil),
        .init(address: "Nathorsvägen 46", room: "Nathorsvägen 46", maxFutureBookings: 1, minutesAfterBooking: 60, quota: nil),
        .init(address: "Norra Stationsgatan 97-109", room: "Norra Stationsgatan 99", maxFutureBookings: 2, minutesAfterBooking: 60, quota: nil),
        .init(address: "Professorsslingan 9", room: "Professorsslingan 15", maxFutureBookings: 1, minutesAfterBooking: 60, quota: .init(count: 4, period: .month)),
        .init(address: "Professorsslingan 10", room: "Professorsslingan 10", maxFutureBookings: 2, minutesAfterBooking: 60, quota: .init(count: 8, period: .month)),
        .init(address: "Professorsslingan 11", room: "Professorsslingan 15", maxFutureBookings: 1, minutesAfterBooking: 60, quota: .init(count: 4, period: .month)),
        .init(address: "Professorsslingan 13", room: "Professorsslingan 15", maxFutureBookings: 1, minutesAfterBooking: 60, quota: .init(count: 4, period: .month)),
        .init(address: "Professorsslingan 15-19", room: "Professorsslingan 15", maxFutureBookings: 1, minutesAfterBooking: 60, quota: .init(count: 4, period: .month)),
        .init(address: "Professorsslingan 21", room: "Professorsslingan 39", maxFutureBookings: 2, minutesAfterBooking: 60, quota: .init(count: 8, period: .month)),
        .init(address: "Professorsslingan 23-25", room: "Professorsslingan 15", maxFutureBookings: 1, minutesAfterBooking: 60, quota: .init(count: 4, period: .month)),
        .init(address: "Professorsslingan 31-45", room: "Professorsslingan 39", maxFutureBookings: 2, minutesAfterBooking: 60, quota: .init(count: 8, period: .month)),
        .init(address: "Professorsslingan 47-49", room: "Professorsslingan 49", maxFutureBookings: 2, minutesAfterBooking: 0, quota: .init(count: 4, period: .month)),
        .init(address: "Professorsslingan 51-53", room: "Professorsslingan 53", maxFutureBookings: 2, minutesAfterBooking: 0, quota: .init(count: 4, period: .month)),
        .init(address: "Professorsslingan 57-65", room: "Professorsslingan 57", maxFutureBookings: 2, minutesAfterBooking: 0, quota: .init(count: 4, period: .month)),
        .init(address: "Roslagstullsbacken 5", room: "Roslagstullsbacken 5", maxFutureBookings: 2, minutesAfterBooking: 60, quota: nil),
        .init(address: "Röntgenvägen 1", room: "Röntgenvägen 1", maxFutureBookings: 2, minutesAfterBooking: 60, quota: nil),
        .init(address: "Simrishamnsvägen 15", room: "Simrishamnsvägen 15", maxFutureBookings: 1, minutesAfterBooking: 0, quota: nil),
        .init(address: "Skomakargatan 24 A+B", room: "Skomakargatan 24 A", maxFutureBookings: 2, minutesAfterBooking: 60, quota: nil),
        .init(address: "Studentbacken 21", room: "Studentbacken 21", maxFutureBookings: 1, minutesAfterBooking: 60, quota: nil),
        .init(address: "Studentbacken 23", room: "Studentbacken 23", maxFutureBookings: 1, minutesAfterBooking: 60, quota: nil),
        .init(address: "Studentbacken 25-27", room: "Studentbacken 25", maxFutureBookings: 1, minutesAfterBooking: 60, quota: nil),
        .init(address: "Understensvägen 10", room: "Understensvägen 10", maxFutureBookings: 1, minutesAfterBooking: 0, quota: nil),
        .init(address: "Understensvägen 20", room: "Understensvägen 20", maxFutureBookings: 1, minutesAfterBooking: 0, quota: nil),
        .init(address: "Värtavägen 66", room: "Värtavägen 66", maxFutureBookings: 1, minutesAfterBooking: 60, quota: nil),
        .init(address: "Öregrundsgatan 9-11", room: "Öregrundsgatan 9", maxFutureBookings: 1, minutesAfterBooking: 90, quota: nil),
    ]
}
