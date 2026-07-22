import Foundation

/// The Metropolitan Museum of Art open-access API.
///
/// The search endpoint requires a `q` parameter (omitting it returns an HTML
/// 502) and its `isPublicDomain` filter is broken, so we gather candidate
/// object-ID sets from search, hydrate every object individually, and filter
/// for public-domain paintings with images client-side.
///
/// The API does not report image pixel dimensions, so for each kept record we
/// range-request the first 128 KiB of the full-res `primaryImage` JPEG and read
/// the dimensions from its SOF header via `Thumbs.imageSize(of:)`.
public struct MetSource: ArtSource {
    public static let id = "met"

    public init() {}

    private static let api = "https://collectionapi.metmuseum.org/public/collection/v1"

    /// Rough cap on how many objects we are willing to hydrate. If the
    /// highlight ∪ all-paintings union exceeds this, fall back to
    /// paintings-per-department for the big painting departments.
    private static let hydrationCap = 12_000
    /// Imperva in front of the Met hosts blocks obvious non-browser UAs at
    /// sustained rates; a browser-like UA plus gentle pacing keeps us served.
    private static let uaHeaders = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
        "Accept": "application/json",
    ]

    /// Departments used in the fallback: European Paintings, American Wing,
    /// Asian Art, Islamic Art.
    private static let paintingDepartments = [11, 1, 6, 14]

    // MARK: - API shapes

    private struct SearchResponse: Decodable {
        var total: Int?
        var objectIDs: [Int]?   // null when total == 0
    }

    private struct MetObject: Decodable {
        var objectID: Int?
        var isHighlight: Bool?
        var isPublicDomain: Bool?
        var primaryImage: String?
        var title: String?
        var artistDisplayName: String?
        var artistNationality: String?
        var artistEndDate: String?
        var objectDate: String?
        var objectBeginDate: Int?
        var objectEndDate: Int?
        var medium: String?
        var culture: String?
        var classification: String?
        var objectName: String?
        var accessionNumber: String?
        var objectURL: String?
        var objectWikidata_URL: String?
        var GalleryNumber: String?
    }

    // MARK: - ArtSource

    public func candidates(_ ctx: SourceContext) async throws -> [Candidate] {
        let ids = try await gatherObjectIDs(ctx)
        ctx.log("met: hydrating \(ids.count) objects")

        var out: [Candidate] = []
        var kept = 0
        var consecutive403 = 0
        var i = 0
        while i < ids.count {
            let id = ids[i]
            if i > 0 && i % 250 == 0 {
                ctx.log("met: hydrated \(i)/\(ids.count) objects (\(kept) kept)")
            }
            do {
                if let c = try await hydrate(id: id, ctx: ctx) {
                    out.append(c)
                    kept += 1
                }
                consecutive403 = 0
            } catch let e as HttpError where e.status == 403 {
                // Imperva bot-block: cool off and retry the same object.
                consecutive403 += 1
                if consecutive403 > 30 {
                    ctx.log("met: \(consecutive403) consecutive 403s — aborting; re-run gather later to resume from cache")
                    break
                }
                ctx.log("met: 403 on object \(id) — cooling off 90s (strike \(consecutive403))")
                try await Task.sleep(nanoseconds: 90_000_000_000)
                continue // retry same id without advancing
            } catch {
                ctx.log("met: object \(id) failed, skipping: \(error)")
            }
            i += 1
        }
        ctx.log("met: done — \(kept) candidates from \(ids.count) objects")

        return out.sorted { $0.sourceId < $1.sourceId }
    }

    // MARK: - Gathering object-ID sets

    private func gatherObjectIDs(_ ctx: SourceContext) async throws -> [Int] {
        let highlights = try await searchIDs(
            [URLQueryItem(name: "isHighlight", value: "true"),
             URLQueryItem(name: "hasImages", value: "true"),
             URLQueryItem(name: "q", value: "*")],
            ctx: ctx)
        ctx.log("met: highlight set: \(highlights.count) ids")

        let allPaintings = try await searchIDs(
            [URLQueryItem(name: "hasImages", value: "true"),
             URLQueryItem(name: "medium", value: "Paintings"),
             URLQueryItem(name: "q", value: "*")],
            ctx: ctx)
        ctx.log("met: all-paintings set: \(allPaintings.count) ids")

        var union = Set(highlights)
        union.formUnion(allPaintings)

        if union.count > Self.hydrationCap {
            ctx.log("met: union \(union.count) exceeds cap \(Self.hydrationCap); using per-department painting sets instead")
            union = Set(highlights)
            for dept in Self.paintingDepartments {
                let deptIDs = try await searchIDs(
                    [URLQueryItem(name: "hasImages", value: "true"),
                     URLQueryItem(name: "medium", value: "Paintings"),
                     URLQueryItem(name: "departmentId", value: String(dept)),
                     URLQueryItem(name: "q", value: "*")],
                    ctx: ctx)
                ctx.log("met: department \(dept) paintings: \(deptIDs.count) ids")
                union.formUnion(deptIDs)
            }
        }

        ctx.log("met: gathered \(union.count) unique object ids")
        return union.sorted()
    }

    private func searchIDs(_ query: [URLQueryItem], ctx: SourceContext) async throws -> [Int] {
        var comps = URLComponents(string: "\(Self.api)/search")!
        comps.queryItems = query
        guard let url = comps.url else { return [] }
        let resp = try await ctx.http.getJSON(SearchResponse.self, url, headers: Self.uaHeaders)
        return resp.objectIDs ?? []
    }

    // MARK: - Hydration

    /// Fetch one object; return a Candidate if it is a public-domain painting
    /// with an image, nil otherwise.
    private func hydrate(id: Int, ctx: SourceContext) async throws -> Candidate? {
        guard let url = URL(string: "\(Self.api)/objects/\(id)") else { return nil }
        let obj = try await ctx.http.getJSON(MetObject.self, url, headers: Self.uaHeaders)

        guard obj.isPublicDomain == true,
              let primaryImage = nonEmpty(obj.primaryImage) else { return nil }
        let isPainting = containsPainting(obj.classification) || containsPainting(obj.objectName)
        guard isPainting else { return nil }

        // The API has no pixel dimensions; read them from the first 128 KiB of
        // the original JPEG (SOF header is near the start). Http caches the
        // partial response, so this is a one-time cost per image.
        var dims: (width: Int, height: Int)?
        if let imageURL = URL(string: primaryImage) {
            do {
                let head = try await ctx.http.get(imageURL, headers: Self.uaHeaders.merging(["Range": "bytes=0-131071", "Accept": "*/*"]) { _, new in new })
                dims = Thumbs.imageSize(of: head)
                if dims == nil {
                    ctx.log("met: object \(id): could not read image dimensions from \(primaryImage)")
                }
            } catch {
                ctx.log("met: object \(id): image head fetch failed (\(error)); leaving dims nil")
            }
        }

        let artist = nonEmpty(obj.artistDisplayName)
        let nationality = nonEmpty(obj.artistNationality)
        let deathYear = deathYear(from: obj.artistEndDate)

        return Candidate(
            source: Self.id,
            sourceId: String(obj.objectID ?? id),
            title: nonEmpty(obj.title) ?? "Untitled",
            artist: artist,
            artistSort: Parse.sortName(artist),
            artistDeathYear: deathYear,
            yearStart: obj.objectBeginDate,
            yearEnd: obj.objectEndDate,
            dateDisplay: nonEmpty(obj.objectDate),
            medium: nonEmpty(obj.medium),
            region: nationality ?? nonEmpty(obj.culture),
            wikidataQID: qid(from: obj.objectWikidata_URL),
            inventoryNumber: nonEmpty(obj.accessionNumber),
            pdEvidence: .museumFlag(field: "isPublicDomain"),
            imageMaxWidth: dims?.width,
            imageMaxHeight: dims?.height,
            imageURLTemplate: primaryImage,   // fixed full-res URL, no {w}
            signals: Signals(
                museumHighlight: obj.isHighlight == true,
                onView: nonEmpty(obj.GalleryNumber) != nil),
            collectionName: "The Metropolitan Museum of Art",
            collectionURL: nonEmpty(obj.objectURL)
                ?? "https://www.metmuseum.org/art/collection/search/\(obj.objectID ?? id)")
    }

    // MARK: - Field parsing

    private func nonEmpty(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func containsPainting(_ s: String?) -> Bool {
        guard let s else { return false }
        return s.range(of: "Painting", options: .caseInsensitive) != nil
    }

    /// artistEndDate is a string year like "1890"; fall back to the first
    /// 4-digit year for values like "1890      ".
    private func deathYear(from s: String?) -> Int? {
        guard let t = nonEmpty(s) else { return nil }
        return Int(t) ?? Parse.year(in: t)
    }

    /// Extract "Q463049" from "https://www.wikidata.org/wiki/Q463049".
    private func qid(from urlString: String?) -> String? {
        guard let s = nonEmpty(urlString) else { return nil }
        guard let re = try? NSRegularExpression(pattern: #"Q[0-9]+"#),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range, in: s) else { return nil }
        return String(s[r])
    }
}
