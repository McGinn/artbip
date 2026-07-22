import Foundation

/// Wikidata + Wikimedia Commons. The canon backbone: every notable painting
/// (instance of Q3305213) with a Commons image, banded by Wikipedia sitelink
/// count so no single SPARQL query hits the 60-second hard timeout. This is
/// also the only route to Louvre/Prado/Uffizi works.
///
/// Verified 2026-07-14:
/// - Unfiltered ORDER BY over all paintings times out — always FILTER by
///   sitelink band; one query per band, GROUP BY to collapse multi-valued
///   P170/P195 which otherwise duplicate rows.
/// - `?image` binds to http://commons.wikimedia.org/wiki/Special:FilePath/<pct-enc name>;
///   percent-decode the last path component to get the Commons file name.
/// - Commons `prop=imageinfo&iiprop=url|size|extmetadata` (≤50 titles/request)
///   yields pixel dims plus LicenseShortName / Copyrighted ("False" = PD).
/// - Hotlinkable at arbitrary widths only via the Special:FilePath PHP thumb
///   route (`?width=N`); upload.wikimedia thumb paths enforce a width whitelist.
public struct WikidataSource: ArtSource {
    public static let id = "wikidata"

    public init() {}

    private static let sparqlEndpoint = "https://query.wikidata.org/sparql"
    private static let commonsAPI = "https://commons.wikimedia.org/w/api.php"

    /// Sitelink bands, highest first. Each band is one SPARQL query;
    /// [low, high) — bands do not overlap.
    private static let bands: [(low: Int, high: Int)] = [
        (100, 1000), (50, 100), (35, 50), (25, 35), (20, 25), (15, 20),
        (12, 15), (10, 12), (8, 10), (6, 8), (5, 6), (4, 5), (3, 4),
    ]

    private static let creatorBatchSize = 200
    private static let commonsBatchSize = 50

    // MARK: - Intermediate records

    private struct Row {
        var qid: String
        var sitelinks: Int
        var title: String?
        var creatorQID: String?
        var creatorLabel: String?
        var creatorDeathYear: Int?
        var imageFile: String      // decoded Commons file name, no "File:" prefix
        var inception: Int?
        var collection: String?
        var movement: String?
        var inventoryNumber: String?
    }

    private struct CommonsFileInfo {
        var width: Int?
        var height: Int?
        var license: String?
        var copyrighted: String?
    }

    // MARK: - ArtSource

    public func candidates(_ ctx: SourceContext) async throws -> [Candidate] {
        // Pass 1: SPARQL, one query per sitelink band.
        var rowsByQID: [String: Row] = [:]
        for band in Self.bands {
            let rows = await Self.bandRows(ctx, low: band.low, high: band.high)
            for row in rows where rowsByQID[row.qid] == nil {
                rowsByQID[row.qid] = row
            }
            ctx.log("wikidata: band \(band.low)-\(band.high) -> \(rows.count) works")
        }

        // Pass 2: sitelink counts for the unique creators (canon signal).
        let creatorSitelinks = await Self.fetchCreatorSitelinks(
            ctx, qids: Set(rowsByQID.values.compactMap(\.creatorQID)))

        // Pass 3: Commons file metadata (resolution + licence).
        let fileInfo = await Self.fetchCommonsInfo(
            ctx, fileNames: Set(rowsByQID.values.map(\.imageFile)))

        // Map to Candidates.
        var skippedNoLabel = 0
        var out: [Candidate] = []
        for row in rowsByQID.values {
            guard let title = row.title, !title.isEmpty else {
                skippedNoLabel += 1
                continue
            }
            let info = fileInfo[row.imageFile]
            let pdEvidence: PDEvidence
            if let license = info?.license, let copyrighted = info?.copyrighted {
                pdEvidence = .commons(license: license, copyrighted: copyrighted)
            } else {
                pdEvidence = .none  // a later gate drops it
            }
            out.append(Candidate(
                source: Self.id,
                sourceId: row.qid,
                title: title,
                artist: row.creatorLabel,
                artistSort: Parse.sortName(row.creatorLabel),
                artistDeathYear: row.creatorDeathYear,
                yearStart: row.inception,
                yearEnd: row.inception,
                dateDisplay: row.inception.map(String.init),
                medium: nil,
                region: nil,
                movement: row.movement,
                wikidataQID: row.qid,
                inventoryNumber: row.inventoryNumber,
                pdEvidence: pdEvidence,
                imageMaxWidth: info?.width,
                imageMaxHeight: info?.height,
                imageURLTemplate: Self.imageURLTemplate(fileName: row.imageFile),
                signals: Signals(sitelinks: row.sitelinks,
                                 creatorSitelinks: row.creatorQID.flatMap { creatorSitelinks[$0] }),
                collectionName: row.collection ?? "Wikimedia Commons",
                collectionURL: "https://www.wikidata.org/wiki/\(row.qid)"
            ))
        }
        if skippedNoLabel > 0 {
            ctx.log("wikidata: skipped \(skippedNoLabel) works without an English label")
        }

        // Deterministic order: numeric by QID, string fallback.
        out.sort { a, b in
            if let ai = Int(a.sourceId.dropFirst()), let bi = Int(b.sourceId.dropFirst()) {
                return ai != bi ? ai < bi : a.sourceId < b.sourceId
            }
            return a.sourceId < b.sourceId
        }
        ctx.log("wikidata: done, \(out.count) candidates")
        return out
    }

