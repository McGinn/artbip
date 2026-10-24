import Foundation

/// Mines Wikipedia "canon" list articles (e.g. "List of most expensive
/// paintings") for the paintings they link to, and reports which lists each
/// painting appears on.
///
/// Method: prop=links on the list page (article namespace only, paginated),
/// prop=pageprops to map titles -> Wikidata QIDs, then wbgetentities to keep
/// only entities whose P31 (instance of) includes Q3305213 (painting).
public enum CanonLists {
    private static let paintingQID = "Q3305213"

    /// The configured "Wikipedia:Vital articles/Level/5/Arts" title is a
    /// redirect to a navigation landing page with no article links; the
    /// actual level-5 arts listing (which contains the paintings) lives at
    /// "…/Level 5/Arts/Audiovisual arts". Tried in order when a
    /// vital-articles page is missing or yields no article links.
    private static let vitalArticlesFallbacks = [
        "Wikipedia:Vital articles/Level 5/Arts/Audiovisual arts",
        "Wikipedia:Vital articles/Level/5/Arts/Visual arts",
        "Wikipedia:Vital articles/Level 5/Arts/Visual arts",
    ]

    /// Returns QID -> [list slugs], mined from Wikipedia list articles.
    public static func fetch(_ ctx: SourceContext) async throws -> [String: [String]] {
        var slugsByQID: [String: Set<String>] = [:]
        for (slug, pageTitle) in ctx.config.canonListPages.sorted(by: { $0.key < $1.key }) {
            guard let titles = try await linkedArticleTitles(pageTitle: pageTitle, ctx: ctx) else {
                ctx.log("canon: warning — page \"\(pageTitle)\" is missing or has no article links; skipping \(slug)")
                continue
            }
            let qids = try await wikidataQIDs(forTitles: titles.sorted(), ctx: ctx)
            let paintings = try await filterPaintings(qids: qids.sorted(), ctx: ctx)
            ctx.log("canon: \(slug) -> \(paintings.count) paintings")
            for qid in paintings {
                slugsByQID[qid, default: []].insert(slug)
            }
        }
        return slugsByQID.mapValues { $0.sorted() }
    }

    // MARK: - Step 1: links on the list page

    /// All article-namespace titles linked from the page, following redirects
    /// and paginating with plcontinue. For vital-articles pages, falls back to
    /// known subpage titles when the configured page is missing or empty.
    /// Returns nil if no candidate page yields any links.
    private static func linkedArticleTitles(pageTitle: String, ctx: SourceContext) async throws -> Set<String>? {
        var candidates = [pageTitle]
        if pageTitle.hasPrefix("Wikipedia:Vital articles") {
            candidates += vitalArticlesFallbacks.filter { $0 != pageTitle }
        }
        for candidate in candidates {
            let titles = try await allLinks(onPage: candidate, ctx: ctx)
            if let titles, !titles.isEmpty {
                if candidate != pageTitle {
                    ctx.log("canon: \"\(pageTitle)\" had no article links; used fallback \"\(candidate)\"")
                }
                return titles
            }
        }
        return nil
    }

    /// One page's article-namespace links, or nil if the page is missing or
    /// invalid.
    private static func allLinks(onPage title: String, ctx: SourceContext) async throws -> Set<String>? {
        var titles: Set<String> = []
        var plcontinue: String? = nil
        repeat {
            var params: [(String, String)] = [
                ("action", "query"),
                ("format", "json"),
                ("formatversion", "2"),
                ("prop", "links"),
                ("plnamespace", "0"),
                ("pllimit", "max"),
                ("redirects", "1"),
                ("titles", title),
            ]
            if let plcontinue { params.append(("plcontinue", plcontinue)) }
            let data = try await ctx.http.get(apiURL(host: "en.wikipedia.org", params: params))
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let query = root?["query"] as? [String: Any]
            guard let page = (query?["pages"] as? [[String: Any]])?.first else { return nil }
            if page["missing"] as? Bool == true || page["invalid"] as? Bool == true { return nil }
            for link in page["links"] as? [[String: Any]] ?? [] {
                if let t = link["title"] as? String { titles.insert(t) }
            }
            plcontinue = (root?["continue"] as? [String: Any])?["plcontinue"] as? String
        } while plcontinue != nil
        return titles
    }

    // MARK: - Step 2: titles -> QIDs

    private static func wikidataQIDs(forTitles titles: [String], ctx: SourceContext) async throws -> Set<String> {
        var qids: Set<String> = []
        for batch in chunks(of: titles, size: 50) {
            let params: [(String, String)] = [
                ("action", "query"),
                ("format", "json"),
                ("formatversion", "2"),
                ("prop", "pageprops"),
                ("ppprop", "wikibase_item"),
                ("redirects", "1"),
                ("titles", batch.joined(separator: "|")),
            ]
            let data = try await ctx.http.get(apiURL(host: "en.wikipedia.org", params: params))
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let pages = ((root?["query"] as? [String: Any])?["pages"] as? [[String: Any]]) ?? []
            for page in pages {
                let props = page["pageprops"] as? [String: Any]
                if let qid = props?["wikibase_item"] as? String { qids.insert(qid) }
            }
        }
        return qids
    }

    // MARK: - Step 3: keep only paintings (P31 includes Q3305213)

    private static func filterPaintings(qids: [String], ctx: SourceContext) async throws -> [String] {
        var paintings: [String] = []
        for batch in chunks(of: qids, size: 50) {
            let params: [(String, String)] = [
                ("action", "wbgetentities"),
                ("format", "json"),
                ("props", "claims"),
                ("ids", batch.joined(separator: "|")),
            ]
            let data = try await ctx.http.get(apiURL(host: "www.wikidata.org", params: params))
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let entities = root?["entities"] as? [String: Any] ?? [:]
            for (qid, entity) in entities {
                let claims = (entity as? [String: Any])?["claims"] as? [String: Any]
                let p31 = claims?["P31"] as? [[String: Any]] ?? []
                let isPainting = p31.contains { statement in
                    let mainsnak = statement["mainsnak"] as? [String: Any]
                    let datavalue = mainsnak?["datavalue"] as? [String: Any]
                    let value = datavalue?["value"] as? [String: Any]
                    return value?["id"] as? String == paintingQID
                }
                if isPainting { paintings.append(qid) }
            }
        }
        return paintings
    }

    // MARK: - Helpers

    private static func chunks(of items: [String], size: Int) -> [[String]] {
        stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    /// Builds a MediaWiki API URL with strict percent-encoding, so titles
    /// containing "+", "&", "=", etc. survive intact. Batch separators join
    /// with "|" before encoding and become %7C, which MediaWiki accepts.
    private static func apiURL(host: String, params: [(String, String)]) -> URL {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let query = params.map { key, value -> String in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return URL(string: "https://\(host)/w/api.php?\(query)")!
    }
}
