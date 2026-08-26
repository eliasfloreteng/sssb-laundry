//
//  ErrorPresenter.swift
//  SSSBLaundry
//

import Foundation

/// What the user was trying to do when something failed. Book and cancel fail
/// for different reasons, so the explanation differs.
enum BookingAction {
    case book
    case cancel
}

/// Turns API/network failures into something a resident can act on. Error codes
/// and HTTP details never reach the UI — every string here says what happened
/// and what to do next. "Aptus" is what SSSB calls the booking system, so that
/// is what the app calls it too.
enum ErrorPresenter {
    /// The headline for a failure that has none of its own — the alert title
    /// when nothing more specific is known.
    static var genericHeadline: String {
        String(localized: "Something went wrong", comment: "Alert title for a failure the app can't name")
    }

    static func headline(for error: APIError) -> String {
        switch error.code {
        case "AUTH_FAILED", "MISSING_OBJECT_ID":
            return String(localized: "Sign-in problem", comment: "Error headline: Aptus rejected the object number")
        case "NO_INTERNET", "TIMEOUT", "NETWORK_ERROR":
            return String(localized: "No connection", comment: "Error headline: the phone couldn't reach the service")
        case "INVALID_TIMESLOT_ID", "INVALID_DATE", "MISSING_DATE":
            return String(localized: "Timeslot out of date", comment: "Error headline: the week list was stale")
        case "INVALID_GROUP_IDS":
            return String(localized: "Too many groups", comment: "Error headline: more groups than one action takes")
        case "SERVICE_ERROR", "BAD_RESPONSE":
            return String(localized: "Aptus problem", comment: "Error headline: the booking system misbehaved")
        // Minted by the app, not the API: a long-press action that failed has no
        // sheet to explain itself in, so it borrows the alert instead. The
        // message is already the one line that says what happened.
        case "BOOKING_FAILED":
            return bookingFailedHeadline
        case "CANCELLATION_FAILED":
            return cancellationFailedHeadline
        default:
            return genericHeadline
        }
    }

    static var bookingFailedHeadline: String {
        String(localized: "Booking didn’t go through", comment: "Headline when nothing was booked")
    }

    static var cancellationFailedHeadline: String {
        String(localized: "Cancellation didn’t go through", comment: "Headline when nothing was cancelled")
    }

    static func explanation(for error: APIError) -> String {
        switch error.code {
        case "AUTH_FAILED":
            return String(
                localized: "Aptus didn’t accept your object number. Check it and sign in again.",
                comment: "What to do about a rejected object number"
            )
        case "MISSING_OBJECT_ID":
            return String(
                localized: "Your object number is missing. Sign in again.",
                comment: "What to do when the app has no object number stored"
            )
        case "NO_INTERNET":
            return String(
                localized: "You appear to be offline. Reconnect and try again.",
                comment: "What to do when the phone has no connection"
            )
        case "TIMEOUT":
            return String(
                localized: "Aptus took too long to answer. Try again in a moment.",
                comment: "What to do when the request timed out"
            )
        case "NETWORK_ERROR":
            return String(
                localized: "Couldn’t connect. Try again in a moment.",
                comment: "What to do when the service couldn't be reached"
            )
        case "INVALID_TIMESLOT_ID", "INVALID_DATE", "MISSING_DATE":
            return String(
                localized: "This timeslot has changed. Pull down to refresh, then try again.",
                comment: "What to do when the week list was stale"
            )
        case "INVALID_GROUP_IDS":
            return String(
                localized: "One booking can cover at most \(LaundryStore.maxGroupsPerBooking) groups.",
                comment: "Aptus's hard limit on groups per booking action"
            )
        case "SERVICE_ERROR":
            return String(
                localized: "Aptus is having trouble right now. Try again in a few minutes.",
                comment: "What to do when the booking system is failing"
            )
        case "BAD_RESPONSE":
            return String(
                localized: "Aptus replied with something unexpected. Try again in a moment.",
                comment: "What to do when the response couldn't be read"
            )
        default:
            return error.message.isEmpty
                ? String(
                    localized: "Aptus couldn’t complete the request.",
                    comment: "Fallback explanation when the service gave no reason"
                )
                : error.message
        }
    }

