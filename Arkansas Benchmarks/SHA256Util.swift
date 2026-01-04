//
//  SHA256Util.swift
//  
//
//  Created by Kevin Wish on 1/1/26.
//


import Foundation
import CryptoKit

enum SHA256Util {
    static func fileHashHex(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = CryptoKit.SHA256()

        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
