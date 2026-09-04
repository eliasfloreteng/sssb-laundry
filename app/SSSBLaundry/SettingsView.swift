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
    @AppStorage(InviteSetting.includeObjectIdKey) private var inviteIncludesObjectId: Bool = InviteSetting.defaultIncludeObjectId
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingSignOut = false
    @State private var copiedObjectId = false
    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var requestingAuthorization = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text(objectId)
                            .font(.system(.body, design: .monospaced))
                        Spacer(minLength: 12)
                        Button {
                            copy()
                        } label: {
                            Image(systemName: copiedObjectId ? "checkmark" : "doc.on.doc")
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Copy object number"))
                    }
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") { copy() }
                    }

                    Button("Sign out", role: .destructive) { confirmingSignOut = true }
                } header: {
                    Text("Object number")
                } footer: {
                    Text("From your rental agreement, and the same for everyone in your apartment. Sign out to use a different one.")
                }

                inviteSection

                if allGroups.isEmpty {
                    Section {
                        Text("No groups loaded yet.")
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Visible groups")
                    } footer: {
                        Text("Hidden groups are left out of the week list.")
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
                            // Not a ternary: mixing a literal with a `String`
                            // would infer `String` and take the verbatim
                            // overload, leaving the heading untranslated.
                            if section.location.isEmpty {
                                Text("Visible groups")
                            } else {
                                Text(section.location)
                            }
                        } footer: {
                            if index == sections.count - 1 {
                                Text("Hidden groups are left out of the week list. Useful when your address covers several buildings.")
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
                    Text("Only timeslots starting in this range are shown. It can span midnight.")
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

                laundryRoomSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Sign out?", isPresented: $confirmingSignOut) {
                Button("Cancel", role: .cancel) {}
                Button("Sign out", role: .destructive) { signOut() }
            } message: {
                Text("Your bookings stay, but this phone stops seeing them and reminders end.")
            }
            .task {
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
        }
    }

    /// One link, shared however the user likes. With the object number in it the
    /// recipient lands in this same apartment; without, it is a pointer to the
    /// app and nothing more. The number is a credential — it is username *and*
    /// password upstream — so the footer says plainly what handing it over does.
    @ViewBuilder
    private var inviteSection: some View {
        Section {
            Toggle("Include object number", isOn: $inviteIncludesObjectId)
            ShareLink(item: InviteLink.url(objectId: inviteIncludesObjectId ? objectId : nil)) {
                Label("Share invite", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("Invite others")
        } footer: {
            if inviteIncludesObjectId {
                Text("Whoever opens the link is signed in to your object number and can book and cancel for your apartment. With the app installed it signs them in on the spot; without it, the number is copied for them and TestFlight takes over.")
            } else {
                Text("The link only points at the app. They sign in with an object number of their own.")
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
                LabeledContent(
                    "Your address",
                    value: selectedRoom?.address ?? String(
                        localized: "Not set",
                        comment: "Settings value when no laundry-room address has been chosen"
                    )
                )
            }
            if let room = selectedRoom {
                LabeledContent("Laundry room", value: room.room)
                LabeledContent("Max future bookings", value: room.maxFutureBookingsLabel)
                LabeledContent("Access after a session", value: room.timeAfterBookingLabel)
                LabeledContent(room.quotaTitle, value: room.quotaLabel)
            }
        } header: {
            Text("Your laundry room")
        } footer: {
            if selectedRoom == nil {
                Text("Set your address to see SSSB's rules for your laundry room.")
            }
        }
    }

    private var selectedRoom: LaundryRoom? {
        LaundryRooms.room(id: laundryRoomId)
    }

    private var notificationsFooter: String {
        if authorizationStatus == .denied {
            return String(
                localized: "Notifications are off in iOS Settings. Turn them back on there.",
                comment: "Settings footer when the system permission has been revoked"
            )
        }
        return String(
            localized: "Reminders arrive with the app closed, and for bookings someone else in your apartment made.",
            comment: "Settings footer explaining what booking reminders cover"
        )
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

    private func copy() {
        UIPasteboard.general.string = objectId
        copiedObjectId = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copiedObjectId = false
        }
    }

    private func signOut() {
        ObjectIdStore.replace(with: nil)
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
