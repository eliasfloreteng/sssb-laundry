//
//  Item.swift
//  sssb-laundry
//
//  Created by Elias Floreteng on 2026-04-18.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
