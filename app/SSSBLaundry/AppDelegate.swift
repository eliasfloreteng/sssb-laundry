//
//  AppDelegate.swift
//  SSSBLaundry
//

import UIKit
import UserNotifications

/// The app is otherwise pure SwiftUI; this exists because APNs token delivery
/// and foreground presentation are still `UIApplicationDelegate` callbacks.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // A token can be reissued at any launch, so ask for a fresh one whenever
        // reminders are on rather than trusting the cached value forever.
        if NotificationSetting.isEnabled {
            application.registerForRemoteNotifications()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushService.store(deviceToken: deviceToken)
        PushService.syncToServer()
    }

    /// Silent pushes only: the server sends one when a booking is cancelled, so
    /// the reminders it already delivered for that slot can be taken down.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        guard userInfo["kind"] as? String == "cancelled",
              let startAt = userInfo["startAt"] as? String,
              let start = LaundryStore.parseISO8601(startAt)
        else { return .noData }

        await PushService.removeDelivered(forBookingStartingAt: start)
        return .newData
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Not surfaced: the toggle stays on and the next launch retries. Failing
        // here is usually no network or a Simulator, neither worth an alert.
        print("Remote notification registration failed: \(error.localizedDescription)")
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // A reminder is worth seeing even with the app open — the whole point is
        // that the session has to be activated within 15 minutes.
        [.banner, .sound, .list]
    }
}
