//
//  SettingsView.swift
//  SSSBLaundry
//

import SwiftUI

struct SettingsView: View {
    @AppStorage(ObjectIdStore.key) private var objectId: String = ""
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var draft: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if editing {
                        TextField("1234-5678-901", text: $draft)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        Text(objectId.isEmpty ? "Not set" : objectId)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(objectId.isEmpty ? .secondary : .primary)
                    }
                } header: {
                    Text("Object id")
                } footer: {
                    Text("Used as the X-Object-Id header on every request.")
                }

                Section {
                    if editing {
                        Button("Save") { save() }
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Cancel", role: .cancel) {
                            editing = false
                            draft = objectId
                        }
                    } else {
                        Button("Change object id") {
                            draft = objectId
                            editing = true
                        }
                        Button("Sign out", role: .destructive) { signOut() }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        objectId = trimmed
        editing = false
    }

    private func signOut() {
        objectId = ""
        dismiss()
    }
}
