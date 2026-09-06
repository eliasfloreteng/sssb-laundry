//
//  LiveActivityService.swift
//  SSSBLaundry
//

import ActivityKit
import Foundation

/// Puts the nearest booking on the Lock Screen and in the Dynamic Island: a
/// countdown to the start, then the 15 minutes before Aptus releases it — and,
/// once the user starts one, whatever is left on the timer.
enum LiveActivityService {
    /// Fires the phase change and the ending while the app is still alive.
    private static var supervisor: Task<Void, Never>?

    /// Starts, advances or ends the activity for whichever booking the user is
    /// closest to. Runs whenever a week lands and when the app comes forward,
    /// so simply opening the app inside the lead window is what starts it.
    static func sync(slots: [BookedSlot], timer: LaundryTimer?) async {
        supervisor?.cancel()
        supervisor = nil

        let now = Date()
        // A timer outranks the clock: while a machine is running, that is the
        // session the card is about, whatever else is booked later.
        let timed = slots.first { slot in
            activeTimer(for: slot, from: timer, asOf: now) != nil
        }
        let nearest = slots
            .filter { now >= $0.start.addingTimeInterval(-laundryActivityLeadWindow) && now < $0.deadline }
            .min { $0.start < $1.start }
        let current = timed ?? nearest

        // Everything else has either been superseded or run out of time.
        for activity in Activity<LaundryActivityAttributes>.activities
        where activity.attributes.bookingId != current?.id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        guard let current, ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let ownTimer = activeTimer(for: current, from: timer, asOf: now)
        let phase: LaundryActivityAttributes.Phase = now < current.start ? .upcoming : .grace
        let state = LaundryActivityAttributes.ContentState(phase: phase, timer: ownTimer)
        // The stale date is the next boundary the card has to be redrawn at: the
        // app is normally suspended by the time any of them arrives, and
        // staleness is what flips the widget over without an update from here —
        // to the release countdown, or to "wash done".
        let staleDate = nextBoundary(for: current, phase: phase, timer: ownTimer, now: now)
        let content = ActivityContent(state: state, staleDate: staleDate)

        let existing = Activity<LaundryActivityAttributes>.activities
            .first { $0.attributes.bookingId == current.id }
        if let existing {
            // Week pagination re-syncs on every page; only push a real change.
            if existing.content.state != state {
                await existing.update(content)
            }
        } else {
            _ = try? Activity.request(attributes: current.activityAttributes, content: content)
        }

        supervisor = Task {
            try? await Task.sleep(for: .seconds(max(1, staleDate.timeIntervalSinceNow + 1)))
            guard !Task.isCancelled else { return }
            // Drop the handle first, otherwise the re-entrant sync cancels this
            // very task partway through.
            supervisor = nil
            await sync(slots: slots, timer: timer)
        }
    }

    /// Drops every activity — used when the user signs out.
    static func endAll() async {
        supervisor?.cancel()
        supervisor = nil
        for activity in Activity<LaundryActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// This session's timer, if it is still worth showing: a rung one stays on
    /// the card for a while, because "done" is the whole point of having set it.
    private static func activeTimer(
        for slot: BookedSlot,
        from timer: LaundryTimer?,
        asOf now: Date
    ) -> LaundryTimer? {
        guard let timer,
              timer.bookingId == slot.id,
              now < timer.fireDate.addingTimeInterval(laundryTimerDoneLinger)
        else { return nil }
        return timer
    }

    /// When the card next says something different from what it says now.
    private static func nextBoundary(
        for slot: BookedSlot,
        phase: LaundryActivityAttributes.Phase,
        timer: LaundryTimer?,
        now: Date
    ) -> Date {
        if let timer {
            return timer.isRunning(asOf: now)
                ? timer.fireDate
                : timer.fireDate.addingTimeInterval(laundryTimerDoneLinger)
        }
        return phase == .upcoming ? slot.start : slot.deadline
    }
}

private extension BookedSlot {
    var activityAttributes: LaundryActivityAttributes {
        LaundryActivityAttributes(
            bookingId: id,
            machines: machines,
            location: location,
            startTime: startTime,
            endTime: endTime,
            startAt: start
        )
    }
}
