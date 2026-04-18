//
//  CalendarEvent.swift
//  sssb-laundry
//

import SwiftUI
import EventKit
import EventKitUI

struct AddToCalendarSheet: UIViewControllerRepresentable {
    let title: String
    let startsAt: Date
    let endsAt: Date
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startsAt
        event.endDate = endsAt
        event.timeZone = TimeZone(identifier: "Europe/Stockholm")
        event.addAlarm(EKAlarm(relativeOffset: -30 * 60))
        event.addAlarm(EKAlarm(relativeOffset: -5 * 60))

        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: EKEventEditViewController, context: Context) {}

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            controller.dismiss(animated: true) { [onFinish] in onFinish() }
        }
    }
}
