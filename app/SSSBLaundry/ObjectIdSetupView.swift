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
            // Scrolls rather than compresses: with the keyboard up from the
            // first frame there is not room for both the field and the rules,
            // and a truncated rule is worse than one the user scrolls to.
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "washer")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(.tint)

                    VStack(spacing: 8) {
                        Text("Sign in")
                            .font(.largeTitle).bold()
                        Text("Enter the object number from your rental agreement.")
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

                    // SSSB's rules, on the one screen every resident sees before
                    // their first booking. The numbers that differ per laundry room
                    // are not here — those are in Settings, once an address is set.
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(BookingRules.residentRules, id: \.self) { rule in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•")
                                Text(rule)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .padding(.horizontal, 32)
                }
                .padding(.vertical, 48)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
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
