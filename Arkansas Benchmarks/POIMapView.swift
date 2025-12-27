//
//  POIMapView.swift
//  Arkansas Benchmarks
//
//  Created by Kevin Wish on 12/21/25.
//


import SwiftUI
import MapKit

struct POIMapView: UIViewRepresentable {
    let allPOIs: [POI]

    @Binding var selectedPOI: POI?
    @Binding var isFollowingUser: Bool

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)

        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.userTrackingMode = .follow // follow initially

        // Optional: hide Apple built-in POIs so yours stand out
        map.pointOfInterestFilter = .excludingAll

        // Gesture detection: stop following when user interacts
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.userDidGesture))
        pan.delegate = context.coordinator
        map.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.userDidGesture))
        pinch.delegate = context.coordinator
        map.addGestureRecognizer(pinch)

        let rotate = UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.userDidGesture))
        rotate.delegate = context.coordinator
        map.addGestureRecognizer(rotate)

        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self

        let desiredMode: MKUserTrackingMode = isFollowingUser ? .follow : .none
        if map.userTrackingMode != desiredMode {
            map.setUserTrackingMode(desiredMode, animated: true)
        }

        context.coordinator.refreshAnnotations(for: map)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: POIMapView

        private var visibleIDs = Set<String>()
        private let poiReuseID = "POIMarker"

        init(parent: POIMapView) {
            self.parent = parent
            super.init()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func userDidGesture() {
            if parent.isFollowingUser {
                parent.isFollowingUser = false
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            refreshAnnotations(for: mapView)
        }

        func refreshAnnotations(for mapView: MKMapView) {
            // Expand viewport to reduce annotation churn while panning.
            let visible = mapView.visibleMapRect
            let paddedRect = visible.insetBy(dx: -visible.size.width * 0.30,
                                             dy: -visible.size.height * 0.30)

            var nowVisibleIDs = Set<String>()
            nowVisibleIDs.reserveCapacity(4000)

            var annotationsToAdd: [POIAnnotation] = []
            annotationsToAdd.reserveCapacity(500)

            for poi in parent.allPOIs {
                let point = MKMapPoint(poi.coordinate)
                guard paddedRect.contains(point) else { continue }

                nowVisibleIDs.insert(poi.id)

                if !visibleIDs.contains(poi.id) {
                    annotationsToAdd.append(POIAnnotation(poi: poi))
                }
            }

            let idsToRemove = visibleIDs.subtracting(nowVisibleIDs)
            if !idsToRemove.isEmpty {
                let toRemove = mapView.annotations.compactMap { ann -> MKAnnotation? in
                    guard let poiAnn = ann as? POIAnnotation else { return nil }
                    return idsToRemove.contains(poiAnn.poi.id) ? poiAnn : nil
                }
                if !toRemove.isEmpty {
                    mapView.removeAnnotations(toRemove)
                }
            }

            if !annotationsToAdd.isEmpty {
                mapView.addAnnotations(annotationsToAdd)
            }

            visibleIDs = nowVisibleIDs
        }

        // MARK: - Annotation Views (clustering always on)

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }

            if let cluster = annotation as? MKClusterAnnotation {
                let view = MKMarkerAnnotationView(annotation: cluster, reuseIdentifier: "Cluster")
                view.canShowCallout = true
                return view
            }

            guard let poiAnn = annotation as? POIAnnotation else { return nil }

            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: poiReuseID) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: poiAnn, reuseIdentifier: poiReuseID)

            view.annotation = poiAnn
            view.canShowCallout = true
            view.clusteringIdentifier = "poi-cluster" // always on

            view.rightCalloutAccessoryView = UIButton(type: .detailDisclosure)
            return view
        }

        func mapView(_ mapView: MKMapView,
                     annotationView view: MKAnnotationView,
                     calloutAccessoryControlTapped control: UIControl) {
            guard let poiAnn = view.annotation as? POIAnnotation else { return }
            parent.selectedPOI = poiAnn.poi
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let poiAnn = view.annotation as? POIAnnotation {
                parent.selectedPOI = poiAnn.poi
            }
        }
    }
}
