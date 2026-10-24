import Foundation

/// Art Institute of Chicago. Elasticsearch-backed search API; `is_public_domain`
/// is the museum's authoritative PD flag (CC0 metadata). We page through all
/// public-domain paintings that have an image and map them to Candidates.
public struct ArticSource: ArtSource {
    public static let id = "artic"

    public init() {}

    private static let searchURL = URL(string: "https://api.artic.edu/api/v1/artworks/search")!
    private static let pageLimit = 100
    private static let maxPages = 100
    private static let headers = [
        "Content-Type": "application/json",
        "AIC-User-Agent": "artbip (\(Http.contact))",
    ]

    // MARK: - Response decoding

    private struct SearchResponse: Decodable {
        var pagination: Pagination?
        var data: [Artwork]?
    }

    private struct Pagination: Decodable {
        var total: Int?
    }

    private struct Thumbnail: Decodable {
        var width: Int?
        var height: Int?
    }

    private struct Color: Decodable {
        var h: Int?
        var s: Int?
        var l: Int?
    }

    private struct Artwork: Decodable {
        var id: Int?
        var title: String?
        var artistTitle: String?
        var artistDisplay: String?
        var dateStart: Int?
        var dateEnd: Int?
        var dateDisplay: String?
        var mediumDisplay: String?
        var placeOfOrigin: String?
        var styleTitle: String?
        var imageId: String?
        var thumbnail: Thumbnail?
        var isBoosted: Bool?
        var boostRank: Int?
        var isOnView: Bool?
        var color: Color?
        var mainReferenceNumber: String?

        enum CodingKeys: String, CodingKey {
            case id, title, thumbnail, color
            case artistTitle = "artist_title"
            case artistDisplay = "artist_display"
            case dateStart = "date_start"
            case dateEnd = "date_end"
            case dateDisplay = "date_display"
            case mediumDisplay = "medium_display"
            case placeOfOrigin = "place_of_origin"
            case styleTitle = "style_title"
            case imageId = "image_id"
            case isBoosted = "is_boosted"
            case boostRank = "boost_rank"
            case isOnView = "is_on_view"
            case mainReferenceNumber = "main_reference_number"
        }
    }

    // MARK: - Request body

    /// Deterministic body per page so the Http disk cache keys stay stable
    /// across runs (JSONSerialization dictionary order is not guaranteed).
    /// The search API rejects limit*page > 1000 ("Invalid number of results"),
    /// so we partition by artwork-id range and recursively split any partition
    /// that would exceed 1000 hits.
    private static func body(page: Int, limit: Int, idLo: Int, idHi: Int) -> Data {
        let json = """
        {"query":{"bool":{"must":[{"term":{"is_public_domain":true}},{"term":{"artwork_type_id":1}},{"exists":{"field":"image_id"}},{"range":{"id":{"gte":\(idLo),"lt":\(idHi)}}}]}},"limit":\(limit),"page":\(page),"fields":["id","title","artist_title","artist_display","date_start","date_end","date_display","medium_display","place_of_origin","style_title","image_id","thumbnail","is_boosted","boost_rank","is_on_view","color","main_reference_number"]}
        """
        return Data(json.utf8)
    }

    private func rangeTotal(_ ctx: SourceContext, lo: Int, hi: Int) async throws -> Int {
        let data = try await ctx.http.post(Self.searchURL,
                                           body: Self.body(page: 1, limit: 1, idLo: lo, idHi: hi),
                                           headers: Self.headers)
        let resp = try JSONDecoder().decode(SearchResponse.self, from: data)
        return resp.pagination?.total ?? 0
    }

    // MARK: - ArtSource

    public func candidates(_ ctx: SourceContext) async throws -> [Candidate] {
        let decoder = JSONDecoder()
        var out: [Candidate] = []
        var ranges: [(Int, Int)] = [(0, 2_000_000)]

        while let (lo, hi) = ranges.popLast() {
            let total = try await rangeTotal(ctx, lo: lo, hi: hi)
            if total == 0 { continue }
            if total > 1000 && hi - lo > 1 {
                let mid = lo + (hi - lo) / 2
                ranges.append((mid, hi))
                ranges.append((lo, mid))
                continue
            }
            var fetched = 0
            var page = 1
            while fetched < total && page <= Self.maxPages {
                let data = try await ctx.http.post(Self.searchURL,
                                                   body: Self.body(page: page, limit: Self.pageLimit, idLo: lo, idHi: hi),
                                                   headers: Self.headers)
                let resp = try decoder.decode(SearchResponse.self, from: data)
                let records = resp.data ?? []
                if records.isEmpty { break }
                fetched += records.count
                for record in records {
                    if let candidate = Self.candidate(from: record) {
                        out.append(candidate)
                    }
                }
                page += 1
            }
            ctx.log("artic: range \(lo)..<\(hi): \(fetched)/\(total) records, \(out.count) candidates total")
        }

        // Deterministic order: numeric by source id, string fallback.
        out.sort { a, b in
            if let ai = Int(a.sourceId), let bi = Int(b.sourceId) { return ai < bi }
            return a.sourceId < b.sourceId
        }
        ctx.log("artic: done, \(out.count) candidates")
        return out
    }

    private static func candidate(from a: Artwork) -> Candidate? {
        guard let id = a.id,
              let title = a.title, !title.isEmpty,
              let imageId = a.imageId, !imageId.isEmpty else { return nil }

        var dominantHSL: [Double]?
        if let c = a.color, let h = c.h, let s = c.s, let l = c.l {
            dominantHSL = [Double(h), Double(s), Double(l)]
        }

        return Candidate(
            source: Self.id,
            sourceId: String(id),
            title: title,
            artist: a.artistTitle,
            artistSort: Parse.sortName(a.artistTitle),
            artistDeathYear: Parse.deathYear(fromArtistDisplay: a.artistDisplay),
            yearStart: a.dateStart,
            yearEnd: a.dateEnd,
            dateDisplay: a.dateDisplay,
            medium: a.mediumDisplay,
            region: a.placeOfOrigin,
            movement: a.styleTitle,
            inventoryNumber: a.mainReferenceNumber,
            pdEvidence: .museumFlag(field: "is_public_domain"),
            imageMaxWidth: a.thumbnail?.width,
            imageMaxHeight: a.thumbnail?.height,
            imageURLTemplate: "https://www.artic.edu/iiif/2/\(imageId)/full/{w},/0/default.jpg",
            signals: Signals(museumHighlight: a.isBoosted ?? false,
                             boostRank: a.boostRank,
                             onView: a.isOnView ?? false),
            collectionName: "Art Institute of Chicago",
            collectionURL: "https://www.artic.edu/artworks/\(id)",
            dominantHSL: dominantHSL
        )
    }
}
