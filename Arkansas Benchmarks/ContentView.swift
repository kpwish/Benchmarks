//
//  ContentView 2.swift
//  Arkansas Benchmarks
//
//  Created by Kevin Wish on 12/21/25.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var locationManager = LocationManager()

    @State private var pois: [POI] = POILoader.loadCSVFromBundle(named: "pois", ext: "csv")

    @State private var selectedPOI: POI?
    @State private var isFollowingUser = true

    @State private var filters: POIFilters = .empty
    @State private var showingFilters = false

    // Map style + zoom commands
    @State private var mapStyle: MapStyle = .standard
    @State private var zoomAction: MapZoomAction? = nil

    var body: some View {
        ZStack {
            POIMapView(
                allPOIs: filteredPOIs,
                selectedPOI: $selectedPOI,
                isFollowingUser: $isFollowingUser,
                mapStyle: $mapStyle,
                zoomAction: $zoomAction
            )
            .onAppear { locationManager.start() }
            .ignoresSafeArea()
            .sheet(item: $selectedPOI) { poi in
                POIDetailView(poi: poi)
            }
            .sheet(isPresented: $showingFilters) {
                FiltersView(options: filterOptions, filters: $filters)
                    .presentationDetents([.medium, .large])
            }

            // Overlay layout:
            // - Bottom-left: Filters/Layers pill cluster (Option B)
            // - Right side: recenter + zoom controls
            // - Bottom: Settings banner + status bar
            VStack {
                Spacer()

                HStack(alignment: .bottom) {
                    // Bottom-left floating pills (Option B)
                    bottomLeftPills

                    Spacer()

                    // Right-side map controls (zoom + recenter)
                    rightMapControls
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 20) // lifts pills above status bar area

                // Bottom system/status area
                VStack(spacing: 10) {
                    if shouldShowSettingsCTA {
                        settingsBanner
                    }
                    statusBar
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 22)
            }
        }
    }

    // MARK: - Bottom-left Pills (Filters / Clear / Layers)

    private var bottomLeftPills: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    showingFilters = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                        Text("Filters")

                        if filters.activeCount > 0 {
                            Text("\(filters.activeCount)")
                                .font(.footnote.monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.thinMaterial)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(radius: 2)
                .accessibilityLabel("Filters")

                if filters.isActive {
                    Button {
                        clearFilters()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark.circle")
                            Text("Clear")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(radius: 2)
                    .accessibilityLabel("Clear filters")
                }
            }

            // Layers menu as a pill beneath (keeps the row from getting too wide)
            Menu {
                Button {
                    mapStyle = .standard
                } label: {
                    Label("Standard", systemImage: mapStyle == .standard ? "checkmark" : "")
                }

                Button {
                    mapStyle = .satellite
                } label: {
                    Label("Satellite", systemImage: mapStyle == .satellite ? "checkmark" : "")
                }

                Button {
                    mapStyle = .hybrid
                } label: {
                    Label("Hybrid", systemImage: mapStyle == .hybrid ? "checkmark" : "")
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.3.layers.3d")
                    Text("Layers")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(radius: 2)
            .accessibilityLabel("Layers")
        }
    }

    // MARK: - Right-side map controls (Recenter + Zoom)

    private var rightMapControls: some View {
        VStack(spacing: 10) {
            // Recenter appears only when needed (not following)
            if locationManager.isAuthorized && !isFollowingUser {
                Button {
                    isFollowingUser = true
                } label: {
                    Image(systemName: "location.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(12)
                }
                .buttonStyle(.plain)
                .background(.thinMaterial)
                .clipShape(Circle())
                .shadow(radius: 2)
                .accessibilityLabel("Recenter")
            }

            Button {
                zoomAction = .zoomIn
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(12)
            }
            .buttonStyle(.plain)
            .background(.thinMaterial)
            .clipShape(Circle())
            .shadow(radius: 2)
            .accessibilityLabel("Zoom in")

            Button {
                zoomAction = .zoomOut
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(12)
            }
            .buttonStyle(.plain)
            .background(.thinMaterial)
            .clipShape(Circle())
            .shadow(radius: 2)
            .accessibilityLabel("Zoom out")
        }
    }

    // MARK: - Clear Filters

    private func clearFilters() {
        filters = .empty
    }

    // MARK: - Permissions / Settings CTA

    private var shouldShowSettingsCTA: Bool {
        locationManager.authorizationStatus == .denied || locationManager.authorizationStatus == .restricted
    }

    private var settingsBanner: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Location Access Needed").font(.headline)
                Text("Enable Location in Settings to show your position on the map.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") { openAppSettings() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            if locationManager.isAuthorized {
                Text(isFollowingUser ? "Following" : "Free roam")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var statusText: String {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            return "Requesting location permission…"
        case .restricted:
            return "Location restricted."
        case .denied:
            return "Location denied."
        case .authorizedWhenInUse, .authorizedAlways:
            if filters.isActive {
                return "POIs: \(filteredPOIs.count) (filtered from \(pois.count))"
            } else {
                return "POIs loaded: \(pois.count)"
            }
        @unknown default:
            return "Unknown authorization state."
        }
    }

    // MARK: - Filtering

    private var filterOptions: FilterOptions {
        let markers = Array(Set(pois.compactMap { $0.marker }.filter { !$0.isEmpty })).sorted()
        let settings = Array(Set(pois.compactMap { $0.setting }.filter { !$0.isEmpty })).sorted()
        let lastConds = Array(Set(pois.compactMap { $0.lastCondition }.filter { !$0.isEmpty })).sorted()

        let years = pois.compactMap { $0.lastRecoveredYear }
        let yearRange: ClosedRange<Int>? = {
            guard let minY = years.min(), let maxY = years.max() else { return nil }
            return minY...maxY
        }()

        return FilterOptions(markers: markers, settings: settings, lastConditions: lastConds, yearRange: yearRange)
    }

    private var filteredPOIs: [POI] {
        guard filters.isActive else { return pois }
        return pois.filter { matches($0, filters: filters) }
    }

    private func matches(_ poi: POI, filters: POIFilters) -> Bool {
        if !filters.markers.isEmpty {
            guard let m = poi.marker, filters.markers.contains(m) else { return false }
        }
        if !filters.settings.isEmpty {
            guard let s = poi.setting, filters.settings.contains(s) else { return false }
        }
        if !filters.lastConditions.isEmpty {
            guard let c = poi.lastCondition, filters.lastConditions.contains(c) else { return false }
        }
        if let minY = filters.minLastRecoveredYear {
            guard let y = poi.lastRecoveredYear, y >= minY else { return false }
        }
        if let maxY = filters.maxLastRecoveredYear {
            guard let y = poi.lastRecoveredYear, y <= maxY else { return false }
        }
        return true
    }
}
