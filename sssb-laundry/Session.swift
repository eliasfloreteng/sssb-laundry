//
//  Session.swift
//  sssb-laundry
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class Session: ObservableObject {
    @AppStorage("objectId") private(set) var objectIdStorage: String = ""

    @Published var me: MeResponse?

    var objectId: String? {
        objectIdStorage.isEmpty ? nil : objectIdStorage
    }

    var isAuthenticated: Bool { objectId != nil }

    func signIn(objectId: String) async throws {
        let trimmed = objectId.trimmingCharacters(in: .whitespacesAndNewlines)
        let me = try await APIClient.shared.me(objectId: trimmed)
        self.objectIdStorage = trimmed
        self.me = me
    }

    func refreshMe() async {
        guard let id = objectId else { return }
        if let me = try? await APIClient.shared.me(objectId: id) {
            self.me = me
        }
    }

    func signOut() {
        objectIdStorage = ""
        me = nil
    }
}
