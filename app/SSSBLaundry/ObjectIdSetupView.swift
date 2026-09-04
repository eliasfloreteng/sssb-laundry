//
//  ObjectIdSetupView.swift
//  SSSBLaundry
//

import SwiftUI

struct ObjectIdSetupView: View {
    @AppStorage(ObjectIdStore.key) private var storedObjectId: String = ""
    @State private var draft: String = ""
    /// Set once the clipboard has been asked, by patterns only, whether it looks
    /// like it holds an invite.
    @State private var offeringPaste = false
    @State private var pasteMissed = false
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

                    if offeringPaste { invitePaste }

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
                                Text(verbatim: "•")
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
            // The keyboard waits for the clipboard answer: someone arriving on
            // an invite is not here to type, and throwing a keyboard over the
            // one button they need is worse than a beat of delay.
            .task {
                offeringPaste = await InviteLink.clipboardMayHoldInvite()
                focused = !offeringPaste
            }
        }
    }

    /// The other half of a deferred deep link. `PasteButton` is the only way to
    /// read a clipboard the user has not been prompted about — the tap is the
    /// permission — so the invite is offered rather than silently applied.
    private var invitePaste: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("Invited to an apartment?")
                    .font(.headline)
                Text("Paste the invite you were sent and the object number fills itself in.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            PasteButton(payloadType: String.self) { pasted in
                accept(pasted)
            }
            .labelStyle(.titleAndIcon)
            .buttonBorderShape(.capsule)

            if pasteMissed {
                Text("That was not an invite link or an object number.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 20)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 24)
    }

    private func accept(_ pasted: [String]) {
        guard let objectId = pasted.lazy.compactMap(InviteLink.objectId(fromPasted:)).first else {
            pasteMissed = true
            return
        }
        pasteMissed = false
        storedObjectId = objectId
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A whole invite link pasted into the field is as much a sign-in as the
    /// number typed by hand, so it is read for one before the raw text is taken.
    private func save() {
        let value = InviteLink.objectId(fromPasted: draft) ?? trimmedDraft
        guard !value.isEmpty else { return }
        storedObjectId = value
    }
}

#Preview {
    ObjectIdSetupView()
}
