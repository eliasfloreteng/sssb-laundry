//
//  BookingRules.swift
//  SSSBLaundry
//

import Foundation

/// What Aptus refuses, and what SSSB merely publishes. Two kinds of rule, and
/// the app treats them differently on purpose.
///
/// **What upstream cannot do at all.** Aptus renders a book button only for a
/// timeslot it is prepared to book, and an unbook link only for a booking it is
/// prepared to release. The API mirrors those two as `canBook` / `canCancel`,
/// and without one it answers `not_bookable` / `NOT_CANCELLABLE` without ever
/// asking the portal. A timeslot whose start has passed is the same answer one
/// refresh later: the portal books nothing in the past, and releases no session
/// that is already running. The app blocks these outright — there is nothing to
/// send.
///
/// **What SSSB publishes.** The per-room maximum in `LaundryRooms` is a number
/// off a web page, counted against a week list that may be minutes old and
/// against bookings Aptus may already have auto-released. The app says what it
/// counts and lets Aptus have the last word — a booking that no longer exists
/// upstream must never be what stops the user booking again.
enum BookingRules {
    /// The rules SSSB publishes for every resident, from
    /// <https://www.sssb.se/en/book-a-laundry-room/>, shortened but not
    /// reinterpreted. The numbers that differ per laundry room are not here —
    /// they are in `LaundryRooms`.
    static let residentRules = [
        "Tag in with your Aptus tag when you start. You can’t tag in before the booked time.",
        "A session you haven’t tagged into within 15 minutes is released to everyone again.",
        "You can hold one or two sessions at a time, depending on your laundry room.",
        "Cancel a session you won’t use, so someone else can take it."
    ]
}

/// Why one group of one timeslot can’t be booked or released right now. `nil`
/// from `restriction(in:)` means the user may still toggle it.
enum GroupRestriction: Equatable {
    /// The timeslot has started. Aptus books nothing in the past, and a session
    /// that is already running cannot be handed back.
    case started
    /// Someone else holds it.
    case taken
    /// Free, but Aptus offers no way to book it — most often the laundry room's
    /// session limit, already used up.
    case notBookable
    /// Yours, but Aptus offers no way to release it.
    case notCancellable

    /// The one word or two shown beside the group's name. Short on purpose: it
    /// is the whole explanation the user gets, and the row it sits on is
    /// already disabled and dimmed. A group with no restriction says nothing at
    /// all, so there is no label for the ordinary case.
    func label(for status: GroupStatus) -> String {
        switch (status, self) {
        case (.own, .started): return "In progress"
        case (.own, _): return "Can’t be cancelled"
        case (_, .started): return "Too late"
        case (_, .taken): return "Unavailable"
        case (_, _): return "Can’t be booked"
        }
    }
}

extension TimeslotGroup {
    /// What stops this group being booked or released, or `nil` when nothing
    /// does. Everything here is something upstream is certain to refuse; the
    /// per-room session quota is deliberately not part of it.
    func restriction(in timeslot: Timeslot, asOf now: Date = Date()) -> GroupRestriction? {
        // Someone else's booking is named as such even after the slot has
        // started: "taken" is the more useful half of a truth where both halves
        // hold.
        if status == .unavailable { return .taken }
        if timeslot.hasStarted(asOf: now) { return .started }
        switch status {
        case .unavailable: return .taken
        case .bookable: return canBook ? nil : .notBookable
        case .own: return canCancel ? nil : .notCancellable
        }
    }
}

extension Timeslot {
    var startDate: Date? { LaundryStore.parseISO8601(startAt) }

    /// A date the app failed to parse counts as still ahead: an unreadable
    /// timestamp must never be what silently blocks a booking.
    func hasStarted(asOf now: Date = Date()) -> Bool {
        guard let startDate else { return false }
        return startDate <= now
    }

    /// The groups the user could still act on, hidden ones left out.
    func actionableGroups(hidden: Set<Int>, asOf now: Date = Date()) -> [TimeslotGroup] {
        groups.filter { !hidden.contains($0.groupId) && $0.restriction(in: self, asOf: now) == nil }
    }

    /// Whether any visible group of this timeslot is booked by the user. A
    /// booking is never filtered out of the week list, however late it is.
    func hasOwnGroup(hidden: Set<Int>) -> Bool {
        groups.contains { !hidden.contains($0.groupId) && $0.status == .own }
    }
}
