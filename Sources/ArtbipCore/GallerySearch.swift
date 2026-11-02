import Foundation

extension ManifestWork {
    /// The subject tag that the `hideNSFW` setting filters on.
    public static let nsfwTag = "nsfw"

    public var isNSFW: Bool { tags?.contains(Self.nsfwTag) ?? false }

    /// Every query word may match a different field (e.g. “Monet landscape”).
    /// Folding makes names searchable without accents; subject aliases accept
    /// common singular/plural spellings without stemming artists' names.
    public func matchesGallerySearch(_ query: String) -> Bool {
        GallerySearch(works: [self]).rank(self, query) != nil
    }
}

/// The gallery's search, built once over the collection. A work matches when
/// every query word is found in its names (title, painter, style, region,
/// museum, date, medium, subject tags) or, failing that, in what the caption
/// and notes say is in the painting (“dog”, “windmill”). Names may be typed
/// run together (“davinci”, “vangogh”), and a misspelt name that matches
/// nothing (“rembrant”) is read as the nearest names in the collection.
public struct GallerySearch: Sendable {
    struct Entry: Sendable {
        var names: String       // folded, space-padded
        var compact: String     // names with spaces removed
        var text: String        // folded caption and notes, space-padded
    }

    private var entries: [String: Entry] = [:]
    private var vocabulary: [String] = []

    static let aliases = ["portraits": "portrait", "landscapes": "landscape",
                          "seascapes": "seascape", "cityscapes": "cityscape",
                          "flowers": "flower", "animals": "animal", "nudes": "nude",
                          "interiors": "interior", "still-life": "still life",
                          "religion": "religious"]

    public init(works: [ManifestWork], notes: InfoFile? = nil) {
        var words = Set<String>()
        for work in works {
            let entry = Self.entry(work, notes: notes?.entries[work.id])
            entries[work.id] = entry
            words.formUnion(entry.names.split(separator: " ").map(String.init))
        }
        vocabulary = words.filter { $0.count >= 3 }.sorted()
    }

    /// Lower-case, accent-free, punctuation as spaces.
    static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        return String(folded.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        })
    }

    static func entry(_ work: ManifestWork, notes: WorkInfo?) -> Entry {
        var names: [String] = [work.title, work.artist, work.collection]
        names += [work.movement, work.region, work.dateDisplay, work.medium].compactMap { $0 }
        names += work.tags ?? []
        var text: [String] = [work.caption ?? ""]
        if let notes { text += (notes.context + notes.details).map { $0.text } }
        let foldedNames = words(names)
        return Entry(names: " \(foldedNames) ",
                     compact: foldedNames.replacingOccurrences(of: " ", with: ""),
                     text: " \(words(text)) ")
    }

    /// Folded words separated by single spaces.
    static func words(_ parts: [String]) -> String {
        fold(parts.joined(separator: " ")).split(separator: " ").joined(separator: " ")
    }

    /// A query read once: its words, each with the names it may be a
    /// misspelling of.
    public struct Query: Sendable {
        var words: [(word: String, stem: String, misspelt: [String])]
    }

    public func prepare(_ query: String) -> Query {
        let words = Self.fold(query.replacingOccurrences(of: "-", with: " "))
            .split(separator: " ").map { Self.aliases[String($0)] ?? String($0) }
        return Query(words: words.map { word in
            // A plural finds the singular in prose.
            let stem = word.count > 3 && word.hasSuffix("s") ? String(word.dropLast()) : word
            return (word, stem, misspellings(of: word).map { " \($0) " })
        })
    }

    /// nil when the work doesn't match; 0 when every word is in its names,
    /// 1 when the caption or notes were needed (shown after the 0s).
    public func rank(_ work: ManifestWork, _ query: String) -> Int? {
        rank(work, prepare(query))
    }

    public func rank(_ work: ManifestWork, _ query: Query) -> Int? {
        let entry = entries[work.id] ?? Self.entry(work, notes: nil)
        var rank = 0
        for (word, stem, misspelt) in query.words {
            if Self.has(entry.names, word) || Self.has(entry.compact, word)
                || misspelt.contains(where: { Self.has(entry.names, $0) }) {
                continue
            }
            // In prose, only whole words or their beginnings (“cat” is not in
            // “indicate”).
            guard Self.has(entry.text, " \(stem)") else { return nil }
            rank = 1
        }
        return rank
    }

    /// Plain byte comparison: both sides are already folded.
    static func has(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: .literal) != nil
    }

    /// The collection's name words one or two edits from `word`, used only
    /// when `word` appears in no name, so “monet” never also finds Manet.
    func misspellings(of word: String) -> [String] {
        guard word.count >= 5, !vocabulary.contains(where: { $0.contains(word) }) else { return [] }
        let limit = word.count >= 8 ? 2 : 1
        let w = Array(word)
        return vocabulary.filter { abs($0.count - w.count) <= limit && Self.distance(w, Array($0), limit: limit) <= limit }
    }

    /// Edit distance (with transpositions), giving up past `limit`. Both are non-empty.
    static func distance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            var best = Int.max
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
                best = min(best, d[i][j])
            }
            if best > limit { return limit + 1 }
        }
        return d[a.count][b.count]
    }
}
