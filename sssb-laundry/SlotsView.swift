//
//  SlotsView.swift
//  sssb-laundry
//

import SwiftUI
import Combine

@MainActor
final class SlotsViewModel: ObservableObject {
    @Published var slots: [Slot] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var errorMessage: String?
    @Published var nextCursor: String?
    @Published var includeAll = false

    private var objectId: String?

    func configure(objectId: String?) {
        self.objectId = objectId
    }

    func load() async {
        guard let objectId else { return }
        isLoading = true
        errorMessage = nil
        do {
            let page = try await APIClient.shared.slots(objectId: objectId, includeAll: includeAll)
            slots = page.items
            nextCursor = page.nextCursor
        } catch let api as APIError {
            errorMessage = api.error.message
        } catch {
            errorMessage = "Couldn't load slots."
        }
        isLoading = false
    }

    func loadMoreIfNeeded(current: Slot) async {
        guard let objectId, let cursor = nextCursor, !isLoadingMore else { return }
        guard let idx = slots.firstIndex(of: current), idx >= slots.count - 6 else { return }
        isLoadingMore = true
        do {
            let page = try await APIClient.shared.slots(objectId: objectId, includeAll: includeAll, cursor: cursor)
            slots.append(contentsOf: page.items)
            nextCursor = page.nextCursor
        } catch {
            // silent; user can retry by scrolling
        }
        isLoadingMore = false
    }

    func book(slot: Slot, prefer: BookingPreference) async -> String? {
        guard let objectId else { return "Not signed in" }
        do {
            try await APIClient.shared.book(objectId: objectId, date: slot.date, passNo: slot.passNo, prefer: prefer)
            await load()
            return nil
        } catch let api as APIError {
            return api.error.message
        } catch {
            return "Booking failed."
        }
    }

    func cancelAll(slot: Slot) async -> String? {
        guard let objectId else { return "Not signed in" }
        do {
            try await APIClient.shared.cancelSlotBookings(objectId: objectId, date: slot.date, passNo: slot.passNo)
            await load()
            return nil
        } catch let api as APIError {
            return api.error.message
        } catch {
            return "Couldn't cancel booking."
        }
    }
}

struct SlotsView: View {
    @EnvironmentObject private var session: Session
    @StateObject private var vm = SlotsViewModel()
    @AppStorage("activeHoursStart") private var activeHoursStart: Int = 0
    @AppStorage("activeHoursEnd") private var activeHoursEnd: Int = 24

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.slots.isEmpty {
                    ProgressView().controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let message = vm.errorMessage, vm.slots.isEmpty {
                    ErrorState(message: message) {
                        Task { await vm.load() }
                    }
                } else if visibleSlots.isEmpty {
                    EmptyState(
                        icon: "calendar.badge.exclamationmark",
                        title: "No slots available",
                        subtitle: emptySubtitle
                    )
                } else {
                    slotList
                }
            }
            .navigationTitle("Slots")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Toggle(isOn: $vm.includeAll) {
                        Text("All")
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                }
            }
            .refreshable { await vm.load() }
            .task(id: session.objectId) {
                vm.configure(objectId: session.objectId)
                await vm.load()
            }
            .onChange(of: vm.includeAll) { _, _ in
                Task { await vm.load() }
            }
        }
    }

    private var slotList: some View {
        List {
            ForEach(groupedByDay, id: \.0) { day, slots in
                Section {
                    ForEach(slots) { slot in
                        NavigationLink(value: slot) {
                            SlotRow(slot: slot)
                        }
                        .task { await vm.loadMoreIfNeeded(current: slot) }
                    }
                } header: {
                    Text(dayHeader(for: day))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
            }
            if vm.isLoadingMore {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .navigationDestination(for: Slot.self) { slot in
            SlotDetailView(slot: slot, vm: vm)
        }
    }

    private var activeHoursEnabled: Bool {
        activeHoursStart != 0 || activeHoursEnd != 24
    }

    private var visibleSlots: [Slot] {
        guard activeHoursEnabled else { return vm.slots }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Stockholm") ?? .current
        return vm.slots.filter { slot in
            let startHour = cal.component(.hour, from: slot.startsAt)
            let endComponents = cal.dateComponents([.hour, .minute], from: slot.endsAt)
            let endHour = endComponents.hour ?? 0
            let endMinute = endComponents.minute ?? 0
            let endEffective = (endHour == 0 && endMinute == 0) ? 24 : endHour + (endMinute > 0 ? 1 : 0)

            if activeHoursStart < activeHoursEnd {
                return startHour >= activeHoursStart && endEffective <= activeHoursEnd
            } else {
                // Wrap-around: slot must fit entirely in [start, 24] OR [0, end]
                let fitsLate = startHour >= activeHoursStart && endEffective <= 24
                let fitsEarly = startHour >= 0 && endEffective <= activeHoursEnd
                return fitsLate || fitsEarly
            }
        }
    }

    private var emptySubtitle: String {
        if activeHoursEnabled && !vm.slots.isEmpty {
            return "All slots are outside your active hours. Adjust them in Profile."
        }
        return vm.includeAll ? "Nothing to show right now." : "Turn on \"Show all\" to see taken and past slots."
    }

    private var groupedByDay: [(String, [Slot])] {
        let groups = Dictionary(grouping: visibleSlots, by: { $0.date })
        return groups.keys.sorted().map { ($0, groups[$0]!.sorted { $0.startsAt < $1.startsAt }) }
    }

    private func dayHeader(for date: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = TimeZone(identifier: "Europe/Stockholm")
        guard let d = parser.date(from: date) else { return date }
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeZone = TimeZone(identifier: "Europe/Stockholm")
        if Calendar.current.isDateInToday(d) { return "Today · " + formatter.string(from: d) }
        if Calendar.current.isDateInTomorrow(d) { return "Tomorrow · " + formatter.string(from: d) }
        return formatter.string(from: d)
    }
}

struct SlotRow: View {
    let slot: Slot

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 2) {
                Text(timeOnly(slot.startsAt))
                    .font(.headline.weight(.semibold))
                    .monospacedDigit()
                Text(timeOnly(slot.endsAt))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(width: 62)
            .padding(.vertical, 10)
            .background(slotTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(statusLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(slotTint)
                Text(groupsSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if slot.bookedByMe {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else if slot.bookable {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            } else {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var slotTint: Color {
        if slot.bookedByMe { return .green }
        if slot.bookable { return .accentColor }
        return .secondary
    }

    private var statusLabel: String {
        if slot.bookedByMe { return "Booked by you" }
        if slot.bookable { return "Available" }
        return "Unavailable"
    }

    private var groupsSummary: String {
        slot.groups.map { "\($0.name) · \(humanStatus($0.status))" }.joined(separator: " • ")
    }

    private func humanStatus(_ raw: String) -> String {
        switch raw {
        case "bookable": return "free"
        case "booked-by-me": return "yours"
        case "taken": return "taken"
        case "past": return "past"
        default: return raw
        }
    }

    private func timeOnly(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(identifier: "Europe/Stockholm")
        return f.string(from: date)
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorState: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Something went wrong")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Try again", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
