//
//  StatePackStore.swift
//  
//
//  Created by Kevin Wish on 1/1/26.
//


import Foundation

final class StatePackStore {
    private let installedKey = "installedStatePacks_v1"
    private let activeKey = "activeStates_v1"

    func loadInstalled() -> [String: InstalledStatePack] {
        guard let data = UserDefaults.standard.data(forKey: installedKey) else { return [:] }
        return (try? JSONDecoder().decode([String: InstalledStatePack].self, from: data)) ?? [:]
    }

    func saveInstalled(_ value: [String: InstalledStatePack]) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: installedKey)
        }
    }

    func loadActive() -> [String] {
        UserDefaults.standard.stringArray(forKey: activeKey) ?? []
    }

    func saveActive(_ value: [String]) {
        UserDefaults.standard.set(value, forKey: activeKey)
    }
}