    // MARK: - SPARQL: paintings per sitelink band

    /// Fetch one band. On failure, split the band in half recursively; a band
    /// of width 1 that still fails is logged and skipped — a bad band must not
    /// abort the whole run.
    private static func bandRows(_ ctx: SourceContext, low: Int, high: Int) async -> [Row] {
        do {
            let bindings = try await sparql(ctx, query: bandQuery(low: low, high: high))
            return bindings.compactMap(row(from:))
        } catch {
            guard high - low > 1 else {
                ctx.log("wikidata: band \(low)-\(high) failed, skipping: \(error)")
                return []
            }
            let mid = (low + high) / 2
            ctx.log("wikidata: band \(low)-\(high) failed (\(error)); splitting at \(mid)")
            let lower = await bandRows(ctx, low: low, high: mid)
            let upper = await bandRows(ctx, low: mid, high: high)
            return lower + upper
        }
    }

    private static func bandQuery(low: Int, high: Int) -> String {
        """
        SELECT ?item ?sl (SAMPLE(?itemLabelE) AS ?itemLabel) (SAMPLE(?creatorQ) AS ?creator) (SAMPLE(?creatorLabelE) AS ?creatorLabel) (SAMPLE(?deathY) AS ?death) (SAMPLE(?img) AS ?image) (SAMPLE(?incY) AS ?inception) (SAMPLE(?collLabelE) AS ?collection) (SAMPLE(?movLabelE) AS ?movement) (GROUP_CONCAT(DISTINCT ?invPair; separator="||") AS ?invno)
        WHERE {
          ?item wdt:P31 wd:Q3305213 ; wikibase:sitelinks ?sl ; wdt:P18 ?img .
          FILTER(?sl >= \(low) && ?sl < \(high))
          OPTIONAL { ?item rdfs:label ?itemLabelE . FILTER(LANG(?itemLabelE) = "en") }
          OPTIONAL { ?item wdt:P170 ?creatorQ .
            OPTIONAL { ?creatorQ rdfs:label ?creatorLabelE . FILTER(LANG(?creatorLabelE) = "en") }
            OPTIONAL { ?creatorQ wdt:P570 ?d . BIND(YEAR(?d) AS ?deathY) } }
          OPTIONAL { ?item wdt:P571 ?inc . BIND(YEAR(?inc) AS ?incY) }
          OPTIONAL { ?item wdt:P195 ?coll . OPTIONAL { ?coll rdfs:label ?collLabelE . FILTER(LANG(?collLabelE) = "en") } }
          OPTIONAL { ?item wdt:P135 ?mov . OPTIONAL { ?mov rdfs:label ?movLabelE . FILTER(LANG(?movLabelE) = "en") } }
          OPTIONAL { ?item p:P217 ?invStmt . ?invStmt ps:P217 ?inv .
            OPTIONAL { ?invStmt pq:P195 ?invColl . ?invColl rdfs:label ?invCollLabelE . FILTER(LANG(?invCollLabelE) = "en") }
            BIND(CONCAT(?inv, "@", COALESCE(?invCollLabelE, "")) AS ?invPair) }
        }
        GROUP BY ?item ?sl
        """
    }

