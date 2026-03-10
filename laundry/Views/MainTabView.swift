import SwiftUI

struct MainTabView: View {
    @Environment(AuthViewModel.self) private var authVM
    @State private var bookingsVM = BookingsViewModel()
    @State private var calendarVM = CalendarViewModel()
    @State private var settingsVM = SettingsViewModel()

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
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
                    .environment(settingsVM)
            }
        }
        .task { await NotificationService.requestPermission() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Log Out") {
                    Task { await authVM.logout() }
                }
            }
        }
    }
}
