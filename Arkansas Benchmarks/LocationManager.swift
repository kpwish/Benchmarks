import Foundation
import CoreLocation

@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var location: CLLocation?

    // Heading support
    @Published private(set) var heading: CLHeading?

    // Track whether we are actively running updates
    private var isUpdatingLocation = false

    // Only run heading updates when at least one view needs it
    private var headingConsumers: Int = 0
    private var isUpdatingHeading: Bool = false

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

    /// Adjusts CLLocationManager settings (foreground only).
    /// - normal: balanced updates
    /// - nearTarget: more frequent updates for close-range navigation
    func setTrackingMode(_ mode: TrackingMode) {
        guard trackingMode != mode else { return }
        trackingMode = mode

        applyTrackingModeSettings(mode)

        // If we are currently updating location, restart to ensure settings take effect immediately.
        // (Not strictly required, but helps on some devices/OS versions.)
        if isUpdatingLocation {
            manager.stopUpdatingLocation()
            manager.startUpdatingLocation()
        }
    }

    private func applyTrackingModeSettings(_ mode: TrackingMode) {
        switch mode {
        case .normal:
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = 10          // meters
            manager.headingFilter = 5            // degrees

        case .nearTarget:
            manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            manager.distanceFilter = 1           // meters
            manager.headingFilter = 1            // degrees
        }
    }

    override init() {
        self.authorizationStatus = manager.authorizationStatus
        super.init()

        manager.delegate = self

        // Prevent background tracking unless you explicitly choose to enable it.
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = true

        // Defaults (normal mode)
        applyTrackingModeSettings(.normal)
    }

    // MARK: - Public lifecycle API

    /// Call this once at app start (e.g., ContentView.onAppear) to request permissions / begin.
    func start() {
        // If we don't have permission yet, request it.
        if authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
            return
        }

        // If authorized, start foreground updates (but do NOT start heading unless requested).
        if isAuthorized {
            resumeForForeground()
        } else {
            suspendForBackground()
        }
    }

    /// Foreground entry point: starts location updates and heading only if requested by a consumer.
    func resumeForForeground() {
        guard isAuthorized else { return }

        // Apply current tracking mode settings
        applyTrackingModeSettings(trackingMode)

        // Ensure background location stays off unless you intentionally enable it later.
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = true

        if !isUpdatingLocation {
            manager.startUpdatingLocation()
            isUpdatingLocation = true
        }

        // Only run heading updates if at least one view needs it.
        updateHeadingIfNeeded()
    }

    /// Background/inactive entry point: stops all hardware updates to preserve battery.
    func suspendForBackground() {
        if isUpdatingLocation {
            manager.stopUpdatingLocation()
            isUpdatingLocation = false
        }

        if isUpdatingHeading {
            manager.stopUpdatingHeading()
            isUpdatingHeading = false
        }
    }

    /// Full stop (e.g., for debugging or explicit user action)
    func stop() {
        suspendForBackground()
    }

    // MARK: - Heading consumer API

    /// Call when a feature/view needs heading (e.g., POIRelativeLocationView onAppear).
    func beginHeadingUpdates() {
        headingConsumers += 1
        updateHeadingIfNeeded()
    }

    /// Call when leaving the feature/view that needs heading (onDisappear).
    func endHeadingUpdates() {
        headingConsumers = max(0, headingConsumers - 1)
        updateHeadingIfNeeded()
    }

    private func updateHeadingIfNeeded() {
        guard CLLocationManager.headingAvailable() else { return }

        let shouldRunHeading = isAuthorized && isUpdatingLocation && headingConsumers > 0

        if shouldRunHeading && !isUpdatingHeading {
            manager.startUpdatingHeading()
            isUpdatingHeading = true
        } else if !shouldRunHeading && isUpdatingHeading {
            manager.stopUpdatingHeading()
            isUpdatingHeading = false
        }
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
