import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var locationManager = LocationManager()

    // IMPORTANT: GitHub Releases manifest URL
    private static let manifestURL = URL(string: "https://github.com/kpwish/Benchmarks/releases/latest/download/manifest.json")!

    @StateObject private var statePacks = StatePackManager(
        manifestURL: ContentView.manifestURL,
        maxActiveStates: 2,
        bundledPacks: [
            BundledStatePack(code: "AR", name: "Arkansas", resourceName: "pois", ext: "csv")
        ]
    )

    @State private var bundledArkansasPOIs: [POI] = POILoader.loadCSVFromBundle(named: "pois", ext: "csv")

    // Priority list
    @State private var priorityPIDs: Set<String> = POILoader.loadPriorityPIDSetFromBundle(named: "priority", ext: "csv")
    @AppStorage("priorityOnlyEnabled") private var priorityOnlyEnabled: Bool = false

    @State private var selectedPOI: POI?
    @State private var isFollowingUser = true

    @State private var filters: POIFilters = .empty
    @State private var showingFilters = false

    @State private var mapStyle: MapStyle = .standard
    @State private var zoomAction: MapZoomAction? = nil

    @State private var showingInfo = false
    @State private var showingSettings = false

    @AppStorage("keepScreenAwake") private var keepScreenAwake: Bool = false

    var body: some View {
        ZStack {
            POIMapView(
                allPOIs: filteredPOIs,
                priorityPIDs: priorityPIDs,
                selectedPOI: $selectedPOI,
                isFollowingUser: $isFollowingUser,
                mapStyle: $mapStyle,
                zoomAction: $zoomAction
            )
            .onAppear {
                locationManager.start()
                applyIdleTimerSetting()
            }
            .task {
                statePacks.ensureDefaultActiveStateIfEmpty(defaultCode: "AR")
                await statePacks.loadPersistedActiveStates()
                await statePacks.refreshManifest()
            }
            .ignoresSafeArea()
            .sheet(item: $selectedPOI) { poi in
                POIDetailView(poi: poi, locationManager: locationManager)
            }
            .sheet(isPresented: $showingFilters) {
                FiltersView(options: filterOptions, filters: $filters)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingInfo) {
                infoSheet
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $showingSettings) {
                settingsSheet
                    .presentationDetents([.medium, .large])
            }
            .onChange(of: keepScreenAwake) { _, _ in
                applyIdleTimerSetting()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                UIApplication.shared.isIdleTimerDisabled = false
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                applyIdleTimerSetting()
            }

            VStack {
                Spacer()

                HStack {
                    Spacer()
                    rightMapControls
                }
                .padding(.trailing, 12)
                .padding(.bottom, 98)

                VStack(spacing: 10) {
                    if shouldShowSettingsCTA {
                        settingsBanner
                    }

                    bottomPillRowFullWidth
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 22)
            }
        }
    }

    // MARK: - POI source

    private var allLoadedPOIs: [POI] {
        let union = statePacks.activePOIsUnion
        return union.isEmpty ? bundledArkansasPOIs : union
    }

    private var displayBasePOIs: [POI] {
        guard priorityOnlyEnabled, !priorityPIDs.isEmpty else { return allLoadedPOIs }
        return allLoadedPOIs.filter { priorityPIDs.contains($0.pid.uppercased()) }
    }

    // MARK: - Full-width Bottom Pill Row

    private var bottomPillRowFullWidth: some View {
        HStack(spacing: 0) {
            iconItemButton(systemImage: "info.circle", accessibilityLabel: "Info") {
                showingInfo = true
            }

            divider

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
                iconItemLabel(systemImage: "square.3.layers.3d", badgeText: nil)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Layers")

            divider

            Button {
                showingFilters = true
            } label: {
                iconItemLabel(
                    systemImage: "line.3.horizontal.decrease.circle",
                    badgeText: filters.activeCount > 0 ? "\(filters.activeCount)" : nil
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Filters")
            .contextMenu {
                if filters.isActive {
                    Button(role: .destructive) {
                        clearFilters()
                    } label: {
                        Label("Clear Filters", systemImage: "xmark.circle")
                    }
                }
            }

            divider

            iconItemButton(
                systemImage: "gearshape",
                accessibilityLabel: "Settings",
                badgeText: keepScreenAwake ? "On" : nil
            ) {
                showingSettings = true
            }
        }
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(radius: 3)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }

    private var divider: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1, height: 26)
            .accessibilityHidden(true)
    }

    private func iconItemButton(
        systemImage: String,
        accessibilityLabel: String,
        badgeText: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            iconItemLabel(systemImage: systemImage, badgeText: badgeText)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 50)
        .accessibilityLabel(accessibilityLabel)
    }

    private func iconItemLabel(systemImage: String, badgeText: String?) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))

            if let badgeText {
                Text(badgeText)
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.thinMaterial)
                    .clipShape(Capsule())
                    .offset(x: 10, y: -8)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 50)
        .contentShape(Rectangle())
    }

    // MARK: - Settings Sheet

    private var settingsSheet: some View {
        NavigationStack {
            List {
                Section("Display") {
                    Toggle(isOn: $keepScreenAwake) {
                        Label("Screen Always On", systemImage: "sun.max")
                    }

                    Text("When enabled, the screen will stay on while the app is active. Recommended when connected to power.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Priority") {
                    Toggle(isOn: $priorityOnlyEnabled) {
                        Label("Priority Only", systemImage: "star.fill")
                    }
                    .tint(.blue)

                    if priorityPIDs.isEmpty {
                        Text("No priority.csv found in the app bundle, or it contains no PIDs.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("When enabled, only PIDs listed in priority.csv will be displayed. (\(priorityPIDs.count) PIDs)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Data") {
                    NavigationLink {
                        DownloadsView(manager: statePacks)
                            .onAppear {
                                // Performance: tighten map region while downloading/activating
                                isFollowingUser = true
                                // If you later add resetFollowZoom, you can trigger it here as well.
                                // zoomAction = .resetFollowZoom
                            }
                    } label: {
                        Label("Downloads", systemImage: "arrow.down.circle")
                    }

                    Text("Download one or more states, and keep up to two active at a time to limit memory usage.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingSettings = false }
                }
            }
        }
    }

    private func applyIdleTimerSetting() {
        UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
    }

    // MARK: - Info Sheet

    private var infoSheet: some View {
        NavigationStack {
            List {
                Section("Status") {
                    row("Location", value: locationStatusText)
                    if locationManager.isAuthorized {
                        row("Mode", value: isFollowingUser ? "Following" : "Free roam")
                    }
                }

                Section("POIs") {
                    row("Displayed", value: "\(filteredPOIs.count)")
                    row("Loaded", value: "\(allLoadedPOIs.count)")
                }

                if !priorityPIDs.isEmpty {
                    Section("Priority") {
                        row("Priority only", value: priorityOnlyEnabled ? "On" : "Off")
                        row("Priority PIDs", value: "\(priorityPIDs.count)")
                    }
                }

                if filters.isActive {
                    Section("Filters") {
                        Text("Filters are currently active.")
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            clearFilters()
                        } label: {
                            Label("Clear Filters", systemImage: "xmark.circle")
                        }
                    }
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingInfo = false }
                }
            }
        }
    }

    private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
    }

    private var locationStatusText: String {
        switch locationManager.authorizationStatus {
        case .notDetermined: return "Requesting permission…"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .authorizedWhenInUse: return "When In Use"
        case .authorizedAlways: return "Always"
        @unknown default: return "Unknown"
        }
    }

    // MARK: - Right-side map controls

    private var rightMapControls: some View {
        VStack(spacing: 10) {
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

    // MARK: - Filtering

    private var filterOptions: FilterOptions {
        // Build options from what’s eligible to be displayed (so options stay relevant in priority-only mode)
        let base = displayBasePOIs

        let markers = Array(Set(base.compactMap { $0.marker }.filter { !$0.isEmpty })).sorted()
        let settings = Array(Set(base.compactMap { $0.setting }.filter { !$0.isEmpty })).sorted()
        let lastConds = Array(Set(base.compactMap { $0.lastCondition }.filter { !$0.isEmpty })).sorted()

        let years = base.compactMap { $0.lastRecoveredYear }
        let yearRange: ClosedRange<Int>? = {
            guard let minY = years.min(), let maxY = years.max() else { return nil }
            return minY...maxY
        }()

        return FilterOptions(markers: markers, settings: settings, lastConditions: lastConds, yearRange: yearRange)
    }

    private var filteredPOIs: [POI] {
        let base = displayBasePOIs
        guard filters.isActive else { return base }
        return base.filter { matches($0, filters: filters) }
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
