//
//  ObjectIdStore.swift
//  SSSBLaundry
//

import Foundation

enum ObjectIdStore {
    static let key = "objectId"

    static func get() -> String? {
        let value = UserDefaults.standard.string(forKey: key)
        return value?.isEmpty == false ? value : nil
    }

    static func set(_ id: String?) {
        if let id, !id.isEmpty {
            UserDefaults.standard.set(id, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Points this phone at a different apartment, or at none.
    ///
    /// The server pushes per object id, so the old registration has to go before
    /// the new number is stored — otherwise this phone keeps getting reminders
    /// for an apartment it has left. A Live Activity counting down to a booking
    /// that is no longer ours goes the same way. `@AppStorage` observes the
    /// defaults store, so views bound to the key follow this on their own.
    static func replace(with id: String?) {
        if let previous = get() {
            PushService.deregister(objectId: previous)
            Task { await LiveActivityService.endAll() }
        }
        set(id)
        if get() != nil { PushService.syncToServer() }
    }
}
