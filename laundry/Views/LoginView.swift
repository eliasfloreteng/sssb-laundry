import SwiftUI

struct LoginView: View {
    @Environment(AuthViewModel.self) private var authVM

    var body: some View {
        @Bindable var auth = authVM
        NavigationStack {
            Form {
                Section("Credentials") {
                    TextField("Apartment ID", text: $auth.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $auth.password)
                }

                Section {
                    Toggle("Remember me", isOn: $auth.rememberMe)
                }

                if let error = authVM.errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await authVM.login() }
                    } label: {
                        if authVM.isLoading {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                        } else {
                            HStack {
                                Spacer()
                                Text("Log In")
                                    .bold()
                                Spacer()
                            }
                        }
                    }
                    .disabled(authVM.isLoading)
                }
            }
            .navigationTitle("SSSB Laundry")
        }
    }
}
