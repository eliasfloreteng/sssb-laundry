import Foundation
import CoreLocation

struct SlotMonitorSettings {
    var isEnabled: Bool
    var homeLatitude: Double?
    var homeLongitude: Double?
    var homeWiFiSSID: String?
    var homeRadiusMeters: Double

    var homeCoordinate: CLLocationCoordinate2D? {
        guard let lat = homeLatitude, let lon = homeLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var hasHomeLocation: Bool { homeLatitude != nil && homeLongitude != nil }
    var isConfigured: Bool { hasHomeLocation || homeWiFiSSID != nil }

    // MARK: - Persistence

    private static let defaults = UserDefaults.standard
    private enum Key {
        static let isEnabled = "slotMonitor.isEnabled"
        static let homeLatitude = "slotMonitor.homeLatitude"
        static let homeLongitude = "slotMonitor.homeLongitude"
        static let homeWiFiSSID = "slotMonitor.homeWiFiSSID"
        static let homeRadiusMeters = "slotMonitor.homeRadiusMeters"
    }

    static func load() -> SlotMonitorSettings {
        let d = defaults
        return SlotMonitorSettings(
            isEnabled: d.bool(forKey: Key.isEnabled),
            homeLatitude: d.object(forKey: Key.homeLatitude) as? Double,
            homeLongitude: d.object(forKey: Key.homeLongitude) as? Double,
            homeWiFiSSID: d.string(forKey: Key.homeWiFiSSID),
            homeRadiusMeters: d.object(forKey: Key.homeRadiusMeters) as? Double ?? 200
        )
    }

    func save() {
        let d = Self.defaults
        d.set(isEnabled, forKey: Key.isEnabled)
        if let lat = homeLatitude { d.set(lat, forKey: Key.homeLatitude) } else { d.removeObject(forKey: Key.homeLatitude) }
        if let lon = homeLongitude { d.set(lon, forKey: Key.homeLongitude) } else { d.removeObject(forKey: Key.homeLongitude) }
        if let ssid = homeWiFiSSID { d.set(ssid, forKey: Key.homeWiFiSSID) } else { d.removeObject(forKey: Key.homeWiFiSSID) }
        d.set(homeRadiusMeters, forKey: Key.homeRadiusMeters)
    }
}
