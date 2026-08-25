//
//  BookingSheet.swift
//  SSSBLaundry
//

import EventKit
import EventKitUI
import SwiftUI

struct BookingSheet: View {
    let timeslot: Timeslot
    let groupsById: [Int: LaundryGroup]
    let hiddenGroups: Set<Int>
    let store: LaundryStore
    @AppStorage(LaundryRooms.selectedIdKey) private var laundryRoomId: String = ""
    @Environment(\.dismiss) private var dismiss

    @State private var selection: Set<Int> = []
    @State private var submitting = false
    @State private var addingToCalendar = false
    @State private var calendarAlert: CalendarAlert?
    @State private var pendingEvent: PendingEvent?
    @State private var feedback: ActionFeedback?

    private struct CalendarAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private struct PendingEvent: Identifiable {
        let id = UUID()
        let store: EKEventStore
        let event: EKEvent
    }

    /// What went wrong, in the words the user needs: one headline, one reason,
    /// and a line per group when the groups disagreed with each other.
    private struct ActionFeedback: Equatable {
        let title: String
        let message: String
        let details: [String]
    }

    /// The sheet stays open when something fails, so it reads the timeslot back
    /// out of the store to reflect the refresh rather than the copy it opened with.
    private var current: Timeslot {
        store.timeslot(id: timeslot.id) ?? timeslot
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)