    /// What actually happened to one group, in a line the user can read back
    /// to themselves: "Grupp 1: couldn't book — someone else took it first".
    /// The name is Aptus's own label for the group, kept verbatim.
    static func summary(for result: ActionResult, action: BookingAction, group: String) -> String {
        guard !result.isSuccessful else {
            switch result.status {
            case "booked":
                return String(localized: "\(group): booked", comment: "Per-group outcome line")
            case "already_booked":
                return String(localized: "\(group): already yours", comment: "Per-group outcome line")
            case "cancelled":
                return String(localized: "\(group): cancelled", comment: "Per-group outcome line")
            case "not_booked":
                return String(localized: "\(group): was not booked", comment: "Per-group outcome line")
            default:
                return String(localized: "\(group): done", comment: "Per-group outcome line")
            }
        }
        let reason = explanation(for: result, action: action)
        switch action {
        case .book:
            return String(
                localized: "\(group): couldn’t book — \(reason)",
                comment: "Per-group failure line; second placeholder is a lowercase reason clause"
            )
        case .cancel:
            return String(
                localized: "\(group): couldn’t cancel — \(reason)",
                comment: "Per-group failure line; second placeholder is a lowercase reason clause"
            )
        }
    }

    /// Why one group didn't end up the way the user asked. Written as a clause
    /// that gets appended to a line, so it starts lowercase and has no full stop.
    static func explanation(for result: ActionResult, action: BookingAction) -> String {
        // Aptus offered no button for it, so the request never left the server.
        // The app blocks these itself; reaching here means the week list was
        // already stale when the user tapped.
        if result.status == "not_bookable" {
            return String(
                localized: "Aptus no longer offers this time — refresh and try again",
                comment: "Reason clause: the timeslot is gone from the portal"
            )
        }
        if let code = result.error?.code {
            switch code {
            case "SLOT_TAKEN", "ALREADY_BOOKED_BY_OTHER":
                return String(
                    localized: "someone else took it first",
                    comment: "Reason clause: another resident booked the slot"
                )
            case "BOOKING_LIMIT", "TOO_MANY_BOOKINGS":
                return sessionLimitReason
            case "NOT_CANCELLABLE":
                return String(
                    localized: "Aptus won’t release a session that has already started",
                    comment: "Reason clause: the session is already running"
                )
            case "BOOK_SLOT_NOT_FOUND", "CANCEL_SLOT_NOT_FOUND":
                return String(
                    localized: "Aptus no longer lists this timeslot — refresh and try again",
                    comment: "Reason clause: the timeslot is gone from the portal"
                )
            case "AUTH_FAILED":
                return String(
                    localized: "Aptus didn’t accept your object number",
                    comment: "Reason clause: the object number was rejected"
                )
            default:
                break
            }
        }
        switch action {
        case .book:
            // Spelled out per case rather than composed from `sessionLimitReason`:
            // a clause that stands alone after a dash and one that follows "or"
            // do not take the same word order in every language.
            guard let max = LaundryRooms.maxFutureBookings else {
                return String(
                    localized: "Aptus turned it down — most likely someone just took it, or you already hold as many sessions as your laundry room allows",
                    comment: "Reason clause for a refused booking, with no published session limit to name"
                )
            }
            return String(
                localized: "Aptus turned it down — most likely someone just took it, or you already hold the maximum of \(max) sessions",
                comment: "Reason clause for a refused booking, naming the laundry room's session limit"
            )
        case .cancel:
            return String(
                localized: "Aptus wouldn’t release it — refresh and try again",
                comment: "Reason clause for a refused cancellation"
            )
        }
    }

    /// Only names a number when the laundry room set in Settings publishes one.
    /// With no room set the app has no business claiming what the limit is.
    private static var sessionLimitReason: String {
        guard let max = LaundryRooms.maxFutureBookings else {
            return String(
                localized: "you already hold as many sessions as your laundry room allows",
                comment: "Reason clause: the session limit is used up, and the app doesn't know the number"
            )
        }
        return String(
            localized: "you already hold the maximum of \(max) sessions",
            comment: "Reason clause: the session limit is used up"
        )
    }
}
