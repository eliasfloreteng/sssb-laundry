import Foundation

enum DateFormatting {

    /// Parses ISO date string "2026-03-06" into a Date
    static func parseISO(_ string: String) -> Date? {
        isoFormatter.date(from: string)
    }

    /// Parses Swedish abbreviated booking date like "FRE 6 MAR" into a Date.
    /// Assumes the current year (or next year if the date has already passed).
    static func parseSwedishBookingDate(_ string: String) -> Date? {
        // Format: "FRE 6 MAR" or "LÖR 7 MAR"
        let parts = string.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ")
            .filter { !$0.isEmpty }
        guard parts.count >= 3 else { return nil }

        let dayStr = parts[1]
        let monthStr = parts[2].uppercased()
        guard let day = Int(dayStr),
              let month = swedishMonthMap[monthStr] else { return nil }

        let calendar = Calendar.current
        let now = Date()
        let currentYear = calendar.component(.year, from: now)

        var components = DateComponents()
        components.day = day
        components.month = month
        components.year = currentYear

        if let date = calendar.date(from: components) {
            // If the date is more than 2 months in the past, assume next year
            if date < calendar.date(byAdding: .month, value: -2, to: now)! {
                components.year = currentYear + 1
                return calendar.date(from: components)
            }
            return date
        }
        return nil
    }

    /// Device-native date format (respects user locale), e.g. "Friday, March 6"
    static func nativeDate(_ date: Date) -> String {
        nativeDateFormatter.string(from: date)
    }

    /// Relative date when close, native format otherwise.
    /// "Today", "Tomorrow", "Wednesday" (within the week), or native format.
    static func relativeDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfDate = calendar.startOfDay(for: date)
        let dayDiff = calendar.dateComponents([.day], from: startOfToday, to: startOfDate).day ?? 0

        if dayDiff == 0 {
            return String(localized: "Today")
        } else if dayDiff == 1 {
            return String(localized: "Tomorrow")
        } else if dayDiff == -1 {
            return String(localized: "Yesterday")
        } else if dayDiff > 1 && dayDiff <= 6 {
            // Show weekday name for this week
            return weekdayFormatter.string(from: date)
        } else {
            return nativeDate(date)
        }
    }

    // MARK: - Private

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let nativeDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()

    private static let swedishMonthMap: [String: Int] = [
        "JAN": 1, "FEB": 2, "MAR": 3, "APR": 4,
        "MAJ": 5, "JUN": 6, "JUL": 7, "AUG": 8,
        "SEP": 9, "OKT": 10, "NOV": 11, "DEC": 12,
    ]
}
