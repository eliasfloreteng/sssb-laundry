//
//  sssb_laundryApp.swift
//  sssb-laundry
//

import SwiftUI

@main
struct sssb_laundryApp: App {
    @StateObject private var session = Session()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .tint(.accentColor)
        }
    }
}
