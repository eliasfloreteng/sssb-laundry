//
//  GroupChip.swift
//  SSSBLaundry
//

import SwiftUI

struct GroupChip: View {
    let name: String
    let status: GroupStatus
    /// The user is in line for it: taken, but marked as theirs-in-waiting.
    var dibs = false

    var body: some View {
        label
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
            .overlay(
                Capsule().stroke(border, lineWidth: status == .bookable || dibs ? 1 : 0)
            )
    }

    @ViewBuilder
    private var label: some View {
        if dibs {
            Label(name, systemImage: "hand.raised.fill")
                .labelStyle(.titleAndIcon)
        } else {
            Text(name)
        }
    }

    private var background: Color {
        if dibs { return .accentColor.opacity(0.12) }
        switch status {
        case .own: return .accentColor
        case .bookable: return Color(.tertiarySystemBackground)
        case .unavailable: return Color(.secondarySystemBackground)
        }
    }

    private var foreground: Color {
        if dibs { return .accentColor }
        switch status {
        case .own: return .white
        case .bookable: return .primary
        case .unavailable: return .secondary
        }
    }

    private var border: Color {
        dibs ? .accentColor.opacity(0.5) : Color(.separator)
    }
}
