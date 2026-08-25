//
//  SSSBLaundryApp.swift
//  SSSBLaundry
//
//  Created by Elias Floreteng on 2026-04-28.
//

import SwiftUI

@main
struct SSSBLaundryApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
