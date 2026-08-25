//
//  TimeslotRow.swift
//  SSSBLaundry
//

import SwiftUI

struct TimeslotRow: View {
    let timeslot: Timeslot
    let groupsById: [Int: LaundryGroup]
    let hiddenGroups: Set<Int>
    /// An action from the long-press menu is in flight. The row is the only
    /// thing on screen that can say so — nothing else opens.
    var isBusy = false

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

            FlowChips(items: chipGroups, groupsById: groupsById, includeLocationInLabel: !sharesSingleLocation)

            Spacer(minLength: 0)

            if isBusy {
                ProgressView()
            } else if hasOwn {
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
        .opacity(isSpent ? 0.55 : 1)
    }

    private var activeGroups: [TimeslotGroup] {
        timeslot.groups.filter { !hiddenGroups.contains($0.groupId) }
    }

    /// Your own groups plus whatever can still be booked. A group that is free
    /// but no longer bookable — the slot has started, or Aptus offers no button
    /// for it — is left off rather than shown as an invitation.
    private var chipGroups: [TimeslotGroup] {
        activeGroups.filter { $0.status == .own || $0.restriction(in: timeslot) == nil }
    }

    private var hasOwn: Bool {
        activeGroups.contains { $0.status == .own }
    }

    private var hasBookable: Bool {
        !timeslot.actionableGroups(hidden: hiddenGroups).isEmpty
    }

    /// Nothing to book and nothing of yours: a row that is only there for
    /// context.
    private var isSpent: Bool {
        !hasOwn && !hasBookable
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
                ForEach(items, id: \.groupId) { item in
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
