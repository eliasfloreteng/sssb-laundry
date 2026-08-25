//
//  LaundryFormat.swift
//  SSSBLaundry
//

import Foundation

/// Days and times as the app writes them, always in Europe/Stockholm — the only
/// timezone the portal speaks, and the only one the app may print. The
/// formatters are stored because building one is expensive and these run per
/// section header on every render of the week list.
enum LaundryFormat {
    private static let dayLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = LaundryStore.stockholm
        formatter.dateFormat = "EEEE d MMM"
        return formatter
    }()

    /// "Monday 1 Sep", from the API's `yyyy-MM-dd`. A day that won't parse is
    /// shown as it arrived rather than dropped.
    static func dayLabel(_ day: String) -> String {
        guard let date = LaundryStore.date(from: day) else { return day }
        return dayLabel(date)
    }

    static func dayLabel(_ date: Date) -> String {
        dayLabelFormatter.string(from: date)
    }
}

extension Timeslot {
    /// "07:00 – 11:00", the way the row and the sheet both show it.
    var timeRange: String { "\(startTime) – \(endTime)" }

    /// Day and time on one line: what the clipboard gets, and how a booking is
    /// named in the confirmation that asks before releasing it.
    var dayAndTime: String { "\(LaundryFormat.dayLabel(localDate)), \(timeRange)" }
}
