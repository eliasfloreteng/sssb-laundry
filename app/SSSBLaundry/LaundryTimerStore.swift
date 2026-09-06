//
//  LaundryTimerStore.swift
//  SSSBLaundry
//

import ActivityKit
import AlarmKit
import Foundation
import Observation
import SwiftUI

/// The timer the user is running, and the AlarmKit alarm behind it.
///
/// An alarm rather than a notification because a machine that finishes while
/// the phone is face down in another room has to be *heard*: an AlarmKit alarm
/// sounds through silent mode and Focus, a reminder does not. The system owns
/// the schedule — everything here is a mirror of it, kept only so the list and
/// the Live Activity have something to show, and dropped as soon as AlarmKit
/// says the alarm is gone.
///
/// One store for the whole app rather than one per view: an alarm outlives the
/// screen it was started from, and the phone has only one of them.
@Observable
final class LaundryTimerStore {
    static let shared = LaundryTimerStore()

    /// One at a time — the next load gets the next timer.
    private(set) var timer: LaundryTimer?

    /// Set when the system refused the alarm, so the view can say why instead
    /// of appearing to do nothing.
    var authorizationDenied = false

    /// Survives a launch: the alarm does, and a timer the app has forgotten
    /// would ring with nothing on screen to explain it.
    private static let storageKey = "timers.running"

    private var alarmObserver: Task<Void, Never>?
    /// Fires when the timer runs out, while the app is still alive.
    private var expiry: Task<Void, Never>?

    private init() {
        timer = Self.load()
        scheduleExpiry()
    }

    var authorizationState: AlarmManager.AuthorizationState {
        AlarmManager.shared.authorizationState
    }

    /// Starts the timer, replacing whatever was running. Returns whether the
    /// alarm was actually scheduled; a refusal leaves the previous one alone.
    @discardableResult
    func start(duration: TimeInterval, session: BookedSlot?) async -> Bool {
        guard await authorize() else {
            authorizationDenied = true
            return false
        }

        let id = UUID()
        let presentation = AlarmPresentation(
            alert: Self.alert(),
            // No pause button: a paused alarm would leave the app's own copy of
            // the fire date wrong, and a laundry programme does not pause.
            countdown: AlarmPresentation.Countdown(title: LaundryTimer.countdownAlarmTitle)
        )
        let configuration = AlarmManager.AlarmConfiguration.timer(
            duration: duration,
            attributes: AlarmAttributes(
                presentation: presentation,
                metadata: LaundryAlarmMetadata(machines: session?.machines ?? ""),
                tintColor: .accentColor
            ),
            sound: .default
        )

        do {
            _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
        } catch {
            return false
        }

        // Only once the replacement is actually scheduled, so a failure cannot
        // take the running timer down with it.
        if let previous = timer { release(previous) }
        replace(
            with: LaundryTimer(
                id: id,
                startedAt: Date(),
                duration: duration,
                bookingId: session?.id ?? ""
            )
        )
        return true
    }

    /// Takes the timer down, whether it is still counting or already ringing.
    func stop() {
        guard let timer else { return }
        release(timer)
        replace(with: nil)
    }

    /// Drops the timer when AlarmKit no longer has its alarm. An alarm the user
    /// stopped from its own alert is gone from the system's list, and that is
    /// the only sign the app gets that it happened.
    func reconcile() {
        guard let timer else { return }
        // A throw is not an empty list: it must never be what takes down the
        // timer the user is watching.
        guard let alarms = try? AlarmManager.shared.alarms else { return }
        if !alarms.contains(where: { $0.id == timer.id }) {
            replace(with: nil)
        }
    }

    /// Follows the system's list for as long as the app is alive, so stopping
    /// the alarm from the Lock Screen takes its row off the list too.
    func observeAlarms() {
        guard alarmObserver == nil else { return }
        reconcile()
        alarmObserver = Task { [weak self] in
            for await alarms in AlarmManager.shared.alarmUpdates {
                guard let self, !Task.isCancelled else { return }
                guard let timer else { continue }
                if !alarms.contains(where: { $0.id == timer.id }) {
                    replace(with: nil)
                }
            }
        }
    }

    /// The timer goes when the user signs out: the alarm is about a booking
    /// this phone is no longer following.
    func endAll() {
        stop()
    }

    private func authorize() async -> Bool {
        switch authorizationState {
        case .authorized:
            return true
        case .denied:
            return false
        case .notDetermined:
            let state = try? await AlarmManager.shared.requestAuthorization()
            return state == .authorized
        @unknown default:
            return false
        }
    }

    /// Hands the alarm back to the system. Which call depends on where it has
    /// got to: a countdown is cancelled, an alert is stopped.
    private func release(_ timer: LaundryTimer) {
        if timer.isRunning() {
            try? AlarmManager.shared.cancel(id: timer.id)
        } else {
            try? AlarmManager.shared.stop(id: timer.id)
        }
    }

    /// What the alarm says when it goes off. iOS 26.1 draws the stop button
    /// itself; 26.0 takes it from the presentation, and the app still runs
    /// there — the second branch goes when the deployment target does.
    private static func alert() -> AlarmPresentation.Alert {
        if #available(iOS 26.1, *) {
            AlarmPresentation.Alert(title: LaundryTimer.alertAlarmTitle)
        } else {
            legacyAlert()
        }
    }

    @available(iOS, deprecated: 26.1, message: "iOS 26.1 provides the stop button itself")
    private static func legacyAlert() -> AlarmPresentation.Alert {
        AlarmPresentation.Alert(
            title: LaundryTimer.alertAlarmTitle,
            stopButton: AlarmButton(
                text: LocalizedStringResource("Stop", comment: "Button that silences a laundry timer's alarm"),
                textColor: .white,
                systemImageName: "stop.fill"
            )
        )
    }

    private func replace(with timer: LaundryTimer?) {
        self.timer = timer
        save()
        scheduleExpiry()
    }

    /// Nothing else would redraw the row at the moment the countdown reaches
    /// zero: the numbers on it tick by themselves, but "still running" and
    /// "ringing" are two different rows, and only the clock tells them apart.
    private func scheduleExpiry() {
        expiry?.cancel()
        expiry = nil
        guard let timer, timer.isRunning() else { return }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, timer.fireDate.timeIntervalSinceNow + 1)))
            guard let self, !Task.isCancelled else { return }
            // Dropped first, otherwise the re-entrant publish cancels this very
            // task partway through.
            expiry = nil
            // The same timer, republished: nothing about it has changed but the
            // time of day, which is the whole point.
            replace(with: timer)
        }
    }

    private func save() {
        guard let timer, let data = try? JSONEncoder().encode(timer) else {
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
            return
        }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private static func load() -> LaundryTimer? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(LaundryTimer.self, from: data)
    }
}
