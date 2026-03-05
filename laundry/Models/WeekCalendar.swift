import Foundation

struct DayColumn: Identifiable {
    var id: String { dayName + dayOfMonth }
    let dayName: String
    let dayOfMonth: String
    let slots: [TimeSlot]
}

struct WeekCalendar {
    let days: [DayColumn]
    let previousWeekPath: String?
    let nextWeekPath: String?
    let weekLabel: String?
}
