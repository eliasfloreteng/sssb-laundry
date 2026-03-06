import SwiftUI

struct BookingsView: View {
    @Environment(BookingsViewModel.self) private var vm

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.bookings.isEmpty {
                    ProgressView("Loading bookings...")
                } else if vm.bookings.isEmpty {
                    ScrollView {
                        ContentUnavailableView(
                            "No Bookings",
                            systemImage: "calendar.badge.exclamationmark",
                            description: Text("You don't have any active bookings.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                    }
                } else {
                    List(vm.bookings) { booking in
                        BookingCardView(booking: booking)
                    }
                }
            }
            .navigationTitle("My Bookings")
            .refreshable {
                await vm.fetchBookings()
            }
            .task {
                await vm.fetchBookings()
            }
            .overlay {
                if (vm.isLoading && !vm.bookings.isEmpty) || vm.isBooking {
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
            .alert("Booking Cancelled", isPresented: .init(
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
