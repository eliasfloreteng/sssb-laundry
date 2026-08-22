//
//  NotificationService.swift
//  SSSBLaundry
//

import Foundation
import UserNotifications

/// How far ahead of a timeslot a reminder fires. Mirrors the alert offsets
/// Calendar.app offers, trimmed to the ones that are useful for a booking that
/// is released 15 minutes after it starts.
enum BookingAlert: Int, CaseIterable, Identifiable {
    case off = -1
    case atStart = 0
    case fiveMinutes = 5
    case tenMinutes = 10
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case oneHour = 60
    case twoHours = 120
    case oneDay = 1440

    var id: Int { rawValue }

    /// Minutes before the timeslot start, or `nil` when nothing should fire.
    var minutesBefore: Int? { self == .off ? nil : rawValue }

    var label: String {
        switch self {
        case .off: return "None"
        case .atStart: return "At start of booking"
        case .fiveMinutes: return "5 minutes before"
        case .tenMinutes: return "10 minutes before"
        case .fifteenMinutes: return "15 minutes before"
        case .thirtyMinutes: return "30 minutes before"
        case .oneHour: return "1 hour before"
        case .twoHours: return "2 hours before"
        case .oneDay: return "1 day before"
        }
    }

    /// Tail of the notification title, e.g. "Laundry in *10 minutes*".
    var leadLabel: String {
        switch self {
        case .off, .atStart: return ""
        case .fiveMinutes: return "5 minutes"
        case .tenMinutes: return "10 minutes"
        case .fifteenMinutes: return "15 minutes"
        case .thirtyMinutes: return "30 minutes"
        case .oneHour: return "1 hour"
        case .twoHours: return "2 hours"
        case .oneDay: return "1 day"
        }
    }
}

enum NotificationSetting {
    static let enabledKey = "notifications.enabled"
    static let alertKey = "notifications.alert"
    static let secondAlertKey = "notifications.secondAlert"
    /// Set once the post-booking prompt has been shown, so it only ever asks once.
    static let promptedKey = "notifications.prompted"

    static let defaultEnabled = false
    static let defaultAlert = BookingAlert.tenMinutes
    static let defaultSecondAlert = BookingAlert.off

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    static func alert(forKey key: String, default fallback: BookingAlert) -> BookingAlert {
        guard let raw = UserDefaults.standard.object(forKey: key) as? Int else { return fallback }
        return BookingAlert(rawValue: raw) ?? fallback
    }

    /// The distinct, enabled offsets to schedule for every booking.
    static var activeAlerts: [BookingAlert] {
        let alerts = [
            alert(forKey: alertKey, default: defaultAlert),
            alert(forKey: secondAlertKey, default: defaultSecondAlert)
        ]
        var seen: Set<Int> = []
        return alerts.filter { $0 != .off && seen.insert($0.rawValue).inserted }
    }
}

/// One booked timeslot, flattened into everything a notification needs.
struct BookingReminder {
    let id: String
    let start: Date
    let dayLabel: String
    let startTime: String
    let endTime: String
    let machines: [String]
}

enum NotificationService {
    private static let identifierPrefix = "booking."
    private static let startEpochKey = "startEpoch"
    /// iOS keeps at most 64 pending local notifications per app.
    private static let maxPendingRequests = 60

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    @discardableResult
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = try? await center.requestAuthorization(options: [.alert, .sound])
        return granted ?? false
    }

    /// Rewrites the pending reminders for every booking starting on or before
    /// `coveredThrough`.
    ///
    /// Only that window is rewritten: weeks are paged in lazily, so on a cold
    /// launch the store knows about the current week only and must not drop
    /// reminders it already scheduled for bookings further out.
    static func sync(reminders: [BookingReminder], coveredThrough: Date?) async {
        let center = UNUserNotificationCenter.current()
        let enabled = NotificationSetting.isEnabled
        let alerts = NotificationSetting.activeAlerts

        guard enabled, !alerts.isEmpty else {
            await cancelAll(in: center)
            return
        }
        guard await isAuthorized() else {
            await cancelAll(in: center)
            return
        }
        // Nothing loaded yet: leave whatever is already scheduled alone.
        guard let coveredThrough else { return }

        let pending = await center.pendingNotificationRequests()
        let stale = pending
            .filter { $0.identifier.hasPrefix(identifierPrefix) }
            .filter { request in
                guard let epoch = request.content.userInfo[startEpochKey] as? Double else { return true }
                return Date(timeIntervalSince1970: epoch) <= coveredThrough
            }
            .map(\.identifier)
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }

        let now = Date()
        var scheduled: [(fireDate: Date, request: UNNotificationRequest)] = []
        for reminder in reminders {
            for alert in alerts {
                guard let minutes = alert.minutesBefore else { continue }
                let fireDate = reminder.start.addingTimeInterval(-Double(minutes) * 60)
                // A reminder that is already due is noise, not a reminder.
                guard fireDate > now else { continue }
                scheduled.append((fireDate, request(for: reminder, alert: alert, fireDate: fireDate)))
            }
        }
        scheduled.sort { $0.fireDate < $1.fireDate }

        for entry in scheduled.prefix(maxPendingRequests) {
            try? await center.add(entry.request)
        }
    }

    static func cancelAll() async {
        await cancelAll(in: UNUserNotificationCenter.current())
    }

    private static func cancelAll(in center: UNUserNotificationCenter) async {
        let ours = await center.pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(identifierPrefix) }
            .map(\.identifier)
        guard !ours.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ours)
    }

    private static func isAuthorized() async -> Bool {
        switch await authorizationStatus() {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    private static func request(for reminder: BookingReminder, alert: BookingAlert, fireDate: Date) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = reminder.id
        content.userInfo = [startEpochKey: reminder.start.timeIntervalSince1970]

        let machines = reminder.machines.joined(separator: ", ")
        let sameDay = isSameStockholmDay(fireDate, reminder.start)
        let when = sameDay ? "" : "\(reminder.dayLabel) "
        let slot = "\(when)\(reminder.startTime)–\(reminder.endTime)"

        if alert == .atStart {
            content.title = "Laundry starts now"
            content.body = machines.isEmpty
                ? "Start the machine within 15 minutes or the booking is released."
                : "\(machines) · start the machine within 15 minutes or the booking is released."
        } else {
            content.title = "Laundry in \(alert.leadLabel)"
            content.body = machines.isEmpty ? slot : "\(machines) · \(slot)"
        }

        let interval = max(fireDate.timeIntervalSinceNow, 1)
        return UNNotificationRequest(
            identifier: "\(identifierPrefix)\(reminder.id).\(alert.rawValue)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        )
    }

    private static func isSameStockholmDay(_ a: Date, _ b: Date) -> Bool {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        return calendar.isDate(a, inSameDayAs: b)
    }
}

/// Lets reminders show as a banner while the app is in the foreground, the way
/// Calendar.app does.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    func register() {
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
