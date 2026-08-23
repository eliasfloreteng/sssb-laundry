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
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Laundry")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showAllTimeslots.toggle()
                        } label: {
                            Image(systemName: showAllTimeslots ? "eye.fill" : "eye.slash")
                        }
                        .accessibilityLabel(showAllTimeslots ? "Show only available timeslots" : "Show all timeslots")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingSettings = true } label: {
                            Image(systemName: "person.crop.circle")
                        }
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

    private var notificationPromptMessage: String {
        let lead: String
        switch notificationAlert {
        case .off, .atStart: lead = "when your booking starts"
        default: lead = "\(notificationAlert.leadLabel) before your booking starts"
        }
        return "SSSB Laundry can notify you \(lead). Bookings are released 15 minutes after the start time if you don't start the machine."
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
                if !showAllTimeslots {
                    let hasAvailable = activeGroups.contains { $0.status != .unavailable }
                    guard hasAvailable else { return false }
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
            limitBanner

            ForEach(filteredDays, id: \.date) { day in
                Section {
                    ForEach(day.slots) { ts in
                        Button {
                            if hasAnyInteractive(ts) {
                                selectedTimeslot = ts
                            }
                        } label: {
                            TimeslotRow(timeslot: ts, groupsById: store.groupsById, hiddenGroups: hiddenGroups)
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasAnyInteractive(ts))
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
    }

    /// The two-booking limit counts across every day, so a full quota is worth
    /// a mention in the week list — quietly. It is a local count of what the
    /// portal last reported, not a rule the app enforces.
    @ViewBuilder
    private var limitBanner: some View {
        let held = store.heldBookings
        if held.count >= LaundryStore.maxActiveBookings {
            let list = held.map(\.whenLabel).formatted(.list(type: .and))
            Text("\(held.count) of \(LaundryStore.maxActiveBookings) bookings in use — \(list).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
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

    private func dayHeader(for dateString: String) -> some View {
        let parser = DateFormatter()
        parser.timeZone = TimeZone(identifier: "Europe/Stockholm")
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        let date = parser.date(from: dateString)
        let printer = DateFormatter()
        printer.timeZone = TimeZone(identifier: "Europe/Stockholm")
        printer.dateFormat = "EEEE d MMM"
        let label = date.map { printer.string(from: $0) } ?? dateString
        return Text(label)
            .textCase(nil)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
    }

    private func hasAnyInteractive(_ ts: Timeslot) -> Bool {
        let hidden = hiddenGroups
        return ts.groups.contains { !hidden.contains($0.groupId) && ($0.status == .bookable || $0.status == .own) }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No upcoming timeslots")
                .font(.headline)
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
