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
        case .oneWeek: return "1 week before"
        }
    }

    /// Tail of the prompt copy, e.g. "10 minutes before your booking starts".
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
        case .oneWeek: return "1 week"
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
