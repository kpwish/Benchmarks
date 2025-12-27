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

    /// Parses CSV with:
    /// - header-based column lookup for DEC_LONG, DEC_LAT, PID, NAME
    /// - quoted field support (commas inside quotes)
    /// - ignores any extra columns (like trailing empty columns)
    static func parseCSV(_ text: String) -> [POI] {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.count >= 2 else { return [] }

        // Parse header
        let headerFields = splitCSVLine(lines[0]).map { $0.trimmingCharacters(in: .whitespaces) }
        let headerIndex: [String: Int] = Dictionary(
            uniqueKeysWithValues: headerFields.enumerated().map { idx, name in
                (name.uppercased(), idx)
            }
        )

        guard
            let iLong = headerIndex["DEC_LONG"],
            let iLat  = headerIndex["DEC_LAT"],
            let iPID  = headerIndex["PID"],
            let iName = headerIndex["NAME"]
        else {
            print("CSV header missing required columns. Found: \(headerFields)")
            return []
        }

        var pois: [POI] = []
        pois.reserveCapacity(lines.count - 1)

        for line in lines.dropFirst() {
            let fields = splitCSVLine(line)

            // Guard against short/malformed rows
            let maxIndex = max(iLong, iLat, iPID, iName)
            guard fields.count > maxIndex else { continue }

            let longStr = fields[iLong].trimmingCharacters(in: .whitespaces)
            let latStr  = fields[iLat].trimmingCharacters(in: .whitespaces)
            let pid     = fields[iPID].trimmingCharacters(in: .whitespaces)
            let name    = fields[iName].trimmingCharacters(in: .whitespaces)

            guard
                let longitude = Double(longStr),
                let latitude  = Double(latStr),
                !pid.isEmpty
            else { continue }

            pois.append(POI(pid: pid, name: name, latitude: latitude, longitude: longitude))
        }

        return pois
    }

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
                    // Escaped quote?
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
}
