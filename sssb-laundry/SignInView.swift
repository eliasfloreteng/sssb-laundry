//
//  SignInView.swift
//  sssb-laundry
//

import SwiftUI

struct SignInView: View {
    @EnvironmentObject private var session: Session
    @State private var objectId = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.25), Color(.systemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 16) {
                    Image(systemName: "washer.fill")
                        .font(.system(size: 58, weight: .regular))
                        .foregroundStyle(.white)
                        .frame(width: 110, height: 110)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .shadow(color: .accentColor.opacity(0.35), radius: 16, y: 8)

                    VStack(spacing: 6) {
                        Text("SSSB Laundry")
                            .font(.largeTitle.weight(.bold))
                        Text("Book a laundry time in seconds.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Apartment number")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    TextField("e.g. 12345", text: $objectId)
                        .keyboardType(.numberPad)
                        .textContentType(.username)
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit(submit)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(.background, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color(.separator), lineWidth: 0.5)
                        )

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .transition(.opacity)
                    }

                    Button(action: submit) {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("Continue")
                                    .font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            canSubmit ? Color.accentColor : Color.accentColor.opacity(0.35),
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                        .foregroundStyle(.white)
                    }
                    .disabled(!canSubmit || isLoading)
                }
                .padding(20)
                .background(.background, in: RoundedRectangle(cornerRadius: 22))
                .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
                .padding(.horizontal, 20)

                Spacer()

                Text("Your apartment number is used as your login to the SSSB booking system.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
            }
        }
        .onAppear { focused = true }
    }

    private var canSubmit: Bool {
        !objectId.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() {
        guard canSubmit, !isLoading else { return }
        focused = false
        isLoading = true
        errorMessage = nil
        Task {
            do {
                try await session.signIn(objectId: objectId)
            } catch let api as APIError {
                errorMessage = api.error.message
            } catch {
                errorMessage = "Couldn't reach the booking service. Please try again."
            }
            isLoading = false
        }
    }
}

#Preview {
    SignInView().environmentObject(Session())
}
