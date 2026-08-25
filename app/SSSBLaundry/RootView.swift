//
//  RootView.swift
//  SSSBLaundry
//

import SwiftUI

struct RootView: View {
    @AppStorage(ObjectIdStore.key) private var objectId: String = ""

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
    }
}

#Preview {
    RootView()
}
