//
//  ProfileView.swift
//  sssb-laundry
//

import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var session: Session
    @State private var showSignOutConfirm = false
    @AppStorage("activeHoursStart") private var activeHoursStart: Int = 0
    @AppStorage("activeHoursEnd") private var activeHoursEnd: Int = 24

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

                    Section {
                        Picker("From", selection: $activeHoursStart) {
                            ForEach(0..<24) { h in
                                Text(hourLabel(h)).tag(h)
                            }
                        }
                        Picker("To", selection: $activeHoursEnd) {
                            ForEach(1...24, id: \.self) { h in
                                Text(hourLabel(h)).tag(h)
                            }
                        }
                        if activeHoursStart >= activeHoursEnd {
                            Label("End must be after start.", systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    } header: {
                        Text("Active hours")
                    } footer: {
                        Text("Slots outside these hours are hidden. Set 00:00–24:00 to show all.")
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

    private func hourLabel(_ hour: Int) -> String {
        String(format: "%02d:00", hour == 24 ? 24 : hour)
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
