//
//  PushService.swift
//  SSSBLaundry
//

import Foundation
import UIKit
import UserNotifications

/// Registers this device with the backend and keeps the server's copy of the
/// alert preferences in step with `@AppStorage`.
///
/// `@AppStorage` stays the source of truth: Settings has to feel instant and
/// work offline, so the server is a mirror that every sync overwrites.
enum PushService {
    /// Debug builds get a sandbox APNs token, TestFlight and App Store builds a
    /// production one. The server has to know which host to push through.
    static var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    @discardableResult
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        if granted { registerForRemoteNotifications() }
        return granted
    }

    @MainActor
    static func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    static func store(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(hex, forKey: NotificationSetting.deviceTokenKey)
    }

    /// Pushes the current preferences up. Safe to call often — the endpoint is an
    /// idempotent upsert keyed on the device token.
    static func syncToServer() {
        guard let token = NotificationSetting.deviceToken,
              let objectId = ObjectIdStore.get(), !objectId.isEmpty
        else { return }

        Task {
            // Permission revoked in iOS Settings behind our back means the server
            // should stop sending, whatever the local toggle still says.
            let authorized = await authorizationStatus() == .authorized
            let enabled = NotificationSetting.isEnabled && authorized
            let client = APIClient(objectIdProvider: { ObjectIdStore.get() })
            _ = try? await client.registerDevice(
                deviceToken: token,
                environment: environment,
                enabled: enabled,
                alertMinutes: NotificationSetting.alert.minutesBefore,
                secondAlertMinutes: NotificationSetting.secondAlert.minutesBefore
            )
        }
    }

    /// Clears everything already delivered for a booking that no longer exists.
    ///
    /// A notification outlives the booking it is about: nothing on the server can
    /// reach into Notification Center, so a cancelled slot arrives here as a
    /// silent push and this is what takes the reminder down. Matched on the
    /// booking's start, which every payload carries, rather than on the thread id
    /// — that one moves when the groups in the slot change.
    static func removeDelivered(forBookingStartingAt start: Date) async {
        let center = UNUserNotificationCenter.current()
        let stale = await center.deliveredNotifications().filter { notification in
            guard let raw = notification.request.content.userInfo["startAt"] as? String,
                  let delivered = LaundryStore.parseISO8601(raw)
            else { return false }
            return abs(delivered.timeIntervalSince(start)) < 1
        }
        guard !stale.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: stale.map(\.request.identifier))
    }

    /// Stops the server pushing this object id's bookings to this phone. Used on
    /// sign-out and when reminders are turned off.
    static func deregister(objectId: String? = nil) {
        guard let token = NotificationSetting.deviceToken else { return }
        let id = objectId ?? ObjectIdStore.get()
        guard let id, !id.isEmpty else { return }

        Task {
            let client = APIClient(objectIdProvider: { id })
            _ = try? await client.deregisterDevice(deviceToken: token)
        }
    }
}
