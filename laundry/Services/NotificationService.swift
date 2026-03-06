import Foundation
import UserNotifications

enum NotificationService {
    @discardableResult
    static func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    static func scheduleReminder(date: Date?, time: String, groupName: String?) async {
        guard let triggerDate = triggerDate(from: date, time: time),
              triggerDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Laundry Reminder"
        content.body = "Your laundry session starts in 5 minutes (\(time))"

        let startHour = Calendar.current.component(.hour, from: triggerDate.addingTimeInterval(5 * 60))
        if startHour >= 22 || startHour < 6 {
            content.interruptionLevel = .passive
        } else {
            content.sound = .default
        }

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: triggerDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let identifier = notificationIdentifier(date: date, time: time)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        try? await UNUserNotificationCenter.current().add(request)
    }

    static func removeReminder(date: Date?, time: String) {
        let identifier = notificationIdentifier(date: date, time: time)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    static func syncReminders(with bookings: [Booking]) async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        for booking in bookings {
            await scheduleReminder(date: booking.date, time: booking.time, groupName: booking.group)
        }
    }

    // MARK: - Private

    private static func notificationIdentifier(date: Date?, time: String) -> String {
        let startTime = String(time.prefix(while: { $0 != " " }))
        let dateString: String
        if let date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            dateString = formatter.string(from: date)
        } else {
            dateString = "unknown"
        }
        return "laundry-\(dateString)-\(startTime)"
    }

    private static func triggerDate(from date: Date?, time: String) -> Date? {
        guard let date else { return nil }

        let parts = time.prefix(while: { $0 != " " }).split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else { return nil }

        var components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = minute

        guard let startDate = Calendar.current.date(from: components) else { return nil }
        return startDate.addingTimeInterval(-5 * 60)
    }
}
