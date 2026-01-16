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
    let showPriorityPOIs: Bool
    
    @Binding var selectedPOI: POI?
    @Binding var isFollowingUser: Bool

    @Binding var mapStyle: MapStyle
    @Binding var zoomAction: MapZoomAction?

    // MARK: - Cluster selection support (Option A)
    // When a cluster is tapped (especially at maximum zoom where clusters may not break apart),
    // we surface its member POIs to SwiftUI so the parent view can present a chooser.
    @Binding var clusterPOIs: [POI]
    @Binding var isClusterSheetPresented: Bool

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

        // Initial render: schedule a refresh once the map has a region.
        context.coordinator.scheduleRefresh(reason: "initial")

        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.mapView = map

        // Follow mode update
        let desiredMode: MKUserTrackingMode = isFollowingUser ? .follow : .none
        if map.userTrackingMode != desiredMode {
            map.setUserTrackingMode(desiredMode, animated: true)
            context.coordinator.scheduleRefresh(reason: "trackingModeChanged")
        }

        // Map style update
        context.coordinator.applyMapStyle(mapStyle)

        // Zoom action
        if let action = zoomAction {
            context.coordinator.performZoom(action)
            DispatchQueue.main.async {
                self.zoomAction = nil
            }
            context.coordinator.scheduleRefresh(reason: "zoomAction")
        }

        // Data changes (state activation, downloads, priority set updates)
        if context.coordinator.noteDatasetChange(allPOIs: allPOIs, priorityPIDs: priorityPIDs) {
            context.coordinator.scheduleRefresh(reason: "datasetChanged")
        }

        // Important: do NOT call refreshAnnotations() here unconditionally.
        // Refresh is driven by debounced region changes and explicit triggers above.
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
        private let clusterReuseID = "Cluster"

        // Debounce
        private var pendingRefreshWork: DispatchWorkItem?

        // Dataset change tracking
        private var lastPOICount: Int = -1
        private var lastPOISignature: UInt64 = 0
        private var lastPriorityCount: Int = -1

        // Policy A threshold: when zoomed out beyond this span, show priority only.
        // Tune as desired. ~0.25° latitude is ~17 miles N/S.
        private let priorityOnlyLatitudeDeltaThreshold: CLLocationDegrees = 0.25

        // Limit for safety (avoid trying to add too many annotations at once).
        // This is not a hard UI rule, just a protective cap for one refresh pass.
        private let maxAnnotationsToAddPerRefresh = 2500

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
            // Debounce expensive work while the user is actively panning/zooming.
            scheduleRefresh(reason: "regionChanged")
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

        // MARK: - Dataset change tracking

        /// Returns true if the POI dataset or priority PID set changed materially.
        func noteDatasetChange(allPOIs: [POI], priorityPIDs: Set<String>) -> Bool {
            var changed = false

            if allPOIs.count != lastPOICount {
                lastPOICount = allPOIs.count
                changed = true
            }

            // Compute a lightweight signature without iterating every POI.
            // Use a few sample IDs to detect changes (good enough for UI refresh triggers).
            let sig = computePOISignature(allPOIs)
            if sig != lastPOISignature {
                lastPOISignature = sig
                changed = true
            }

            if priorityPIDs.count != lastPriorityCount {
                lastPriorityCount = priorityPIDs.count
                changed = true
            }

            return changed
        }

        private func computePOISignature(_ pois: [POI]) -> UInt64 {
            // Sample up to 16 elements across the array
            guard !pois.isEmpty else { return 0 }

            let sampleCount = min(16, pois.count)
            var acc: UInt64 = UInt64(pois.count)

            for i in 0..<sampleCount {
                let idx = (i * max(1, pois.count / sampleCount))
                let id = pois[idx].id
                acc ^= fnv1a64(id)
            }
            return acc
        }

        private func fnv1a64(_ s: String) -> UInt64 {
            // Simple FNV-1a 64-bit over UTF-8 bytes
            let prime: UInt64 = 1099511628211
            var hash: UInt64 = 14695981039346656037
            for b in s.utf8 {
                hash ^= UInt64(b)
                hash &*= prime
            }
            return hash
        }

        // MARK: - Debounced Refresh

        func scheduleRefresh(reason: String) {
            guard let mapView else { return }

            pendingRefreshWork?.cancel()

            let work = DispatchWorkItem { [weak self, weak mapView] in
                guard let self, let mapView else { return }
                self.refreshAnnotations(for: mapView)
            }
            pendingRefreshWork = work

            // 200ms debounce: smooths out rapid region changes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: work)
        }

        // MARK: - Annotation Management (Policy A)

        func refreshAnnotations(for mapView: MKMapView) {
            // Determine which dataset should be eligible based on zoom level (Policy A).
            let region = mapView.region
            let zoomedOut = region.span.latitudeDelta >= priorityOnlyLatitudeDeltaThreshold

            // Policy A: when zoomed out, show PRIORITY only (if any).
            let eligiblePOIs: [POI]
            if zoomedOut, !parent.priorityPIDs.isEmpty {
                eligiblePOIs = parent.allPOIs.filter { parent.priorityPIDs.contains($0.pid.uppercased()) }
            } else if zoomedOut {
                // If there are no priority PIDs, fall back to showing nothing when zoomed out.
                eligiblePOIs = []
            } else {
                // Zoomed in: show everything.
                eligiblePOIs = parent.allPOIs
            }

            let visible = mapView.visibleMapRect
            let paddedRect = visible.insetBy(dx: -visible.size.width * 0.30,
                                             dy: -visible.size.height * 0.30)

            var nowVisibleIDs = Set<String>()
            nowVisibleIDs.reserveCapacity(2000)

            var annotationsToAdd: [POIAnnotation] = []
            annotationsToAdd.reserveCapacity(300)

            // Scan eligible only (still O(M), but M is reduced dramatically when zoomed out).
            for poi in eligiblePOIs {
                let point = MKMapPoint(poi.coordinate)
                guard paddedRect.contains(point) else { continue }

                nowVisibleIDs.insert(poi.id)

                if !visibleIDs.contains(poi.id) {
                    annotationsToAdd.append(POIAnnotation(poi: poi))
                    if annotationsToAdd.count >= maxAnnotationsToAddPerRefresh {
                        break
                    }
                }
            }

            // Remove POIs that are no longer visible/eligible
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

        // MARK: - Annotation Views (clustering always on, blue if any priority member)

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }

            // CLUSTER VIEW
            if let cluster = annotation as? MKClusterAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: clusterReuseID) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: cluster, reuseIdentifier: clusterReuseID)

                view.annotation = cluster
                view.canShowCallout = true

                // Tint blue if any cluster member is priority
                let hasPriorityMember =
                    parent.showPriorityPOIs &&
                    cluster.memberAnnotations.contains { member in
                        guard let poiAnn = member as? POIAnnotation else { return false }
                        return parent.priorityPIDs.contains(poiAnn.poi.pid.uppercased())
                    }

                if hasPriorityMember {
                    view.markerTintColor = .systemBlue
                    view.glyphImage = UIImage(systemName: "star.fill")
                } else {
                    view.markerTintColor = nil
                    view.glyphImage = nil
                }

                return view
            }

            // INDIVIDUAL POI VIEW
            guard let poiAnn = annotation as? POIAnnotation else { return nil }

            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: poiReuseID) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: poiAnn, reuseIdentifier: poiReuseID)

            view.annotation = poiAnn
            view.canShowCallout = true
            view.clusteringIdentifier = "poi-cluster"
            view.rightCalloutAccessoryView = UIButton(type: .detailDisclosure)

            let isPriority =
                parent.showPriorityPOIs &&
                parent.priorityPIDs.contains(poiAnn.poi.pid.uppercased())
            if isPriority {
                view.markerTintColor = .systemBlue
                view.glyphImage = UIImage(systemName: "star.fill")
            } else {
                // Default system marker style (red)
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
            // Option A: If a cluster is selected, present a SwiftUI sheet listing member POIs.
            // This solves the "can't tap an individual POI" problem when points are too dense
            // or share identical coordinates at max zoom.
            if let cluster = view.annotation as? MKClusterAnnotation {
                let pois: [POI] = cluster.memberAnnotations.compactMap { member in
                    guard let poiAnn = member as? POIAnnotation else { return nil }
                    return poiAnn.poi
                }
                .sorted { $0.pid < $1.pid }

                if !pois.isEmpty {
                    parent.clusterPOIs = pois
                    parent.isClusterSheetPresented = true
                }

                // Deselect to avoid a lingering highlighted cluster.
                mapView.deselectAnnotation(cluster, animated: true)
                return
            }

            // Individual POI selection
            if let poiAnn = view.annotation as? POIAnnotation {
                parent.selectedPOI = poiAnn.poi
            }
        }
    }
}
