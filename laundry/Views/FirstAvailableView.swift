import SwiftUI

struct FirstAvailableView: View {
    @Environment(CalendarViewModel.self) private var vm
    @State private var bookingSlot: TimeSlot?

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoadingFirstAvailable && vm.firstAvailableSlots.isEmpty {
                    ProgressView("Loading available slots...")
                } else if vm.firstAvailableSlots.isEmpty {
                    ScrollView {
                        ContentUnavailableView(
                            "No Available Slots",
                            systemImage: "calendar.badge.exclamationmark",
                            description: Text("No slots available right now.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                    }
                } else {
                    List(vm.firstAvailableSlots) { slot in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(slot.time)
                                    .font(.headline)
                                Text(slot.date)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let group = slot.groupName {
                                Text(group)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button("Book") {
                                bookingSlot = slot
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                        }
                    }
                }
            }
            .navigationTitle("Quick Book")
            .refreshable {
                await vm.fetchFirstAvailable()
            }
            .task {
                await vm.fetchFirstAvailable()
            }
            .confirmationDialog(
                "Confirm Booking",
                isPresented: .init(
                    get: { bookingSlot != nil },
                    set: { if !$0 { bookingSlot = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let slot = bookingSlot {
                    Button("Book \(slot.time) on \(slot.date)") {
                        let s = slot
                        bookingSlot = nil
                        Task { await vm.bookFirstAvailable(s) }
                    }
                }
                Button("Cancel", role: .cancel) {
                    bookingSlot = nil
                }
            } message: {
                if let slot = bookingSlot {
                    Text("Book \(slot.time) on \(slot.date) (\(slot.groupName ?? ""))?")
                }
            }
            .overlay {
                if vm.isLoadingFirstAvailable && !vm.firstAvailableSlots.isEmpty {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.ultraThinMaterial)
                }
            }
            .alert("Error", isPresented: .init(
                get: { vm.errorMessage != nil },
                set: { if !$0 { vm.errorMessage = nil } }
            )) {
                Button("OK") { vm.errorMessage = nil }
            } message: {
                Text(vm.errorMessage ?? "")
            }
            .alert("Booked!", isPresented: .init(
                get: { vm.feedbackMessage != nil },
                set: { if !$0 { vm.feedbackMessage = nil } }
            )) {
                Button("OK") { vm.feedbackMessage = nil }
            } message: {
                Text(vm.feedbackMessage ?? "")
            }
        }
    }
}
