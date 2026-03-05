import SwiftUI

struct BookingsView: View {
    @Environment(BookingsViewModel.self) private var vm

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.bookings.isEmpty {
                    ProgressView("Loading bookings...")
                } else if vm.bookings.isEmpty {
                    ContentUnavailableView(
                        "No Bookings",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("You don't have any active bookings.")
                    )
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
