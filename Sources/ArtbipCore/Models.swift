import Foundation

// MARK: - Candidate (gather-stage record, one per source object)

/// Evidence for public-domain status. US rule: a museum's own PD/CC0 flag is
/// authoritative; Commons files require Copyrighted == "False".
public enum PDEvidence: Codable, Sendable, Equatable {
    case museumFlag(field: String)
    case commons(license: String, copyrighted: String)
    case none
}

public struct Signals: Codable, Sendable {
    /// Wikipedia sitelink count for the work item (canon signal).
    public var sitelinks: Int?
    /// Sitelink count for the creator item.
    public var creatorSitelinks: Int?
    /// Museum's own editorial flag (ARTIC is_boosted, Met isHighlight,
    /// Cleveland highlight, Rijksmuseum Top-1000 membership).
    public var museumHighlight: Bool
    /// ARTIC boost_rank when present (lower = more prominent).
    public var boostRank: Int?
    /// Currently hanging in a gallery.
    public var onView: Bool
    /// Slugs of canon lists this work appears on (e.g. "most-expensive-paintings").
    public var canonLists: [String]

    public init(sitelinks: Int? = nil, creatorSitelinks: Int? = nil,
                museumHighlight: Bool = false, boostRank: Int? = nil,
                onView: Bool = false, canonLists: [String] = []) {
        self.sitelinks = sitelinks
        self.creatorSitelinks = creatorSitelinks
        self.museumHighlight = museumHighlight
        self.boostRank = boostRank
        self.onView = onView
        self.canonLists = canonLists
    }
}

public struct Candidate: Codable, Sendable {
    public var source: String        // plugin id, e.g. "artic"
    public var sourceId: String      // source-local object id
    public var title: String
    public var artist: String?
    public var artistSort: String?   // "Seurat, Georges"
    public var artistDeathYear: Int?
    public var yearStart: Int?
    public var yearEnd: Int?
    public var dateDisplay: String?
    public var medium: String?
    public var region: String?       // place of origin / artist nationality
    public var movement: String?
    public var wikidataQID: String?  // "Q185372" when known
    public var inventoryNumber: String?  // museum accession no. (join key)
    public var pdEvidence: PDEvidence
    public var imageMaxWidth: Int?
    public var imageMaxHeight: Int?
    /// URL template with "{w}" placeholder for requested pixel width, or a
    /// fixed URL when the source serves a single derivative.
    public var imageURLTemplate: String
    public var signals: Signals
    public var collectionName: String
    public var collectionURL: String
    /// Dominant colour [h, s, l] when the source provides it (ARTIC does).
    public var dominantHSL: [Double]?

    public var id: String { "\(source)-\(sourceId)" }

    public func imageURL(width: Int) -> URL? {
        URL(string: imageURLTemplate.replacingOccurrences(of: "{w}", with: String(width)))
    }

    public init(source: String, sourceId: String, title: String,
                artist: String? = nil, artistSort: String? = nil, artistDeathYear: Int? = nil,
                yearStart: Int? = nil, yearEnd: Int? = nil, dateDisplay: String? = nil,
                medium: String? = nil, region: String? = nil, movement: String? = nil,
                wikidataQID: String? = nil, inventoryNumber: String? = nil,
                pdEvidence: PDEvidence = .none,
                imageMaxWidth: Int? = nil, imageMaxHeight: Int? = nil,
                imageURLTemplate: String, signals: Signals = Signals(),
                collectionName: String, collectionURL: String,
                dominantHSL: [Double]? = nil) {
        self.source = source
        self.sourceId = sourceId
        self.title = title
        self.artist = artist
        self.artistSort = artistSort
        self.artistDeathYear = artistDeathYear
        self.yearStart = yearStart
        self.yearEnd = yearEnd
        self.dateDisplay = dateDisplay
        self.medium = medium
        self.region = region
        self.movement = movement
        self.wikidataQID = wikidataQID
        self.inventoryNumber = inventoryNumber
        self.pdEvidence = pdEvidence
        self.imageMaxWidth = imageMaxWidth
        self.imageMaxHeight = imageMaxHeight
        self.imageURLTemplate = imageURLTemplate
        self.signals = signals
        self.collectionName = collectionName
        self.collectionURL = collectionURL
        self.dominantHSL = dominantHSL
    }
}

