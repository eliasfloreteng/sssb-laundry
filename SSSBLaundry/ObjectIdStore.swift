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
}
