//
//  ObjectIdSetupView.swift
//  SSSBLaundry
//

import SwiftUI

struct ObjectIdSetupView: View {
    @AppStorage(ObjectIdStore.key) private var storedObjectId: String = ""
    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "washer")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.tint)

                VStack(spacing: 8) {
                    Text("Sign in")
                        .font(.largeTitle).bold()
                    Text("Enter the object id for your apartment to view and book laundry timeslots.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)

                TextField("1234-5678-901", text: $draft)
                    .font(.system(.title3, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 14)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 24)
                    .focused($focused)
                    .onSubmit(save)

                Button(action: save) {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedDraft.isEmpty)
                .padding(.horizontal, 24)

                Spacer()
                Spacer()
            }
            .background(Color(.systemBackground))
            .onAppear { focused = true }
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedDraft.isEmpty else { return }
        storedObjectId = trimmedDraft
    }
}

#Preview {
    ObjectIdSetupView()
}
