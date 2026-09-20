@preconcurrency import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class LocationService: NSObject, @preconcurrency CLLocationManagerDelegate {
    var currentLocation: CLLocation?
    var authorizationStatus: CLAuthorizationStatus = .notDetermined
    var errorMessage: String?
    var onLocation: ((CLLocation) -> Void)?

    private let manager = CLLocationManager()
    private var wantsBackgroundUpdates = false
    private var pendingAlwaysAuthorizationRequest = false

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        manager.pausesLocationUpdatesAutomatically = true
        authorizationStatus = manager.authorizationStatus
    }

    func requestPermission() {
        requestAlwaysPermission()
    }

    func requestAlwaysPermission() {
        switch manager.authorizationStatus {
        case .notDetermined:
            pendingAlwaysAuthorizationRequest = true
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            pendingAlwaysAuthorizationRequest = true
            manager.startUpdatingLocation()
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            pendingAlwaysAuthorizationRequest = false
            manager.startUpdatingLocation()
        default:
            pendingAlwaysAuthorizationRequest = false
        }
    }

    func start(background: Bool) {
        wantsBackgroundUpdates = background
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse where background:
            manager.requestAlwaysAuthorization()
            manager.startUpdatingLocation()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.allowsBackgroundLocationUpdates = background && manager.authorizationStatus == .authorizedAlways
            manager.showsBackgroundLocationIndicator = background
            manager.startUpdatingLocation()
        default:
            errorMessage = "Location access is required to beacon your position."
        }
    }

    func stop() {
        wantsBackgroundUpdates = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if manager.authorizationStatus == .authorizedWhenInUse &&
            (wantsBackgroundUpdates || pendingAlwaysAuthorizationRequest) {
            pendingAlwaysAuthorizationRequest = false
            manager.requestAlwaysAuthorization()
        }
        if manager.authorizationStatus == .authorizedAlways {
            pendingAlwaysAuthorizationRequest = false
        }
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = wantsBackgroundUpdates && manager.authorizationStatus == .authorizedAlways
            manager.showsBackgroundLocationIndicator = wantsBackgroundUpdates
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        currentLocation = location
        onLocation?(location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        errorMessage = error.localizedDescription
    }
}
