//
//  POIAnnotation.swift
//  Arkansas Benchmarks
//
//  Created by Kevin Wish on 12/21/25.
//


import MapKit

final class POIAnnotation: NSObject, MKAnnotation {
    let poi: POI

    var coordinate: CLLocationCoordinate2D { poi.coordinate }
    var title: String? { poi.name }
    var subtitle: String? { poi.pid }

    init(poi: POI) {
        self.poi = poi
        super.init()
    }
}
