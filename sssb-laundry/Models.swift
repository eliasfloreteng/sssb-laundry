//
//  Models.swift
//  sssb-laundry
//

import Foundation

struct MeResponse: Codable, Equatable {
    let objectId: String
    let category: Category?
    let groups: [Group]

    struct Category: Codable, Equatable, Hashable {
        let id: String?
        let name: String
    }

    struct Group: Codable, Equatable, Hashable, Identifiable {
        let id: String
        let name: String
    }

    var categoryName: String? { category?.name }
}

struct SlotsPage: Codable {
    let items: [Slot]
    let nextCursor: String?
}

struct Slot: Codable, Identifiable, Hashable {
    let date: String
    let passNo: Int
    let startsAt: Date
    let endsAt: Date
    let groups: [SlotGroup]
    let bookable: Bool
    let bookedByMe: Bool
    let bookableGroupIds: [String]

    var id: String { "\(date)-\(passNo)" }

    struct SlotGroup: Codable, Hashable, Identifiable {
        let id: String
        let name: String
        let status: String
        let bookingId: String?
    }
}

struct Booking: Codable, Identifiable, Hashable {
    let id: String
    let slot: SlotRef?
    let group: GroupRef?
    let status: String?
    let rawTimeRange: String?

    struct SlotRef: Codable, Hashable {
        let date: String
        let passNo: Int
        let startsAt: Date?
        let endsAt: Date?
    }

    struct GroupRef: Codable, Hashable {
        let id: String
        let name: String
    }
}

struct BookingsPage: Codable {
    let items: [Booking]
    let nextCursor: String?
}

struct APIError: Codable, Error, LocalizedError {
    struct Payload: Codable {
        let code: String
        let message: String
    }
    let error: Payload

    var errorDescription: String? { error.message }
    var code: String { error.code }
}

/// What to send as the `prefer` value on `POST /slots/:date/:passNo/book`.
///
/// The wire protocol also accepts `"any"` and positional `"1"`, `"2"`, `"N"`
/// values, but the iOS client only ever needs `.all` (book every bookable
/// group in one server-side pass) or `.group(id:)` (target a specific group
/// by id). The client always uses `.group(id:)` when the user picks
/// concrete groups, since that gives per-group success/failure info.
enum BookingPreference: Equatable {
    case all
    case group(id: String)

    var apiValue: String {
        switch self {
        case .all: return "all"
        case .group(let id): return id
        }
    }
}
