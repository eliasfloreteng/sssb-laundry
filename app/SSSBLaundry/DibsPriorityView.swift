//
//  DibsPriorityView.swift
//  SSSBLaundry
//

import SwiftUI

/// The user's dibs and bookings in one list, most wanted first. The order is
/// what the server acts on: when a dibs frees up and Aptus's session limit is
/// in the way, the booking ranked lowest below it is cancelled to make room.
struct DibsPriorityView: View {
    let store: LaundryStore

    @State private var order: [PriorityItem] = []
    @State private var loading = true
    @State private var saving = false
    @State private var error: APIError?

    var body: some View {
        List {
            if loading && order.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if order.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to rank", systemImage: "hand.raised")
                } description: {
                    Text("Call dibs on a taken timeslot and it shows up here, alongside your bookings.")
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(Array(order.enumerated()), id: \.element.id) { index, item in
                        row(item, rank: index + 1)
                    }
                    .onMove(perform: move)
                } footer: {
                    Text("Most wanted at the top. When a dibs frees up and you’re at your booking limit, the booking furthest below it is cancelled to make room. Nothing ranked above a dibs is ever cancelled for it.")
                }
            }
        }
        .listStyle(.insetGrouped)
        // Always sorting: reordering is the only thing this screen is for.
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Dibs priority")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if saving {
                ToolbarItem(placement: .primaryAction) { ProgressView() }
            }
        }
        .task {
            order = store.priorityItems
            await store.loadToEnd()
            order = store.priorityItems
            loading = false
        }
        .onChange(of: store.priorityItems) { _, items in
            // A save in flight owns the order until it lands or is put back.
            if !saving { order = items }
        }
        .alert(
            error.map { ErrorPresenter.headline(for: $0) } ?? ErrorPresenter.genericHeadline,
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }),
            presenting: error
        ) { _ in
            Button("OK", role: .cancel) { error = nil }
        } message: { error in
            Text(ErrorPresenter.explanation(for: error))
        }
    }

    private func row(_ item: PriorityItem, rank: Int) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: "\(rank)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.timeslot.dayAndTime)
                    .font(.body)
                    .monospacedDigit()
                Text(status(of: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: item.isBooked ? "checkmark.circle.fill" : "hand.raised.circle.fill")
                .foregroundStyle(.tint)
                .font(.title3)
        }
        .accessibilityElement(children: .combine)
    }

    /// What the user has of the slot: which machines are booked, and which
    /// they are still waiting for and where in line.
    private func status(of item: PriorityItem) -> String {
        let own = item.timeslot.groups.filter { $0.status == .own }.map(\.groupId)
        let waiting = item.dibsGroups.map(\.groupId)
        var parts: [String] = []
        if !own.isEmpty {
            parts.append(String(
                localized: "Booked: \(LaundryFormat.groupNames(own, in: store.groupsById))",
                comment: "Priority list: the machines of a timeslot the user holds"
            ))
        }
        if !waiting.isEmpty {
            let names = LaundryFormat.groupNames(waiting, in: store.groupsById)
            if let place = item.dibsGroups.compactMap(\.dibsQueue).min() {
                parts.append(String(
                    localized: "Dibs on \(names) · #\(place) in line",
                    comment: "Priority list: machines the user waits for, and their best place in line"
                ))
            } else {
                parts.append(String(
                    localized: "Dibs on \(names)",
                    comment: "Priority list: machines the user waits for"
                ))
            }
        }
        return parts.joined(separator: " · ")
    }

    private func move(from source: IndexSet, to destination: Int) {
        order.move(fromOffsets: source, toOffset: destination)
        let ids = order.map(\.id)
        saving = true
        Task {
            if let failure = await store.setPriority(ids) {
                error = failure
            }
            saving = false
            order = store.priorityItems
        }
    }
}
