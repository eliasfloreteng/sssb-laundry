//
//  ContentView.swift
//  sssb-laundry
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: Session

    var body: some View {
        Group {
            if session.isAuthenticated {
                MainTabView()
                    .transition(.opacity)
            } else {
                SignInView()
                    .transition(.opacity)
            }
        }
        .animation(.default, value: session.isAuthenticated)
        .task { await session.refreshMe() }
    }
}

#Preview {
    RootView().environmentObject(Session())
}
