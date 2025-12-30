//
//  ContentView.swift
//  Arkansas Benchmarks
//
//  Created by Kevin Wish on 12/21/25.
//

import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var locationManager = LocationManager()

    // IMPORTANT: start empty so the UI (and MKMapView) can render immediately.
    @State private var pois: [POI] = []
    @State private var isLoadingPOIs: Bool = true
    @State private var loadErrorMessage: String? = nil

    @State private var selectedPOI: POI?
    @State private var isFollowingUser = true

    @State private var filters: POIFilters = .empty
    @State private var showingFilters = false

    // Map style + zoom commands (per your existing implementation)
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
                POIDetailView(poi: poi, locationManager: locationManager)
            }
            .sheet(isPresented: $showingFilters) {
                FiltersView(options: filterOptions, filters: $filters)
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $selectedPOI) { poi in
                POIDetailView(poi: poi, locationManager: locationManager)
                    .environmentObject(locationManager)
            }

            // Overlay layout:
            // - Bottom-left: Filters/Layers (Option B)
            // - Right side: zoom + recenter controls
            // - Bottom: settings banner + status bar
            VStack {
                Spacer()

                HStack(alignment: .bottom) {
                    bottomLeftPills
                    Spacer()
                    rightMapControls
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 20)   // you can keep your tuned values here

                VStack(spacing: 10) {
                    if shouldShowSettingsCTA {
                        settingsBanner
                    }
                    statusBar
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 22)   // you can keep your tuned values here
            }

            // Startup screen overlay (logo + caption).
            // NOTE: Name is StartupOverlayView to avoid collision with any existing StartupLoadingView.swift.
            if isLoadingPOIs {
                StartupOverlayView(
                    title: "Arkansas Benchmarks",
                    subtitle: (loadErrorMessage == nil ? "Loading benchmarks…" : "Unable to load benchmarks."),
                    logoAssetName: "AppLogo", // <-- set to your Asset Catalog logo name
                    errorMessage: loadErrorMessage,
                    onRetry: {
                        Task { await loadPOIsAsync(forceRebuildCache: true) }
                    }
                )
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .task {
            // Optional: allow the first UI frame to render before heavy work begins.
            // try? await Task.sleep(nanoseconds: 150_000_000)

            await loadPOIsAsync()
        }
    }

    // MARK: - Async POI Load + Simple Cache

    private func loadPOIsAsync(forceRebuildCache: Bool = false) async {
        await MainActor.run {
            isLoadingPOIs = true
            loadErrorMessage = nil
        }

        do {
            // 1) Try cache first (fast path)
            if !forceRebuildCache,
               let cached = try POICache.loadIfValidForBundledCSV(resourceName: "pois", ext: "csv") {
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.25)) {
                        self.pois = cached
                        self.isLoadingPOIs = false
                    }
                }
                return
            }

            // 2) Parse CSV in background (lower priority so the UI can remain responsive)
            let parsed = try await Task.detached(priority: .utility) { () -> [POI] in
                POILoader.loadCSVFromBundle(named: "pois", ext: "csv")
            }.value

            // 3) Publish results to UI (dismiss startup screen smoothly)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.25)) {
                    self.pois = parsed
                    self.isLoadingPOIs = false
                }
            }

            // 4) Save cache in background (do not block UI)
            Task.detached(priority: .background) {
                try? POICache.saveForBundledCSV(parsed, resourceName: "pois", ext: "csv")
            }

        } catch {
            await MainActor.run {
                self.pois = []
                self.loadErrorMessage = error.localizedDescription
                // Keep overlay up and show Retry
                self.isLoadingPOIs = true
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
                .disabled(isLoadingPOIs)

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
                Button { mapStyle = .standard } label: {
                    Label("Standard", systemImage: mapStyle == .standard ? "checkmark" : "")
                }
                Button { mapStyle = .satellite } label: {
                    Label("Satellite", systemImage: mapStyle == .satellite ? "checkmark" : "")
                }
                Button { mapStyle = .hybrid } label: {
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

            Button { zoomAction = .zoomIn } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(12)
            }
            .buttonStyle(.plain)
            .background(.thinMaterial)
            .clipShape(Circle())
            .shadow(radius: 2)
            .accessibilityLabel("Zoom in")

            Button { zoomAction = .zoomOut } label: {
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
            if isLoadingPOIs { return "Starting up…" }
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
        guard !isLoadingPOIs else { return [] }
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

// MARK: - Startup Loading Screen (logo + caption)
// Named StartupOverlayView to avoid collisions with any existing StartupLoadingView.swift in your project.

private struct StartupOverlayView: View {
    let title: String
    let subtitle: String
    let logoAssetName: String
    let errorMessage: String?
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(logoAssetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let err = errorMessage, !err.isEmpty {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)

                    Button("Retry", action: onRetry)
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                } else {
                    ProgressView()
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 24)
        }
    }
}

// MARK: - Simple Cache (Property List, versioned)
//
// NOTE:
// This cache assumes your POI type supports these properties and a matching initializer.
// If your POI initializer differs (label names), paste your current POI.swift and I’ll align it exactly.

private enum POICache {
    private static let cacheVersion: Int = 1

    private struct CacheEnvelope: Codable {
        let version: Int
        let sourceByteCount: Int
        let items: [POICacheItem]
    }

    private struct POICacheItem: Codable {
        let pid: String
        let name: String
        let latitude: Double
        let longitude: Double

        let dataDate: Int?
        let dataSource: String?

        let state: String?
        let county: String?
        let marker: String?
        let setting: String?
        let lastRecoveredYear: Int?
        let lastCondition: String?
        let lastRecoveredBy: String?
        let orthoHeight: Double?
    }

    static func loadIfValidForBundledCSV(resourceName: String, ext: String) throws -> [POI]? {
        guard let srcURL = Bundle.main.url(forResource: resourceName, withExtension: ext) else { return nil }
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: srcURL.path)[.size] as? NSNumber)?.intValue ?? -1
        guard byteCount > 0 else { return nil }

        let cacheURL = try cacheFileURL()
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return nil }

        let data = try Data(contentsOf: cacheURL)
        let envelope = try PropertyListDecoder().decode(CacheEnvelope.self, from: data)
        guard envelope.version == cacheVersion, envelope.sourceByteCount == byteCount else { return nil }

        return envelope.items.map { item in
            POI(
                pid: item.pid,
                name: item.name,
                latitude: item.latitude,
                longitude: item.longitude,
                dataDate: item.dataDate,
                dataSource: item.dataSource,
                state: item.state,
                county: item.county,
                marker: item.marker,
                setting: item.setting,
                lastRecoveredYear: item.lastRecoveredYear,
                lastCondition: item.lastCondition,
                lastRecoveredBy: item.lastRecoveredBy,
                orthoHeight: item.orthoHeight
            )
        }

    }

    static func saveForBundledCSV(_ pois: [POI], resourceName: String, ext: String) throws {
        guard let srcURL = Bundle.main.url(forResource: resourceName, withExtension: ext) else { return }
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: srcURL.path)[.size] as? NSNumber)?.intValue ?? -1
        guard byteCount > 0 else { return }

        let items: [POICacheItem] = pois.map { p in
            POICacheItem(
                pid: p.pid,
                name: p.name,
                latitude: p.latitude,
                longitude: p.longitude,
                dataDate: p.dataDate,
                dataSource: p.dataSource,
                state: p.state,
                county: p.county,
                marker: p.marker,
                setting: p.setting,
                lastRecoveredYear: p.lastRecoveredYear,
                lastCondition: p.lastCondition,
                lastRecoveredBy: p.lastRecoveredBy,
                orthoHeight: p.orthoHeight
            )
        }

        let envelope = CacheEnvelope(version: cacheVersion, sourceByteCount: byteCount, items: items)
        let data = try PropertyListEncoder().encode(envelope)

        let url = try cacheFileURL()
        try data.write(to: url, options: [.atomic])
    }

    private static func cacheFileURL() throws -> URL {
        let dir = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return dir.appendingPathComponent("pois_cache_v\(cacheVersion).plist")
    }
}
