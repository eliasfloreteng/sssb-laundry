//
//  TimeslotRow.swift
//  SSSBLaundry
//

import SwiftUI

struct TimeslotRow: View {
    let timeslot: Timeslot
    let groupsById: [Int: LaundryGroup]
    let hiddenGroups: Set<Int>
    let groupNamePrefix: String

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

            FlowChips(items: activeGroups, groupsById: groupsById, groupNamePrefix: groupNamePrefix)

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

    private var activeGroups: [TimeslotGroup] {
        timeslot.groups.filter { !hiddenGroups.contains($0.groupId) }
    }

    private var hasOwn: Bool {
        activeGroups.contains { $0.status == .own }
    }

    private var hasBookable: Bool {
        activeGroups.contains { $0.status == .bookable }
    }

    private var allUnavailable: Bool {
        activeGroups.allSatisfy { $0.status == .unavailable }
    }
}

private struct FlowChips: View {
    let items: [TimeslotGroup]
    let groupsById: [Int: LaundryGroup]
    let groupNamePrefix: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items.filter { $0.status != .unavailable }, id: \.groupId) { item in
                    let fullName = groupsById[item.groupId]?.displayName ?? "Group \(item.groupId)"
                    let name = LaundryGroup.trimmedDisplayName(fullName, prefix: groupNamePrefix)
                    GroupChip(name: name, status: item.status)
                }
            }
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.85),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }
}
