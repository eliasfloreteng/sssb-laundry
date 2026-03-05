import SwiftUI

struct WeekCalendarView: View {
    @Environment(CalendarViewModel.self) private var vm
    @State private var actionSlot: TimeSlot?
    @State private var actionIsUnbook = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Group picker
                if vm.groups.count > 1 {
                    Picker("Group", selection: Binding(
                        get: { vm.selectedGroup?.id ?? 0 },
                        set: { id in
                            if let group = vm.groups.first(where: { $0.id == id }) {
                                Task { await vm.selectGroup(group) }
                            }
                        }
                    )) {
                        ForEach(vm.groups) { group in
                            Text(group.name).tag(group.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }

                // Week navigation
                if let calendar = vm.weekCalendar {
                    HStack {
                        Button {
                            Task { await vm.navigatePreviousWeek() }
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(calendar.previousWeekPath == nil)

                        Spacer()
                        Text(calendar.weekLabel ?? "")
                            .font(.headline)
                        Spacer()

                        Button {
                            Task { await vm.navigateNextWeek() }
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(calendar.nextWeekPath == nil)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }

                // Calendar grid
                if vm.isLoading && vm.weekCalendar == nil {
                    Spacer()
                    ProgressView("Loading calendar...")
                    Spacer()
                } else if let calendar = vm.weekCalendar {
                    calendarGrid(calendar)
                } else {
                    Spacer()
                    ContentUnavailableView(
                        "No Calendar Data",
                        systemImage: "calendar",
                        description: Text("Select a group to view the calendar.")
                    )
                    Spacer()
                }
            }
            .navigationTitle("Calendar")
            .task {
                await vm.fetchGroups()
                await vm.fetchWeekCalendar()
            }
            .confirmationDialog(
                actionIsUnbook ? "Cancel Booking" : "Confirm Booking",
                isPresented: .init(
                    get: { actionSlot != nil },
                    set: { if !$0 { actionSlot = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let slot = actionSlot {
                    if actionIsUnbook {
                        Button("Cancel Booking", role: .destructive) {
                            let s = slot
                            actionSlot = nil
                            Task { await vm.unbookFromCalendar(s) }
                        }
                    } else {
                        Button("Book \(slot.time)") {
                            let s = slot
                            actionSlot = nil
                            Task { await vm.bookFromCalendar(s) }
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    actionSlot = nil
                }
            } message: {
                if let slot = actionSlot {
                    if actionIsUnbook {
                        Text("Cancel your booking at \(slot.time)?")
                    } else {
                        Text("Book \(slot.time)?")
                    }
                }
            }
            .alert("Done", isPresented: .init(
                get: { vm.feedbackMessage != nil },
                set: { if !$0 { vm.feedbackMessage = nil } }
            )) {
                Button("OK") { vm.feedbackMessage = nil }
            } message: {
                Text(vm.feedbackMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private func calendarGrid(_ calendar: WeekCalendar) -> some View {
        ScrollView(.horizontal) {
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 2) {
                    ForEach(calendar.days) { day in
                        dayColumn(day)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder
    private func dayColumn(_ day: DayColumn) -> some View {
        VStack(spacing: 2) {
            // Day header
            VStack(spacing: 2) {
                Text(day.dayName.prefix(3))
                    .font(.caption2)
                    .fontWeight(.semibold)
                Text(day.dayOfMonth)
                    .font(.caption)
            }
            .frame(width: 50)
            .padding(.vertical, 4)

            // Time slots
            ForEach(day.slots) { slot in
                slotCell(slot)
            }
        }
    }

    @ViewBuilder
    private func slotCell(_ slot: TimeSlot) -> some View {
        let color: Color = switch slot.status {
        case .available: .green
        case .own: .blue
        case .unavailable: Color(.systemGray5)
        }

        Button {
            switch slot.status {
            case .available:
                actionIsUnbook = false
                actionSlot = slot
            case .own:
                actionIsUnbook = true
                actionSlot = slot
            case .unavailable:
                break
            }
        } label: {
            Text(shortTime(slot.time))
                .font(.system(size: 9))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 50, height: 32)
                .background(color.opacity(slot.status == .unavailable ? 0.3 : 0.7))
                .foregroundStyle(slot.status == .unavailable ? .secondary : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .disabled(slot.status == .unavailable)
    }

    private func shortTime(_ time: String) -> String {
        // "02:00 - 04:00" → "02-04"
        let parts = time.components(separatedBy: " - ")
        if parts.count == 2 {
            let start = parts[0].prefix(2)
            let end = parts[1].prefix(2)
            return "\(start)-\(end)"
        }
        return time
    }
}
