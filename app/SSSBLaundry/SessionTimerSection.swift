//
//  SessionTimerSection.swift
//  SSSBLaundry
//

import SwiftUI

/// The timer for the session under way, at the top of the week list.
///
/// It is only there while it is any use: from the moment a booked session
/// starts until half an hour after it ends, and for as long as a timer is still
/// running whatever the booking says. Nothing upstream knows when a machine is
/// done — Aptus books the room, not the drum — so the countdown is the user's
/// own, and an AlarmKit alarm is what makes it audible from another room.
struct SessionTimerSection: View {
    /// The session the machines are running for, or `nil` once it is over — a
    /// timer already going keeps the section up either way.
    let session: BookedSlot?

    private let store = LaundryTimerStore.shared
    @State private var showingSetup = false

    var body: some View {
        if session != nil || store.timer != nil {
            Section {
                if let timer = store.timer {
                    TimerRow(timer: timer) { store.stop() }
                } else {
                    startRow
                }
            }
        }
    }

    private var startRow: some View {
        Button {
            showingSetup = true
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "timer")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                Text("Start a timer")
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // On the row rather than on the section: a modifier on a `Section` is no
        // longer a section, and the list stops laying it out as one.
        .sheet(isPresented: $showingSetup) {
            TimerSetupSheet(session: session)
        }
    }
}

private struct TimerRow: View {
    let timer: LaundryTimer
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: isRunning ? "timer" : "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(isRunning ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.green))
                .frame(width: 32)
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 2) {
                Text("Timer")
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if isRunning {
                Text(timerInterval: timer.countdownRange, countsDown: true)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 88, alignment: .trailing)
                Button(action: stop) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Cancel timer"))
            } else {
                // A rung alarm is still ringing until it is stopped, so the
                // button that stops it is the one thing worth the space.
                Button("Stop", action: stop)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var isRunning: Bool { timer.isRunning() }

    private var subtitle: String {
        let time = LaundryFormat.clockTime(timer.fireDate)
        return isRunning
            ? String(localized: "Ends \(time)", comment: "Subtitle of a running laundry timer; the placeholder is a time like \"14:32\"")
            : String(localized: "Rang \(time)", comment: "Subtitle of a laundry timer that has run out; the placeholder is a time like \"14:32\"")
    }
}
