//
//  BookingFeedback.swift
//  SSSBLaundry
//

import SwiftUI

extension ActionOutcome {
    /// What a finished book or cancel should feel like. Three answers rather
    /// than two: a booking action covers up to two groups and `results` can come
    /// back mixed, and half a booking must not feel like a clean one.
    var haptic: SensoryFeedback {
        if isFullSuccess { return .success }
        return results.contains(where: \.isSuccessful) ? .warning : .error
    }

    /// The failure to raise where there is no room for a per-group breakdown.
    /// The week list's context actions ask for one group at a time, so one line
    /// is the whole story; the booking sheet has room to list every group and
    /// builds its own notice instead.
    ///
    /// `nil` when nothing failed.
    func failure(groupName: (Int) -> String) -> APIError? {
        if let requestError { return requestError }
        guard let failed = failures.first else { return nil }
        return APIError.local(
            code: failed.action == .book ? "BOOKING_FAILED" : "CANCELLATION_FAILED",
            message: ErrorPresenter.summary(
                for: failed.result,
                action: failed.action,
                group: groupName(failed.groupId)
            )
        )
    }
}
