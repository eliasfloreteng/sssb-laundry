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
    let groupNamePrefix: String
    let store: LaundryStore
    @Environment(\.dismiss) private var dismiss

    @State private var selection: Set<Int> = []
    @State private var submitting = false
    @State private var addingToCalendar = false
    @State private var calendarAlert: CalendarAlert?
    @State private var pendingEvent: PendingEvent?

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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)

                List {
                    Section {
                        ForEach(visibleGroups, id: \.groupId) { item in
                            row(for: item)
                        }
                    } footer: {
                        Text("Select up to 2 machines per booking. Bookings auto-cancel if not started within 15 minutes.")
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
                            message: "\(timeslot.localDate) \(timeslot.startTime)–\(timeslot.endTime)"
                        )
                    }
                }
                .ignoresSafeArea()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { selection = ownGroupIds }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(weekdayLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("\(timeslot.startTime) – \(timeslot.endTime)")
                    .font(.title2.bold())
                    .monospacedDigit()
            }
            Spacer()
            if timeslot.spansMidnight {
                Label("Overnight", systemImage: "moon.stars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(for item: TimeslotGroup) -> some View {
        let fullName = groupsById[item.groupId]?.displayName ?? "Group \(item.groupId)"
        let name = LaundryGroup.trimmedDisplayName(fullName, prefix: groupNamePrefix)
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
        VStack(spacing: 8) {
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
            .disabled(!hasChanges || submitting || overLimit)

            if overLimit {
                Text("Maximum 2 machines per booking or cancellation.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var visibleGroups: [TimeslotGroup] {
        timeslot.groups.filter { !hiddenGroups.contains($0.groupId) }
    }

    private var ownGroupIds: Set<Int> {
        Set(visibleGroups.filter { $0.status == .own }.map(\.groupId))
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

    private var overLimit: Bool {
        toBook.count > 2 || toCancel.count > 2
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
        if selection.contains(item.groupId) {
            selection.remove(item.groupId)
        } else {
            selection.insert(item.groupId)
        }
    }

    private func addOwnBookingToCalendar() {
        let names = ownGroupIds.sorted().map { id -> String in
            let fullName = groupsById[id]?.displayName ?? "Group \(id)"
            return LaundryGroup.trimmedDisplayName(fullName, prefix: groupNamePrefix)
        }
        addingToCalendar = true
        Task {
            do {
                let prepared = try await CalendarService.prepareEvent(for: timeslot, machineNames: names)
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
        guard hasChanges, !overLimit else { return }
        submitting = true
        Task {
            await store.bookAndCancel(timeslotId: timeslot.id, toBook: toBook, toCancel: toCancel)
            submitting = false
            dismiss()
        }
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
        guard let date = parser.date(from: timeslot.localDate) else { return timeslot.localDate }
        let printer = DateFormatter()
        printer.timeZone = TimeZone(identifier: "Europe/Stockholm")
        printer.dateFormat = "EEEE, d MMM"
        return printer.string(from: date)
    }
}
