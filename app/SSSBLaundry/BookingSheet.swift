//
//  BookingSheet.swift
//  SSSBLaundry
//

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
    @State private var calendarFlow = CalendarEventFlow()
    @State private var feedback: ActionFeedback?

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
                    ForEach(locationSections) { section in
                        Section {
                            ForEach(section.items, id: \.groupId) { item in
                                row(for: item)
                            }
                        } header: {
                            if !section.location.isEmpty {
                                Text(section.location)
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
                            if calendarFlow.isPreparing {
                                ProgressView()
                            } else {
                                Image(systemName: "calendar.badge.plus")
                            }
                        }
                        .disabled(calendarFlow.isPreparing || submitting)
                        .accessibilityLabel("Add to Calendar")
                    }
                }
            }
            .calendarEventFlow(calendarFlow)
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
                Text(current.timeRange)
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
        // Everything upstream would refuse is already off the table here, so
        // the row explains itself rather than sending a request that can only
        // come back as an error. A row with nothing in its way says nothing:
        // the checkmark is the whole state.
        let restriction = item.restriction(in: current)
        return Button {
            toggle(item)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.title3)

                Text(name)
                    .font(.body)

                Spacer()

                if let restriction {
                    Text(restriction.label(for: item.status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if item.status == .own {
                    Text("Booked")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(restriction != nil || submitting)
        .opacity(restriction != nil ? 0.5 : 1)
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

    private struct LocationSection: Identifiable {
        let location: String
        let items: [TimeslotGroup]
        var id: String { location }
    }

    private var locationSections: [LocationSection] {
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
        return order.map { LocationSection(location: $0, items: buckets[$0] ?? []) }
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
            .filter { id in
                guard let group = visibleGroups.first(where: { $0.groupId == id }) else { return false }
                return group.status == .bookable && group.restriction(in: current) == nil
            }
            .sorted()
    }

    /// A booking whose slot started while the sheet sat open drops out here, so
    /// the button goes back to "No changes" instead of sending a cancellation
    /// Aptus has already stopped accepting.
    private var toCancel: [Int] {
        ownGroupIds.subtracting(selection)
            .filter { id in visibleGroups.first(where: { $0.groupId == id })?.restriction(in: current) == nil }
            .sorted()
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
        !current.hasStarted()
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

    /// One quiet line under the button, and only when something stands in the
    /// way — a booking that is going to work says nothing at all. The account
    /// limit only informs: it does not disable the button, because it is a
    /// local count of what the portal last reported, and a booking that has
    /// already been auto-cancelled upstream must never be what stops the user
    /// booking again.
    private var limitHint: String? {
        if overSlotLimit {
            return "At most \(LaundryStore.maxGroupsPerBooking) groups per booking."
        }
        if overAccountLimit, let max = maxFutureSessions {
            return "That would be \(projectedTotal) sessions of \(max) — SSSB may turn it down."
        }
        return nil
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
        guard item.restriction(in: current) == nil else { return }
        feedback = nil
        if selection.contains(item.groupId) {
            selection.remove(item.groupId)
        } else {
            selection.insert(item.groupId)
        }
    }

    private func addOwnBookingToCalendar() {
        Task {
            await calendarFlow.add(current, groupIds: Array(ownGroupIds), groupsById: groupsById)
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
