import Foundation

struct TimeSlot: Identifiable {
    enum Status {
        case available
        case own
        case unavailable
    }

    var id: String { "\(passNo)-\(passDate)-\(groupId)" }
    let passNo: Int
    let passDate: String
    let date: Date?
    let groupId: Int
    let time: String
    let status: Status
    let bookPath: String?
    let unbookPath: String?
    let groupName: String?

    var formattedDate: String {
        guard let date else { return passDate }
        return DateFormatting.relativeDate(date)
    }

    var fullFormattedDate: String {
        guard let date else { return passDate }
        return DateFormatting.nativeDate(date)
    }
}
