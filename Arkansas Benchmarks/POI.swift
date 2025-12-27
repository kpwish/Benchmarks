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

    let pid: String
    let name: String
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
