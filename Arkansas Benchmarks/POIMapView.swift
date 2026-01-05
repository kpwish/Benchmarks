import SwiftUI
import MapKit
import UIKit

enum MapStyle: String, CaseIterable {
    case standard
    case satellite
    case hybrid
}

enum MapZoomAction: Equatable {
    case zoomIn
    case zoomOut
}

struct POIMapView: UIViewRepresentable {
    let allPOIs: [POI]
    let priorityPIDs: Set<String>

    @Binding var selectedPOI: POI?
    @Binding var isFollowingUser: Bool

    @Binding var mapStyle: MapStyle
    @Binding var zoomAction: MapZoomAction?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)

        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.userTrackingMode = .follow

        map.showsCompass = true
        map.showsScale = true

        map.pointOfInterestFilter = .excludingAll

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.userDidGesture))
        pan.delegate = context.coordinator
        map.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.userDidGesture))
        pinch.delegate = context.coordinator
        map.addGestureRecognizer(pinch)

        let rotate = UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.userDidGesture))
        rotate.delegate = context.coordinator
        map.addGestureRecognizer(rotate)

        context.coordinator.mapView = map
        context.coordinator.applyMapStyle(mapStyle)

        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.mapView = map

        let desiredMode: MKUserTrackingMode = isFollowingUser ? .follow : .none
        if map.userTrackingMode != desiredMode {
            map.setUserTrackingMode(desiredMode, animated: true)
        }

        context.coordinator.applyMapStyle(mapStyle)

        if let action = zoomAction {
            context.coordinator.performZoom(action)
            DispatchQueue.main.async {
                self.zoomAction = nil
            }
        }

        context.coordinator.refreshAnnotations(for: map)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: POIMapView
        weak var mapView: MKMapView?

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

        // MARK: - Map Style

        func applyMapStyle(_ style: MapStyle) {
            guard let mapView else { return }

            switch style {
            case .standard:
                mapView.preferredConfiguration = MKStandardMapConfiguration()
            case .satellite:
                mapView.preferredConfiguration = MKImageryMapConfiguration()
            case .hybrid:
                mapView.preferredConfiguration = MKHybridMapConfiguration()
            }
        }

        // MARK: - Zoom

        func performZoom(_ action: MapZoomAction) {
            guard let mapView else { return }

            var region = mapView.region

            let minDelta: CLLocationDegrees = 0.0005
            let maxDelta: CLLocationDegrees = 90.0

            let factor: CLLocationDegrees = (action == .zoomIn) ? 0.5 : 2.0

            region.span.latitudeDelta = max(min(region.span.latitudeDelta * factor, maxDelta), minDelta)
            region.span.longitudeDelta = max(min(region.span.longitudeDelta * factor, maxDelta), minDelta)

            mapView.setRegion(region, animated: true)
        }

        // MARK: - Annotation Management

        func refreshAnnotations(for mapView: MKMapView) {
            let visible = mapView.visibleMapRect
            let paddedRect = visible.insetBy(dx: -visible.size.width * 0.30,
                                             dy: -visible.size.height * 0.30)

            var nowVisibleIDs = Set<String>()
            nowVisibleIDs.reserveCapacity(2000)

            var annotationsToAdd: [POIAnnotation] = []
            annotationsToAdd.reserveCapacity(300)

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
            view.clusteringIdentifier = "poi-cluster"
            view.rightCalloutAccessoryView = UIButton(type: .detailDisclosure)

            // Priority styling
            if parent.priorityPIDs.contains(poiAnn.poi.pid.uppercased()) {
                view.markerTintColor = .systemBlue
                view.glyphImage = UIImage(systemName: "star.fill")
            } else {
                // Default MapKit red marker; set nil so the system chooses the standard appearance.
                view.markerTintColor = nil
                view.glyphImage = nil
            }

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
