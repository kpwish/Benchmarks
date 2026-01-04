//
//  StatePackManager.swift
//  
//
//  Created by Kevin Wish on 1/1/26.
//


import Foundation

@MainActor
final class StatePackManager: ObservableObject {

    // MARK: - Published state

    @Published private(set) var manifest: StatePackManifest?
    @Published private(set) var remoteStates: [StatePackRemote] = []

    @Published private(set) var installed: [String: InstalledStatePack] = [:]
    @Published private(set) var activeStates: [String] = []   // max 2 enforced
    @Published private(set) var statusByState: [String: StatePackStatus] = [:]

    /// Only active states are loaded into memory.
    @Published private(set) var loadedPOIsByState: [String: [POI]] = [:]

    /// UI-friendly error (e.g., manifest fetch failure).
    @Published var globalErrorMessage: String?

    // MARK: - Config

    let maxActiveStates: Int
    private let manifestURL: URL
    private let bundledPacks: [String: BundledStatePack]

    // MARK: - Internals

    private let store = StatePackStore()
    private let fileManager = FileManager.default

    init(
        manifestURL: URL,
        maxActiveStates: Int = 2,
        bundledPacks: [BundledStatePack] = []
    ) {
        self.manifestURL = manifestURL
        self.maxActiveStates = maxActiveStates
        self.bundledPacks = Dictionary(uniqueKeysWithValues: bundledPacks.map { ($0.code, $0) })

        self.installed = store.loadInstalled()
        self.activeStates = store.loadActive()

        // Initialize statuses for installed packs
        for code in installed.keys {
            statusByState[code] = .installed
        }
    }

    // MARK: - Derived

    var activePOIsUnion: [POI] {
        activeStates.flatMap { loadedPOIsByState[$0] ?? [] }
    }

    func isBundledOnly(_ code: String) -> Bool {
        installed[code] == nil && bundledPacks[code] != nil
    }

    // MARK: - Paths

    private var baseDir: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("StatePacks", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var tmpDir: URL {
        let dir = baseDir.appendingPathComponent(".tmp", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func localCSVURL(for stateCode: String) -> URL? {
        guard let inst = installed[stateCode] else { return nil }
        return baseDir.appendingPathComponent(inst.localFilename)
    }

    // MARK: - Startup defaults

    func ensureDefaultActiveStateIfEmpty(defaultCode: String) {
        if activeStates.isEmpty {
            activeStates = [defaultCode]
            store.saveActive(activeStates)
        } else if activeStates.count > maxActiveStates {
            activeStates = Array(activeStates.prefix(maxActiveStates))
            store.saveActive(activeStates)
        }
    }

    // MARK: - Manifest

    func refreshManifest() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: manifestURL)
            let decoded = try JSONDecoder().decode(StatePackManifest.self, from: data)
            manifest = decoded
            remoteStates = decoded.states.sorted { $0.name < $1.name }
            globalErrorMessage = nil

            // Recompute status for each remote state
            for s in remoteStates {
                recomputeStatus(for: s.code)
            }
        } catch {
            globalErrorMessage = "Failed to load state list. Check your connection and try again."
            // Keep any existing remoteStates list if it was already loaded.
        }
    }

    private func recomputeStatus(for code: String) {
        guard let remote = remoteStates.first(where: { $0.code == code }) else { return }

        if let local = installed[code] {
            if local.version != remote.version {
                statusByState[code] = .updateAvailable(localVersion: local.version, remoteVersion: remote.version)
            } else {
                if case .downloading = statusByState[code] { return }
                statusByState[code] = .installed
            }
        } else {
            if case .downloading = statusByState[code] { return }
            statusByState[code] = .notInstalled
        }
    }

    // MARK: - Download / Update (atomic, checksum verified)

    func downloadOrUpdate(stateCode: String) async {
        guard let remote = remoteStates.first(where: { $0.code == stateCode }) else { return }
        await download(remote: remote)
    }

