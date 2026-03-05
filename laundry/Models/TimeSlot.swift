import Foundation

struct TimeSlot: Identifiable {
    enum Status {
        case available
        case own
        case unavailable
    }

    var id: String { "\(passNo)-\(date)-\(groupId)" }
    let passNo: Int
    let date: String
    let groupId: Int
    let time: String
    let status: Status
    let bookPath: String?
    let unbookPath: String?
    let groupName: String?
}
