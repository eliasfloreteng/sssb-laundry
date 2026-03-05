import SwiftUI

struct ContentView: View {
    @Environment(AuthViewModel.self) private var authVM

    var body: some View {
        Group {
            if authVM.isAuthenticated {
                MainTabView()
            } else {
                LoginView()
            }
        }
        .task {
            await authVM.checkSavedCredentials()
        }
    }
}
