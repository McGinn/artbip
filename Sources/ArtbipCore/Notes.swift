import Foundation

/// The notes that ship inside the app (`data/education/starter.json`, bundled
/// as `notes.json`): the works they cover plus an `InfoFile` holding those
/// works' entries and the shared records (artists, styles, symbols, sources)
/// the entries display. Pure data — it is decoded into typed structs and
/// nothing in it is ever executed, loaded as code or used as a file path.
public struct NotesFile: Codable, Sendable {
    public static let format = "artbip-notes"
    public static let formatVersion = 1
    /// Generous for text (the file is ~300 KB) but a hard ceiling all the same.
    public static let maxBytes = 8 * 1024 * 1024

    public var format: String
    public var formatVersion: Int
    public var version: Int
    public var works: [String]
    public var info: InfoFile

    public init(version: Int, works: [String], info: InfoFile) {
        self.format = Self.format
        self.formatVersion = Self.formatVersion
        self.version = version
        self.works = works
        self.info = info
    }

    public static func load(from url: URL) throws -> NotesFile {
        try validate(Data(contentsOf: url))
    }

    /// Accept `data` only if it is a notes file in a format this build reads,
    /// its entries are exactly the works it lists, and every record it shows
    /// resolves inside the file. Checks run cheapest first.
    public static func validate(_ data: Data) throws -> NotesFile {
        guard data.count <= maxBytes else { throw NotesError.tooLarge(data.count) }
        let notes: NotesFile
        do {
            notes = try JSONDecoder().decode(NotesFile.self, from: data)
        } catch {
            throw NotesError.badFormat("undecodable JSON")
        }
        guard notes.format == format, notes.formatVersion == formatVersion else {
            throw NotesError.badFormat("unsupported format \(notes.format) v\(notes.formatVersion)")
        }
        guard Set(notes.works) == Set(notes.info.entries.keys), Set(notes.works).count == notes.works.count else {
            throw NotesError.badFormat("works and entries disagree")
        }
        try checkDependencies(notes.info)
        return notes
    }

    /// Every symbol, alias and citation the entries use must resolve inside
    /// the file, and every link must be plain https.
    static func checkDependencies(_ info: InfoFile) throws {
        for (work, symbols) in info.workSymbols {
            guard info.entries[work] != nil else { throw NotesError.missingDependency("entry \(work)") }
            for symbol in symbols where info.symbols[symbol] == nil {
                throw NotesError.missingDependency("symbol \(symbol)")
            }
        }
        for (alias, key) in info.artistAliases where info.artists[key] == nil {
            throw NotesError.missingDependency("artist \(key) for \(alias)")
        }
        for (alias, key) in info.schoolAliases where info.schools[key] == nil {
            throw NotesError.missingDependency("style \(key) for \(alias)")
        }
        var paragraphs: [InfoParagraph] = info.entries.values.flatMap { $0.context + $0.details }
        paragraphs += info.artists.values.flatMap(\.context) + info.schools.values.flatMap(\.context)
        let cites = paragraphs.flatMap(\.cite) + info.symbols.values.flatMap(\.cite)
        for cite in cites {
            if cite.hasPrefix("book:") {
                let parts = cite.split(separator: ":")
                guard parts.count >= 2, info.sources[String(parts[1])] != nil else {
                    throw NotesError.missingDependency("source for \(cite)")
                }
            } else if cite.hasPrefix("url:") {
                // Links open in the browser; only plain https is acceptable.
                guard let url = URL(string: String(cite.dropFirst(4))), url.scheme == "https", url.host != nil else {
                    throw NotesError.unsafeLink(cite)
                }
            } else {
                throw NotesError.unsafeLink(cite)
            }
        }
    }
}

public enum NotesError: Error, Equatable, LocalizedError {
    case tooLarge(Int)
    case badFormat(String)
    case missingDependency(String)
    case unsafeLink(String)

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let n): return "The notes file is too large (\(n) bytes)."
        case .badFormat(let why): return "The notes file is not valid: \(why)."
        case .missingDependency(let what): return "The notes file is missing \(what)."
        case .unsafeLink(let link): return "The notes file contains an unsupported link: \(link)."
        }
    }
}

extension InfoFile {
    /// Union of several info files. Shared records are identical copies of
    /// one master record, so the first one wins and nothing is duplicated.
    public static func merged(_ parts: [InfoFile]) -> InfoFile {
        var out = InfoFile()
        for part in parts {
            out.sources.merge(part.sources) { a, _ in a }
            out.entries.merge(part.entries) { a, _ in a }
            out.schools.merge(part.schools) { a, _ in a }
            out.schoolAliases.merge(part.schoolAliases) { a, _ in a }
            out.artists.merge(part.artists) { a, _ in a }
            out.artistAliases.merge(part.artistAliases) { a, _ in a }
            out.symbols.merge(part.symbols) { a, _ in a }
            out.workSymbols.merge(part.workSymbols) { a, _ in a }
        }
        return out
    }
}
