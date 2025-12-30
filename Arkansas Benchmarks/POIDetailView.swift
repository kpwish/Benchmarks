import SwiftUI
import CoreLocation
import UIKit

struct POIDetailView: View {
    let poi: POI
    @ObservedObject var locationManager: LocationManager

    var body: some View {
        NavigationStack {
            List {
                header

                if hasRecoveryInfo {
                    Section("Recovery") {
                        labeledRow("Last recovered", value: poi.lastRecoveredYear.map(String.init))
                        labeledRow("Condition", value: poi.lastCondition)
                        labeledRow("Recovered by", value: poi.lastRecoveredBy)
                    }
                }

                Section("Classification") {
                    labeledRow("Marker", value: poi.marker)
                    labeledRow("Setting", value: poi.setting)
                }

                Section("Location") {
                    labeledRow("County", value: poi.county)
                    labeledRow("State", value: poi.state)

                    labeledRow("Latitude", value: formatCoord(poi.latitude), monospaced: true)
                    labeledRow("Longitude", value: formatCoord(poi.longitude), monospaced: true)

                    if let h = poi.orthoHeight {
                        labeledRow("Ortho height (m)", value: String(format: "%.3f", h), monospaced: true)
                        labeledRow("Ortho height (ft)", value: String(format: "%.2f", h * 3.280839895), monospaced: true)
                    }
                }

                Section("Actions") {
                    NavigationLink {
                        POIRelativeLocationView(poi: poi, locationManager: locationManager)
                    } label: {
                        Label("Distance & Direction", systemImage: "location.north.line")
                    }

                    if let url = dataSourceURL {
                        Link(destination: url) {
                            Label("Open datasheet", systemImage: "safari")
                        }
                    }

                    Button {
                        copyToPasteboard(poi.pid)
                    } label: {
                        Label("Copy PID", systemImage: "doc.on.doc")
                    }

                    Button {
                        copyToPasteboard("\(poi.latitude), \(poi.longitude)")
                    } label: {
                        Label("Copy coordinates", systemImage: "mappin.and.ellipse")
                    }
                }

                if hasSourceInfo {
                    Section("Source") {
                        labeledRow("Data date", value: poi.dataDate.map(String.init), monospaced: true)

                        if let s = poi.dataSource, !s.isEmpty {
                            Text(s)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                    }
                }
            }
            .navigationTitle("Benchmark")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(poi.name)
                .font(.headline)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Text(poi.pid)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospaced()

                if let marker = nonEmpty(poi.marker) {
                    Text("•")
                        .foregroundStyle(.secondary)
                    Text(markerShort(marker))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    private var hasRecoveryInfo: Bool {
        poi.lastRecoveredYear != nil ||
        nonEmpty(poi.lastCondition) != nil ||
        nonEmpty(poi.lastRecoveredBy) != nil
    }

    private var hasSourceInfo: Bool {
        poi.dataDate != nil || dataSourceURL != nil
    }

    private var dataSourceURL: URL? {
        guard let s = nonEmpty(poi.dataSource) else { return nil }
        return URL(string: s)
    }

    private func labeledRow(_ label: String, value: String?, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            if let v = nonEmpty(value) {
                Text(v)
                    .multilineTextAlignment(.trailing)
                    .font(monospaced ? .body.monospaced() : .body)
                    .textSelection(.enabled)
            } else {
                Text("Not available")
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func formatCoord(_ value: Double) -> String {
        String(format: "%.10f", value)
    }

    private func markerShort(_ marker: String) -> String {
        if let eq = marker.firstIndex(of: "=") {
            return marker[marker.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return marker
    }

    private func copyToPasteboard(_ s: String) {
        UIPasteboard.general.string = s
    }
}

// MARK: - Distance & Direction View

private struct POIRelativeLocationView: View {
    let poi: POI
    @ObservedObject var locationManager: LocationManager

    @State private var nearTargetEnabled = false

    // 100 ft enter, 150 ft exit (hysteresis)
    private let enterNearTargetMeters: Double = 30.48
    private let exitNearTargetMeters: Double = 45.72

    private var poiLocation: CLLocation {
        CLLocation(latitude: poi.latitude, longitude: poi.longitude)
    }

    var body: some View {
        List {
            Section("POI Coordinates") {
                coordRow(title: "Latitude", value: poi.latitude)
                coordRow(title: "Longitude", value: poi.longitude)
            }

            Section("Your Coordinates") {
                if !locationManager.isAuthorized {
                    Text(userLocationUnavailableText)
                        .foregroundStyle(.secondary)
                } else if let user = currentUserLocation {
                    coordRow(title: "Latitude", value: user.coordinate.latitude)
                    coordRow(title: "Longitude", value: user.coordinate.longitude)
                } else {
                    Text("Waiting for a GPS fix…")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Relative Position") {
                if !locationManager.isAuthorized {
                    Text(userLocationUnavailableText)
                        .foregroundStyle(.secondary)

                } else if let user = currentUserLocation {
                    let distanceMeters = poiLocation.distance(from: user)
                    let bearing = bearingDegrees(from: user.coordinate, to: poiLocation.coordinate)
                    let cardinal = cardinalDirection(from: bearing)

                    // IMPORTANT:
                    // Do NOT call a Void function directly in a ViewBuilder.
                    // Instead, trigger tracking updates from a modifier on a View.
                    let distanceBucket = Int(distanceMeters.rounded()) // reduces update spam

                    EmptyView()
                        .onAppear {
                            updateTrackingModeIfNeeded(distanceMeters: distanceMeters)
                        }
                        .onChange(of: distanceBucket) { _, _ in
                            updateTrackingModeIfNeeded(distanceMeters: distanceMeters)
                        }

                    HStack {
                        Label("Distance", systemImage: "ruler")
                        Spacer()
                        Text(formatDistance(distanceMeters))
                            .monospacedDigit()
                    }

                    HStack {
                        Label("Direction", systemImage: "location.north")
                        Spacer()
                        Text("\(Int(round(bearing)))° \(cardinal)")
                            .monospacedDigit()
                    }

                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(.thinMaterial)
                                .frame(width: 84, height: 84)

                            Image(systemName: "location.north.fill")
                                .font(.system(size: 34, weight: .semibold))
                                .rotationEffect(.degrees(relativeArrowDegrees(bearingToPOI: bearing)))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Arrow points toward the benchmark.")
                                .font(.subheadline)

                            if locationManager.headingDegrees != nil {
                                Text("Arrow accounts for device heading.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Heading unavailable; using true-north bearing.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 6)

                } else {
                    Text("Waiting for a GPS fix…")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Distance & Direction")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Ensure deterministic state.
            nearTargetEnabled = false
            locationManager.setTrackingMode(.normal)
        }
        .onDisappear {
            // Revert immediately when leaving (per your requirement).
            nearTargetEnabled = false
            locationManager.setTrackingMode(.normal)
        }
    }

    private var currentUserLocation: CLLocation? {
        locationManager.location
    }

    private var userLocationUnavailableText: String {
        switch locationManager.authorizationStatus {
        case .denied:
            return "Location access is denied. Enable Location Services for this app in Settings to compute distance and direction."
        case .restricted:
            return "Location access is restricted on this device."
        case .notDetermined:
            return "Location permission has not been requested yet."
        default:
            return "Location is not available."
        }
    }

    private func updateTrackingModeIfNeeded(distanceMeters: Double) {
        guard locationManager.isAuthorized else { return }

        if !nearTargetEnabled && distanceMeters <= enterNearTargetMeters {
            nearTargetEnabled = true
            locationManager.setTrackingMode(.nearTarget)
        } else if nearTargetEnabled && distanceMeters >= exitNearTargetMeters {
            nearTargetEnabled = false
            locationManager.setTrackingMode(.normal)
        }
    }

    private func coordRow(title: String, value: Double) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%.10f", value))
                .font(.body.monospaced())
                .textSelection(.enabled)
        }
    }

    private func formatDistance(_ meters: CLLocationDistance) -> String {
        let mf = MeasurementFormatter()
        mf.unitOptions = .providedUnit
        mf.numberFormatter.maximumFractionDigits = meters >= 1000 ? 2 : 0

        if Locale.current.usesMetricSystem {
            if meters >= 1000 {
                return mf.string(from: Measurement(value: meters / 1000.0, unit: UnitLength.kilometers))
            } else {
                return mf.string(from: Measurement(value: meters, unit: UnitLength.meters))
            }
        } else {
            let feet = meters * 3.28084
            let miles = feet / 5280.0
            if miles >= 1.0 {
                return mf.string(from: Measurement(value: miles, unit: UnitLength.miles))
            } else {
                return mf.string(from: Measurement(value: feet, unit: UnitLength.feet))
            }
        }
    }

    private func bearingDegrees(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> Double {
        let lat1 = start.latitude * .pi / 180
        let lon1 = start.longitude * .pi / 180
        let lat2 = end.latitude * .pi / 180
        let lon2 = end.longitude * .pi / 180

        let dLon = lon2 - lon1
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)

        var brng = atan2(y, x) * 180 / .pi
        brng = (brng + 360).truncatingRemainder(dividingBy: 360)
        return brng
    }

    private func cardinalDirection(from bearing: Double) -> String {
        let directions = ["N","NNE","NE","ENE","E","ESE","SE","SSE","S","SSW","SW","WSW","W","WNW","NW","NNW"]
        let idx = Int((bearing / 22.5).rounded()) % directions.count
        return directions[idx]
    }

    private func relativeArrowDegrees(bearingToPOI: Double) -> Double {
        if let heading = locationManager.headingDegrees {
            return normalizeDegrees(bearingToPOI - heading)
        }
        return normalizeDegrees(bearingToPOI)
    }

    private func normalizeDegrees(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }
}
