//
//  EventEditView.swift
//  SSSBLaundry
//

import EventKit
import EventKitUI
import SwiftUI

struct EventEditView: UIViewControllerRepresentable {
    let store: EKEventStore
    let event: EKEvent
    let onComplete: (EKEventEditViewAction) -> Void

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let onComplete: (EKEventEditViewAction) -> Void

        init(onComplete: @escaping (EKEventEditViewAction) -> Void) {
            self.onComplete = onComplete
        }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            controller.dismiss(animated: true) { [onComplete] in
                onComplete(action)
            }
        }
    }
}
