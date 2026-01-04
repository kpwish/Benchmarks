//
//  DownloadsView.swift
//  
//
//  Created by Kevin Wish on 1/1/26.
//


import SwiftUI

struct DownloadsView: View {
    @ObservedObject var manager: StatePackManager

    @State private var showingReplacePrompt = false
    @State private var pendingActivateCode: String?
    @State private var activeToReplace: [String] = []

    var body: some View {
        List {
            activeSection
            allStatesSection
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if manager.manifest == nil {
                await manager.refreshManifest()
            }
        }
        .refreshable {
            await manager.refreshManifest()
        }
        .alert("Only \(manager.maxActiveStates) states can be active", isPresented: $showingReplacePrompt) {
            ForEach(activeToReplace, id: \.self) { code in
                Button("Replace \(labelFor(code))") {
                    guard let newCode = pendingActivateCode else { return }
                    Task { await manager.replaceActiveState(disable: code, enable: newCode) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deactivate one state to activate another.")
        }
    }

    private var activeSection: some View {
        Section("Active (max \(manager.maxActiveStates))") {
            if manager.activeStates.isEmpty {
                Text("No active states. Activate up to \(manager.maxActiveStates) states.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.activeStates, id: \.self) { code in
                    HStack {
                        Text(labelFor(code))
                        Spacer()
                        Button("Deactivate") {
                            manager.deactivateState(stateCode: code)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var allStatesSection: some View {
        Section("All States") {
            if let msg = manager.globalErrorMessage {
                Text(msg)
                    .foregroundStyle(.secondary)
            }

            // If manifest lists states, show them.
            if !manager.remoteStates.isEmpty {
                ForEach(manager.remoteStates) { s in
                    StateRow(
                        remote: s,
                        status: manager.statusByState[s.code] ?? .notInstalled,
                        isInstalled: manager.installed[s.code] != nil,
                        isActive: manager.activeStates.contains(s.code),
                        isBundledOnly: manager.isBundledOnly(s.code),
                        onDownloadOrUpdate: { Task { await manager.downloadOrUpdate(stateCode: s.code) } },
                        onDelete: { manager.deleteState(stateCode: s.code) },
                        onActivate: { activateTapped(code: s.code) }
                    )
                }
            } else {
                Text("Pull to refresh to load the state list.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func activateTapped(code: String) {
        Task {
            if let currentlyActive = await manager.tryActivateState(stateCode: code) {
                pendingActivateCode = code
                activeToReplace = currentlyActive
                showingReplacePrompt = true
            }
        }
    }

    private func labelFor(_ code: String) -> String {
        if let remote = manager.remoteStates.first(where: { $0.code == code }) {
            return "\(remote.name) (\(remote.code))"
        }
        // If not in manifest (offline), show code only.
        return code
    }
}

private struct StateRow: View {
    let remote: StatePackRemote
    let status: StatePackStatus
    let isInstalled: Bool
    let isActive: Bool
    let isBundledOnly: Bool

    let onDownloadOrUpdate: () -> Void
    let onDelete: () -> Void
    let onActivate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(remote.name) (\(remote.code))")
                    .font(.headline)

                Spacer()

                if isActive {
                    Text("Active")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.thinMaterial)
                        .clipShape(Capsule())
                }
            }

            HStack {
                Text(sizeString(remote.bytes))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()

                statusBadge(status)
            }

            controls
        }
        .padding(.vertical, 6)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if isInstalled {
                Button(role: .destructive) { onDelete() } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch status {
        case .notInstalled:
            Button("Download") { onDownloadOrUpdate() }
                .buttonStyle(.borderedProminent)

        case .installed:
            HStack {
                if !isActive {
                    Button("Activate") { onActivate() }
                        .buttonStyle(.bordered)
                } else {
                    Text("Enabled on map")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isBundledOnly && !isInstalled {
                    Text("Bundled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isInstalled {
                    Menu {
                        Button(role: .destructive) { onDelete() } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                    }
                }
            }

        case let .updateAvailable(_, remoteVersion):
            HStack {
                Button("Update") { onDownloadOrUpdate() }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Text("v\(remoteVersion)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .downloading:
            HStack {
                ProgressView()
                Text("Downloading…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case let .error(message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Retry") { onDownloadOrUpdate() }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                    if isInstalled {
                        Button("Delete") { onDelete() }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func sizeString(_ bytes: Int) -> String {
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.1f MB", mb)
    }

    @ViewBuilder
    private func statusBadge(_ status: StatePackStatus) -> some View {
        switch status {
        case .notInstalled:
            Text("Not installed").font(.caption).foregroundStyle(.secondary)
        case .installed:
            Text("Installed").font(.caption).foregroundStyle(.secondary)
        case .updateAvailable:
            Text("Update available").font(.caption).foregroundStyle(.secondary)
        case .downloading:
            Text("Downloading").font(.caption).foregroundStyle(.secondary)
        case .error:
            Text("Error").font(.caption).foregroundStyle(.secondary)
        }
    }
}
