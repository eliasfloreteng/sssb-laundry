//
//  LaundryLiveActivity.swift
//  SSSBLaundryWidgets
//

import ActivityKit
import SwiftUI
import WidgetKit

struct LaundryLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LaundryActivityAttributes.self) { context in
            LockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.attributes.machines)
                            .font(.caption)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: context.symbolName)
                            .foregroundStyle(context.tint)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CountdownText(context: context, font: .system(.title3, design: .rounded).weight(.semibold))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 84, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        CountdownBar(context: context)
                        HStack {
                            Text(context.headline)
                            Spacer()
                            Text(context.slotLabel)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: context.symbolName)
                    .foregroundStyle(context.tint)
            } compactTrailing: {
                if let range = context.countdownRange {
                    Text(timerInterval: range, countsDown: true, showsHours: false)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                        .frame(width: 44)
                        .foregroundStyle(context.tint)
                } else {
                    Image(systemName: "checkmark")
                        .foregroundStyle(context.tint)
                }
            } minimal: {
                Image(systemName: context.symbolName)
                    .foregroundStyle(context.tint)
            }
            .keylineTint(context.tint)
        }
    }
}

/// Whatever the card is counting down: the booking, or the wash the user set a
/// timer for. A timer that has rung has nothing left to count, so it says so
/// instead.
private struct CountdownText: View {
    let context: ActivityViewContext<LaundryActivityAttributes>
    let font: Font

    var body: some View {
        Group {
            if let range = context.countdownRange {
                Text(timerInterval: range, countsDown: true)
            } else {
                Text("Done", comment: "Live Activity headline once a laundry timer has run out")
            }
        }
        .font(font)
        .monospacedDigit()
        .foregroundStyle(context.tint)
    }
}

private struct CountdownBar: View {
    let context: ActivityViewContext<LaundryActivityAttributes>

    var body: some View {
        Group {
            if let range = context.countdownRange {
                ProgressView(timerInterval: range, countsDown: true) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            } else {
                ProgressView(value: 1, total: 1)
            }
        }
        .progressViewStyle(.linear)
        .tint(context.tint)
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<LaundryActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: context.symbolName)
                    .font(.title3)
                    .foregroundStyle(context.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.machines)
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 1) {
                    CountdownText(context: context, font: .system(.title, design: .rounded).weight(.semibold))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 116, alignment: .trailing)
                    Text(context.headline)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            CountdownBar(context: context)
        }
        .padding(16)
        .activityBackgroundTint(nil)
    }

    private var subtitle: String {
        let location = context.attributes.location
        return location.isEmpty ? context.slotLabel : "\(location) · \(context.slotLabel)"
    }
}

/// What the card is about at this moment. A timer outranks the booking: once a
/// machine is running, the minutes left on it are the only number worth the
/// space.
enum LaundryActivityDisplay {
    case upcoming
    case grace
    case running(LaundryTimer)
    case done(LaundryTimer)
}

extension ActivityViewContext where Attributes == LaundryActivityAttributes {
    /// The app pushes the state while it is running, but it is normally
    /// suspended by the time anything changes — the stale date (set to the next
    /// boundary) is what flips the card over on a locked phone.
    var display: LaundryActivityDisplay {
        if let timer = state.timer {
            return timer.isRunning() ? .running(timer) : .done(timer)
        }
        return (state.phase == .grace || isStale) ? .grace : .upcoming
    }

    /// Both bounds come from the booking or the timer itself, never from
    /// `Date.now`, so the range can't invert while the system is re-rendering.
    /// `nil` once a timer has rung: there is nothing left to count.
    var countdownRange: ClosedRange<Date>? {
        switch display {
        case .upcoming:
            attributes.startAt.addingTimeInterval(-laundryActivityLeadWindow)...attributes.startAt
        case .grace:
            attributes.startAt...attributes.deadline
        case .running(let timer):
            timer.countdownRange
        case .done:
            nil
        }
    }

    /// The caption under the countdown, read as the tail of "12:34 …".
    var headline: String {
        switch display {
        case .upcoming:
            String(
                localized: "until your session starts",
                comment: "Caption under a Live Activity countdown to the booking's start"
            )
        case .grace:
            String(
                localized: "to tag in",
                comment: "Caption under a Live Activity countdown to the booking being released"
            )
        case .running:
            String(
                localized: "left on your timer",
                comment: "Caption under a Live Activity countdown of a running laundry timer"
            )
        case .done:
            String(
                localized: "your timer is up",
                comment: "Caption on the Live Activity once the laundry timer has rung"
            )
        }
    }

    var symbolName: String {
        switch display {
        case .upcoming: "washer.fill"
        case .grace: "exclamationmark.triangle.fill"
        case .running: "timer"
        case .done: "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch display {
        case .upcoming, .running: .accentColor
        case .grace: .orange
        case .done: .green
        }
    }

    var slotLabel: String {
        "\(attributes.startTime) – \(attributes.endTime)"
    }
}
