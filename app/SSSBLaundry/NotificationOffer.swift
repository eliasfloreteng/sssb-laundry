//
//  NotificationOffer.swift
//  SSSBLaundry
//

import SwiftUI

/// The one-time "turn on reminders?" ask, raised right after a booking lands.
///
/// It travels as a modifier because there are two views it can be raised from:
/// the week list, when a long press did the booking, and the booking sheet,
/// which stays open afterwards. An alert asked for by a view sitting underneath
/// a sheet is never shown, so `active` picks whichever of the two is on screen
/// — one flag, one alert, wherever the user is looking.
private struct NotificationOffer: ViewModifier {
    @Binding var isPresented: Bool
    let active: Bool
    let onAccept: () -> Void

    @AppStorage(NotificationSetting.alertKey) private var alert: BookingAlert = NotificationSetting.defaultAlert

    func body(content: Content) -> some View {
        content.alert(
            "Remind you before laundry?",
            isPresented: active ? $isPresented : .constant(false)
        ) {
            Button("Turn on reminders", action: onAccept)
            Button("Not now", role: .cancel) {}
        } message: {
            Text(message)
        }
    }

    /// Whole sentences rather than a lead phrase slotted into one: how the
    /// offset joins the sentence around it differs per language.
    private var message: String {
        switch alert {
        case .off, .atStart:
            return String(
                localized: "Get a reminder when your booking starts. Bookings are released 15 minutes after the start unless you tag in.",
                comment: "Body of the one-time offer to turn reminders on"
            )
        default:
            return String(
                localized: "Get a reminder \(alert.leadLabel) before your booking starts. Bookings are released 15 minutes after the start unless you tag in.",
                comment: "Body of the one-time offer to turn reminders on; the placeholder is a span like \"10 minutes\""
            )
        }
    }
}

extension View {
    func notificationOffer(
        isPresented: Binding<Bool>,
        active: Bool = true,
        onAccept: @escaping () -> Void
    ) -> some View {
        modifier(NotificationOffer(isPresented: isPresented, active: active, onAccept: onAccept))
    }
}
