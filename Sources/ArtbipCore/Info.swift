import Foundation

// MARK: - Artwork info (data/info.json) — see docs/artwork-info.md
//
// Optional per-work "About this work" content: context (why the work
// matters) and details (what to look at), each paragraph carrying the
// citations that ground it. Wording is original; citations point into a
// private reference corpus (book:<slug>:<page>) or the open web
// (url:<https…>). A work with no entry simply renders its titleplate
// from the manifest — absence is the designed fallback, never filler.

public struct InfoSource: Codable, Sendable {
    public var title: String
    public var author: String
    public var year: Int?
    public var kind: String            // "book" | "web"

    public init(title: String, author: String, year: Int? = nil, kind: String = "book") {
        self.title = title
        self.author = author
        self.year = year
        self.kind = kind
    }
}

public struct InfoParagraph: Codable, Sendable {
    public var text: String
    /// Citations grounding this paragraph: "book:<slug>:<page>" (page is the
    /// PDF page of the corpus edition) or "url:<https…>".
    public var cite: [String]

    public init(text: String, cite: [String]) {
        self.text = text
        self.cite = cite
    }
}

public struct WorkInfo: Codable, Sendable {
    public var context: [InfoParagraph]
    public var details: [InfoParagraph]
    /// Provenance of the entry itself ("claude-fable-5", "2026-08-02") so a
    /// bad entry can be traced to the generation wave that wrote it.
    public var generatedBy: String?
    public var generatedOn: String?

    public init(context: [InfoParagraph] = [], details: [InfoParagraph] = [],
                generatedBy: String? = nil, generatedOn: String? = nil) {
        self.context = context
        self.details = details
        self.generatedBy = generatedBy
        self.generatedOn = generatedOn
    }
}

/// Period, style and place for a school or movement — the gallery's section
/// label rather than its object label.
///
/// Keyed by the manifest's `movement` string, so one entry serves every work
/// tagged with it. That is the only way this scales: 12 of 2,000 works have a
/// per-work entry, while the 30 commonest movements alone cover 929 of them.
public struct SchoolInfo: Codable, Sendable {
    /// Display name — manifest movement strings are inconsistently cased
    /// ("academic art" next to "High Renaissance").
    public var name: String
    /// When the school was active, e.g. "c. 1600–1680".
    public var span: String?
    /// Where, e.g. "The Dutch Republic".
    public var places: String?
    public var context: [InfoParagraph]
    public var generatedBy: String?
    public var generatedOn: String?

    public init(name: String, span: String? = nil, places: String? = nil,
                context: [InfoParagraph] = [],
                generatedBy: String? = nil, generatedOn: String? = nil) {
        self.name = name
        self.span = span
        self.places = places
        self.context = context
        self.generatedBy = generatedBy
        self.generatedOn = generatedOn
    }

