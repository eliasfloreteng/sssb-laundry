//
//  RootView.swift
//  SSSBLaundry
//

import SwiftUI

struct RootView: View {
    @AppStorage(ObjectIdStore.key) private var objectId: String = ""
    /// An invite that arrived while another object number was already signed in,
    /// held until the switch is confirmed.
    @State private var offeredObjectId: String?

    var body: some View {
        Group {
            if objectId.isEmpty {
                ObjectIdSetupView()
            } else {
                WeekView()
                    .id(objectId)
            }
        }
        .animation(.default, value: objectId.isEmpty)
        // A universal link arrives as a URL when the app is already running and
        // as a browsing user activity when the tap is what launched it. SwiftUI
        // does not fold the two together, so both spellings are needed.
        .onOpenURL { open(InviteLink.objectId(from: $0)) }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            open(activity.webpageURL.flatMap(InviteLink.objectId(from:)))
        }
        .alert(
            "Switch object number?",
            isPresented: offeringSwitch,
            presenting: offeredObjectId
        ) { invited in
            Button("Cancel", role: .cancel) {}
            Button("Switch") { ObjectIdStore.replace(with: invited) }
        } message: { invited in
            Text("This phone will show \(invited) instead. Your own bookings stay, but they leave this phone along with their reminders.")
        }
    }

    /// Signed out, an invite simply *is* the sign-in — nothing is being replaced,
    /// so it needs no confirmation. Signed in, it would silently swap which
    /// apartment the app books for, and that is worth asking about.
    private func open(_ invited: String?) {
        guard let invited, invited != objectId else { return }
        if objectId.isEmpty {
            objectId = invited
        } else {
            offeredObjectId = invited
        }
    }

    private var offeringSwitch: Binding<Bool> {
        Binding(
            get: { offeredObjectId != nil },
            set: { if !$0 { offeredObjectId = nil } }
        )
    }
}

#Preview {
    RootView()
}
