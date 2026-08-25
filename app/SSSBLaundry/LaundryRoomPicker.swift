//
//  LaundryRoomPicker.swift
//  SSSBLaundry
//

import SwiftUI

/// Pick the street address SSSB lists you under. The rules that come with it are
/// informational — Aptus enforces them either way — so leaving this unset is a
/// supported state, not a half-configured app.
struct LaundryRoomPicker: View {
    @Binding var selectedId: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        List {
            Section {
                Button {
                    selectedId = ""
                    dismiss()
                } label: {
                    row(title: "Not set", subtitle: "No rules shown", isSelected: selectedId.isEmpty)
                }
                .buttonStyle(.plain)
            }

            Section {
                ForEach(matches) { room in
                    Button {
                        selectedId = room.id
                        dismiss()
                    } label: {
                        row(
                            title: room.address,
                            // Two rooms serve the same Kungshamra address under
                            // different rules, so the room is what tells them apart.
                            subtitle: "Laundry room: \(room.room)",
                            isSelected: room.id == selectedId
                        )
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("From sssb.se.")
            }
        }
        .searchable(text: $search, prompt: "Street address")
        .navigationTitle("Your address")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var matches: [LaundryRoom] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return LaundryRooms.all }
        return LaundryRooms.all.filter { room in
            room.address.localizedCaseInsensitiveContains(query)
                || room.room.localizedCaseInsensitiveContains(query)
        }
    }

    private func row(title: String, subtitle: String, isSelected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .font(.body.weight(.semibold))
            }
        }
        .contentShape(Rectangle())
    }
}
