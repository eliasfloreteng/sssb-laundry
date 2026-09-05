//
//  InviteSheet.swift
//  SSSBLaundry
//

import SwiftUI

/// Hands the link to someone else. Sharing needs no explaining, so the link
/// itself is the description — it changes as the switch does, and the one thing
/// worth a sentence is what the number in it lets the other person do.
struct InviteSheet: View {
    @AppStorage(ObjectIdStore.key) private var objectId: String = ""
    @AppStorage(InviteSetting.includeObjectIdKey) private var includesObjectId: Bool = InviteSetting.defaultIncludeObjectId
    @Environment(\.dismiss) private var dismiss

    private var url: URL {
        InviteLink.url(objectId: includesObjectId ? objectId : nil)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "person.2.badge.plus")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tint)

                Text(url.absoluteString)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Include object number", isOn: $includesObjectId)
                    if includesObjectId {
                        Text("They book and cancel as your apartment.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))

                ShareLink(item: url) {
                    Text("Share link")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                Spacer(minLength: 0)
            }
            .animation(.default, value: includesObjectId)
            .padding(24)
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    InviteSheet()
}