                List {
                    let sections = locationSections
                    ForEach(Array(sections.enumerated()), id: \.element.location) { index, section in
                        Section {
                            ForEach(section.items, id: \.groupId) { item in
                                row(for: item)
                            }
                        } header: {
                            if !section.location.isEmpty {
                                Text(section.location)
                            }
                        } footer: {
                            if index == sections.count - 1 {
                                Text("Pick up to \(LaundryStore.maxGroupsPerBooking) groups — together they are one laundry session. Activate it with your Aptus tag within 15 minutes of the start, or it is released.")
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)

                footer
                    .padding(20)
                    .background(.bar)
            }
            .navigationTitle("Timeslot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if !ownGroupIds.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            addOwnBookingToCalendar()
                        } label: {
                            if addingToCalendar {
                                ProgressView()
                            } else {
                                Image(systemName: "calendar.badge.plus")
                            }
                        }
                        .disabled(addingToCalendar || submitting)
                        .accessibilityLabel("Add to Calendar")
                    }
                }
            }
            .alert(item: $calendarAlert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
            }
            .sheet(item: $pendingEvent) { pending in
                EventEditView(store: pending.store, event: pending.event) { action in
                    pendingEvent = nil
                    if action == .saved {
                        calendarAlert = CalendarAlert(
                            title: "Added to Calendar",
                            message: "\(current.localDate) \(current.startTime)–\(current.endTime)"
                        )
                    }
                }
                .ignoresSafeArea()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { selection = ownGroupIds }
        .onChange(of: ownGroupIds) { _, newValue in
            // A refresh landed (usually after a partial failure) — show what the
            // server actually holds rather than the selection that was attempted.
            selection = newValue
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(weekdayLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("\(current.startTime) – \(current.endTime)")
                    .font(.title2.bold())
                    .monospacedDigit()
            }
            Spacer()
            if current.spansMidnight {
                Label("Overnight", systemImage: "moon.stars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(for item: TimeslotGroup) -> some View {
        let name = groupsById[item.groupId]?.name ?? "Group \(item.groupId)"
        let isSelected = selection.contains(item.groupId)
        let disabled = item.status == .unavailable
        return Button {
            toggle(item)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body)
                    Text(statusLabel(for: item.status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if item.status == .own {
                    Text("Booked")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled || submitting)
        .opacity(disabled ? 0.5 : 1)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let feedback {
                notice(
                    title: feedback.title,
                    message: feedback.message,
                    details: feedback.details,
                    icon: "exclamationmark.triangle.fill",
                    tint: .red
                )
            }

            Button(action: submit) {
                HStack {
                    if submitting {
                        ProgressView()
                    }
                    Text(actionTitle)
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasChanges || submitting || overSlotLimit)

            if let limitHint {
                Text(limitHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func notice(title: String, message: String, details: [String], icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
            ForEach(details, id: \.self) { detail in
                Text("• \(detail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private var visibleGroups: [TimeslotGroup] {
        current.groups.filter { !hiddenGroups.contains($0.groupId) }
    }

    private var locationSections: [(location: String, items: [TimeslotGroup])] {
        var order: [String] = []
        var buckets: [String: [TimeslotGroup]] = [:]
        for item in visibleGroups {
            let location = groupsById[item.groupId]?.location ?? ""
            if buckets[location] == nil {
                order.append(location)
                buckets[location] = []
            }
            buckets[location]?.append(item)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private var ownGroupIds: Set<Int> {
        Set(visibleGroups.filter { $0.status == .own }.map(\.groupId))
    }

    /// Hidden groups are filtered out of the UI but still hold a booking, so
    /// the limit has to count them.
    private var ownCountInSlot: Int {
        current.groups.filter { $0.status == .own }.count
    }

    private var toBook: [Int] {
        selection.subtracting(ownGroupIds)
            .filter { id in visibleGroups.first { $0.groupId == id }?.status == .bookable }
            .sorted()
    }

    private var toCancel: [Int] {
        ownGroupIds.subtracting(selection).sorted()
    }

    private var hasChanges: Bool {
        !toBook.isEmpty || !toCancel.isEmpty
    }

    private var overSlotLimit: Bool {
        toBook.count > LaundryStore.maxGroupsPerBooking || toCancel.count > LaundryStore.maxGroupsPerBooking
    }

    /// The maximum SSSB publishes for the laundry room set in Settings. `nil`
    /// when no room is set or the room has no maximum, and then the app says
    /// nothing about a limit rather than inventing one.
    private var maxFutureSessions: Int? {
        LaundryRooms.room(id: laundryRoomId)?.maxFutureBookings
    }

    private var otherFutureSessions: Int {
        store.futureSessions(excludingTimeslot: current.id).count
    }

    /// Whether this slot would still be a *future* session after the changes.
    /// A session that has already started no longer counts against the quota —
    /// the machines may still be running, but SSSB counts bookings ahead of you.
    private var slotCountsAsFuture: Bool {
        guard let start = LaundryStore.parseISO8601(current.startAt) else { return true }
        return start > Date()
    }

    /// Future sessions the user would hold once this sheet's changes went
    /// through, counted across every day the way SSSB counts them: one per
    /// booked time, not one per group.
    private var projectedTotal: Int {
        let stillHeldHere = ownCountInSlot - toCancel.count + toBook.count > 0
        let thisSlot = (stillHeldHere && slotCountsAsFuture) ? 1 : 0
        return otherFutureSessions + thisSlot
    }

    private var overAccountLimit: Bool {
        guard let max = maxFutureSessions else { return false }
        return projectedTotal > max
    }

    /// One quiet line under the button, or nothing at all when there is neither
    /// a published limit nor a booking to report. The account limit only
    /// informs — it does not disable the button, because it is a local count of
    /// what the portal last reported: a booking that has already been
    /// auto-cancelled upstream must never be what stops the user booking again.
    private var limitHint: String? {
        if overSlotLimit {
            return "Aptus takes at most \(LaundryStore.maxGroupsPerBooking) groups in one booking."
        }
        let held = store.futureSessions.count
        guard let max = maxFutureSessions else {
            guard held > 0 else { return nil }
            return held == 1
                ? "1 future session booked."
                : "\(held) future sessions booked."
        }
        if overAccountLimit {
            return "That would be \(projectedTotal) future sessions, and your laundry room allows \(max) — SSSB may turn it down."
        }
        return "\(held) of \(max) future sessions booked."
    }

    private var actionTitle: String {
        switch (toBook.isEmpty, toCancel.isEmpty) {
        case (false, true): return toBook.count > 1 ? "Book \(toBook.count)" : "Book"
        case (true, false): return toCancel.count > 1 ? "Cancel \(toCancel.count)" : "Cancel"
        case (false, false): return "Apply changes"
        default: return "No changes"
        }
    }

    private func toggle(_ item: TimeslotGroup) {
        guard item.status != .unavailable else { return }
        feedback = nil
        if selection.contains(item.groupId) {
            selection.remove(item.groupId)
        } else {
            selection.insert(item.groupId)
        }
    }

    private func addOwnBookingToCalendar() {
        let ids = ownGroupIds.sorted()
        let names = ids.map { id in groupsById[id]?.name ?? "Group \(id)" }
        let locations = Set(ids.compactMap { groupsById[$0]?.location }.filter { !$0.isEmpty })
        let location = locations.count == 1 ? locations.first : nil
        addingToCalendar = true
        Task {
            do {
                let prepared = try await CalendarService.prepareEvent(for: current, groupNames: names, location: location)
                addingToCalendar = false
                pendingEvent = PendingEvent(store: prepared.store, event: prepared.event)
            } catch {
                addingToCalendar = false
                calendarAlert = CalendarAlert(
                    title: "Couldn’t add to Calendar",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func submit() {
        guard hasChanges, !overSlotLimit else { return }
        feedback = nil
        submitting = true
        let attempted = (book: toBook, cancel: toCancel)
        Task {
            let outcome = await store.bookAndCancel(
                timeslotId: current.id,
                toBook: attempted.book,
                toCancel: attempted.cancel
            )
            submitting = false
            guard let outcome else {
                dismiss()
                return
            }
            if outcome.isFullSuccess {
                dismiss()
            } else {
                // Stay open with the reason visible — dismissing here is what made
                // failures look like nothing had happened at all.
                feedback = makeFeedback(from: outcome, attempted: attempted)
            }
        }
    }

    private func makeFeedback(
        from outcome: ActionOutcome,
        attempted: (book: [Int], cancel: [Int])
    ) -> ActionFeedback {
        if let error = outcome.requestError {
            return ActionFeedback(
                title: ErrorPresenter.headline(for: error),
                message: ErrorPresenter.explanation(for: error),
                details: []
            )
        }

        let succeeded = outcome.results.filter(\.isSuccessful)
        // Every group gets a line, successes included — after a partial failure
        // the only thing that helps is knowing exactly where things landed.
        let details = outcome.results.map { item in
            let name = groupsById[item.groupId]?.name ?? "Group \(item.groupId)"
            return ErrorPresenter.summary(for: item.result, action: item.action, group: name)
        }

        let title: String
        let message: String
        if succeeded.isEmpty {
            let onlyCancelling = attempted.book.isEmpty
            title = onlyCancelling ? "Cancellation didn’t go through" : "Booking didn’t go through"
            message = onlyCancelling
                ? "Nothing was cancelled — your booking is unchanged."
                : "Nothing was booked — the timeslot is unchanged."
        } else {
            title = "Only part of it worked"
            message = "\(succeeded.count) of \(outcome.results.count) groups went through:"
        }
        return ActionFeedback(title: title, message: message, details: details)
    }

    private func statusLabel(for status: GroupStatus) -> String {
        switch status {
        case .bookable: return "Available"
        case .own: return "Your booking"
        case .unavailable: return "Unavailable"
        }
    }

    private var weekdayLabel: String {
        let parser = DateFormatter()
        parser.timeZone = TimeZone(identifier: "Europe/Stockholm")
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: current.localDate) else { return current.localDate }
        let printer = DateFormatter()
        printer.timeZone = TimeZone(identifier: "Europe/Stockholm")
        printer.dateFormat = "EEEE, d MMM"
        return printer.string(from: date)
    }
}
