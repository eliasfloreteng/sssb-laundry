//
//  ProfileView.swift
//  sssb-laundry
//

import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var session: Session
    @State private var showSignOutConfirm = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                }
                .listRowBackground(Color.clear)

                if let me = session.me {
                    Section("Account") {
                        labeledRow(title: "Apartment", value: me.objectId, icon: "house.fill")
                        if let category = me.categoryName {
                            labeledRow(title: "Category", value: category, icon: "tag.fill")
                        }
                    }

                    Section("Booking groups") {
                        if me.groups.isEmpty {
                            Text("No groups found for your account.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(me.groups) { g in
                                HStack {
                                    Image(systemName: "square.stack.3d.up.fill")
                                        .foregroundStyle(Color.accentColor)
                                    Text(g.name)
                                    Spacer()
                                    Text("#\(g.id)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showSignOutConfirm = true
                    } label: {
                        HStack {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                            Text("Sign out")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Profile")
            .task { await session.refreshMe() }
            .confirmationDialog(
                "Sign out?",
                isPresented: $showSignOutConfirm,
                titleVisibility: .visible
            ) {
                Button("Sign out", role: .destructive) { session.signOut() }
                Button("Cancel", role: .cancel) { }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "washer.fill")
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .accentColor.opacity(0.3), radius: 10, y: 4)
            Text(session.me?.objectId ?? session.objectId ?? "—")
                .font(.title2.weight(.bold))
                .monospacedDigit()
            Text("SSSB Laundry")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func labeledRow(title: String, value: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}
