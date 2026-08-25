//
//  LiveActivityService.swift
//  SSSBLaundry
//

import ActivityKit
import Foundation

/// Puts the nearest booking on the Lock Screen and in the Dynamic Island: a
/// countdown to the start, then the 15 minutes before Aptus releases it.
enum LiveActivityService {
    /// Fires the phase change and the ending while the app is still alive.
    private static var supervisor: Task<Void, Never>?

    /// Starts, advances or ends the activity for whichever booking the user is
    /// closest to. Runs whenever a week lands and when the app comes forward,
    /// so simply opening the app inside the lead window is what starts it.
    static func sync(slots: [BookedSlot]) async {
        supervisor?.cancel()
        supervisor = nil

        let now = Date()
        let current = slots
            .filter { now >= $0.start.addingTimeInterval(-laundryActivityLeadWindow) && now < $0.deadline }
            .min { $0.start < $1.start }

        // Everything else has either been superseded or run out of time.
        for activity in Activity<LaundryActivityAttributes>.activities
        where activity.attributes.bookingId != current?.id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        guard let current, ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let phase: LaundryActivityAttributes.Phase = now < current.start ? .upcoming : .grace
        let boundary = phase == .upcoming ? current.start : current.deadline
        // The stale date is the phase boundary: the app is normally suspended by
        // the time the slot starts, and staleness is what flips the widget over
        // to the release countdown without an update from here.
        let content = ActivityContent(
            state: LaundryActivityAttributes.ContentState(phase: phase),
            staleDate: boundary
        )

        let existing = Activity<LaundryActivityAttributes>.activities
            .first { $0.attributes.bookingId == current.id }
        if let existing {
            // Week pagination re-syncs on every page; only push a real change.
            if existing.content.state.phase != phase {
                await existing.update(content)
            }
        } else {
            _ = try? Activity.request(attributes: current.activityAttributes, content: content)
        }

        supervisor = Task {
            try? await Task.sleep(for: .seconds(max(1, boundary.timeIntervalSinceNow + 1)))
            guard !Task.isCancelled else { return }
            // Drop the handle first, otherwise the re-entrant sync cancels this
            // very task partway through.
            supervisor = nil
            await sync(slots: slots)
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
