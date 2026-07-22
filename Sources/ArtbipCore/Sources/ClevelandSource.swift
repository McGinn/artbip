import Foundation

/// Cleveland Museum of Art open-access API. `share_license_status == "CC0"`
/// (requested via `cc0=1`) is the museum's authoritative PD flag. We page
/// through all CC0 paintings with images and map them to Candidates.
///
/// API notes (verified 2026-07-14): unknown query params are silently ignored,
/// so parameter spelling matters. Numeric-looking fields on records
/// (creator birth/death years, image width/height/filesize) are strings.
/// The record-level highlight field is `is_highlight` (the query param is
/// `highlight`). `current_location` non-empty means the work is on view.
public struct ClevelandSource: ArtSource {
    public static let id = "cleveland"

    public init() {}

    private static let baseURL = "https://openaccess-api.clevelandart.org/api/artworks/"
    private static let pageLimit = 1000
    private static let maxPages = 50

    // MARK: - Response decoding

    private struct Response: Decodable {
        var info: Info?
        var data: [Artwork]?
    }

    private struct Info: Decodable {
        var total: Int?
    }

    private struct Creator: Decodable {
        var description: String?
        var birthYear: String?
        var deathYear: String?

        enum CodingKeys: String, CodingKey {
            case description
            case birthYear = "birth_year"
            case deathYear = "death_year"
        }
    }

    private struct ImageTier: Decodable {
        var url: String?
        var width: String?
        var height: String?
    }

    private struct Images: Decodable {
        var web: ImageTier?
        var print: ImageTier?
        var full: ImageTier?
    }

    private struct Artwork: Decodable {
        var id: Int?
        var title: String?
        var creators: [Creator]?
        var culture: [String]?
        var technique: String?
        var creationDate: String?
        var creationDateEarliest: Int?
        var creationDateLatest: Int?
        var url: String?
        var accessionNumber: String?
        var images: Images?
        var isHighlight: Bool?
        var currentLocation: String?

        enum CodingKeys: String, CodingKey {
            case id, title, creators, culture, technique, url, images
            case creationDate = "creation_date"
            case creationDateEarliest = "creation_date_earliest"
            case creationDateLatest = "creation_date_latest"
            case accessionNumber = "accession_number"
            case isHighlight = "is_highlight"
            case currentLocation = "current_location"
        }
    }

    // MARK: - Request

    private static func pageURL(skip: Int) -> URL? {
        var comps = URLComponents(string: baseURL)
        comps?.queryItems = [
            URLQueryItem(name: "cc0", value: "1"),
            URLQueryItem(name: "type", value: "Painting"),
            URLQueryItem(name: "has_image", value: "1"),
            URLQueryItem(name: "limit", value: String(pageLimit)),
            URLQueryItem(name: "skip", value: String(skip)),
        ]
        return comps?.url
    }

    // MARK: - ArtSource

    public func candidates(_ ctx: SourceContext) async throws -> [Candidate] {
        let decoder = JSONDecoder()
        var out: [Candidate] = []
        var skip = 0
        var total: Int?
        var page = 0

        while page < Self.maxPages {
            page += 1
            guard let url = Self.pageURL(skip: skip) else { break }
            let data = try await ctx.http.get(url)
            let resp = try decoder.decode(Response.self, from: data)
            if let t = resp.info?.total { total = t }

            let records = resp.data ?? []
            for record in records {
                if let candidate = Self.candidate(from: record) {
                    out.append(candidate)
                }
            }
            skip += records.count
            ctx.log("cleveland: page \(page), \(skip)/\(total ?? 0) records, \(out.count) candidates")

            // Last page: fewer records than the limit (or none at all).
            if records.count < Self.pageLimit { break }
        }

        // Deterministic order: numeric by source id, string fallback.
        out.sort { a, b in
            if let ai = Int(a.sourceId), let bi = Int(b.sourceId) { return ai < bi }
            return a.sourceId < b.sourceId
        }
        ctx.log("cleveland: done, \(out.count) candidates")
        return out
    }

    // MARK: - Mapping

    private static func candidate(from a: Artwork) -> Candidate? {
        guard let id = a.id,
              let title = a.title, !title.isEmpty else { return nil }

        // Prefer the print tier (~3400px JPEG); fall back to web. The full
        // tier is a huge TIFF — never use it.
        guard let tier = usableTier(a.images) else { return nil }

        let display = a.creators?.first?.description
        let artist = strippedArtistName(display)
        let deathYear = (a.creators?.first?.deathYear).flatMap(Int.init)
            ?? Parse.deathYear(fromArtistDisplay: display)
        let onView = !(a.currentLocation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return Candidate(
            source: Self.id,
            sourceId: String(id),
            title: title,
            artist: artist,
            artistSort: Parse.sortName(artist),
            artistDeathYear: deathYear,
            yearStart: a.creationDateEarliest,
            yearEnd: a.creationDateLatest,
            dateDisplay: a.creationDate,
            medium: a.technique,
            region: a.culture?.first(where: { !$0.isEmpty }),
            inventoryNumber: a.accessionNumber,
            pdEvidence: .museumFlag(field: "share_license_status=CC0"),
            imageMaxWidth: tier.width.flatMap(Int.init),
            imageMaxHeight: tier.height.flatMap(Int.init),
            imageURLTemplate: tier.url!,  // usableTier guarantees non-nil
            signals: Signals(museumHighlight: a.isHighlight ?? false,
                             onView: onView),
            collectionName: "Cleveland Museum of Art",
            collectionURL: a.url ?? "https://www.clevelandart.org/art/\(id)"
        )
    }

    /// Best usable image tier: print, else web. A tier is usable when it has
    /// a non-empty URL.
    private static func usableTier(_ images: Images?) -> ImageTier? {
        for tier in [images?.print, images?.web] {
            if let tier, let url = tier.url, !url.isEmpty { return tier }
        }
        return nil
    }

    /// "John Singleton Copley (American, 1738–1815)" -> "John Singleton Copley".
    private static func strippedArtistName(_ description: String?) -> String? {
        guard let description else { return nil }
        let stripped = description
            .replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }
}
