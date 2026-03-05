import SwiftUI

struct MainTabView: View {
    @Environment(AuthViewModel.self) private var authVM
    @State private var bookingsVM = BookingsViewModel()
    @State private var calendarVM = CalendarViewModel()

    var body: some View {
        TabView {
            Tab("Bookings", systemImage: "calendar.badge.clock") {
                BookingsView()
                    .environment(bookingsVM)
            }
            Tab("Quick Book", systemImage: "bolt.fill") {
                FirstAvailableView()
                    .environment(calendarVM)
            }
            Tab("Calendar", systemImage: "calendar") {
                WeekCalendarView()
                    .environment(calendarVM)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Log Out") {
                    Task { await authVM.logout() }
                }
            }
        }
    }
}
