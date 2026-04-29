//
//  SlotDetailView.swift
//  sssb-laundry
//

import SwiftUI

struct SlotDetailView: View {
    let initialSlot: Slot
    @ObservedObject var vm: SlotsViewModel

    @State private var selectedGroupIds: Set<String> = []
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var showCancelConfirm = false
    @State private var showAddToCalendar = false
    @Environment(\.dismiss) private var dismiss

    /// The freshest version of the slot from the view model's list, falling
    /// back to the slot we navigated in with if it's no longer present (e.g.
    /// after a paginated reload). Reading `vm.slots` here makes the body
    /// reactive: when `book(...)` finishes and `load()` republishes, the
    /// detail view re-renders with the new `bookedByMe` / `groups` state.
    private var slot: Slot {
        vm.slots.first(where: { $0.id == initialSlot.id }) ?? initialSlot
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                hero

                card {
                    VStack(alignment: .leading, spacing: 14) {
                        groupsCardHeader
                        if showsCheckboxes {
                            Text(selectionHint)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(slot.groups) { g in
                            groupRow(g)
                            if g.id != slot.groups.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                if let successMessage {
                    Label(successMessage, systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                        .padding(.horizontal)
                }

                actionButton

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Slot")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { seedDefaultSelection() }
        .onChange(of: slot.bookableGroupIds) { _ in seedDefaultSelection() }
        .confirmationDialog(
            "Cancel this booking?",
            isPresented: $showCancelConfirm,
            titleVisibility: .visible
        ) {
            Button("Cancel booking", role: .destructive) {
                Task { await performCancel() }
            }
            Button("Keep it", role: .cancel) { }
        }
        .sheet(isPresented: $showAddToCalendar) {
            AddToCalendarSheet(
                title: calendarEventTitle,
                startsAt: slot.startsAt,
                endsAt: slot.endsAt
            ) {
                showAddToCalendar = false
            }
            .ignoresSafeArea()
        }
    }

    private var calendarEventTitle: String {
        let names = slot.groups
            .filter { $0.status == "booked-by-me" }
            .map(\.name)
            .joined(separator: ", ")
        return names.isEmpty ? "Laundry booking" : "Laundry – \(names)"
    }

    private var hero: some View {
        VStack(spacing: 8) {
            Text(dayLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(timeRange)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
            HStack(spacing: 6) {
                Image(systemName: slot.bookedByMe ? "checkmark.seal.fill" : (slot.bookable ? "sparkles" : "lock.fill"))
                Text(headerStatus)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(heroTint, in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(
            LinearGradient(
                colors: [heroTint.opacity(0.15), heroTint.opacity(0.03)],
                startPoint: .top,
                endPoint: .bottom
            ),
            in: RoundedRectangle(cornerRadius: 22)
        )
    }

    @ViewBuilder
    private var actionButton: some View {
        if slot.bookedByMe {
            VStack(spacing: 10) {
                Button {
                    showAddToCalendar = true
                } label: {
                    Label("Add to Calendar", systemImage: "calendar.badge.plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                .disabled(isWorking)

                Button(role: .destructive) {
                    showCancelConfirm = true
                } label: {
                    HStack {
                        if isWorking { ProgressView().tint(.white) } else {
                            Label("Cancel booking", systemImage: "xmark.circle.fill")
                                .font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.red, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
                }
                .disabled(isWorking)
            }
        } else if slot.bookable {
            Button {
                Task { await performBook() }
            } label: {
                HStack {
                    if isWorking { ProgressView().tint(.white) } else {
                        Label(bookButtonTitle, systemImage: "calendar.badge.plus")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    (selectedGroupIds.isEmpty ? Color.secondary : Color.accentColor),
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .foregroundStyle(.white)
            }
            .disabled(isWorking || selectedGroupIds.isEmpty)
        } else {
            Text("This slot isn't bookable right now.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
    }

    private func performBook() async {
        isWorking = true
        errorMessage = nil
        successMessage = nil
        let outcome = await vm.book(slot: slot, groupIds: orderedSelection)
        if outcome.failures.isEmpty {
            successMessage = outcome.bookedGroupNames.count <= 1
                ? "Booked! Check the Bookings tab."
                : "Booked \(outcome.bookedGroupNames.joined(separator: ", "))."
        } else if outcome.bookedGroupNames.isEmpty {
            errorMessage = outcome.failures
                .map { $0.message }
                .joined(separator: "\n")
        } else {
            successMessage = "Booked: \(outcome.bookedGroupNames.joined(separator: ", "))."
            errorMessage = outcome.failures
                .map { "\($0.groupName) — \($0.message)" }
                .joined(separator: "\n")
        }
        isWorking = false
    }

    /// Selection ordered to match `slot.groups` so the user-visible group
    /// order is preserved when iterating booking calls.
    private var orderedSelection: [String] {
        slot.groups
            .map(\.id)
            .filter { selectedGroupIds.contains($0) }
    }

    private func performCancel() async {
        isWorking = true
        errorMessage = nil
        successMessage = nil
        if let err = await vm.cancelAll(slot: slot) {
            errorMessage = err
        } else {
            successMessage = "Booking canceled."
            try? await Task.sleep(nanoseconds: 500_000_000)
            dismiss()
        }
        isWorking = false
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func statusPill(_ raw: String) -> some View {
        let (text, color): (String, Color) = {
            switch raw {
            case "bookable": return ("Free", .accentColor)
            case "booked-by-me": return ("Yours", .green)
            case "taken": return ("Taken", .secondary)
            case "past": return ("Past", .secondary)
            default: return (raw, .secondary)
            }
        }()
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var heroTint: Color {
        if slot.bookedByMe { return .green }
        if slot.bookable { return .accentColor }
        return .secondary
    }

    private var headerStatus: String {
        if slot.bookedByMe { return "Booked by you" }
        if slot.bookable { return "Available" }
        return "Unavailable"
    }

    private var dayLabel: String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = TimeZone(identifier: "Europe/Stockholm")
        guard let d = parser.date(from: slot.date) else { return slot.date }
        let f = DateFormatter()
        f.dateFormat = "EEEE · d MMM"
        f.timeZone = TimeZone(identifier: "Europe/Stockholm")
        return f.string(from: d)
    }

    private var timeRange: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(identifier: "Europe/Stockholm")
        return "\(f.string(from: slot.startsAt)) – \(f.string(from: slot.endsAt))"
    }

    private func humanStatus(_ raw: String) -> String {
        switch raw {
        case "bookable": return "Available to book"
        case "booked-by-me": return "Booked by you"
        case "taken": return "Booked by someone else"
        case "past": return "Past"
        default: return raw
        }
    }

    // MARK: - Group selection (checkboxes)

    /// Whether the merged Groups card should show interactive checkboxes.
    /// We hide them once the slot is already booked (Cancel takes over) and
    /// when there's nothing the user could plausibly book.
    private var showsCheckboxes: Bool {
        slot.bookable && !slot.bookedByMe && !slot.bookableGroupIds.isEmpty
    }

    /// Cap selections at 2 because Aptus enforces a max of 2 active bookings
    /// per tenant. If only 1 group is bookable, the cap collapses to 1.
    private var maxSelectable: Int {
        min(2, slot.bookableGroupIds.count)
    }

    private var selectionHint: String {
        let n = slot.bookableGroupIds.count
        if n == 1 { return "Tap Book to confirm." }
        if n == 2 { return "Both groups selected. Untap to skip one." }
        return "Pick up to 2 groups to book — the active-booking limit is 2."
    }

    private var bookButtonTitle: String {
        switch selectedGroupIds.count {
        case 0: return "Pick a group to book"
        case 1: return "Book this slot"
        default: return "Book \(selectedGroupIds.count) groups"
        }
    }

    @ViewBuilder
    private var groupsCardHeader: some View {
        HStack {
            Text("Groups").font(.headline)
            Spacer()
            if showsCheckboxes && maxSelectable > 1 {
                Text("\(selectedGroupIds.count) of \(maxSelectable) selected")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func groupRow(_ g: Slot.SlotGroup) -> some View {
        let isBookable = slot.bookableGroupIds.contains(g.id)
        let interactive = isBookable && showsCheckboxes
        let isSelected = selectedGroupIds.contains(g.id)
        let atCap = !isSelected && selectedGroupIds.count >= maxSelectable

        Button {
            guard interactive else { return }
            if isSelected {
                selectedGroupIds.remove(g.id)
            } else if !atCap {
                selectedGroupIds.insert(g.id)
            }
        } label: {
            HStack(spacing: 12) {
                if interactive {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(checkboxTint(isSelected: isSelected, atCap: atCap))
                        .accessibilityLabel(isSelected ? "Selected" : "Not selected")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(g.name)
                        .font(.subheadline.weight(.semibold))
                    Text(humanStatus(g.status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusPill(g.status)
            }
            .contentShape(Rectangle())
            .opacity(interactive && atCap ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!interactive)
    }

    private func checkboxTint(isSelected: Bool, atCap: Bool) -> Color {
        if isSelected { return .accentColor }
        if atCap { return .secondary.opacity(0.5) }
        return .secondary
    }

    private func seedDefaultSelection() {
        let bookable = slot.bookableGroupIds
        // Drop any stale selection (e.g. group that was bookable on first
        // load but isn't anymore after a refresh).
        selectedGroupIds = selectedGroupIds.intersection(bookable)
        guard selectedGroupIds.isEmpty else { return }
        if bookable.count <= 2 {
            selectedGroupIds = Set(bookable)
        }
        // 3+ bookable groups: leave empty, force the user to pick.
    }
}
