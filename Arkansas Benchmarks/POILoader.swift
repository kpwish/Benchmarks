//
//  POILoader.swift
//  Arkansas Benchmarks
//
//  Created by Kevin Wish on 12/21/25.
//

import Foundation

enum POILoader {

    static func loadCSVFromBundle(named filename: String, ext: String = "csv") -> [POI] {
        guard let url = Bundle.main.url(forResource: filename, withExtension: ext) else {
            print("Missing \(filename).\(ext) in app bundle.")
            return []
        }

        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            return parseCSV(text)
        } catch {
            print("Failed to read \(filename).\(ext): \(error)")
            return []
        }
    }
    static func loadCSVFromFile(url: URL) -> [POI] {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            return parseCSV(text)
        } catch {
            print("Failed to read CSV at \(url): \(error)")
            return []
        }
    }
    
    /// Parses CSV with:
    /// - header-based column lookup (supports both old and new schemas)
    /// - quoted field support (commas inside quotes)
    static func parseCSV(_ text: String) -> [POI] {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.count >= 2 else { return [] }

        // Parse header
        let headerFields = splitCSVLine(lines[0]).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Build header index safely (avoids duplicate-key fatal error)
        var headerIndex: [String: Int] = [:]
        headerIndex.reserveCapacity(headerFields.count)

        for (idx, rawName) in headerFields.enumerated() {
            let key = normalizeHeader(rawName)
            guard !key.isEmpty else { continue }
            if headerIndex[key] == nil {
                headerIndex[key] = idx
            }
        }

        func indexForAny(_ keys: [String]) -> Int? {
            for k in keys {
                if let i = headerIndex[normalizeHeader(k)] { return i }
            }
            return nil
        }

        // Required columns (support both old and new header naming)
        guard
            let iPID  = indexForAny(["pid", "PID"]),
            let iName = indexForAny(["name", "NAME"]),
            let iLat  = indexForAny(["dec_lat", "DEC_LAT"]),
            let iLon  = indexForAny(["dec_lon", "DEC_LONG", "dec_long"])
        else {
            print("CSV header missing required columns. Found: \(headerFields)")
            return []
        }

        // Optional columns (new schema)
        let iDataDate   = indexForAny(["data_date", "DATA_DATE"])
        let iDataSrce   = indexForAny(["data_srce", "DATA_SRCE"])
        let iState      = indexForAny(["state", "STATE"])
        let iCounty     = indexForAny(["county", "COUNTY"])
        let iMarker     = indexForAny(["marker", "MARKER"])
        let iSetting    = indexForAny(["setting", "SETTING"])
        let iLastRecv   = indexForAny(["last_recv", "LAST_RECV"])
        let iLastCond   = indexForAny(["last_cond", "LAST_COND"])
        let iLastRecBy  = indexForAny(["last_recby", "LAST_RECBY"])
        let iOrthoHt    = indexForAny(["ortho_ht", "ORTHO_HT"])

        var pois: [POI] = []
        pois.reserveCapacity(lines.count - 1)

        for line in lines.dropFirst() {
            let fields = splitCSVLine(line)

            func field(_ i: Int?) -> String? {
                guard let i, i >= 0, i < fields.count else { return nil }
                let v = normalizeValue(fields[i])
                return v.isEmpty ? nil : v
            }

            guard
                let pid = field(iPID),
                let name = field(iName),
                let latStr = field(iLat),
                let lonStr = field(iLon),
                let latitude = Double(latStr),
                let longitude = Double(lonStr)
            else { continue }

            // Parse numeric optionals
            let dataDate: Int? = field(iDataDate).flatMap { Int($0) }
            let lastYear: Int? = field(iLastRecv).flatMap { Int($0) }
            let ortho: Double? = field(iOrthoHt).flatMap { Double($0) }

            // Construct POI with your expanded model
            pois.append(
                POI(
                    pid: pid,
                    name: name,
                    latitude: latitude,
                    longitude: longitude,
                    dataDate: dataDate,
                    dataSource: field(iDataSrce),
                    state: field(iState),
                    county: field(iCounty),
                    marker: field(iMarker),
                    setting: field(iSetting),
                    lastRecoveredYear: lastYear,
                    lastCondition: field(iLastCond),
                    lastRecoveredBy: field(iLastRecBy),
                    orthoHeight: ortho
                )
            )
        }

        return pois
    }

    // MARK: - Helpers

    /// Splits a single CSV line into fields.
    /// Supports:
    /// - comma delimiters
    /// - quotes around fields
    /// - escaped quotes within quoted fields ("" -> ")
    private static func splitCSVLine(_ line: String) -> [String] {
        var result: [String] = []
        result.reserveCapacity(16)

        var current = ""
        var inQuotes = false
        var i = line.startIndex

        while i < line.endIndex {
            let ch = line[i]

            if ch == "\"" {
                if inQuotes {
                    let next = line.index(after: i)
                    if next < line.endIndex, line[next] == "\"" {
                        current.append("\"")
                        i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    inQuotes = true
                }
            } else if ch == "," && !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(ch)
            }

            i = line.index(after: i)
        }

        result.append(current)
        return result
    }

    private static func normalizeHeader(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{feff}", with: "") // BOM guard
            .uppercased()
    }

    private static func normalizeValue(_ s: String) -> String {
        // Trim + collapse repeated whitespace (cleans padded COUNTY/marker strings)
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.replacingOccurrences(of: #"[\s]+"#, with: " ", options: .regularExpression)
    }
}
