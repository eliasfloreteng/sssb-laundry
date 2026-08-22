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
/// and what to do next.
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
            return "Too many machines"
        case "SERVICE_ERROR", "BAD_RESPONSE":
            return "Laundry service problem"
        default:
            return "Something went wrong"
        }
    }

    static func explanation(for error: APIError) -> String {
        switch error.code {
        case "AUTH_FAILED":
            return "The laundry system didn’t accept your object id. Check it and sign in again."
        case "MISSING_OBJECT_ID":
            return "Your object id is missing, so the app can’t identify your apartment. Sign in again."
        case "NO_INTERNET":
            return "You appear to be offline. Reconnect and try again."
        case "TIMEOUT":
            return "The laundry service took too long to answer. Try again in a moment."
        case "NETWORK_ERROR":
            return "The app couldn’t reach the laundry service. Try again in a moment."
        case "INVALID_TIMESLOT_ID", "INVALID_DATE", "MISSING_DATE":
            return "This timeslot changed since the app loaded it. Pull down to refresh, then try again."
        case "INVALID_GROUP_IDS":
            return "One booking can cover at most 2 machines."
        case "SERVICE_ERROR":
            return "The laundry service is having trouble right now. Try again in a few minutes."
        case "BAD_RESPONSE":
            return "The laundry service replied with something the app didn’t understand. Try again in a moment."
        default:
            return error.message.isEmpty
                ? "The laundry service couldn’t complete the request."
                : error.message
        }
    }

    /// What actually happened to one machine, in a line the user can read back
    /// to themselves: "Machine 3: couldn't book — someone else took it first".
    static func summary(for result: ActionResult, action: BookingAction, machine: String) -> String {
        guard !result.isSuccessful else {
            switch result.status {
            case "booked": return "\(machine): booked"
            case "already_booked": return "\(machine): already yours"
            case "cancelled": return "\(machine): cancelled"
            case "not_booked": return "\(machine): was not booked"
            default: return "\(machine): done"
            }
        }
        let verb = action == .book ? "couldn’t book" : "couldn’t cancel"
        return "\(machine): \(verb) — \(explanation(for: result, action: action))"
    }

    /// Why one machine didn't end up the way the user asked.
    static func explanation(for result: ActionResult, action: BookingAction) -> String {
        if let code = result.error?.code {
            switch code {
            case "SLOT_TAKEN", "ALREADY_BOOKED_BY_OTHER":
                return "someone else took it first"
            case "BOOKING_LIMIT", "TOO_MANY_BOOKINGS":
                return "you already hold the maximum of \(LaundryStore.maxActiveBookings) bookings"
            case "AUTH_FAILED":
                return "the laundry system didn’t accept your object id"
            default:
                break
            }
        }
        switch action {
        case .book:
            return "the laundry system turned it down — it was most likely just taken, or you already hold \(LaundryStore.maxActiveBookings) bookings"
        case .cancel:
            return "the laundry system wouldn’t release it — refresh and try again"
        }
    }
}
