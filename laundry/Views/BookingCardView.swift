import SwiftUI

struct BookingCardView: View {
    @Environment(BookingsViewModel.self) private var vm
    let booking: Booking
    @State private var showConfirm = false
    @State private var calendarMessage: String?

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

            HStack {
                Button {
                    Task {
                        let result = await CalendarExportService.addToCalendar(
                            date: booking.date, time: booking.time, groupName: booking.group
                        )
                        calendarMessage = result
                    }
                } label: {
                    Label("Add to Calendar", systemImage: "calendar.badge.plus")
                        .font(.subheadline)
                }

                Spacer()

                Button(role: .destructive) {
                    showConfirm = true
                } label: {
                    Label("Cancel Booking", systemImage: "xmark.circle")
                        .font(.subheadline)
                }
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
        .alert("Calendar", isPresented: .init(
            get: { calendarMessage != nil },
            set: { if !$0 { calendarMessage = nil } }
        )) {
            Button("OK") { calendarMessage = nil }
        } message: {
            Text(calendarMessage ?? "")
        }
    }
}
