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

public struct InfoFile: Codable, Sendable {
    public var schemaVersion: Int
    public var sources: [String: InfoSource]
    public var entries: [String: WorkInfo]

    public init(schemaVersion: Int = 1, sources: [String: InfoSource] = [:],
                entries: [String: WorkInfo] = [:]) {
        self.schemaVersion = schemaVersion
        self.sources = sources
        self.entries = entries
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