// MARK: - LLM scoring

public struct ScoreResult: Codable, Sendable {
    public var id: String            // candidate id
    public var promptHash: String    // invalidates cache when the prompt changes
    public var score: Double         // 0–10 significance
    public var caption: String       // wall-label caption
    public var defects: [String]     // "damage", "frame", "color-card", "skew", "crop", "not-a-painting"
    public var scoredBy: String      // "claude-session", "openrouter:<model>"

    public init(id: String, promptHash: String, score: Double, caption: String,
                defects: [String], scoredBy: String) {
        self.id = id
        self.promptHash = promptHash
        self.score = score
        self.caption = caption
        self.defects = defects
        self.scoredBy = scoredBy
    }

    // The scoring contract (score-prep INSTRUCTIONS, in-session results, and the
    // OpenRouter scorer) uses snake_case keys; map them explicitly so the files
    // round-trip. Keys are spelled out rather than via a strategy because
    // Foundation's snake_case conversion mangles acronyms.
    enum CodingKeys: String, CodingKey {
        case id
        case promptHash = "prompt_hash"
        case score
        case caption
        case defects
        case scoredBy = "scored_by"
    }
}

/// data/scores.json — durable consolidation of every scored work, committed so
/// re-curation never needs re-scoring once work/ scratch is gone.
public struct ScoresFile: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var score: Double
        public var caption: String
        public var defects: [String]
        public var scoredBy: String

        enum CodingKeys: String, CodingKey {
            case score, caption, defects
            case scoredBy = "scored_by"
        }
    }

    public var promptHash: String
    public var model: String?
    public var count: Int?
    public var scores: [String: Entry]

    public func asResults() -> [String: ScoreResult] {
        scores.reduce(into: [:]) { acc, kv in
            acc[kv.key] = ScoreResult(id: kv.key, promptHash: promptHash, score: kv.value.score,
                                      caption: kv.value.caption, defects: kv.value.defects,
                                      scoredBy: kv.value.scoredBy)
        }
    }
}

// MARK: - Manifest (the runtime contract)

public struct ManifestImage: Codable, Sendable {
    public var url: String
    /// URL template with "{w}" for the requested pixel width, when the source
    /// serves arbitrary sizes (IIIF, Commons FilePath). Lets the runtime fetch
    /// gallery thumbnails without pulling the full-size derivative.
    public var urlTemplate: String?
    public var sourceMaxWidth: Int
    public var sourceMaxHeight: Int
    public var format: String

    public init(url: String, urlTemplate: String? = nil, sourceMaxWidth: Int, sourceMaxHeight: Int, format: String = "jpeg") {
        self.url = url
        self.urlTemplate = urlTemplate
        self.sourceMaxWidth = sourceMaxWidth
        self.sourceMaxHeight = sourceMaxHeight
        self.format = format
    }

    public func url(width: Int) -> URL? {
        if let urlTemplate {
            return URL(string: urlTemplate.replacingOccurrences(of: "{w}", with: String(width)))
        }
        return URL(string: url)
    }
}

public struct ManifestLicense: Codable, Sendable {
    public var status: String      // "CC0" | "PD"
    public var evidence: String    // e.g. "artic:is_public_domain"
    public var sourceURL: String

    public init(status: String, evidence: String, sourceURL: String) {
        self.status = status
        self.evidence = evidence
        self.sourceURL = sourceURL
    }
}

public struct ManifestSignificance: Codable, Sendable {
    public var sitelinks: Int?
    public var museumHighlight: Bool
    public var canonLists: [String]
    public var llmScore: Double?

