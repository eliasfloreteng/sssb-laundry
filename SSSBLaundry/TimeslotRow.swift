//
//  TimeslotRow.swift
//  SSSBLaundry
//

import SwiftUI

struct TimeslotRow: View {
    let timeslot: Timeslot
    let groupsById: [Int: LaundryGroup]
    let hiddenGroups: Set<Int>

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

            FlowChips(items: activeGroups, groupsById: groupsById, includeLocationInLabel: !sharesSingleLocation)

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

    private var sharesSingleLocation: Bool {
        let locations = Set(activeGroups.compactMap { groupsById[$0.groupId]?.location })
        return locations.count <= 1
    }
}

private struct FlowChips: View {
    let items: [TimeslotGroup]
    let groupsById: [Int: LaundryGroup]
    let includeLocationInLabel: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items.filter { $0.status != .unavailable }, id: \.groupId) { item in
                    GroupChip(name: label(for: item), status: item.status)
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

    private func label(for item: TimeslotGroup) -> String {
        guard let group = groupsById[item.groupId] else { return "Group \(item.groupId)" }
        if includeLocationInLabel, !group.location.isEmpty {
            return "\(group.location) · \(group.name)"
        }
        return group.name
    }
}
