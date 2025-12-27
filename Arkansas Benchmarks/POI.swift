//
//  POI.swift
//  Arkansas Benchmarks
//
//  Created by Kevin Wish on 12/21/25.
//

import Foundation
import CoreLocation

struct POI: Identifiable, Hashable {
    // Use PID as stable identifier
    var id: String { pid }

    // Required (current)
    let pid: String
    let name: String
    let latitude: Double
    let longitude: Double

    // Added fields (from your new dataset)
    // data_date (e.g., 20251219). Keep as Int? for simple sorting/filtering.
    let dataDate: Int?

    // data_srce (URL string)
    let dataSource: String?

    // state / county
    let state: String?
    let county: String?

    // marker / setting
    let marker: String?
    let setting: String?

    // last_recv (year in your sample)
    let lastRecoveredYear: Int?

    // last_cond / last_recby
    let lastCondition: String?
    let lastRecoveredBy: String?

    // ortho_ht
    let orthoHeight: Double?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