    private static func row(from binding: [String: Any]) -> Row? {
        guard let itemURI = value(binding, "item"),
              let qid = qidFromEntityURI(itemURI),
              let sl = value(binding, "sl").flatMap(Int.init),
              let imageURI = value(binding, "image"),
              let fileName = fileNameFromFilePathURI(imageURI) else { return nil }
        return Row(
            qid: qid,
            sitelinks: sl,
            title: value(binding, "itemLabel"),
            creatorQID: value(binding, "creator").flatMap(qidFromEntityURI),
            creatorLabel: value(binding, "creatorLabel"),
            creatorDeathYear: value(binding, "death").flatMap(Int.init),
            imageFile: fileName,
            inception: value(binding, "inception").flatMap(Int.init),
            collection: value(binding, "collection"),
            movement: value(binding, "movement"),
            inventoryNumber: value(binding, "invno")
        )
    }

    // MARK: - SPARQL: creator sitelinks (batched VALUES)

    private static func fetchCreatorSitelinks(_ ctx: SourceContext, qids: Set<String>) async -> [String: Int] {
        // Only well-formed QIDs — these are interpolated into the query.
        let sorted = qids.filter { isQID($0) }.sorted()
        var out: [String: Int] = [:]
        for chunk in chunked(sorted, size: creatorBatchSize) {
            let values = chunk.map { "wd:\($0)" }.joined(separator: " ")
            let query = "SELECT ?c ?csl WHERE { VALUES ?c { \(values) } ?c wikibase:sitelinks ?csl }"
            do {
                for binding in try await sparql(ctx, query: query) {
                    if let qid = value(binding, "c").flatMap(qidFromEntityURI),
                       let csl = value(binding, "csl").flatMap(Int.init) {
                        out[qid] = csl
                    }
                }
            } catch {
                ctx.log("wikidata: creator sitelink batch failed (\(chunk.count) QIDs): \(error)")
            }
        }
        ctx.log("wikidata: creator sitelinks for \(out.count)/\(sorted.count) creators")
        return out
    }

    // MARK: - Commons enrichment (resolution + licence)

    private static func fetchCommonsInfo(_ ctx: SourceContext, fileNames: Set<String>) async -> [String: CommonsFileInfo] {
        var out: [String: CommonsFileInfo] = [:]
        for chunk in chunked(fileNames.sorted(), size: commonsBatchSize) {
            do {
                let batch = try await commonsBatch(ctx, fileNames: chunk)
                out.merge(batch) { a, _ in a }
            } catch {
                ctx.log("wikidata: commons batch failed (\(chunk.count) files): \(error)")
            }
        }
        ctx.log("wikidata: commons metadata for \(out.count)/\(fileNames.count) files")
        return out
    }

