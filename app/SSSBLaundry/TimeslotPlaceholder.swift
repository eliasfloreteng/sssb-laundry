//
//  TimeslotPlaceholder.swift
//  SSSBLaundry
//

import SwiftUI

/// The week list with nothing in it yet: real `TimeslotRow`s over stand-in
/// timeslots, redacted. Drawing the actual row rather than a second set of grey
/// rectangles is the whole point — the placeholder is exactly as tall as what
/// replaces it, so the list stops collapsing and re-expanding around a fetch.
enum TimeslotPlaceholder {
    /// Rows for one day. Nothing here is ever read — redaction replaces every
    /// glyph — so the values only have to produce the right shapes: a time on
    /// the left, one or two group capsules beside it, a chevron on the right.
    static func slots(count: Int, day: Int = 0) -> [Timeslot] {
        (0..<count).map { index in
            // A day in 2099: `TimeslotRow` dims a slot whose start has passed,
            // and a placeholder must never come up half-faded.
            let start = String(format: "%02d", 7 + index % 12)
            let end = String(format: "%02d", 11 + index % 12)
            return Timeslot(
                id: "placeholder-\(day)-\(index)",
                startAt: "2099-01-01T\(start):00:00Z",
                endAt: "2099-01-01T\(end):00:00Z",
                localDate: "2099-01-01",
                startTime: "\(start):00",
                endTime: "\(end):00",
                spansMidnight: false,
                // Alternating one and two groups: a column of identical capsules
                // reads as a pattern rather than as content waiting to arrive.
                groups: (0...(index % 2)).map {
                    TimeslotGroup(groupId: $0 + 1, status: .bookable, canBook: true, canCancel: false)
                }
            )
        }
    }

    /// The days the list would be showing, so the redacted headers are the width
    /// of the real ones.
    static func dayLabel(offset: Int) -> String {
        let today = LaundryStore.todayInStockholm()
        return LaundryFormat.dayLabel(LaundryStore.addDays(to: today, days: offset) ?? today)
    }
}

/// The first load, before there is a week to show: about a screenful of the
/// shape the list is going to take.
struct TimeslotListPlaceholder: View {
    var days = 2
    var rowsPerDay = 4

    var body: some View {
        List {
            ForEach(0..<days, id: \.self) { day in
                Section {
                    ForEach(TimeslotPlaceholder.slots(count: rowsPerDay, day: day)) { slot in
                        TimeslotRow(timeslot: slot, groupsById: [:], hiddenGroups: [])
                    }
                } header: {
                    Text(TimeslotPlaceholder.dayLabel(offset: day))
                        .textCase(nil)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        // One announcement for the whole stand-in, rather than a screenful of
        // rows reading out times that aren't there.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading timeslots")
    }
}
