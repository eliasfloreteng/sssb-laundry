import SwiftUI

@main
struct laundryApp: App {
    @State private var authVM = AuthViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(authVM)
        }
    }
}
