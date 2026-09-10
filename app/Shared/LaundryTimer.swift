//
//  LaundryTimer.swift
//  SSSBLaundry
//
//  Shared by the app and the widget extension.
//

import AlarmKit
import Foundation

/// The timer the user is running. `id` is the AlarmKit alarm's id: the alarm is
/// the timer, and this is only the copy the app's own UI and Live Activity read.
///
/// One at a time, because that is how a laundry session goes — a machine is
/// started, and the timer says when to come back down for it. The next load
/// gets the next timer.
struct LaundryTimer: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    let duration: TimeInterval
    /// The `BookedSlot` it was started from, so the session's Live Activity
    /// picks up its own timer and not somebody else's. Empty when the booking
    /// has since dropped off the loaded weeks.
    let bookingId: String

    var fireDate: Date { startedAt.addingTimeInterval(duration) }

    /// Both bounds come from the timer itself, never from `Date.now`, so a
    /// countdown range can't invert while the system is re-rendering.
    var countdownRange: ClosedRange<Date> { startedAt...fireDate }

    func isRunning(asOf now: Date = Date()) -> Bool { now < fireDate }

    /// The alarm's own headline while it counts down. A `LocalizedStringResource`
    /// rather than a `String` because AlarmKit stores the presentation and
    /// resolves it later, in whatever language the phone is in by then.
    static let countdownAlarmTitle = LocalizedStringResource(
        "Laundry",
        comment: "Alarm title while a laundry timer runs"
    )

    /// The alarm's headline when it goes off.
    static let alertAlarmTitle = LocalizedStringResource(
        "Laundry done",
        comment: "Alarm title when a laundry timer rings"
    )
}

/// What the duration wheel opens on: the length of an ordinary programme, and
/// the number the user most often just accepts.
let laundryTimerDefaultDuration: TimeInterval = 60 * 60

/// How long past the end of a session a timer can still be started. The washing
/// and the drying both happen inside the booked time, but the last load comes
/// out of the machine after it — and that is exactly when a timer is still
/// worth setting.
let laundryTimerOfferWindow: TimeInterval = 30 * 60

/// How long a timer that has rung stays on the Lock Screen before the session's
/// Live Activity gives up on it. The alarm itself is dismissed from its own
/// alert; this is only about the card that says the laundry is done.
let laundryTimerDoneLinger: TimeInterval = 15 * 60

/// The metadata every `AlarmAttributes` is built with. Empty on purpose: the
/// only thing that ever reads it is the alarm's own Live Activity, and this app
/// does not put one up — the booking's card is what shows the timer.
struct LaundryAlarmMetadata: AlarmMetadata {}
