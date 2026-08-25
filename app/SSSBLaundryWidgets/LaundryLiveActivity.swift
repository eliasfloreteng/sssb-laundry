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
                    Text(timerInterval: context.countdownRange, countsDown: true)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 84, alignment: .trailing)
                        .foregroundStyle(context.tint)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        countdownBar(context)
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
                Text(timerInterval: context.countdownRange, countsDown: true, showsHours: false)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .frame(width: 44)
                    .foregroundStyle(context.tint)
            } minimal: {
                Image(systemName: context.symbolName)
                    .foregroundStyle(context.tint)
            }
            .keylineTint(context.tint)
        }
    }

    private func countdownBar(_ context: ActivityViewContext<LaundryActivityAttributes>) -> some View {
        ProgressView(timerInterval: context.countdownRange, countsDown: true) {
            EmptyView()
        } currentValueLabel: {
            EmptyView()
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
                    Text(timerInterval: context.countdownRange, countsDown: true)
                        .font(.system(.title, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 116, alignment: .trailing)
                        .foregroundStyle(context.tint)
                    Text(context.headline)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            ProgressView(timerInterval: context.countdownRange, countsDown: true) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.linear)
            .tint(context.tint)
        }
        .padding(16)
        .activityBackgroundTint(nil)
    }

    private var subtitle: String {
        let location = context.attributes.location
        return location.isEmpty ? context.slotLabel : "\(location) · \(context.slotLabel)"
    }
}

extension ActivityViewContext where Attributes == LaundryActivityAttributes {
    /// The app pushes the phase while it is running, but it is normally
    /// suspended by the time the slot starts — the stale date (set to the start)
    /// is what actually flips the countdown over on a locked phone.
    var resolvedPhase: LaundryActivityAttributes.Phase {
        (state.phase == .grace || isStale) ? .grace : .upcoming
    }

    /// Both bounds come from the booking itself, never from `Date.now`, so the
    /// range can't invert while the system is re-rendering.
    var countdownRange: ClosedRange<Date> {
        switch resolvedPhase {
        case .upcoming:
            return attributes.startAt.addingTimeInterval(-laundryActivityLeadWindow)...attributes.startAt
        case .grace:
            return attributes.startAt...attributes.deadline
        }
    }

    var headline: String {
        switch resolvedPhase {
        case .upcoming: return "until your session starts"
        case .grace: return "to tag in"
        }
    }

    var symbolName: String {
        resolvedPhase == .grace ? "exclamationmark.triangle.fill" : "washer.fill"
    }

    var tint: Color {
        resolvedPhase == .grace ? .orange : .accentColor
    }

    var slotLabel: String {
        "\(attributes.startTime) – \(attributes.endTime)"
    }
}
