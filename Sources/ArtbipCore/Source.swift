import Foundation

/// Context handed to every source plugin.
public struct SourceContext: Sendable {
    public let http: Http
    /// Scratch dir for large downloads (e.g. NGA CSVs): work/sources/<id>/
    public let workDir: URL
    public let config: CurateConfig
    public let log: @Sendable (String) -> Void

    public init(http: Http, workDir: URL, config: CurateConfig, log: @escaping @Sendable (String) -> Void) {
        self.http = http
        self.workDir = workDir
        self.config = config
        self.log = log
    }
}

/// A museum / aggregator source. Adding a museum is one file implementing this.
public protocol ArtSource: Sendable {
    static var id: String { get }
    func candidates(_ ctx: SourceContext) async throws -> [Candidate]
}

// MARK: - Shared parsing helpers used by plugins

public enum Parse {
    /// Extract a death year from display strings like
    /// "Georges Seurat (French, 1859–1891)" or "Dutch, 1606 - 1669".
    public static func deathYear(fromArtistDisplay s: String?) -> Int? {
        guard let s else { return nil }
        // Match year ranges with en-dash, em-dash, or hyphen; take the second year.
        let pattern = #"(1[0-9]{3}|20[0-2][0-9])\s*[–—-]\s*(1[0-9]{3}|20[0-2][0-9])"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 2), in: s) else { return nil }
        return Int(s[r])
    }

    /// "Georges Seurat" -> "Seurat, Georges". Leaves single-token and
    /// already-comma'd names alone.
    public static func sortName(_ name: String?) -> String? {
        guard let name, !name.contains(",") else { return name }
        let parts = name.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return name }
        let last = parts.last!
        let rest = parts.dropLast().joined(separator: " ")
        return "\(last), \(rest)"
    }

    /// First 4-digit year in a string.
    public static func year(in s: String?) -> Int? {
        guard let s else { return nil }
        let pattern = #"1[0-9]{3}|20[0-2][0-9]"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range, in: s) else { return nil }
        return Int(s[r])
    }

    /// Strip HTML tags and collapse whitespace (Commons extmetadata values are HTML).
    public static func stripHTML(_ s: String) -> String {
        let noTags = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return noTags
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
