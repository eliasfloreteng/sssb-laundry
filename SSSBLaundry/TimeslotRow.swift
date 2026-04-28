//
//  TimeslotRow.swift
//  SSSBLaundry
//

import SwiftUI

struct TimeslotRow: View {
    let timeslot: Timeslot
    let groupsById: [Int: LaundryGroup]

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(timeslot.startTime)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Text(timeslot.endTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(width: 56, alignment: .leading)

            FlowChips(items: timeslot.groups, groupsById: groupsById)

            Spacer(minLength: 0)

            if hasOwn {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .font(.title3)
            } else if hasBookable {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .opacity(allUnavailable ? 0.55 : 1)
    }

    private var hasOwn: Bool {
        timeslot.groups.contains { $0.status == .own }
    }

    private var hasBookable: Bool {
        timeslot.groups.contains { $0.status == .bookable }
    }

    private var allUnavailable: Bool {
        timeslot.groups.allSatisfy { $0.status == .unavailable }
    }
}

private struct FlowChips: View {
    let items: [TimeslotGroup]
    let groupsById: [Int: LaundryGroup]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.groupId) { item in
                let name = groupsById[item.groupId]?.name ?? "Group \(item.groupId)"
                GroupChip(name: name, status: item.status)
            }
        }
    }
}
