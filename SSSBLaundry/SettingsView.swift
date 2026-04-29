//
//  SettingsView.swift
//  SSSBLaundry
//

import SwiftUI

struct SettingsView: View {
    let allGroups: [LaundryGroup]

    @AppStorage(ObjectIdStore.key) private var objectId: String = ""
    @AppStorage(ActiveHoursSetting.enabledKey) private var activeHoursEnabled: Bool = ActiveHoursSetting.defaultEnabled
    @AppStorage(ActiveHoursSetting.startKey) private var activeHoursStart: Int = ActiveHoursSetting.defaultStartMinutes
    @AppStorage(ActiveHoursSetting.endKey) private var activeHoursEnd: Int = ActiveHoursSetting.defaultEndMinutes
    @AppStorage(ActiveGroupsSetting.hiddenIdsKey) private var hiddenGroupsRaw: String = ""
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
                    if allGroups.isEmpty {
                        Text("No groups loaded yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(allGroups) { group in
                            Toggle(group.displayName, isOn: visibilityBinding(for: group.id))
                        }
                        if !hiddenSet.isEmpty {
                            Button("Show all groups") {
                                hiddenGroupsRaw = ""
                            }
                        }
                    }
                } header: {
                    Text("Visible groups")
                } footer: {
                    Text("Only selected groups appear in the timeslot list and booking sheet. Useful when an object id covers multiple buildings.")
                }

                Section {
                    Toggle("Filter timeslots", isOn: $activeHoursEnabled)
                    if activeHoursEnabled {
                        DatePicker(
                            "From",
                            selection: startBinding,
                            displayedComponents: .hourAndMinute
                        )
                        DatePicker(
                            "To",
                            selection: endBinding,
                            displayedComponents: .hourAndMinute
                        )
                    }
                } header: {
                    Text("Active hours")
                } footer: {
                    Text("Only timeslots starting within this range are shown. The range can span midnight.")
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

    private var hiddenSet: Set<Int> {
        ActiveGroupsSetting.parse(hiddenGroupsRaw)
    }

    private func visibilityBinding(for groupId: Int) -> Binding<Bool> {
        Binding(
            get: { !hiddenSet.contains(groupId) },
            set: { isVisible in
                var set = hiddenSet
                if isVisible {
                    set.remove(groupId)
                } else {
                    set.insert(groupId)
                }
                hiddenGroupsRaw = ActiveGroupsSetting.encode(set)
            }
        )
    }

    private var startBinding: Binding<Date> {
        Binding(
            get: { Self.date(fromMinutes: activeHoursStart) },
            set: { activeHoursStart = Self.minutes(fromDate: $0) }
        )
    }

    private var endBinding: Binding<Date> {
        Binding(
            get: { Self.date(fromMinutes: activeHoursEnd) },
            set: { activeHoursEnd = Self.minutes(fromDate: $0) }
        )
    }

    private static func date(fromMinutes minutes: Int) -> Date {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .minute, value: minutes, to: startOfDay) ?? startOfDay
    }

    private static func minutes(fromDate date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}
