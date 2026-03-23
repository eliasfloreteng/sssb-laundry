import SwiftUI

@main
struct laundryApp: App {
    @State private var authVM = AuthViewModel()

    init() {
        SlotMonitorService.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(authVM)
        }
    }
}
