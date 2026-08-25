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
    static func headline(for error: APIError) -> String {
        switch error.code {
        case "AUTH_FAILED", "MISSING_OBJECT_ID":
            return "Sign-in problem"
        case "NO_INTERNET", "TIMEOUT", "NETWORK_ERROR":
            return "No connection"
        case "INVALID_TIMESLOT_ID", "INVALID_DATE", "MISSING_DATE":
            return "Timeslot out of date"
        case "INVALID_GROUP_IDS":
            return "Too many groups"
        case "SERVICE_ERROR", "BAD_RESPONSE":
            return "Aptus problem"
        default:
            return "Something went wrong"
        }
    }

    static func explanation(for error: APIError) -> String {
        switch error.code {
        case "AUTH_FAILED":
            return "Aptus didn’t accept your object number. Check it and sign in again."
        case "MISSING_OBJECT_ID":
            return "Your object number is missing. Sign in again."
        case "NO_INTERNET":
            return "You appear to be offline. Reconnect and try again."
        case "TIMEOUT":
            return "Aptus took too long to answer. Try again in a moment."
        case "NETWORK_ERROR":
            return "Couldn’t connect. Try again in a moment."
        case "INVALID_TIMESLOT_ID", "INVALID_DATE", "MISSING_DATE":
            return "This timeslot has changed. Pull down to refresh, then try again."
        case "INVALID_GROUP_IDS":
            return "One booking can cover at most \(LaundryStore.maxGroupsPerBooking) groups."
        case "SERVICE_ERROR":
            return "Aptus is having trouble right now. Try again in a few minutes."
        case "BAD_RESPONSE":
            return "Aptus replied with something unexpected. Try again in a moment."
        default:
            return error.message.isEmpty
                ? "Aptus couldn’t complete the request."
                : error.message
        }
    }

    /// What actually happened to one group, in a line the user can read back
    /// to themselves: "Grupp 1: couldn't book — someone else took it first".
    /// The name is Aptus's own label for the group, kept verbatim.
    static func summary(for result: ActionResult, action: BookingAction, group: String) -> String {
        guard !result.isSuccessful else {
            switch result.status {
            case "booked": return "\(group): booked"
            case "already_booked": return "\(group): already yours"
            case "cancelled": return "\(group): cancelled"
            case "not_booked": return "\(group): was not booked"
            default: return "\(group): done"
            }
        }
        let verb = action == .book ? "couldn’t book" : "couldn’t cancel"
        return "\(group): \(verb) — \(explanation(for: result, action: action))"
    }

    /// Why one group didn't end up the way the user asked.
    static func explanation(for result: ActionResult, action: BookingAction) -> String {
        // Aptus offered no button for it, so the request never left the server.
        // The app blocks these itself; reaching here means the week list was
        // already stale when the user tapped.
        if result.status == "not_bookable" {
            return "Aptus no longer offers this time — refresh and try again"
        }
        if let code = result.error?.code {
            switch code {
            case "SLOT_TAKEN", "ALREADY_BOOKED_BY_OTHER":
                return "someone else took it first"
            case "BOOKING_LIMIT", "TOO_MANY_BOOKINGS":
                return sessionLimitReason
            case "NOT_CANCELLABLE":
                return "Aptus won’t release a session that has already started"
            case "BOOK_SLOT_NOT_FOUND", "CANCEL_SLOT_NOT_FOUND":
                return "Aptus no longer lists this timeslot — refresh and try again"
            case "AUTH_FAILED":
                return "Aptus didn’t accept your object number"
            default:
                break
            }
        }
        switch action {
        case .book:
            return "Aptus turned it down — most likely someone just took it, or \(sessionLimitReason)"
        case .cancel:
            return "Aptus wouldn’t release it — refresh and try again"
        }
    }

    /// Only names a number when the laundry room set in Settings publishes one.
    /// With no room set the app has no business claiming what the limit is.
    private static var sessionLimitReason: String {
        guard let max = LaundryRooms.maxFutureBookings else {
            return "you already hold as many sessions as your laundry room allows"
        }
        return "you already hold the maximum of \(max) sessions"
    }
}
