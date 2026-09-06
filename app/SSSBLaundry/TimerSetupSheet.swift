//
//  TimerSetupSheet.swift
//  SSSBLaundry
//

import AlarmKit
import SwiftUI
import UIKit

/// How long the machine is going to take. The Clock app's timer with everything
/// the laundry room doesn't need taken off it: no seconds wheel, no saved
/// presets, no repeat — a length, and the button that starts counting.
struct TimerSetupSheet: View {
    let session: BookedSlot?

    private let store = LaundryTimerStore.shared
    @State private var duration: TimeInterval = laundryTimerDefaultDuration
    @State private var starting = false
    @State private var wasDenied = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                DurationPicker(duration: $duration)
                    .frame(maxWidth: .infinity)

                Button {
                    start()
                } label: {
                    Group {
                        if starting {
                            ProgressView()
                        } else {
                            Text("Start")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(starting)

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.visible)
        // The alarm is the whole feature, so a refusal has to be explained
        // where it happened rather than leaving the button doing nothing.
        .alert("Alarms are turned off", isPresented: $wasDenied) {
            Button("Open iOS Settings") { openSystemSettings() }
            Button("OK", role: .cancel) {}
        } message: {
            Text("SSSB Laundry needs permission to set alarms, so a timer can ring even when the phone is silenced.")
        }
    }

    private func start() {
        starting = true
        Task {
            let started = await store.start(duration: duration, session: session)
            starting = false
            if started {
                dismiss()
            } else {
                wasDenied = store.authorizationState == .denied
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// `UIDatePicker` in countdown mode, which is the Clock app's own wheel — hours
/// and minutes, with the labels beside them. SwiftUI has no equivalent, and a
/// pair of plain wheel pickers would be a worse imitation of a control the user
/// already knows.
private struct DurationPicker: UIViewRepresentable {
    @Binding var duration: TimeInterval

    func makeUIView(context: Context) -> UIDatePicker {
        let picker = UIDatePicker()
        picker.datePickerMode = .countDownTimer
        picker.minuteInterval = 1
        picker.addTarget(
            context.coordinator,
            action: #selector(Coordinator.durationChanged(_:)),
            for: .valueChanged
        )
        // UIKit ignores a countdown duration set before the picker has been
        // laid out, which is what leaves it sitting on 1 minute instead of the
        // hour it was told to open on.
        DispatchQueue.main.async {
            picker.countDownDuration = duration
        }
        return picker
    }

    func updateUIView(_ picker: UIDatePicker, context: Context) {
        context.coordinator.duration = $duration
        // Only when it disagrees: writing the wheel's own value back to it
        // interrupts the spin the user is in the middle of.
        if abs(picker.countDownDuration - duration) >= 1 {
            picker.countDownDuration = duration
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(duration: $duration)
    }

    final class Coordinator: NSObject {
        var duration: Binding<TimeInterval>

        init(duration: Binding<TimeInterval>) {
            self.duration = duration
        }

        @objc func durationChanged(_ picker: UIDatePicker) {
            duration.wrappedValue = picker.countDownDuration
        }
    }
}
