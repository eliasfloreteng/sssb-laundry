//
//  LaundryAlarmActivity.swift
//  SSSBLaundryWidgets
//

import ActivityKit
import AlarmKit
import SwiftUI
import WidgetKit

/// The alarm's own card, the one AlarmKit puts up while a laundry timer counts
/// down and when it goes off. It is a separate Live Activity from the booking's
/// — the system owns it, draws the Stop button on it, and keeps it going while
/// the alarm rings — so all this does is dress it in the app's own words.
struct LaundryAlarmActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<LaundryAlarmMetadata>.self) { context in
            LockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.title)
                            .font(.caption)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: context.symbolName)
                            .foregroundStyle(context.attributes.tintColor)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    remaining(context, font: .system(.title3, design: .rounded).weight(.semibold))
                        .frame(width: 84, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let machines = context.attributes.metadata?.machines, !machines.isEmpty {
                        Text(machines)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                }
            } compactLeading: {
                Image(systemName: context.symbolName)
                    .foregroundStyle(context.attributes.tintColor)
            } compactTrailing: {
                remaining(context, font: .caption.weight(.semibold), showsHours: false)
                    .frame(width: 44)
            } minimal: {
                Image(systemName: context.symbolName)
                    .foregroundStyle(context.attributes.tintColor)
            }
            .keylineTint(context.attributes.tintColor)
        }
    }

    /// What is left of the countdown. A paused or ringing alarm has no range to
    /// count, so it shows its title instead.
    @ViewBuilder
    private func remaining(
        _ context: ActivityViewContext<AlarmAttributes<LaundryAlarmMetadata>>,
        font: Font,
        showsHours: Bool = true
    ) -> some View {
        if let range = context.countdownRange {
            Text(timerInterval: range, countsDown: true, showsHours: showsHours)
                .font(font)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(context.attributes.tintColor)
        } else {
            Image(systemName: "bell.fill")
                .font(font)
                .foregroundStyle(context.attributes.tintColor)
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<AlarmAttributes<LaundryAlarmMetadata>>

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: context.symbolName)
                .font(.title3)
                .foregroundStyle(context.attributes.tintColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(context.title)
                    .font(.headline)
                    .lineLimit(1)
                if let machines = context.attributes.metadata?.machines, !machines.isEmpty {
                    Text(machines)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let range = context.countdownRange {
                Text(timerInterval: range, countsDown: true)
                    .font(.system(.title, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 116, alignment: .trailing)
                    .foregroundStyle(context.attributes.tintColor)
            }
        }
        .padding(16)
        .activityBackgroundTint(nil)
    }
}

private extension ActivityViewContext where Attributes == AlarmAttributes<LaundryAlarmMetadata> {
    /// The presentation AlarmKit was handed when the alarm was scheduled, picked
    /// by the state the alarm is in now.
    var title: LocalizedStringResource {
        switch state.mode {
        case .countdown:
            attributes.presentation.countdown?.title ?? attributes.presentation.alert.title
        case .paused:
            attributes.presentation.paused?.title ?? attributes.presentation.alert.title
        case .alert:
            attributes.presentation.alert.title
        @unknown default:
            attributes.presentation.alert.title
        }
    }

    /// Bounds from the alarm itself rather than from `Date.now`, so the range
    /// can't invert while the system is re-rendering. `nil` while it rings.
    var countdownRange: ClosedRange<Date>? {
        guard case .countdown(let countdown) = state.mode,
              countdown.startDate < countdown.fireDate
        else { return nil }
        return countdown.startDate...countdown.fireDate
    }

    var symbolName: String { "timer" }
}
