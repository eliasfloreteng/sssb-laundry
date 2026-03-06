import Foundation

struct Booking: Identifiable {
    let id: String
    let time: String
    let date: Date?
    let group: String
    let unbookPath: String

    var formattedDate: String {
        guard let date else { return "" }
        return DateFormatting.relativeDate(date)
    }

    var fullFormattedDate: String {
        guard let date else { return "" }
        return DateFormatting.nativeDate(date)
    }
}
