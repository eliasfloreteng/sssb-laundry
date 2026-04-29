//
//  Models.swift
//  SSSBLaundry
//

import Foundation

struct WeekResponse: Decodable {
    let week: Week
    let groups: [LaundryGroup]
    let timeslots: [Timeslot]
}

struct Week: Decodable {
    let fromDate: String
    let toDate: String
    let timezone: String
}

struct LaundryGroup: Decodable, Identifiable, Hashable {
    let id: Int
    let location: String
    let name: String
}

struct Timeslot: Decodable, Identifiable, Hashable {
    let id: String
    let startAt: String
    let endAt: String
    let localDate: String
    let startTime: String
    let endTime: String
    let spansMidnight: Bool
    let groups: [TimeslotGroup]
}

struct TimeslotGroup: Decodable, Hashable {
    let groupId: Int
    let status: GroupStatus
    let canBook: Bool
    let canCancel: Bool
}

enum GroupStatus: String, Decodable {
    case bookable
    case own
    case unavailable
}

struct ActionResponse: Decodable {
    let timeslotId: String
    let overallStatus: OverallStatus
    let results: [ActionResult]
}

enum OverallStatus: String, Decodable {
    case success
    case partial_success
    case failed
}

struct ActionResult: Decodable, Identifiable {
    let groupId: Int
    let status: String
    let message: String?
    let error: APIError?

    var id: Int { groupId }

    var isSuccessful: Bool {
        switch status {
        case "booked", "already_booked", "cancelled", "not_booked":
            return true
        default:
            return false
        }
    }
}

struct APIError: Decodable, Error, LocalizedError {
    let code: String
    let message: String
    let details: [String: AnyCodable]?

    var errorDescription: String? { message }

    static func local(code: String, message: String) -> APIError {
        APIError(code: code, message: message, details: nil)
    }
}

struct APIErrorEnvelope: Decodable {
    let error: APIError
}

enum ActiveGroupsSetting {
    static let hiddenIdsKey = "activeGroups.hiddenIds"

    static func parse(_ raw: String) -> Set<Int> {
        Set(raw.split(separator: ",").compactMap { Int($0) })
    }

    static func encode(_ ids: Set<Int>) -> String {
        ids.sorted().map(String.init).joined(separator: ",")
    }

    static func isActive(groupId: Int, hidden: Set<Int>) -> Bool {
        !hidden.contains(groupId)
    }
}

enum ActiveHoursSetting {
    static let enabledKey = "activeHours.enabled"
    static let startKey = "activeHours.startMinutes"
    static let endKey = "activeHours.endMinutes"

    static let defaultEnabled = true
    static let defaultStartMinutes = 6 * 60
    static let defaultEndMinutes = 0

    static func minutes(fromTimeString s: String) -> Int? {
        let parts = s.split(separator: ":")
        guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }

    static func includes(timeslot: Timeslot, startMinutes: Int, endMinutes: Int) -> Bool {
        guard let m = minutes(fromTimeString: timeslot.startTime) else { return true }
        if startMinutes == endMinutes { return true }
        if startMinutes < endMinutes {
            return m >= startMinutes && m < endMinutes
        }
        return m >= startMinutes || m < endMinutes
    }
}

struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }
}
