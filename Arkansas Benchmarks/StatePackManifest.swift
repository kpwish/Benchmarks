//
//  StatePackManifest.swift
//  
//
//  Created by Kevin Wish on 1/1/26.
//


import Foundation

struct StatePackManifest: Codable {
    let schemaVersion: Int
    let updatedAt: String
    let states: [StatePackRemote]
}

struct StatePackRemote: Codable, Identifiable, Hashable {
    var id: String { code }
    let code: String      // "AR"
    let name: String      // "Arkansas"
    let version: String   // e.g. "2025-12-19"
    let bytes: Int
    let sha256: String
    let url: URL
}

struct InstalledStatePack: Codable, Hashable {
    let code: String
    let name: String
    let version: String
    let bytes: Int
    let sha256: String
    let localFilename: String
    let installedAt: Date
}

struct BundledStatePack: Hashable {
    let code: String
    let name: String
    let resourceName: String
    let ext: String
}

enum StatePackStatus: Equatable {
    case notInstalled
    case downloading(progress: Double)
    case installed
    case updateAvailable(localVersion: String, remoteVersion: String)
    case error(message: String)
}
