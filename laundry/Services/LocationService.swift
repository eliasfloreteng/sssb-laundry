import CoreLocation
import NetworkExtension

enum LocationService {

    static func requestPermission() async -> Bool {
        let delegate = LocationDelegate()
        let manager = CLLocationManager()
        manager.delegate = delegate
        return await withCheckedContinuation { continuation in
            delegate.authContinuation = continuation
            let status = manager.authorizationStatus
            if status == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else {
                continuation.resume(returning: status == .authorizedWhenInUse || status == .authorizedAlways)
            }
        }
    }

    static func currentLocation() async -> CLLocationCoordinate2D? {
        let delegate = LocationDelegate()
        let manager = CLLocationManager()
        manager.delegate = delegate
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters

        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return nil }

        return await withCheckedContinuation { continuation in
            delegate.locationContinuation = continuation

            // 5 second timeout
            let timeout = DispatchWorkItem {
                delegate.finishLocation(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
            delegate.timeoutWork = timeout

            manager.requestLocation()
        }
    }

    static func isNear(_ coordinate: CLLocationCoordinate2D, radiusMeters: Double) async -> Bool {
        guard let current = await currentLocation() else { return false }
        let currentLoc = CLLocation(latitude: current.latitude, longitude: current.longitude)
        let targetLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return currentLoc.distance(from: targetLoc) <= radiusMeters
    }

    static func currentWiFiSSID() async -> String? {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
    }

    static func isAtHome() async -> Bool {
        let settings = SlotMonitorSettings.load()

        // Check WiFi first (cheap)
        if let expectedSSID = settings.homeWiFiSSID {
            if let currentSSID = await currentWiFiSSID(), currentSSID == expectedSSID {
                return true
            }
        }

        // Fall back to GPS
        if let homeCoord = settings.homeCoordinate {
            return await isNear(homeCoord, radiusMeters: settings.homeRadiusMeters)
        }

        // No home configured — default to allowing notifications
        return !settings.isConfigured
    }
}

// MARK: - CLLocationManager Delegate

private class LocationDelegate: NSObject, CLLocationManagerDelegate {
    var authContinuation: CheckedContinuation<Bool, Never>?
    var locationContinuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?
    var timeoutWork: DispatchWorkItem?
    private var didFinishLocation = false

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard status != .notDetermined else { return }
        authContinuation?.resume(returning: status == .authorizedWhenInUse || status == .authorizedAlways)
        authContinuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finishLocation(locations.first?.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finishLocation(nil)
    }

    func finishLocation(_ coordinate: CLLocationCoordinate2D?) {
        guard !didFinishLocation else { return }
        didFinishLocation = true
        timeoutWork?.cancel()
        locationContinuation?.resume(returning: coordinate)
        locationContinuation = nil
    }
}
