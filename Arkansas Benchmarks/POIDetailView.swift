import SwiftUI

struct POIDetailView: View {
    let poi: POI

    var body: some View {
        NavigationStack {
            List {
                header

                if hasRecoveryInfo {
                    Section("Recovery") {
                        labeledRow("Last recovered", value: poi.lastRecoveredYear.map(String.init))
                        labeledRow("Condition", value: poi.lastCondition)
                        labeledRow("Recovered by", value: poi.lastRecoveredBy)
                    }
                }

                Section("Classification") {
                    labeledRow("Marker", value: poi.marker)
                    labeledRow("Setting", value: poi.setting)
                }

                Section("Location") {
                    labeledRow("County", value: poi.county)
                    labeledRow("State", value: poi.state)

                    // Show coordinates in a consistent monospaced format
                    labeledRow("Latitude", value: formatCoord(poi.latitude), monospaced: true)
                    labeledRow("Longitude", value: formatCoord(poi.longitude), monospaced: true)

                    if let h = poi.orthoHeight {
                        labeledRow("Ortho height (m)", value: String(format: "%.3f", h), monospaced: true)
                    }
                }

                Section("Actions") {
                    if let url = dataSourceURL {
                        Link(destination: url) {
                            Label("Open datasheet", systemImage: "safari")
                        }
                    }

                    Button {
                        copyToPasteboard(poi.pid)
                    } label: {
                        Label("Copy PID", systemImage: "doc.on.doc")
                    }

                    Button {
                        copyToPasteboard("\(poi.latitude), \(poi.longitude)")
                    } label: {
                        Label("Copy coordinates", systemImage: "mappin.and.ellipse")
                    }
                }

                if hasSourceInfo {
                    Section("Source") {
                        labeledRow("Data date", value: poi.dataDate.map(String.init), monospaced: true)

                        if let s = poi.dataSource, !s.isEmpty {
                            // Keep the raw URL visible but subdued; users can still inspect it.
                            Text(s)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                    }
                }
            }
            .navigationTitle("Benchmark")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Header (primary identity)

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(poi.name)
                .font(.headline)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Text(poi.pid)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospaced()

                if let marker = nonEmpty(poi.marker) {
                    Text("•")
                        .foregroundStyle(.secondary)
                    Text(markerShort(marker))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Helpers / Formatting

    private var hasRecoveryInfo: Bool {
        poi.lastRecoveredYear != nil ||
        nonEmpty(poi.lastCondition) != nil ||
        nonEmpty(poi.lastRecoveredBy) != nil
    }

    private var hasSourceInfo: Bool {
        poi.dataDate != nil || dataSourceURL != nil
    }

    private var dataSourceURL: URL? {
        guard let s = nonEmpty(poi.dataSource) else { return nil }
        return URL(string: s)
    }

    private func labeledRow(_ label: String, value: String?, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            if let v = nonEmpty(value) {
                Text(v)
                    .multilineTextAlignment(.trailing)
                    .font(monospaced ? .body.monospaced() : .body)
                    .textSelection(.enabled)
            } else {
                Text("Not available")
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func formatCoord(_ value: Double) -> String {
        String(format: "%.10f", value)
    }

    // Optional: shorten marker strings like "B = BOLT" to just "BOLT" for the header line.
    private func markerShort(_ marker: String) -> String {
        if let eq = marker.firstIndex(of: "=") {
            return marker[marker.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return marker
    }

    private func copyToPasteboard(_ s: String) {
        UIPasteboard.general.string = s
    }
}
