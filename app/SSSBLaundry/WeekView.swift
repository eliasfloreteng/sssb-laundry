//
//  WeekView.swift
//  SSSBLaundry
//

import SwiftUI
import UserNotifications

struct WeekView: View {
    @State private var store = LaundryStore()
    @State private var selectedTimeslot: Timeslot?
    @State private var showingSettings = false
    @AppStorage(ObjectIdStore.key) private var objectId: String = ""
    @AppStorage(ActiveHoursSetting.enabledKey) private var activeHoursEnabled: Bool = ActiveHoursSetting.defaultEnabled
    @AppStorage(ActiveHoursSetting.startKey) private var activeHoursStart: Int = ActiveHoursSetting.defaultStartMinutes
    @AppStorage(ActiveHoursSetting.endKey) private var activeHoursEnd: Int = ActiveHoursSetting.defaultEndMinutes
    @AppStorage(ActiveGroupsSetting.hiddenIdsKey) private var hiddenGroupsRaw: String = ""
    @AppStorage("showAllTimeslots") private var showAllTimeslots: Bool = false
    @AppStorage(NotificationSetting.enabledKey) private var notificationsEnabled: Bool = NotificationSetting.defaultEnabled
    @AppStorage(NotificationSetting.alertKey) private var notificationAlert: BookingAlert = NotificationSetting.defaultAlert
    @AppStorage(NotificationSetting.promptedKey) private var notificationsPrompted: Bool = false
    @State private var showingNotificationPrompt = false
    @State private var showingDatePicker = false
    @State private var jumpDate = Date()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Laundry")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        jumpToDateButton
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            // Named actions rather than a bare eye icon the
                            // reader has to decode; off means free timeslots
                            // within the active hours only.
                            Toggle(isOn: $showAllTimeslots) {
                                Label("Show all timeslots", systemImage: "eye")
                            }
                            Button { showingSettings = true } label: {
                                Label("Settings", systemImage: "gearshape")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("Menu")
                    }
                }
                .sheet(item: $selectedTimeslot) { ts in
                    BookingSheet(
                        timeslot: ts,
                        groupsById: store.groupsById,
                        hiddenGroups: hiddenGroups,
                        store: store
                    )
                }
                .sheet(isPresented: $showingSettings) {
                    SettingsView(allGroups: store.allGroups)
                }
                // One alert per view: SwiftUI silently drops the extras when
                // several are stacked on the same view, which is how load and
                // booking failures ended up showing nothing at all.
                .alert(
                    store.lastError.map(ErrorPresenter.headline) ?? "Something went wrong",
                    isPresented: errorAlertBinding,
                    presenting: store.lastError
                ) { _ in
                    Button("OK", role: .cancel) { store.lastError = nil }
                    Button("Try again") {
                        store.lastError = nil
                        Task { await store.refresh() }
                    }
                } message: { err in
                    Text(ErrorPresenter.explanation(for: err))
                }
                .task {
                    await store.loadInitial()
                }
                .onChange(of: store.lastOutcome?.id) { _, _ in
                    if store.lastOutcome?.didBook == true {
                        offerNotificationsAfterBooking()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    // Catches permission revoked in iOS Settings while we were away.
                    PushService.syncToServer()
                    // `Activity.request` needs the foreground, so coming forward
                    // inside the lead window is what starts the Live Activity.
                    Task { await store.syncLiveActivity() }
                }
                .refreshable {
                    await store.refresh()
                }
                .onChange(of: store.authFailed) { _, failed in
                    if failed {
                        PushService.deregister(objectId: objectId)
                        Task { await LiveActivityService.endAll() }
                        objectId = ""
                    }
                }
        }
        // Sits on the NavigationStack, not on `content`: the error alert already
        // owns that view and SwiftUI silently drops a second one.
        .alert("Remind you before laundry?", isPresented: $showingNotificationPrompt) {
            Button("Turn on reminders") { enableNotifications() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text(notificationPromptMessage)
        }
    }

    /// A calendar button rather than another entry in the menu: jumping is a
    /// navigation, and the icon carries the current position — the picker opens
    /// on whatever day the list starts at.
    @ViewBuilder
    private var jumpToDateButton: some View {
        if store.isJumping {
            ProgressView()
        } else {
            Button {
                jumpDate = LaundryStore.date(from: store.anchorDate) ?? Date()
                showingDatePicker = true
            } label: {
                Image(systemName: "calendar")
            }
            .accessibilityLabel("Jump to date")
            .popover(isPresented: $showingDatePicker) {
                datePicker
            }
        }
    }

    private var datePicker: some View {
        VStack(spacing: 8) {
            DatePicker(
                "Jump to date",
                selection: $jumpDate,
                in: jumpLowerBound...,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            if !store.isViewingToday {
                Button("Back to today") { jump(to: store.today) }
            }
        }
        // The grid is a Stockholm calendar, so the day the user taps is the day
        // the API is asked for — wherever the phone thinks it is.
        .environment(\.timeZone, LaundryStore.stockholm)
        .padding()
        .frame(minWidth: 320)
        .presentationCompactAdaptation(.popover)
        .onChange(of: jumpDate) { _, picked in
            jump(to: LaundryStore.day(from: picked))
        }
    }

    /// Aptus books nothing in the past, so yesterday is not somewhere to go.
    private var jumpLowerBound: Date {
        LaundryStore.date(from: store.today) ?? Date()
    }

    private func jump(to date: String) {
        guard date != store.anchorDate else { return }
        showingDatePicker = false
        Task { await store.jump(to: date) }
    }

    private var notificationPromptMessage: String {
        let lead: String
        switch notificationAlert {
        case .off, .atStart: lead = "when your booking starts"
        default: lead = "\(notificationAlert.leadLabel) before your booking starts"
        }
        return "Get a reminder \(lead). Bookings are released 15 minutes after the start unless you tag in."
    }

    /// Asked once, right after the first booking — that is when the reminder is
    /// worth something, so that is when we ask for permission.
    private func offerNotificationsAfterBooking() {
        guard !notificationsEnabled, !notificationsPrompted else { return }
        Task {
            guard await PushService.authorizationStatus() == .notDetermined else { return }
            // Wait out the booking sheet's dismissal — an alert raised mid-dismiss
            // is dropped without a trace.
            try? await Task.sleep(for: .milliseconds(700))
            showingNotificationPrompt = true
        }
    }

    private func enableNotifications() {
        notificationsPrompted = true
        Task {
            let granted = await PushService.requestAuthorization()
            notificationsEnabled = granted
            // The token arrives asynchronously; the delegate syncs again once it does.
            PushService.syncToServer()
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.weeks.isEmpty {
            switch store.loadState {
            case .error(let err):
                errorState(err)
            default:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if filteredDays.isEmpty && store.reachedEnd {
            emptyState
        } else {
            listView
        }
    }

    private var hiddenGroups: Set<Int> {
        ActiveGroupsSetting.parse(hiddenGroupsRaw)
    }

    private var filteredDays: [(date: String, slots: [Timeslot])] {
        let days = store.timeslotsByDay
        let hidden = hiddenGroups
        let applyActiveHours = !showAllTimeslots && activeHoursEnabled && activeHoursStart != activeHoursEnd
        return days.compactMap { day in
            let slots = day.slots.filter { ts in
                let activeGroups = ts.groups.filter { !hidden.contains($0.groupId) }
                guard !activeGroups.isEmpty else { return false }
                // A booking is never filtered away. Active hours and the
                // free-slots filter are about what is worth browsing; a time
                // the user actually holds has to be findable whatever they are
                // set to, and it stays on the list once it has started.
                if ts.hasOwnGroup(hidden: hidden) { return true }
                if !showAllTimeslots {
                    // Free but unbookable — passed, or a slot Aptus offers no
                    // button for — is noise in the browsing list.
                    guard !ts.actionableGroups(hidden: hidden).isEmpty else { return false }
                }
                if applyActiveHours {
                    return ActiveHoursSetting.includes(timeslot: ts, startMinutes: activeHoursStart, endMinutes: activeHoursEnd)
                }
                return true
            }
            return slots.isEmpty ? nil : (day.date, slots)
        }
    }

    private var listView: some View {
        List {
            ForEach(filteredDays, id: \.date) { day in
                Section {
                    ForEach(day.slots) { ts in
                        Button {
                            if canOpen(ts) {
                                selectedTimeslot = ts
                            }
                        } label: {
                            TimeslotRow(timeslot: ts, groupsById: store.groupsById, hiddenGroups: hiddenGroups)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canOpen(ts))
                    }
                } header: {
                    dayHeader(for: day.date)
                }
            }

            footerRow
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        // A jump is a different list, not a scroll: rebuilding it puts the day
        // the user picked at the top instead of keeping the old offset.
        .id(store.anchorDate)
    }

    @ViewBuilder
    private var footerRow: some View {
        if store.reachedEnd {
            HStack {
                Spacer()
                Text("No more timeslots")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 12)
        } else {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.vertical, 16)
            .task(id: store.weeks.count) {
                await store.loadMoreIfNeeded()
            }
        }
    }

    private static let dayLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = LaundryStore.stockholm
        formatter.dateFormat = "EEEE d MMM"
        return formatter
    }()

    private static func dayLabel(for dateString: String) -> String {
        LaundryStore.date(from: dateString).map { dayLabelFormatter.string(from: $0) } ?? dateString
    }

    private func dayHeader(for dateString: String) -> some View {
        Text(Self.dayLabel(for: dateString))
            .textCase(nil)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
    }

    /// A booking stays openable after it has started: nothing in the sheet can
    /// be changed any more, but it is still where the slot is added to the
    /// calendar and where the groups it covers are listed.
    private func canOpen(_ ts: Timeslot) -> Bool {
        let hidden = hiddenGroups
        return ts.hasOwnGroup(hidden: hidden) || !ts.actionableGroups(hidden: hidden).isEmpty
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            if store.isViewingToday {
                Text("No upcoming timeslots")
                    .font(.headline)
            } else {
                // Landing past the end of the window is the ordinary way a jump
                // finds nothing, so say so and offer the way back rather than
                // leaving the user on a list they cannot scroll out of.
                Text("Nothing from \(Self.dayLabel(for: store.anchorDate))")
                    .font(.headline)
                Text("SSSB only opens bookings a few weeks ahead.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Back to today") {
                    Task { await store.jumpToToday() }
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ err: APIError) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(ErrorPresenter.headline(for: err))
                .font(.headline)
            Text(ErrorPresenter.explanation(for: err))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try again") {
                Task { await store.refresh() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )
    }
}
