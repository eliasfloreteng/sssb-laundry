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
                .disabled(starting || duration < 60)

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

/// The Clock app's timer wheel — hours and minutes, with the units standing
/// still beside the numbers. `UIDatePicker`'s countdown mode draws the same
/// thing but refuses to rest on zero, which is where this one opens, so it is
/// rebuilt from a `UIPickerView`.
private struct DurationPicker: UIViewRepresentable {
    @Binding var duration: TimeInterval

    func makeUIView(context: Context) -> DurationPickerView {
        let picker = DurationPickerView()
        picker.dataSource = context.coordinator
        picker.delegate = context.coordinator
        select(duration, in: picker, animated: false)
        return picker
    }

    func updateUIView(_ picker: DurationPickerView, context: Context) {
        context.coordinator.duration = $duration
        // Only when it disagrees: writing the wheel's own value back to it
        // interrupts the spin the user is in the middle of.
        if abs(Coordinator.duration(of: picker) - duration) >= 1 {
            select(duration, in: picker, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(duration: $duration)
    }

    private func select(_ duration: TimeInterval, in picker: UIPickerView, animated: Bool) {
        let minutes = Int(duration / 60)
        picker.selectRow(min(minutes / 60, Coordinator.hours - 1), inComponent: 0, animated: animated)
        picker.selectRow(minutes % 60, inComponent: 1, animated: animated)
    }

    final class Coordinator: NSObject, UIPickerViewDataSource, UIPickerViewDelegate {
        static let hours = 24
        static let componentWidth: CGFloat = 100

        var duration: Binding<TimeInterval>

        init(duration: Binding<TimeInterval>) {
            self.duration = duration
        }

        static func duration(of picker: UIPickerView) -> TimeInterval {
            TimeInterval(picker.selectedRow(inComponent: 0) * 3600 + picker.selectedRow(inComponent: 1) * 60)
        }

        func numberOfComponents(in pickerView: UIPickerView) -> Int { 2 }

        func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
            component == 0 ? Self.hours : 60
        }

        func pickerView(_ pickerView: UIPickerView, widthForComponent component: Int) -> CGFloat {
            Self.componentWidth
        }

        func pickerView(
            _ pickerView: UIPickerView,
            viewForRow row: Int,
            forComponent component: Int,
            reusing view: UIView?
        ) -> UIView {
            let label = UILabel()
            label.text = row.formatted()
            label.font = .preferredFont(forTextStyle: .title2)
            // The number sits left of centre, leaving the right-hand side of
            // the column to the unit that stays put while it spins.
            label.textAlignment = .right
            let container = UIView()
            container.addSubview(label)
            label.frame = CGRect(x: 0, y: 0, width: DurationPickerView.numberWidth, height: 32)
            return container
        }

        func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
            duration.wrappedValue = Self.duration(of: pickerView)
        }
    }
}

/// The wheel with its two unit labels pinned beside the selection band, where
/// the Clock app keeps them.
private final class DurationPickerView: UIPickerView {
    static let numberWidth: CGFloat = 36

    private let unitLabels: [UILabel] = [
        String(localized: "hours", comment: "Unit beside the hours wheel of the laundry timer"),
        String(localized: "min", comment: "Unit beside the minutes wheel of the laundry timer"),
    ].map { text in
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .body).withWeight(.semibold)
        label.isUserInteractionEnabled = false
        return label
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        unitLabels.forEach(addSubview)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (component, label) in unitLabels.enumerated() {
            // The selected row's view is where UIKit put this column; the
            // unit goes just past its number.
            guard let row = view(forRow: selectedRow(inComponent: component), forComponent: component) else {
                continue
            }
            let origin = row.convert(CGPoint.zero, to: self)
            label.sizeToFit()
            label.frame.origin = CGPoint(
                x: origin.x + Self.numberWidth + 8,
                y: bounds.midY - label.bounds.height / 2
            )
            bringSubviewToFront(label)
        }
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