    private func download(remote: StatePackRemote) async {
        let code = remote.code

        if case .downloading = statusByState[code] { return }
        statusByState[code] = .downloading(progress: 0)

        let request = URLRequest(url: remote.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 180)

        do {
            // Download to temp file
            let (tempURL, _) = try await URLSession.shared.download(for: request)

            // Move to our tmp directory
            let tmpURL = tmpDir.appendingPathComponent("\(code).download")
            try? fileManager.removeItem(at: tmpURL)
            try fileManager.moveItem(at: tempURL, to: tmpURL)

            // Verify checksum
            let actualHash = try SHA256Util.fileHashHex(at: tmpURL)
            guard actualHash.lowercased() == remote.sha256.lowercased() else {
                try? fileManager.removeItem(at: tmpURL)
                statusByState[code] = .error(message: "Checksum failed. Please retry.")
                return
            }

            // Atomic replacement
            let finalFilename = "\(code).csv"
            let finalURL = baseDir.appendingPathComponent(finalFilename)
            let replaceURL = baseDir.appendingPathComponent("\(code).csv.replace")

            try? fileManager.removeItem(at: replaceURL)
            try fileManager.moveItem(at: tmpURL, to: replaceURL)

            if fileManager.fileExists(atPath: finalURL.path) {
                try? fileManager.removeItem(at: finalURL)
            }
            try fileManager.moveItem(at: replaceURL, to: finalURL)

            // Persist installed metadata
            let installedPack = InstalledStatePack(
                code: code,
                name: remote.name,
                version: remote.version,
                bytes: remote.bytes,
                sha256: remote.sha256,
                localFilename: finalFilename,
                installedAt: Date()
            )
            installed[code] = installedPack
            store.saveInstalled(installed)

            statusByState[code] = .installed

            // If active, reload from disk
            if activeStates.contains(code) {
                await loadStatePOIs(code: code)
            }

        } catch {
            statusByState[code] = .error(message: error.localizedDescription)
        }
    }

    func deleteState(stateCode: String) {
        if activeStates.contains(stateCode) {
            deactivateState(stateCode: stateCode)
        }

        if let url = localCSVURL(for: stateCode) {
            try? fileManager.removeItem(at: url)
        }

        installed[stateCode] = nil
        store.saveInstalled(installed)

        // Reset status (if remote exists, set to notInstalled; otherwise remove)
        if remoteStates.contains(where: { $0.code == stateCode }) {
            statusByState[stateCode] = .notInstalled
        } else {
            statusByState[stateCode] = nil
        }
    }

    // MARK: - Activate / Deactivate (max 2)

    /// Returns nil if activation succeeded; otherwise returns the list of currently active codes (caller should prompt to replace).
    func tryActivateState(stateCode: String) async -> [String]? {
        if !isActivatable(stateCode) { return nil }
        if activeStates.contains(stateCode) { return nil }

        if activeStates.count >= maxActiveStates {
            return activeStates
        }

        activeStates.append(stateCode)
        store.saveActive(activeStates)

        await loadStatePOIs(code: stateCode)
        return nil
    }

    func replaceActiveState(disable oldCode: String, enable newCode: String) async {
        guard activeStates.contains(oldCode) else { return }
        guard isActivatable(newCode) else { return }

        deactivateState(stateCode: oldCode)
        _ = await tryActivateState(stateCode: newCode)
    }

    func deactivateState(stateCode: String) {
        activeStates.removeAll { $0 == stateCode }
        store.saveActive(activeStates)

        // Unload immediately
        loadedPOIsByState[stateCode] = nil
    }

    func isActivatable(_ code: String) -> Bool {
        installed[code] != nil || bundledPacks[code] != nil
    }

    // MARK: - Load persisted active states (disk or bundle)

    func loadPersistedActiveStates() async {
        if activeStates.count > maxActiveStates {
            activeStates = Array(activeStates.prefix(maxActiveStates))
            store.saveActive(activeStates)
        }

        for code in activeStates {
            await loadStatePOIs(code: code)
        }
    }

    // MARK: - POI loading (disk preferred, bundle fallback)

    private func loadStatePOIs(code: String) async {
        do {
            if let diskURL = localCSVURL(for: code) {
                let pois = try await Task.detached(priority: .userInitiated) {
                    try POILoader.loadCSVFromFile(url: diskURL)

                }.value
                loadedPOIsByState[code] = pois
                return
            }

            if let bundled = bundledPacks[code] {
                let pois = POILoader.loadCSVFromBundle(named: bundled.resourceName, ext: bundled.ext)
                loadedPOIsByState[code] = pois
                return
            }

            loadedPOIsByState[code] = []
        } catch {
            loadedPOIsByState[code] = []
            statusByState[code] = .error(message: "Failed to parse \(code).csv. Consider re-downloading.")
        }
    }
}
