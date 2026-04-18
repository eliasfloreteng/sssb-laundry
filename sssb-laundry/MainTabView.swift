//
//  MainTabView.swift
//  sssb-laundry
//

import SwiftUI

struct MainTabView: View {
    @State private var selection: Tab = .slots

    enum Tab: Hashable {
        case slots, bookings, profile
    }

    var body: some View {
        TabView(selection: $selection) {
            SlotsView()
                .tabItem {
                    Label("Slots", systemImage: "calendar")
                }
                .tag(Tab.slots)

            BookingsView()
                .tabItem {
                    Label("Bookings", systemImage: "checkmark.seal.fill")
                }
                .tag(Tab.bookings)

            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle")
                }
                .tag(Tab.profile)
        }
    }
}

#Preview {
    MainTabView().environmentObject(Session())
}
