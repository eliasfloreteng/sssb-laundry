//
//  WeekView.swift
//  SSSBLaundry
//

import SwiftUI

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
                        groupNamePrefix: groupNamePrefix,
                        store: store
                    )
                }
                .sheet(isPresented: $showingSettings) {
                    SettingsView(allGroups: store.allGroups)
                }
                .alert(item: outcomeBinding) { outcome in
                    outcomeAlert(for: outcome)
                }
                .task {
                    await store.loadInitial()
                }
                .refreshable {
                    await store.refresh()
                }
                .onChange(of: store.authFailed) { _, failed in
                    if failed {
                        objectId = ""
                    }
                }
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

    private var groupNamePrefix: String {
        let hidden = hiddenGroups
        let visibleNames = store.allGroups
            .filter { !hidden.contains($0.id) }
            .map(\.displayName)
        return LaundryGroup.commonDisplayPrefix(visibleNames)
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
            ForEach(filteredDays, id: \.date) { day in
                Section {
                    ForEach(day.slots) { ts in
                        Button {
                            if hasAnyInteractive(ts) {
                                selectedTimeslot = ts
                            }
                        } label: {
                            TimeslotRow(timeslot: ts, groupsById: store.groupsById, hiddenGroups: hiddenGroups, groupNamePrefix: groupNamePrefix)
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
            Text(err.message)
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

    private var outcomeBinding: Binding<ActionOutcome?> {
        Binding(
            get: { store.lastOutcome },
            set: { store.lastOutcome = $0 }
        )
    }

    private func outcomeAlert(for outcome: ActionOutcome) -> Alert {
        let title: String
        switch outcome.overallStatus {
        case .success: title = "Done"
        case .partial_success: title = "Partial success"
        case .failed: title = "Failed"
        }
        let lines = outcome.results.map { r -> String in
            let name = store.groupsById[r.groupId]?.displayName ?? "Group \(r.groupId)"
            return "\(name): \(r.message ?? r.status)"
        }
        return Alert(
            title: Text(title),
            message: Text(lines.joined(separator: "\n")),
            dismissButton: .default(Text("OK"))
        )
    }
}
