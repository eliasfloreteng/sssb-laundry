//
//  WeekView.swift
//  SSSBLaundry
//

import SwiftUI
import UIKit
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
    @State private var calendarFlow = CalendarEventFlow()
    @State private var pendingCancel: PendingCancel?
    /// Timeslots with a long-press action in flight. Local to the list: the
    /// booking sheet reports its own progress, and this is only about the rows
    /// that act without one.
    @State private var busyTimeslots: Set<String> = []
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
                // On the list rather than in the booking sheet: the sheet is
                // already dismissing when a success lands, and a long-press
                // action never opens one at all.
                .sensoryFeedback(trigger: store.lastOutcome?.id) { _, _ in
                    store.lastOutcome?.haptic
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
                TimeslotListPlaceholder()
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
                            TimeslotRow(
                                timeslot: ts,
                                groupsById: store.groupsById,
                                hiddenGroups: hiddenGroups,
                                isBusy: busyTimeslots.contains(ts.id)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canOpen(ts) || busyTimeslots.contains(ts.id))
                        .contextMenu { rowActions(for: ts) }
                    }
                } header: {
                    dayHeader(for: day.date)
                }
            }

            footerRows
        }
        .listStyle(.insetGrouped)
        // A jump is a different list, not a scroll: rebuilding it puts the day
        // the user picked at the top instead of keeping the old offset.
        .id(store.anchorDate)
        .calendarEventFlow(calendarFlow)
        // A released session goes straight back on the board for everyone, and
        // there is no undo, so the one destructive action asks first. It sits on
        // the list rather than on `content`, which already owns an alert.
        .confirmationDialog(
            "Cancel this booking?",
            isPresented: cancelDialogBinding,
            titleVisibility: .visible,
            presenting: pendingCancel
        ) { pending in
            Button("Cancel booking", role: .destructive) {
                act(on: pending.timeslot, book: [], cancel: pending.groupIds)
            }
            Button("Keep booking", role: .cancel) {}
        } message: { pending in
            Text(pending.message)
        }
    }

    /// Long press: the two things the booking sheet exists for, without the
    /// sheet, plus the time on the clipboard. Only what Aptus would accept is
    /// offered — `actionableGroups` is the same rule the row and the sheet use —
    /// and the group is named only where the row covers more than one.
    @ViewBuilder
    private func rowActions(for ts: Timeslot) -> some View {
        let hidden = hiddenGroups
        let actionable = ts.actionableGroups(hidden: hidden)
        let named = ts.groups.filter { !hidden.contains($0.groupId) }.count > 1
        let bookable = actionable.filter { $0.status == .bookable }
        let cancellable = actionable.filter { $0.status == .own }

        // Aptus takes at most two groups in one action, so a pair is the whole
        // of what is on offer and there is never a third to leave out. Both
        // groups of one timeslot still count as a single session against the
        // room's quota, so this asks nothing more of the user's allowance than
        // booking one of them would.
        if bookable.count == LaundryStore.maxGroupsPerBooking {
            Button {
                act(on: ts, book: bookable.map(\.groupId).sorted(), cancel: [])
            } label: {
                Label("Book both", systemImage: "plus.circle.fill")
            }
        }

        ForEach(bookable, id: \.groupId) { group in
            Button {
                act(on: ts, book: [group.groupId], cancel: [])
            } label: {
                Label(named ? "Book \(groupName(group.groupId))" : "Book", systemImage: "plus.circle")
            }
        }

        if ts.hasOwnGroup(hidden: hidden) {
            Button {
                Task {
                    await calendarFlow.add(
                        ts,
                        groupIds: ownGroupIds(in: ts),
                        groupsById: store.groupsById
                    )
                }
            } label: {
                Label("Add to Calendar", systemImage: "calendar.badge.plus")
            }
        }

        Button {
            UIPasteboard.general.string = ts.dayAndTime
        } label: {
            Label("Copy time", systemImage: "doc.on.doc")
        }

        // The mirror of "Book both", and the same two reasons: Aptus releases
        // at most two groups in one action, and a slot held on both groups is
        // one session that the user almost always wants back whole.
        if cancellable.count == LaundryStore.maxGroupsPerBooking {
            Button(role: .destructive) {
                askToCancel(cancellable.map(\.groupId), in: ts, named: named)
            } label: {
                Label("Cancel both", systemImage: "xmark.circle.fill")
            }
        }

        ForEach(cancellable, id: \.groupId) { group in
            Button(role: .destructive) {
                askToCancel([group.groupId], in: ts, named: named)
            } label: {
                Label(named ? "Cancel \(groupName(group.groupId))" : "Cancel booking", systemImage: "xmark.circle")
            }
        }
    }

    /// Names what is about to be released the way the menu named it, so the
    /// confirmation is plainly about the row that was long-pressed — and in the
    /// number the user chose, since releasing both groups is one of the two
    /// things this menu offers.
    private func askToCancel(_ groupIds: [Int], in ts: Timeslot, named: Bool) {
        let ids = groupIds.sorted()
        let names = ids.map(groupName).joined(separator: " and ")
        let subject = named ? "\(names), \(ts.dayAndTime)" : ts.dayAndTime
        let plural = ids.count > 1
        pendingCancel = PendingCancel(
            timeslot: ts,
            groupIds: ids,
            message: "\(subject) \(plural ? "are" : "is") released the moment you cancel"
                + " — anyone else can book \(plural ? "them" : "it") then."
        )
    }

    /// A long-press action has nowhere of its own to report into: the row itself
    /// is the progress, the haptic is the confirmation, and a failure goes to
    /// the alert the list already owns.
    private func act(on ts: Timeslot, book: [Int], cancel: [Int]) {
        busyTimeslots.insert(ts.id)
        Task {
            let outcome = await store.bookAndCancel(timeslotId: ts.id, toBook: book, toCancel: cancel)
            busyTimeslots.remove(ts.id)
            if let failure = outcome?.failure(groupName: groupName) {
                store.lastError = failure
            }
        }
    }

    private func groupName(_ id: Int) -> String {
        store.groupsById[id]?.name ?? "Group \(id)"
    }

    private func ownGroupIds(in ts: Timeslot) -> [Int] {
        ts.groups.filter { !hiddenGroups.contains($0.groupId) && $0.status == .own }.map(\.groupId)
    }

    /// The booking a long press asked to release, held until the confirmation
    /// comes back.
    private struct PendingCancel: Identifiable {
        let id = UUID()
        let timeslot: Timeslot
        let groupIds: [Int]
        /// Written when the menu item was tapped, where what was asked for is
        /// still known.
        let message: String
    }

    @ViewBuilder
    private var footerRows: some View {
        if store.reachedEnd {
            HStack {
                Spacer()
                Text("No more timeslots")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 12)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        } else {
            // Stand-in rows rather than a spinner: the next week arrives into
            // the height its placeholder was already holding. The task runs once
            // per row, and `loadMoreIfNeeded` collapses those into one fetch.
            ForEach(TimeslotPlaceholder.slots(count: 3)) { slot in
                TimeslotRow(timeslot: slot, groupsById: [:], hiddenGroups: [])
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Loading more timeslots")
            }
            .redacted(reason: .placeholder)
            .allowsHitTesting(false)
            .task(id: store.weeks.count) {
                await store.loadMoreIfNeeded()
            }
        }
    }

    private func dayHeader(for dateString: String) -> some View {
        Text(LaundryFormat.dayLabel(dateString))
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

    /// Three different nothings, said in three different ways: a date SSSB has
    /// not opened yet is not the same answer as a week somebody else has taken
    /// every slot of.
    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptyIcon)
        } description: {
            Text(emptyMessage)
        } actions: {
            if !store.isViewingToday {
                // Without this the user is left on a list they cannot scroll
                // out of — there is nothing above the anchor to scroll to.
                Button("Back to today") {
                    Task { await store.jumpToToday() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var emptyTitle: String {
        switch store.emptyReason {
        case .beyondBookingWindow: "Not open for booking yet"
        case .nothingFree: "No free timeslots"
        case .noTimeslots: "No upcoming timeslots"
        }
    }

    private var emptyIcon: String {
        switch store.emptyReason {
        case .beyondBookingWindow: "calendar.badge.clock"
        case .nothingFree, .noTimeslots: "calendar.badge.exclamationmark"
        }
    }

    private var emptyMessage: String {
        switch store.emptyReason {
        case .beyondBookingWindow:
            "SSSB opens the laundry schedule a few weeks ahead. Nothing from \(LaundryFormat.dayLabel(store.anchorDate)) can be booked yet."
        case .nothingFree:
            "Every timeslot is taken or has already started. Pull down to refresh — a cancellation puts one back."
        case .noTimeslots:
            "Nothing is scheduled for this laundry room right now."
        }
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

    private var cancelDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingCancel != nil },
            set: { if !$0 { pendingCancel = nil } }
        )
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )
    }
}
