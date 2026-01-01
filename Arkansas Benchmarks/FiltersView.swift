//
//  FiltersView.swift
//  Arkansas Benchmarks
//
//  Created by Kevin Wish on 12/27/25.
//


import SwiftUI

struct FiltersView: View {
    @Environment(\.dismiss) private var dismiss

    let options: FilterOptions
    @Binding var filters: POIFilters

    // Local editable copies so Cancel is easy to support later if you want it
    @State private var markers: Set<String>
    @State private var settings: Set<String>
    @State private var lastConditions: Set<String>
    @State private var minYearText: String
    @State private var maxYearText: String

    init(options: FilterOptions, filters: Binding<POIFilters>) {
        self.options = options
        self._filters = filters

        _markers = State(initialValue: filters.wrappedValue.markers)
        _settings = State(initialValue: filters.wrappedValue.settings)
        _lastConditions = State(initialValue: filters.wrappedValue.lastConditions)

        _minYearText = State(initialValue: filters.wrappedValue.minLastRecoveredYear.map(String.init) ?? "")
        _maxYearText = State(initialValue: filters.wrappedValue.maxLastRecoveredYear.map(String.init) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                
                Section {
                    Button("Clear Filters") {
                        markers = []
                        settings = []
                        lastConditions = []
                        minYearText = ""
                        maxYearText = ""
                    }
                    .foregroundStyle(.red)
                }

                Section("last_cond") {
                    MultiSelectList(values: options.lastConditions, selection: $lastConditions)
                }

                Section("last_recv") {
                    HStack {
                        Text("min")
                        Spacer()
                        TextField("e.g., 1930", text: $minYearText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                    }
                    HStack {
                        Text("max")
                        Spacer()
                        TextField("e.g., 2025", text: $maxYearText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                    }

                    if let minY = parseYear(minYearText),
                       let maxY = parseYear(maxYearText),
                       minY > maxY {
                        Text("min must be ≤ max")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }

                    if let range = options.yearRange {
                        Text("dataset range: \(range.lowerBound)–\(range.upperBound)")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }
                }

                Section("marker") {
                    MultiSelectList(values: options.markers, selection: $markers)
                }

                Section("setting") {
                    MultiSelectList(values: options.settings, selection: $settings)
                }

            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        apply()
                        dismiss()
                    }
                    .disabled(hasYearRangeError)
                }
            }
        }
    }

    private var hasYearRangeError: Bool {
        if let minY = parseYear(minYearText),
           let maxY = parseYear(maxYearText) {
            return minY > maxY
        }
        return false
    }

    private func parseYear(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return Int(t)
    }

    private func apply() {
        filters.markers = markers
        filters.settings = settings
        filters.lastConditions = lastConditions
        filters.minLastRecoveredYear = parseYear(minYearText)
        filters.maxLastRecoveredYear = parseYear(maxYearText)
    }
}

// MARK: - Options model

struct FilterOptions {
    let markers: [String]
    let settings: [String]
    let lastConditions: [String]
    let yearRange: ClosedRange<Int>?
}

// MARK: - Multi-select list

private struct MultiSelectList: View {
    let values: [String]
    @Binding var selection: Set<String>

    var body: some View {
        if values.isEmpty {
            Text("—")
                .foregroundStyle(.secondary)
        } else {
            ForEach(values, id: \.self) { v in
                Button {
                    toggle(v)
                } label: {
                    HStack {
                        Text(v)
                        Spacer()
                        if selection.contains(v) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func toggle(_ v: String) {
        if selection.contains(v) {
            selection.remove(v)
        } else {
            selection.insert(v)
        }
    }
}
