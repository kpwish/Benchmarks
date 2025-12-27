//
//  POIFilters.swift
//  Arkansas Benchmarks
//
//  Created by Kevin Wish on 12/27/25.
//


import Foundation

struct POIFilters: Equatable {
    var markers: Set<String> = []
    var settings: Set<String> = []
    var lastConditions: Set<String> = []

    // last_recv is year in your dataset
    var minLastRecoveredYear: Int? = nil
    var maxLastRecoveredYear: Int? = nil

    var isActive: Bool {
        !markers.isEmpty ||
        !settings.isEmpty ||
        !lastConditions.isEmpty ||
        minLastRecoveredYear != nil ||
        maxLastRecoveredYear != nil
    }

    var activeCount: Int {
        var count = 0
        if !markers.isEmpty { count += 1 }
        if !settings.isEmpty { count += 1 }
        if !lastConditions.isEmpty { count += 1 }
        if minLastRecoveredYear != nil || maxLastRecoveredYear != nil { count += 1 }
        return count
    }

    static let empty = POIFilters()
}
