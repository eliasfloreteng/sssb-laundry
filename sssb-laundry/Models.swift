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
    let preferred: String?

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

enum BookingPreference: String, CaseIterable, Identifiable {
    case both, one = "1", two = "2", any
    var id: String { rawValue }
    var label: String {
        switch self {
        case .both: return "Both groups"
        case .one: return "Group 1"
        case .two: return "Group 2"
        case .any: return "Any group"
        }
    }
}