    public init(sitelinks: Int?, museumHighlight: Bool, canonLists: [String], llmScore: Double?) {
        self.sitelinks = sitelinks
        self.museumHighlight = museumHighlight
        self.canonLists = canonLists
        self.llmScore = llmScore
    }
}

/// Height and width in centimetres — the unit museum labels use, and what the
/// Wikidata pass normalises to.
public struct ManifestDimensions: Codable, Sendable {
    public var heightCm: Double
    public var widthCm: Double

    public init(heightCm: Double, widthCm: Double) {
        self.heightCm = heightCm
        self.widthCm = widthCm
    }

    /// "86.3 × 156 cm" — trailing ".0" dropped, since a whole number of
    /// centimetres is how a wall label would print it.
    public var display: String {
        func fmt(_ v: Double) -> String {
            v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
        }
        return "\(fmt(heightCm)) × \(fmt(widthCm)) cm"
    }
}

public struct ManifestWork: Codable, Sendable {
    public var id: String
    public var wikidata: String?
    public var title: String
    public var artist: String
    public var artistSort: String
    /// Life dates. Both are filled by `scripts/enrich_wikidata.py` where the
    /// source museums left them blank; birth years come only from that pass.
    public var artistBirthYear: Int?
    public var artistDeathYear: Int?
    public var dateDisplay: String?
    public var year: Int?
    public var movement: String?
    public var region: String?
    public var medium: String?
    public var collection: String
    public var collectionURL: String
    public var image: ManifestImage
    public var license: ManifestLicense
    public var paletteDominantHSL: [Double]?
    public var significance: ManifestSignificance
    public var caption: String?
    /// Physical size of the work, filled by the Wikidata enrichment pass.
    public var dimensions: ManifestDimensions?

    public init(id: String, wikidata: String?, title: String, artist: String, artistSort: String,
                artistBirthYear: Int? = nil,
                artistDeathYear: Int?, dateDisplay: String?, year: Int?, movement: String?,
                region: String?, medium: String?, collection: String, collectionURL: String,
                image: ManifestImage, license: ManifestLicense, paletteDominantHSL: [Double]?,
                significance: ManifestSignificance, caption: String?,
                dimensions: ManifestDimensions? = nil) {
        self.artistBirthYear = artistBirthYear
        self.dimensions = dimensions
        self.id = id
        self.wikidata = wikidata
        self.title = title
        self.artist = artist
        self.artistSort = artistSort
        self.artistDeathYear = artistDeathYear
        self.dateDisplay = dateDisplay
        self.year = year
        self.movement = movement
        self.region = region
        self.medium = medium
        self.collection = collection
        self.collectionURL = collectionURL
        self.image = image
        self.license = license
        self.paletteDominantHSL = paletteDominantHSL
        self.significance = significance
        self.caption = caption
    }
}

public struct Manifest: Codable, Sendable {
    public var schemaVersion: Int
    public var generatedAt: String
    public var works: [ManifestWork]

    public init(schemaVersion: Int = 1, generatedAt: String, works: [ManifestWork]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.works = works
    }
}

// MARK: - Hand-edit overrides (merged last; survive re-runs)

public struct Override: Codable, Sendable {
    /// Never include this work in generated manifests.
    public var exclude: Bool?
    /// Include regardless of score/threshold.
    public var pin: Bool?
    /// Field overrides applied after generation.
    public var caption: String?
    public var title: String?
    public var artist: String?
    public var region: String?
    public var movement: String?

    public init() {}
}

/// Keyed by work id ("artic-27992") or "artist:<name>" for artist-level blocks.
public typealias Overrides = [String: Override]

// MARK: - JSON helpers

public enum JSONIO {
    // Exact property names as JSON keys — no snake_case strategy, because
    // Foundation's conversion does not round-trip acronyms (imageURLTemplate
    // -> image_url_template -> imageUrlTemplate).
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(value).write(to: url, options: .atomic)
    }
}
