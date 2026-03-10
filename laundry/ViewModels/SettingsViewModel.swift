import CoreLocation
import Foundation
import Observation

@Observable
final class SettingsViewModel {
    var settings: SlotMonitorSettings
    var isRequestingLocation = false
    var isRequestingWiFi = false
    var locationStatus: String?

    init() {
        settings = .load()
    }

    func toggleEnabled() {
        settings.isEnabled.toggle()
        save()
        if !settings.isEnabled {
            NotificationService.removeAllFreedSlotNotifications()
        }
    }

    func setCurrentLocationAsHome() async {
        isRequestingLocation = true
        locationStatus = nil

        let granted = await LocationService.requestPermission()
        guard granted else {
            locationStatus = "Location permission denied"
            isRequestingLocation = false
            return
        }

        if let coord = await LocationService.currentLocation() {
            settings.homeLatitude = coord.latitude
            settings.homeLongitude = coord.longitude
            locationStatus = "Location set"
            save()
        } else {
            locationStatus = "Could not get location"
        }
        isRequestingLocation = false
    }

    func detectCurrentWiFi() async {
        isRequestingWiFi = true
        if let ssid = await LocationService.currentWiFiSSID() {
            settings.homeWiFiSSID = ssid
            save()
        }
        isRequestingWiFi = false
    }

    func clearHomeLocation() {
        settings.homeLatitude = nil
        settings.homeLongitude = nil
        locationStatus = nil
        save()
    }

    func clearWiFiSSID() {
        settings.homeWiFiSSID = nil
        save()
    }

    func updateRadius(_ radius: Double) {
        settings.homeRadiusMeters = radius
        save()
    }

    func save() {
        settings.save()
    }
}