    /// "c. 1600–1680 · The Dutch Republic"
    public var subtitle: String? {
        let parts = [span, places].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The painter — the gallery's other section label, and the one that reaches
/// furthest.
///
/// Keyed by the manifest's `artistSort` ("Gogh, Vincent van"), which every work
/// carries. Artists concentrate harder than movements do: 50 of them account for
/// 1,220 of 2,000 works and 100 for 1,526. They also cover ground schools cannot
/// — 954 works have no `movement` string at all, and 727 of the works no school
/// reaches are by a top-100 artist.
public struct ArtistInfo: Codable, Sendable {
    /// Display name in natural order, since `artistSort` is filed backwards.
    public var name: String
    /// Life dates, e.g. "1606–1669".
    public var span: String?
    /// Where they worked, e.g. "Leiden and Amsterdam".
    public var places: String?
    public var context: [InfoParagraph]
    public var generatedBy: String?
    public var generatedOn: String?

    public init(name: String, span: String? = nil, places: String? = nil,
                context: [InfoParagraph] = [],
                generatedBy: String? = nil, generatedOn: String? = nil) {
        self.name = name
        self.span = span
        self.places = places
        self.context = context
        self.generatedBy = generatedBy
        self.generatedOn = generatedOn
    }

    /// "1606–1669 · Leiden and Amsterdam"
    public var subtitle: String? {
        let parts = [span, places].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// An iconographic object and what it conventionally means.
///
/// The text says what the object signifies *in this tradition* — never what a
/// particular painting means by it. That distinction is what makes the tier
/// safe to generate: works are tagged by matching the manifest's caption, which
/// is a heuristic rather than an observation, so a stray tag shows a glossary
/// entry that does not apply rather than asserting something false about the
/// picture in front of you.
public struct SymbolInfo: Codable, Sendable {
    public var name: String
    public var text: String
    public var cite: [String]

    public init(name: String, text: String, cite: [String] = []) {
        self.name = name
        self.text = text
        self.cite = cite
    }
}

public struct InfoFile: Codable, Sendable {
    public var schemaVersion: Int
    public var sources: [String: InfoSource]
    public var entries: [String: WorkInfo]
    public var schools: [String: SchoolInfo]
    public var artists: [String: ArtistInfo]
    /// Manifest movement string -> school key, for the many near-synonyms the
    /// source data carries ("Italian Baroque painting", "Spanish Baroque
    /// painting"). Only for movements a school genuinely covers — never to
    /// bolt a rough match onto the nearest entry.
    public var schoolAliases: [String: String]
    /// Manifest `artistSort` -> artist key. The manifest's sort keys were built
    /// by moving the last word to the front, which splits one painter across
    /// several strings — an accent ("Manet, Édouard" beside "Manet, Edouard"),
    /// a parenthesised full name, an honorific, or a patronymic Rembrandt is
    /// filed under four different ways. Same discipline as `schoolAliases`:
    /// only for variants that are genuinely the same hand, never to attach a
    /// near-miss to the closest entry.
    public var artistAliases: [String: String]
    /// Iconographic objects, keyed by a short slug ("skull", "lily").
    public var symbols: [String: SymbolInfo]
    /// Work id -> the symbol slugs its caption says are visible.
    public var workSymbols: [String: [String]]

    public init(schemaVersion: Int = 1, sources: [String: InfoSource] = [:],
                entries: [String: WorkInfo] = [:],
                schools: [String: SchoolInfo] = [:],
                schoolAliases: [String: String] = [:],
                artists: [String: ArtistInfo] = [:],
                artistAliases: [String: String] = [:],
                symbols: [String: SymbolInfo] = [:],
                workSymbols: [String: [String]] = [:]) {
        self.schemaVersion = schemaVersion
        self.sources = sources
        self.entries = entries
        self.schools = schools
        self.schoolAliases = schoolAliases
        self.artists = artists
        self.artistAliases = artistAliases
        self.symbols = symbols
        self.workSymbols = workSymbols
    }

    // `schools` and later `artists` arrived after the first entries were
    // written, so treat a missing key as empty rather than failing the file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        sources = try c.decodeIfPresent([String: InfoSource].self, forKey: .sources) ?? [:]
        entries = try c.decodeIfPresent([String: WorkInfo].self, forKey: .entries) ?? [:]
        schools = try c.decodeIfPresent([String: SchoolInfo].self, forKey: .schools) ?? [:]
        schoolAliases = try c.decodeIfPresent([String: String].self, forKey: .schoolAliases) ?? [:]
        artists = try c.decodeIfPresent([String: ArtistInfo].self, forKey: .artists) ?? [:]
        artistAliases = try c.decodeIfPresent([String: String].self, forKey: .artistAliases) ?? [:]
        symbols = try c.decodeIfPresent([String: SymbolInfo].self, forKey: .symbols) ?? [:]
        workSymbols = try c.decodeIfPresent([String: [String]].self, forKey: .workSymbols) ?? [:]
    }

    /// The symbols recorded for a work, in the order they are stored, skipping
    /// any slug with no entry written yet.
    public func symbols(forWorkId id: String) -> [SymbolInfo] {
        (workSymbols[id] ?? []).compactMap { symbols[$0] }
    }

    /// Look up a painter by the manifest's `artistSort`, then through aliases.
    /// Matched loosely for the same reason movements are, and never for
    /// "Unknown" — 60 works are filed under it with no painter in common.
    public func artist(forSort sort: String?) -> ArtistInfo? {
        guard let sort, sort != "Unknown" else { return nil }
        if let hit = artists[sort] { return hit }
        let key = sort.lowercased()
        if let hit = artists.first(where: { $0.key.lowercased() == key })?.value { return hit }
        guard let alias = artistAliases[sort]
                ?? artistAliases.first(where: { $0.key.lowercased() == key })?.value else { return nil }
        return artists[alias] ?? artists.first { $0.key.lowercased() == alias.lowercased() }?.value
    }

    /// Movement strings vary in case between sources ("Post-impressionism"
    /// beside "Post-Impressionism"), so match loosely, then through aliases.
    public func school(forMovement movement: String?) -> SchoolInfo? {
        guard let movement else { return nil }
        if let hit = schools[movement] { return hit }
        let key = movement.lowercased()
        if let hit = schools.first(where: { $0.key.lowercased() == key })?.value { return hit }
        guard let alias = schoolAliases[movement]
                ?? schoolAliases.first(where: { $0.key.lowercased() == key })?.value else { return nil }
        return schools[alias] ?? schools.first { $0.key.lowercased() == alias.lowercased() }?.value
    }

    public static let empty = InfoFile()

    /// Human-readable label for a cite string, for the Sources line in UIs:
    /// "book:hagen-…-2:212" → "Hagen & Hagen, What Great Paintings Say, Vol. 2, p. 212 (2003 ed.)"
    /// "url:https://www.rijksmuseum.nl/…" → "rijksmuseum.nl"
    public func label(forCite cite: String) -> String {
        if cite.hasPrefix("url:") {
            let raw = String(cite.dropFirst(4))
            if let host = URL(string: raw)?.host {
                return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            }
            return raw
        }
        if cite.hasPrefix("book:") {
            let parts = cite.split(separator: ":")
            let slug = parts.count > 1 ? String(parts[1]) : ""
            let page = parts.count > 2 ? String(parts[2]) : nil
            guard let source = sources[slug] else { return cite }
            var label = "\(source.author), \(source.title)"
            // "ebook" sources have no stable pagination; the locator is a
            // section index in the corpus edition rather than a page.
            if let page { label += source.kind == "ebook" ? ", §\(page)" : ", p. \(page)" }
            return label
        }
        return cite
    }

    /// URL for a cite when it has one (web cites only) — lets UIs link it.
    public func url(forCite cite: String) -> URL? {
        cite.hasPrefix("url:") ? URL(string: String(cite.dropFirst(4))) : nil
    }
}
