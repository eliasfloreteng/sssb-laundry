//
//  BookingsView.swift
//  sssb-laundry
//

import SwiftUI
import Combine

@MainActor
final class BookingsViewModel: ObservableObject {
    @Published var active: [Booking] = []
    @Published var history: [Booking] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var nextCursor: String?

    private var objectId: String?

    func configure(objectId: String?) { self.objectId = objectId }

    func load() async {
        guard let objectId else { return }
        isLoading = true
        errorMessage = nil
        async let activeCall = APIClient.shared.bookings(objectId: objectId)
        async let historyCall = APIClient.shared.bookingsHistory(objectId: objectId)
        do {
            let (a, h) = try await (activeCall, historyCall)
            active = a
            history = h.items
            nextCursor = h.nextCursor
        } catch let api as APIError {
            errorMessage = api.error.message
        } catch {
            errorMessage = "Couldn't load your bookings."
        }
        isLoading = false
    }

    func cancel(bookingId: String) async -> String? {
        guard let objectId else { return "Not signed in" }
        do {
            try await APIClient.shared.cancelBooking(objectId: objectId, bookingId: bookingId)
            await load()
            return nil
        } catch let api as APIError {
            return api.error.message
        } catch {
            return "Couldn't cancel."
        }
    }

    func loadMoreHistory() async {
        guard let objectId, let cursor = nextCursor else { return }
        do {
            let page = try await APIClient.shared.bookingsHistory(objectId: objectId, cursor: cursor)
            history.append(contentsOf: page.items)
            nextCursor = page.nextCursor
        } catch {
            // ignore
        }
    }
}

struct BookingsView: View {
    @EnvironmentObject private var session: Session
    @StateObject private var vm = BookingsViewModel()
    @State private var pendingCancel: Booking?

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.active.isEmpty && vm.history.isEmpty {
                    ProgressView().controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let message = vm.errorMessage, vm.active.isEmpty && vm.history.isEmpty {
                    ErrorState(message: message) {
                        Task { await vm.load() }
                    }
                } else {
                    listContent
                }
            }
            .navigationTitle("Bookings")
            .refreshable { await vm.load() }
            .task(id: session.objectId) {
                vm.configure(objectId: session.objectId)
                await vm.load()
            }
            .confirmationDialog(
                "Cancel booking?",
                isPresented: Binding(get: { pendingCancel != nil }, set: { if !$0 { pendingCancel = nil } }),
                titleVisibility: .visible
            ) {
                Button("Cancel booking", role: .destructive) {
                    if let b = pendingCancel {
                        Task { _ = await vm.cancel(bookingId: b.id) }
                    }
                    pendingCancel = nil
                }
                Button("Keep it", role: .cancel) { pendingCancel = nil }
            }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        List {
            Section {
                if vm.active.isEmpty {
                    emptyActiveRow
                } else {
                    ForEach(vm.active) { booking in
                        ActiveBookingRow(booking: booking) {
                            pendingCancel = booking
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingCancel = booking
                            } label: {
                                Label("Cancel", systemImage: "xmark")
                            }
                        }
                    }
                }
            } header: {
                sectionHeader("Active", systemImage: "checkmark.seal.fill")
            } footer: {
                Text("You can have up to 2 active bookings.")
                    .font(.caption)
            }

            Section {
                if vm.history.isEmpty {
                    Text("No past bookings yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.history) { booking in
                        BookingRow(booking: booking, isActive: false)
                            .task {
                                if booking.id == vm.history.last?.id {
                                    await vm.loadMoreHistory()
                                }
                            }
                    }
                }
            } header: {
                sectionHeader("History", systemImage: "clock.arrow.circlepath")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyActiveRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.plus")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("No active bookings")
                    .font(.subheadline.weight(.semibold))
                Text("Head to the Slots tab to book one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
        .textCase(nil)
    }
}

struct ActiveBookingRow: View {
    let booking: Booking
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BookingRow(booking: booking, isActive: true)

            Button(role: .destructive, action: onCancel) {
                Label("Cancel booking", systemImage: "xmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

struct BookingRow: View {
    let booking: Booking
    let isActive: Bool

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 2) {
                Text(dayNumber)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                Text(monthShort)
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 56, height: 56)
            .background(
                (isActive ? Color.accentColor : Color.secondary).opacity(0.12),
                in: RoundedRectangle(cornerRadius: 12)
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(timeRange)
                    .font(.headline)
                    .monospacedDigit()
                Text(groupLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var dayNumber: String {
        if let d = booking.slot?.startsAt {
            let f = DateFormatter()
            f.dateFormat = "d"
            f.timeZone = TimeZone(identifier: "Europe/Stockholm")
            return f.string(from: d)
        }
        if let dateString = booking.slot?.date {
            let parser = DateFormatter()
            parser.dateFormat = "yyyy-MM-dd"
            parser.timeZone = TimeZone(identifier: "Europe/Stockholm")
            if let d = parser.date(from: dateString) {
                let f = DateFormatter()
                f.dateFormat = "d"
                f.timeZone = TimeZone(identifier: "Europe/Stockholm")
                return f.string(from: d)
            }
        }
        return "—"
    }

    private var monthShort: String {
        if let d = booking.slot?.startsAt {
            let f = DateFormatter()
            f.dateFormat = "MMM"
            f.timeZone = TimeZone(identifier: "Europe/Stockholm")
            return f.string(from: d)
        }
        if let dateString = booking.slot?.date {
            let parser = DateFormatter()
            parser.dateFormat = "yyyy-MM-dd"
            parser.timeZone = TimeZone(identifier: "Europe/Stockholm")
            if let d = parser.date(from: dateString) {
                let f = DateFormatter()
                f.dateFormat = "MMM"
                f.timeZone = TimeZone(identifier: "Europe/Stockholm")
                return f.string(from: d)
            }
        }
        return ""
    }

    private var timeRange: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(identifier: "Europe/Stockholm")
        if let start = booking.slot?.startsAt, let end = booking.slot?.endsAt {
            return "\(f.string(from: start)) – \(f.string(from: end))"
        }
        if let raw = booking.rawTimeRange { return raw.replacingOccurrences(of: "-", with: " – ") }
        return booking.slot?.date ?? "—"
    }

    private var groupLine: String {
        if let g = booking.group { return g.name }
        return "Booking #\(booking.id)"
    }
}
