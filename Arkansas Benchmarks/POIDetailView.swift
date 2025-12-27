//
//  POIDetailView.swift
//  Arkansas Benchmarks
//
//  Created by Kevin Wish on 12/21/25.
//


import SwiftUI

struct POIDetailView: View {
    let poi: POI

    var body: some View {
        NavigationStack {
            List {
                Section("PID") {
                    Text(poi.pid).monospaced()
                }
                Section("Name") {
                    Text(poi.name)
                }
                Section("Coordinates") {
                    Text(String(format: "%.6f, %.6f", poi.latitude, poi.longitude))
                        .monospaced()
                }
            }
            .navigationTitle("POI")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
