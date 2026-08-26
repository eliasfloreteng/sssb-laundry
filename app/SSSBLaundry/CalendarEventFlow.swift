//
//  CalendarEventFlow.swift
//  SSSBLaundry
//

import EventKit
import EventKitUI
import SwiftUI

/// Putting a booked timeslot in the system calendar: the write-only access
/// prompt, the EventKit editor the event is handed to, and the two ways it can
/// end. The booking sheet and the week list's long-press menu both run it, so it
/// lives here rather than twice.
@Observable
final class CalendarEventFlow {
    /// The editor, once access is granted and the event is built.
    var pending: PendingEvent?
    var alert: CalendarAlert?
    /// True while access is being asked for — the sheet's toolbar spins on it.
    var isPreparing = false

    /// The `EKEventStore` must outlive the `EKEvent` it made, so the two travel
    /// together.
    struct PendingEvent: Identifiable {
        let id = UUID()
        let store: EKEventStore
        let event: EKEvent
        let timeslot: Timeslot
    }

    struct CalendarAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// The event is titled with the groups it covers, and located at the laundry
    /// room only when they all share one.
    func add(_ timeslot: Timeslot, groupIds: [Int], groupsById: [Int: LaundryGroup]) async {
        let ids = groupIds.sorted()
        let names = ids.map { LaundryFormat.groupName($0, in: groupsById) }
        let locations = Set(ids.compactMap { groupsById[$0]?.location }.filter { !$0.isEmpty })
        isPreparing = true
        defer { isPreparing = false }
        do {
            let prepared = try await CalendarService.prepareEvent(
                for: timeslot,
                groupNames: names,
                location: locations.count == 1 ? locations.first : nil
            )
            pending = PendingEvent(store: prepared.store, event: prepared.event, timeslot: timeslot)
        } catch {
            alert = CalendarAlert(
                title: String(
                    localized: "Couldn’t add to Calendar",
                    comment: "Alert title when the calendar event couldn't be prepared"
                ),
                message: error.localizedDescription
            )
        }
    }
}

extension View {
    /// The editor and the two alerts a `CalendarEventFlow` can raise. Attach it
    /// to a view that owns no alert of its own: SwiftUI silently drops a second
    /// alert on the same view.
    func calendarEventFlow(_ flow: CalendarEventFlow) -> some View {
        modifier(CalendarEventFlowModifier(flow: flow))
    }
}

private struct CalendarEventFlowModifier: ViewModifier {
    @Bindable var flow: CalendarEventFlow

    func body(content: Content) -> some View {
        content
            .sheet(item: $flow.pending) { pending in
                EventEditView(store: pending.store, event: pending.event) { action in
                    flow.pending = nil
                    if action == .saved {
                        flow.alert = CalendarEventFlow.CalendarAlert(
                            title: String(
                                localized: "Added to Calendar",
                                comment: "Alert title confirming the booking was saved to the calendar"
                            ),
                            message: pending.timeslot.dayAndTime
                        )
                    }
                }
                .ignoresSafeArea()
            }
            .alert(item: $flow.alert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
    }
}
