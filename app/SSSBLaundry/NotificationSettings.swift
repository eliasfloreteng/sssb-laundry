//
//  NotificationSettings.swift
//  SSSBLaundry
//

import Foundation

/// How far ahead of a timeslot a reminder fires. Mirrors the alert offsets
/// Calendar.app offers, trimmed to the ones that are useful for a booking that
/// is released 15 minutes after it starts.
///
/// Raw values are minutes before the start, which is exactly what the server
/// stores as `alertMinutes`, so no mapping table is needed on either side.
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
    case oneWeek = 10080

    var id: Int { rawValue }

    /// Minutes before the timeslot start, or `nil` when nothing should fire.
    var minutesBefore: Int? { self == .off ? nil : rawValue }

    /// The picker row. "Before" is spelled into each case rather than composed
    /// from `leadLabel`, because the two halves do not join the same way in
    /// every language.
    var label: String {
        switch self {
        case .off:
            return String(localized: "None", comment: "Reminder offset: no reminder at all")
        case .atStart:
            return String(localized: "At start", comment: "Reminder offset: when the booking starts")
        case .fiveMinutes:
            return String(localized: "5 minutes before", comment: "Reminder offset")
        case .tenMinutes:
            return String(localized: "10 minutes before", comment: "Reminder offset")
        case .fifteenMinutes:
            return String(localized: "15 minutes before", comment: "Reminder offset")
        case .thirtyMinutes:
            return String(localized: "30 minutes before", comment: "Reminder offset")
        case .oneHour:
            return String(localized: "1 hour before", comment: "Reminder offset")
        case .twoHours:
            return String(localized: "2 hours before", comment: "Reminder offset")
        case .oneDay:
            return String(localized: "1 day before", comment: "Reminder offset")
        case .oneWeek:
            return String(localized: "1 week before", comment: "Reminder offset")
        }
    }

    /// Just the span, for the prompt copy that puts it in a sentence of its own.
    var leadLabel: String {
        switch self {
        case .off, .atStart: return ""
        case .fiveMinutes:
            return String(localized: "5 minutes", comment: "How long before a booking a reminder arrives")
        case .tenMinutes:
            return String(localized: "10 minutes", comment: "How long before a booking a reminder arrives")
        case .fifteenMinutes:
            return String(localized: "15 minutes", comment: "How long before a booking a reminder arrives")
        case .thirtyMinutes:
            return String(localized: "30 minutes", comment: "How long before a booking a reminder arrives")
        case .oneHour:
            return String(localized: "1 hour", comment: "How long before a booking a reminder arrives")
        case .twoHours:
            return String(localized: "2 hours", comment: "How long before a booking a reminder arrives")
        case .oneDay:
            return String(localized: "1 day", comment: "How long before a booking a reminder arrives")
        case .oneWeek:
            return String(localized: "1 week", comment: "How long before a booking a reminder arrives")
        }
    }
}

enum NotificationSetting {
    static let enabledKey = "notifications.enabled"
    static let alertKey = "notifications.alert"
    static let secondAlertKey = "notifications.secondAlert"
    /// Set once the post-booking prompt has been shown, so it only ever asks once.
    static let promptedKey = "notifications.prompted"
    /// Last APNs token handed to us, so a sync doesn't have to wait for a fresh callback.
    static let deviceTokenKey = "notifications.deviceToken"

    static let defaultEnabled = false
    static let defaultAlert = BookingAlert.tenMinutes
    static let defaultSecondAlert = BookingAlert.off

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    static var deviceToken: String? {
        UserDefaults.standard.string(forKey: deviceTokenKey)
    }

    static func alert(forKey key: String, default fallback: BookingAlert) -> BookingAlert {
        guard let raw = UserDefaults.standard.object(forKey: key) as? Int else { return fallback }
        return BookingAlert(rawValue: raw) ?? fallback
    }

    static var alert: BookingAlert { alert(forKey: alertKey, default: defaultAlert) }
    static var secondAlert: BookingAlert { alert(forKey: secondAlertKey, default: defaultSecondAlert) }
}
