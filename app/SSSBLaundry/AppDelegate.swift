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
