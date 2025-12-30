import Foundation
import CoreLocation

@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var location: CLLocation?

    // Heading support
    @Published private(set) var heading: CLHeading?

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    /// Returns a usable heading in degrees [0, 360), preferring trueHeading when available.
    var headingDegrees: Double? {
        guard let h = heading else { return nil }

        // trueHeading is -1 when invalid; fall back to magneticHeading.
        let raw = (h.trueHeading >= 0) ? h.trueHeading : h.magneticHeading
        guard raw >= 0 else { return nil }
        return raw
    }

    // MARK: - Tracking mode

    enum TrackingMode: Equatable {
        case normal
        case nearTarget
    }

    private var trackingMode: TrackingMode = .normal

    /// Adjusts CLLocationManager settings without requiring a restart.
    /// - normal: balanced updates
    /// - nearTarget: more frequent updates for close-range navigation
    func setTrackingMode(_ mode: TrackingMode) {
        guard trackingMode != mode else { return }
        trackingMode = mode

        switch mode {
        case .normal:
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = 10          // meters (your default)
            manager.headingFilter = 5            // degrees (your default)

        case .nearTarget:
            manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            manager.distanceFilter = 1           // meters (higher frequency)
            manager.headingFilter = 1            // degrees (more responsive arrow)
        }
    }

    override init() {
        self.authorizationStatus = manager.authorizationStatus
        super.init()

        manager.delegate = self

        // Defaults (normal mode)
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        manager.headingFilter = 5
    }

    func start() {
        if authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
            return
        }

        if isAuthorized {
            // Always start in normal mode; feature views can temporarily switch to nearTarget.
            setTrackingMode(.normal)

            manager.startUpdatingLocation()

            // Only start heading updates if available on device
            if CLLocationManager.headingAvailable() {
                manager.startUpdatingHeading()
            }
        } else {
            manager.stopUpdatingLocation()
            manager.stopUpdatingHeading()
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationStatus = manager.authorizationStatus
            self.start()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in
            self.location = last
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        Task { @MainActor in
            self.heading = newHeading
        }
    }

    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        true
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error)")
    }
}
