//
//  SettingsView.swift
//  SSSBLaundry
//

import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    let allGroups: [LaundryGroup]

    @AppStorage(ObjectIdStore.key) private var objectId: String = ""
    @AppStorage(ActiveHoursSetting.enabledKey) private var activeHoursEnabled: Bool = ActiveHoursSetting.defaultEnabled
    @AppStorage(ActiveHoursSetting.startKey) private var activeHoursStart: Int = ActiveHoursSetting.defaultStartMinutes
    @AppStorage(ActiveHoursSetting.endKey) private var activeHoursEnd: Int = ActiveHoursSetting.defaultEndMinutes
    @AppStorage(ActiveGroupsSetting.hiddenIdsKey) private var hiddenGroupsRaw: String = ""
    @AppStorage(LaundryRooms.selectedIdKey) private var laundryRoomId: String = ""
    @AppStorage(NotificationSetting.enabledKey) private var notificationsEnabled: Bool = NotificationSetting.defaultEnabled
    @AppStorage(NotificationSetting.alertKey) private var alert: BookingAlert = NotificationSetting.defaultAlert
    @AppStorage(NotificationSetting.secondAlertKey) private var secondAlert: BookingAlert = NotificationSetting.defaultSecondAlert
    @AppStorage(NotificationSetting.promptedKey) private var notificationsPrompted: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var unlocked = false
    @State private var draft: String = ""
    @State private var confirmingSignOut = false
    @FocusState private var objectIdFocused: Bool
    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var requestingAuthorization = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("1234-5678-901", text: $draft)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                            .focused($objectIdFocused)
                            .submitLabel(.done)
                            .onSubmit { commit() }
                            // Locked, the field is a plain read-only value: it can
                            // be long-pressed to copy but not tapped into.
                            .allowsHitTesting(unlocked)

                        Button {
                            if unlocked {
                                commit()
                            } else {
                                unlocked = true
                                objectIdFocused = true
                            }
                        } label: {
                            Image(systemName: unlocked ? "lock.open" : "lock")
                                .foregroundStyle(unlocked ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(unlocked ? "Lock object number" : "Unlock object number to change it")
                    }
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = objectId
                        }
                        .disabled(objectId.isEmpty)
                    }
                } header: {
                    Text("Object number")
                } footer: {
                    Text("The object number from your rental agreement — Aptus uses it as both username and password. Tap the lock to change it, or clear the field to sign out.")
                }

                laundryRoomSection

                if allGroups.isEmpty {
                    Section {
                        Text("No groups loaded yet.")
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Visible groups")
                    } footer: {
                        Text("Only selected groups appear in the timeslot list and booking sheet. Useful when an object number covers several buildings.")
                    }
                } else {
                    let sections = locationSections
                    ForEach(Array(sections.enumerated()), id: \.element.location) { index, section in
                        Section {
                            ForEach(section.groups) { group in
                                Toggle(group.name, isOn: visibilityBinding(for: group.id))
                            }
                            if index == sections.count - 1, !hiddenSet.isEmpty {
                                Button("Show all groups") {
                                    hiddenGroupsRaw = ""
                                }
                            }
                        } header: {
                            Text(section.location.isEmpty ? "Visible groups" : section.location)
                        } footer: {
                            if index == sections.count - 1 {
                                Text("Only selected groups appear in the timeslot list and booking sheet. Useful when an object number covers several buildings. Names are Aptus's own.")
                            }
                        }
                    }
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
                    Toggle("Booking reminders", isOn: notificationsEnabledBinding)
                        .disabled(requestingAuthorization)
                    if notificationsEnabled {
                        Picker("Alert", selection: $alert) {
                            ForEach(BookingAlert.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                        Picker("Second alert", selection: $secondAlert) {
                            ForEach(BookingAlert.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    if authorizationStatus == .denied {
                        Button("Open iOS Settings") { openSystemSettings() }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text(notificationsFooter)
                }

            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        commit()
                        // Leave the sheet up if commit raised the sign-out alert.
                        if !confirmingSignOut { dismiss() }
                    }
                }
            }
            .alert("Sign out?", isPresented: $confirmingSignOut) {
                Button("Cancel", role: .cancel) { draft = objectId }
                Button("Sign out", role: .destructive) { signOut() }
            } message: {
                Text("Clearing the object number signs you out. Bookings made on it stay, but this phone stops seeing them and reminders end.")
            }
            .task {
                draft = objectId
                authorizationStatus = await PushService.authorizationStatus()
                // The user may have flipped permission in iOS Settings behind our back.
                if notificationsEnabled, authorizationStatus == .denied {
                    notificationsEnabled = false
                }
                PushService.syncToServer()
            }
            // The server holds the schedule, so a changed offset has to go up
            // before it means anything.
            .onChange(of: alert) { _, _ in PushService.syncToServer() }
            .onChange(of: secondAlert) { _, _ in PushService.syncToServer() }
            // Tapping away from the field is as much a commit as hitting Done.
            .onChange(of: objectIdFocused) { _, isFocused in
                if !isFocused, unlocked { commit() }
            }
        }
    }

    /// SSSB publishes different rules per laundry room, and nothing identifies
    /// which one an object number belongs to, so the address is asked for. It
    /// stays optional: unset means the app shows no limits at all rather than
    /// asserting one that is wrong for three quarters of SSSB's addresses.
    @ViewBuilder
    private var laundryRoomSection: some View {
        Section {
            NavigationLink {
                LaundryRoomPicker(selectedId: $laundryRoomId)
            } label: {
                LabeledContent("Your address", value: selectedRoom?.address ?? "Not set")
            }
            if let room = selectedRoom {
                LabeledContent("Laundry room", value: room.room)
                LabeledContent("Max future bookings", value: room.maxFutureBookingsLabel)
                LabeledContent("Time after booking", value: room.timeAfterBookingLabel)
                LabeledContent("Max booking per week/month", value: room.quotaLabel)
            }
        } header: {
            Text("Your laundry room")
        } footer: {
            Text(selectedRoom == nil
                 ? "Set your address to see the rules SSSB publishes for your laundry room. Until then the app shows no booking limits."
                 : "The rules SSSB publishes for this address. Aptus enforces them, not the app.")
        }
    }

    private var selectedRoom: LaundryRoom? {
        LaundryRooms.room(id: laundryRoomId)
    }

    private var notificationsFooter: String {
        if authorizationStatus == .denied {
            return "Notifications are turned off for SSSB Laundry in iOS Settings. Turn them back on there to get booking reminders."
        }
        return "Reminders are sent by the server, so they arrive even if someone else books on your object number and the app is closed. A session is released 15 minutes after it starts unless you activate it with your Aptus tag."
    }

    /// Turning the toggle on is what triggers the system permission prompt.
    private var notificationsEnabledBinding: Binding<Bool> {
        Binding(
            get: { notificationsEnabled },
            set: { wantsEnabled in
                guard wantsEnabled else {
                    notificationsEnabled = false
                    PushService.deregister()
                    return
                }
                notificationsPrompted = true
                requestingAuthorization = true
                Task {
                    let status = await PushService.authorizationStatus()
                    if status == .notDetermined {
                        await PushService.requestAuthorization()
                    } else if status == .authorized {
                        PushService.registerForRemoteNotifications()
                    }
                    authorizationStatus = await PushService.authorizationStatus()
                    notificationsEnabled = authorizationStatus != .denied
                    requestingAuthorization = false
                    PushService.syncToServer()
                }
            }
        )
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Locks the field again and applies whatever is in it. An empty field means
    /// sign out, which is confirmed first so it can't happen by fumbling.
    private func commit() {
        objectIdFocused = false
        unlocked = false
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != objectId else {
            draft = objectId
            return
        }
        guard !trimmed.isEmpty else {
            confirmingSignOut = true
            return
        }
        // The server pushes per object id, so the old registration has to go or
        // this phone keeps getting reminders for an apartment it left.
        if !objectId.isEmpty {
            PushService.deregister(objectId: objectId)
            Task { await LiveActivityService.endAll() }
        }
        objectId = trimmed
        draft = trimmed
        PushService.syncToServer()
    }

    private func signOut() {
        // Deregister first: once the object id is gone the request can no longer
        // be authenticated, and the server would keep pushing to this phone.
        PushService.deregister(objectId: objectId)
        Task { await LiveActivityService.endAll() }
        objectId = ""
        draft = ""
        dismiss()
    }

    private var hiddenSet: Set<Int> {
        ActiveGroupsSetting.parse(hiddenGroupsRaw)
    }

    private var locationSections: [(location: String, groups: [LaundryGroup])] {
        var order: [String] = []
        var buckets: [String: [LaundryGroup]] = [:]
        for group in allGroups {
            if buckets[group.location] == nil {
                order.append(group.location)
                buckets[group.location] = []
            }
            buckets[group.location]?.append(group)
        }
        return order.map { ($0, buckets[$0] ?? []) }
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
