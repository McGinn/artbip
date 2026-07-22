import Foundation

/// Minimal RFC-4180 CSV parser (quoted fields, embedded commas/newlines/quotes).
/// Used for the NGA open-data dumps.
public enum CSV {
    /// Parse into rows of dictionaries keyed by the header row.
    public static func parse(_ data: Data) -> [[String: String]] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        var i = text.startIndex

        while i < text.endIndex {
            let c = text[i]
            if inQuotes {
                if c == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex && text[next] == "\"" {
                        field.append("\"")
                        i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",":
                    row.append(field); field = ""
                case "\r": break
                case "\n":
                    row.append(field); field = ""
                    rows.append(row); row = []
                default: field.append(c)
                }
            }
            i = text.index(after: i)
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }

        guard let header = rows.first else { return [] }
        return rows.dropFirst().compactMap { r in
            guard r.count == header.count else { return nil }
            return Dictionary(uniqueKeysWithValues: zip(header, r))
        }
    }
}
