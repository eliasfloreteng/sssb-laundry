import SwiftUI

struct BookingCardView: View {
    @Environment(BookingsViewModel.self) private var vm
    let booking: Booking
    @State private var showConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(booking.time)
                        .font(.headline)
                    Text(booking.formattedDate)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(booking.group)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.blue.opacity(0.1))
                    .clipShape(Capsule())
            }

            Button(role: .destructive) {
                showConfirm = true
            } label: {
                Label("Cancel Booking", systemImage: "xmark.circle")
                    .font(.subheadline)
            }
        }
        .confirmationDialog(
            "Cancel this booking?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("Cancel Booking", role: .destructive) {
                Task { await vm.unbook(booking) }
            }
        } message: {
            Text("Do you want to cancel \(booking.time) on \(booking.formattedDate)?")
        }
    }
}
