//
//  SlotDetailView.swift
//  sssb-laundry
//

import SwiftUI

struct SlotDetailView: View {
    let slot: Slot
    @ObservedObject var vm: SlotsViewModel

    @State private var preference: BookingPreference = .both
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var showCancelConfirm = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                hero

                card {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Groups")
                            .font(.headline)
                        ForEach(slot.groups) { g in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(g.name)
                                        .font(.subheadline.weight(.semibold))
                                    Text(humanStatus(g.status))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                statusPill(g.status)
                            }
                            if g.id != slot.groups.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                if slot.bookable && !slot.bookedByMe {
                    card {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Booking preference")
                                .font(.headline)
                            Text("Choose which group(s) to book. Default matches the suggestion from the server.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            Picker("Preference", selection: $preference) {
                                ForEach(BookingPreference.allCases) { p in
                                    Text(p.label).tag(p)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                if let successMessage {
                    Label(successMessage, systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                        .padding(.horizontal)
                }

                actionButton

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Slot")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let p = slot.preferred, let pref = BookingPreference(rawValue: p) {
                preference = pref
            }
        }
        .confirmationDialog(
            "Cancel this booking?",
            isPresented: $showCancelConfirm,
            titleVisibility: .visible
        ) {
            Button("Cancel booking", role: .destructive) {
                Task { await performCancel() }
            }
            Button("Keep it", role: .cancel) { }
        }
    }

    private var hero: some View {
        VStack(spacing: 8) {
            Text(dayLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(timeRange)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
            HStack(spacing: 6) {
                Image(systemName: slot.bookedByMe ? "checkmark.seal.fill" : (slot.bookable ? "sparkles" : "lock.fill"))
                Text(headerStatus)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(heroTint, in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(
            LinearGradient(
                colors: [heroTint.opacity(0.15), heroTint.opacity(0.03)],
                startPoint: .top,
                endPoint: .bottom
            ),
            in: RoundedRectangle(cornerRadius: 22)
        )
    }

    @ViewBuilder
    private var actionButton: some View {
        if slot.bookedByMe {
            Button(role: .destructive) {
                showCancelConfirm = true
            } label: {
                HStack {
                    if isWorking { ProgressView().tint(.white) } else {
                        Label("Cancel booking", systemImage: "xmark.circle.fill")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(.red, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
            }
            .disabled(isWorking)
        } else if slot.bookable {
            Button {
                Task { await performBook() }
            } label: {
                HStack {
                    if isWorking { ProgressView().tint(.white) } else {
                        Label("Book this slot", systemImage: "calendar.badge.plus")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
            }
            .disabled(isWorking)
        } else {
            Text("This slot isn't bookable right now.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
    }

    private func performBook() async {
        isWorking = true
        errorMessage = nil
        successMessage = nil
        if let err = await vm.book(slot: slot, prefer: preference) {
            errorMessage = err
        } else {
            successMessage = "Booked! Check the Bookings tab."
        }
        isWorking = false
    }

    private func performCancel() async {
        isWorking = true
        errorMessage = nil
        successMessage = nil
        if let err = await vm.cancelAll(slot: slot) {
            errorMessage = err
        } else {
            successMessage = "Booking canceled."
            try? await Task.sleep(nanoseconds: 500_000_000)
            dismiss()
        }
        isWorking = false
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func statusPill(_ raw: String) -> some View {
        let (text, color): (String, Color) = {
            switch raw {
            case "bookable": return ("Free", .accentColor)
            case "booked-by-me": return ("Yours", .green)
            case "taken": return ("Taken", .secondary)
            case "past": return ("Past", .secondary)
            default: return (raw, .secondary)
            }
        }()
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var heroTint: Color {
        if slot.bookedByMe { return .green }
        if slot.bookable { return .accentColor }
        return .secondary
    }

    private var headerStatus: String {
        if slot.bookedByMe { return "Booked by you" }
        if slot.bookable { return "Available" }
        return "Unavailable"
    }

    private var dayLabel: String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = TimeZone(identifier: "Europe/Stockholm")
        guard let d = parser.date(from: slot.date) else { return slot.date }
        let f = DateFormatter()
        f.dateFormat = "EEEE · d MMM"
        f.timeZone = TimeZone(identifier: "Europe/Stockholm")
        return f.string(from: d)
    }

    private var timeRange: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(identifier: "Europe/Stockholm")
        return "\(f.string(from: slot.startsAt)) – \(f.string(from: slot.endsAt))"
    }

    private func humanStatus(_ raw: String) -> String {
        switch raw {
        case "bookable": return "Available to book"
        case "booked-by-me": return "Booked by you"
        case "taken": return "Booked by someone else"
        case "past": return "Past"
        default: return raw
        }
    }
}
