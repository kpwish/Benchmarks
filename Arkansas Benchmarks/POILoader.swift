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

    static func loadCSVFromFile(url: URL) throws -> [POI] {
        // Load raw bytes from disk
        let data = try Data(contentsOf: url)

        // Decode explicitly as UTF-8
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "POILoader",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "CSV file is not valid UTF-8"]
            )
        }

        return parseCSV(text)
    }

    // MARK: - Priority PID loading

    /// Loads `priority.csv` from the bundle and returns a Set of PIDs.
    /// Supported formats:
    /// - One PID per line
    /// - Optional header row (e.g. "pid")
    /// - CSV rows where PID is the first column
    static func loadPriorityPIDSetFromBundle(named filename: String = "priority", ext: String = "csv") -> Set<String> {
        guard let url = Bundle.main.url(forResource: filename, withExtension: ext) else {
            print("Missing \(filename).\(ext) in app bundle.")
            return []
        }

        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            return parsePIDList(text)
        } catch {
            print("Failed to read \(filename).\(ext): \(error)")
            return []
        }
    }

    private static func parsePIDList(_ text: String) -> Set<String> {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return [] }

        var result = Set<String>()
        result.reserveCapacity(min(lines.count, 10_000))

        for line in lines {
            // Allow CSV style rows; take first field
            let fields = splitCSVLine(line)
            guard let first = fields.first else { continue }

            let pid = normalizeValue(first)
                .uppercased()

            if pid.isEmpty { continue }
            if pid == "PID" { continue } // ignore optional header

            result.insert(pid)
        }

        return result
    }

    // MARK: - POI CSV parsing (existing)

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
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.replacingOccurrences(of: #"[\s]+"#, with: " ", options: .regularExpression)
    }
}
