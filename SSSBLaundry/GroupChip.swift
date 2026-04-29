//
//  GroupChip.swift
//  SSSBLaundry
//

import SwiftUI

struct GroupChip: View {
    let name: String
    let status: GroupStatus

    var body: some View {
        Text(name)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
            .overlay(
                Capsule().stroke(border, lineWidth: status == .bookable ? 1 : 0)
            )
    }

    private var background: Color {
        switch status {
        case .own: return .accentColor
        case .bookable: return Color(.tertiarySystemBackground)
        case .unavailable: return Color(.secondarySystemBackground)
        }
    }

    private var foreground: Color {
        switch status {
        case .own: return .white
        case .bookable: return .primary
        case .unavailable: return .secondary
        }
    }

    private var border: Color {
        Color(.separator)
    }
}
