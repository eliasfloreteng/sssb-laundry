//
//  LaundryActivityAttributes.swift
//  SSSBLaundry
//
//  Shared by the app and the widget extension.
//

import ActivityKit
import Foundation

/// How long a booking survives after its start before Aptus releases it again.
let laundryGracePeriod: TimeInterval = 15 * 60

/// How early a booking is allowed to put a Live Activity on the Lock Screen.
let laundryActivityLeadWindow: TimeInterval = 60 * 60

struct LaundryActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: Phase
        /// The timer running for this booking, once the user has started one.
        var timer: LaundryTimer?

        init(phase: Phase, timer: LaundryTimer? = nil) {
            self.phase = phase
            self.timer = timer
        }

        /// Hand-written so that an activity started by an older build — whose
        /// stored state has no timer in it at all — still decodes instead of
        /// leaving a dead card on the Lock Screen.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            phase = try container.decode(Phase.self, forKey: .phase)
            timer = try container.decodeIfPresent(LaundryTimer.self, forKey: .timer)
        }
    }

    enum Phase: String, Codable, Hashable {
        /// Counting down to the timeslot start.
        case upcoming
        /// Started; counting down the 15 minutes before it is released.
        case grace
    }

    /// Derived from the timeslot start and the booked groups rather than the
    /// opaque `timeslotId`, which must not be persisted across server changes.
    var bookingId: String
    /// Aptus group names, already joined for display.
    var machines: String
    var location: String
    /// `HH:mm` in Europe/Stockholm, straight from the API — never re-derived
    /// from `startAt` in the local timezone.
    var startTime: String
    var endTime: String
    var startAt: Date

    /// When Aptus releases the session again if it has not been activated.
    var deadline: Date { startAt.addingTimeInterval(laundryGracePeriod) }
}