    private static func commonsBatch(_ ctx: SourceContext, fileNames: [String]) async throws -> [String: CommonsFileInfo] {
        let titles = fileNames.map { "File:" + $0 }.joined(separator: "|")
        guard let url = urlWithQuery(commonsAPI, [
            ("action", "query"),
            ("format", "json"),
            ("formatversion", "2"),
            ("prop", "imageinfo"),
            ("iiprop", "url|size|extmetadata"),
            ("titles", titles),
        ]) else {
            throw HttpError(status: 0, url: commonsAPI, bodyPrefix: "could not build commons URL")
        }
        let data = try await ctx.http.get(url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = root["query"] as? [String: Any],
              let pages = query["pages"] as? [[String: Any]] else {
            throw HttpError(status: 0, url: url.absoluteString,
                            bodyPrefix: "unexpected commons response shape")
        }

        // The API may normalize titles (underscores, unicode NFC, …);
        // map the response title back to the title we asked for.
        var normalizedToRequested: [String: String] = [:]
        if let normalized = query["normalized"] as? [[String: Any]] {
            for entry in normalized {
                if let from = entry["from"] as? String, let to = entry["to"] as? String {
                    normalizedToRequested[to] = from
                }
            }
        }

        var out: [String: CommonsFileInfo] = [:]
        for page in pages {
            guard let pageTitle = page["title"] as? String else { continue }
            let requested = normalizedToRequested[pageTitle] ?? pageTitle
            let fileName = requested.hasPrefix("File:") ? String(requested.dropFirst(5)) : requested
            guard let imageinfo = (page["imageinfo"] as? [[String: Any]])?.first else { continue }

            var info = CommonsFileInfo()
            info.width = imageinfo["width"] as? Int
            info.height = imageinfo["height"] as? Int
            if let ext = imageinfo["extmetadata"] as? [String: Any] {
                // extmetadata values can carry HTML — strip it.
                if let v = (ext["LicenseShortName"] as? [String: Any])?["value"] as? String {
                    info.license = Parse.stripHTML(v)
                }
                if let v = (ext["Copyrighted"] as? [String: Any])?["value"] as? String {
                    info.copyrighted = Parse.stripHTML(v)
                }
            }
            out[fileName] = info
        }
        return out
    }

    // MARK: - HTTP / parsing helpers

    /// Run a SPARQL query; returns result bindings. GET with a urlencoded
    /// query param; the Http actor supplies the mandatory User-Agent and
    /// paces query.wikidata.org at 3s/request.
    private static func sparql(_ ctx: SourceContext, query: String) async throws -> [[String: Any]] {
        guard let url = urlWithQuery(sparqlEndpoint, [("query", query)]) else {
            throw HttpError(status: 0, url: sparqlEndpoint, bodyPrefix: "could not build SPARQL URL")
        }
        let data = try await ctx.http.get(url, headers: ["Accept": "application/sparql-results+json"])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [String: Any],
              let bindings = results["bindings"] as? [[String: Any]] else {
            throw HttpError(status: 0, url: url.absoluteString,
                            bodyPrefix: "unexpected SPARQL response shape")
        }
        return bindings
    }

    /// RFC 3986 unreserved characters — everything else gets percent-encoded.
    /// (URLComponents leaves "&" and "+" bare inside query values; SPARQL
    /// queries contain "&&", so encode strictly by hand.)
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func urlWithQuery(_ base: String, _ params: [(String, String)]) -> URL? {
        var pairs: [String] = []
        for (key, rawValue) in params {
            guard let value = rawValue.addingPercentEncoding(withAllowedCharacters: unreserved) else {
                return nil
            }
            pairs.append("\(key)=\(value)")
        }
        return URL(string: base + "?" + pairs.joined(separator: "&"))
    }

    /// "http://www.wikidata.org/entity/Q185372" -> "Q185372".
    private static func qidFromEntityURI(_ uri: String) -> String? {
        guard let last = uri.split(separator: "/").last else { return nil }
        let qid = String(last)
        return isQID(qid) ? qid : nil
    }

    private static func isQID(_ s: String) -> Bool {
        s.hasPrefix("Q") && s.count > 1 && s.dropFirst().allSatisfy(\.isNumber)
    }

    /// "http://commons.wikimedia.org/wiki/Special:FilePath/Meisje%20met%20de%20parel.jpg"
    /// -> "Meisje met de parel.jpg".
    private static func fileNameFromFilePathURI(_ uri: String) -> String? {
        guard let last = uri.split(separator: "/").last,
              let decoded = String(last).removingPercentEncoding,
              !decoded.isEmpty else { return nil }
        return decoded
    }

    /// PHP thumb route — accepts arbitrary widths (rounds up server-side).
    /// Never hotlink upload.wikimedia thumb paths: those whitelist widths.
    private static func imageURLTemplate(fileName: String) -> String {
        let encoded = fileName.addingPercentEncoding(withAllowedCharacters: unreserved) ?? fileName
        return "https://commons.wikimedia.org/wiki/Special:FilePath/\(encoded)?width={w}"
    }

    private static func value(_ binding: [String: Any], _ key: String) -> String? {
        (binding[key] as? [String: Any])?["value"] as? String
    }

    private static func chunked<T>(_ items: [T], size: Int) -> [[T]] {
        stride(from: 0, to: items.count, by: size).map {
            Array(items[$0..<min($0 + size, items.count)])
        }
    }
}
