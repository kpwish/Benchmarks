//
//  ContentView 2.swift
//  Arkansas Benchmarks
//
//  Created by Kevin Wish on 12/21/25.
//


import SwiftUI

struct ContentView: View {
    @StateObject private var locationManager = LocationManager()

    // Ensure you have a file named "pois.csv" in your app bundle.
    @State private var pois: [POI] = POILoader.loadCSVFromBundle(named: "pois", ext: "csv")

    @State private var selectedPOI: POI?
    @State private var isFollowingUser = true

    var body: some View {
        ZStack(alignment: .bottom) {
            POIMapView(
                allPOIs: pois,
                selectedPOI: $selectedPOI,
                isFollowingUser: $isFollowingUser
            )
            .onAppear {
                locationManager.start()
            }
            .sheet(item: $selectedPOI) { poi in
                POIDetailView(poi: poi)
            }

            VStack(spacing: 10) {
                if shouldShowSettingsCTA {
                    settingsBanner
                }

                // Recenter button appears only when needed (not following)
                if locationManager.isAuthorized && !isFollowingUser {
                    HStack {
                        Spacer()
                        Button {
                            // Resume following; MKMapView will track user automatically.
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
                }

                statusBar
            }
            .padding()
        }
        .ignoresSafeArea()
    }

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
        case .notDetermined: return "Requesting location permission…"
        case .restricted: return "Location restricted."
        case .denied: return "Location denied."
        case .authorizedWhenInUse, .authorizedAlways:
            return "POIs loaded: \(pois.count)"
        @unknown default: return "Unknown authorization state."
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
