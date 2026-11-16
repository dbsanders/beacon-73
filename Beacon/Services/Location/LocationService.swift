@preconcurrency import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class LocationService: NSObject, @preconcurrency CLLocationManagerDelegate {
    var currentLocation: CLLocation?
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    var errorMessage: String?
    var onLocation: ((CLLocation) -> Void)?
    var onAuthorizationChange: (() -> Void)?

    var hasLocationPermission: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse
    }

    static let permissionRequiredMessage = String(localized: "Location access is required to beacon your position. Enable Location access for Beacon 73 in iOS Settings, then turn beaconing on again.")

    private let manager: CLLocationManager
    private var wantsLocationUpdates = false
    private var wantsBackgroundUpdates = false

    init(manager: CLLocationManager = CLLocationManager()) {
        self.manager = manager
        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        manager.pausesLocationUpdatesAutomatically = true
        authorizationStatus = manager.authorizationStatus
    }

    func requestPermission() {
        start(background: wantsBackgroundUpdates)
    }

    func start(background: Bool) {
        wantsLocationUpdates = true
        wantsBackgroundUpdates = background
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        refreshAuthorization()
    }

    func stop() {
        wantsLocationUpdates = false
        wantsBackgroundUpdates = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        manager.pausesLocationUpdatesAutomatically = true
    }

    func refreshAuthorization() {
        authorizationDidChange(to: manager.authorizationStatus)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refreshAuthorization()
    }

    func authorizationDidChange(to status: CLAuthorizationStatus) {
        authorizationStatus = status
        guard hasLocationPermission else {
            currentLocation = nil
            if status != .notDetermined {
                errorMessage = Self.permissionRequiredMessage
                stop()
            } else {
                manager.stopUpdatingLocation()
                manager.allowsBackgroundLocationUpdates = false
                manager.showsBackgroundLocationIndicator = false
            }
            onAuthorizationChange?()
            return
        }

        errorMessage = nil
        if wantsLocationUpdates {
            // An explicitly started session can continue with When In Use access.
            let background = wantsBackgroundUpdates
            manager.allowsBackgroundLocationUpdates = background
            manager.showsBackgroundLocationIndicator = background
            // Pausing a When In Use session in the background can end access
            // until the app returns to the foreground, including while stationary.
            manager.pausesLocationUpdatesAutomatically = !background
            manager.startUpdatingLocation()
        }
        onAuthorizationChange?()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard hasLocationPermission, wantsLocationUpdates,
              let location = locations.last else { return }
        currentLocation = location
        onLocation?(location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        errorMessage = error.localizedDescription
    }
}
