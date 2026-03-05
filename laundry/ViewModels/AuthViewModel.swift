import Foundation
import Observation

@Observable
final class AuthViewModel {
    var isAuthenticated = false
    var isLoading = false
    var errorMessage: String?
    var username = ""
    var password = ""
    var rememberMe = true

    private let service = AptusService.shared

    func checkSavedCredentials() async {
        if let creds = KeychainService.load() {
            username = creds.username
            password = creds.password
            await login()
        }
    }

    func login() async {
        guard !username.isEmpty, !password.isEmpty else {
            errorMessage = "Please enter your credentials."
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let success = try await service.login(username: username, password: password)
            if success {
                isAuthenticated = true
                if rememberMe {
                    KeychainService.save(username: username, password: password)
                }
            } else {
                errorMessage = "Login failed. Check your credentials."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func logout() async {
        await service.logout()
        KeychainService.delete()
        isAuthenticated = false
        password = ""
    }
}
