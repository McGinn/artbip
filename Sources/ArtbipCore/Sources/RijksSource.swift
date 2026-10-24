import Foundation

/// Rijksmuseum "Top 1000" paintings via the new keyless linked-data API
/// (the old rijksmuseum.nl/api is dead — HTTP 410).
///
/// Flow per work (~5 requests, all disk-cached by Http):
///   1. search page lists HumanMadeObject URIs (100/page, `next` pagination)
///   2. GET id.rijksmuseum.nl/<id>          → Linked Art HumanMadeObject
///   3. GET shows[0].id                     → VisualItem (carries the PD Right)
///   4. GET digitally_shown_by[0].id        → DigitalObject → iiif.micr.io URL
///   5. GET iiif.micr.io/<imageId>/info.json → pixel dimensions
///
/// Top-1000 membership itself is the museum-highlight signal. Works without a
/// Public Domain rights marker are skipped.
public struct RijksSource: ArtSource {
    public static let id = "rijks"

    public init() {}

    private static let searchStart =
        "https://data.rijksmuseum.nl/search/collection?memberOfSetId=260214&type=painting&imageAvailable=true"
    private static let ldHeaders = ["Accept": "application/ld+json"]
    /// Getty AAT ids used by the Rijksmuseum's Linked Art records.
    private static let aatEnglish = "300388277"       // language: English
    private static let aatObjectNumber = "300312355"  // identifier: object/accession number
    private static let maxSearchPages = 50            // safety valve (~399 items = 4 pages)

    // MARK: - ArtSource

    public func candidates(_ ctx: SourceContext) async throws -> [Candidate] {
        // Stage 1: paginate the OrderedCollectionPage search results.
        var objectURLs: [String] = []
        var total = 0
        var page = 0
        var pageURL: String? = Self.searchStart
        while let urlString = pageURL, let url = URL(string: urlString), page < Self.maxSearchPages {
            page += 1
            let data = try await ctx.http.get(url, headers: Self.ldHeaders)
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw HttpError(status: 0, url: urlString, bodyPrefix: "search response is not a JSON object")
            }
            if let partOf = Self.asDict(dict["partOf"]), let t = partOf["totalItems"] as? Int {
                total = t
            }
            for item in Self.dicts(dict["orderedItems"]) {
                if let id = item["id"] as? String { objectURLs.append(id) }
            }
            pageURL = Self.asDict(dict["next"]).flatMap { $0["id"] as? String }
            ctx.log("rijks: search page \(page), \(objectURLs.count)/\(total) items")
        }

        // Stage 2: resolve each object. A single failure must not abort the run.
        var out: [Candidate] = []
        var skipped = 0
        var failed = 0
        for (i, objectURL) in objectURLs.enumerated() {
            do {
                if let c = try await Self.candidate(objectURL: objectURL, ctx: ctx) {
                    out.append(c)
                } else {
                    skipped += 1
                }
            } catch {
                failed += 1
                ctx.log("rijks: FAILED \(objectURL): \(error)")
            }
            if (i + 1) % 25 == 0 || i + 1 == objectURLs.count {
                ctx.log("rijks: \(i + 1)/\(objectURLs.count) works, \(out.count) candidates")
            }
        }

        // Deterministic order: numeric by source id, string fallback.
        out.sort { a, b in
            if let ai = Int(a.sourceId), let bi = Int(b.sourceId) { return ai < bi }
            return a.sourceId < b.sourceId
        }
        ctx.log("rijks: done, \(out.count) candidates (\(skipped) skipped, \(failed) failed)")
        return out
    }

    // MARK: - Per-object resolution

    private static func candidate(objectURL: String, ctx: SourceContext) async throws -> Candidate? {
        guard let url = URL(string: objectURL) else { return nil }
        let sourceId = url.lastPathComponent
        let data = try await ctx.http.get(url, headers: ldHeaders)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            ctx.log("rijks: skip \(sourceId) — object is not a JSON dictionary")
            return nil
        }

        let identifiedBy = dicts(obj["identified_by"])
        let producedBy = asDict(obj["produced_by"]) ?? [:]

        let artist = artistName(producedBy: producedBy)
        guard let title = title(identifiedBy: identifiedBy, artist: artist) else {
            ctx.log("rijks: skip \(sourceId) — no title")
            return nil
        }
        let objectNumber = objectNumber(identifiedBy: identifiedBy)

        // Timespan → years + English display string.
        let timespan = asDict(producedBy["timespan"]) ?? [:]
        let yearStart = isoYear(timespan["begin_of_the_begin"] as? String)
        let yearEnd = isoYear(timespan["end_of_the_end"] as? String)
        let dateDisplay = preferredName(dicts(timespan["identified_by"]))

        // Image chain: shows → VisualItem → digitally_shown_by → DigitalObject.
        guard let visualItemURL = firstId(obj["shows"]).flatMap(URL.init(string:)) else {
            ctx.log("rijks: skip \(sourceId) — no shows/VisualItem")
            return nil
        }
        let visData = try await ctx.http.get(visualItemURL, headers: ldHeaders)
        guard let visualItem = try JSONSerialization.jsonObject(with: visData) as? [String: Any],
              let digitalObjectURL = firstId(visualItem["digitally_shown_by"]).flatMap(URL.init(string:)) else {
            ctx.log("rijks: skip \(sourceId) — no DigitalObject")
            return nil
        }
        let digData = try await ctx.http.get(digitalObjectURL, headers: ldHeaders)
        guard let digitalObject = try JSONSerialization.jsonObject(with: digData) as? [String: Any] else {
            ctx.log("rijks: skip \(sourceId) — DigitalObject is not a JSON dictionary")
            return nil
        }

        // PD gate: the Right lives on the VisualItem's subject_to in practice;
        // also accept it on the DigitalObject. No marker → skip.
        guard hasPublicDomainRight(visualItem) || hasPublicDomainRight(digitalObject) else {
            ctx.log("rijks: skip \(sourceId) — no Public Domain marker")
            return nil
        }

        // access_point[0].id = https://iiif.micr.io/<imageId>/full/max/0/default.jpg
        guard let accessPoint = firstId(digitalObject["access_point"]),
              let imageId = micrioImageId(accessPoint) else {
            ctx.log("rijks: skip \(sourceId) — no IIIF access point")
            return nil
        }

        // Image dimensions from the IIIF service.
        var imageWidth: Int?
        var imageHeight: Int?
        if let infoURL = URL(string: "https://iiif.micr.io/\(imageId)/info.json") {
            let info = try await ctx.http.get(infoURL, headers: [:])
            if let infoDict = try JSONSerialization.jsonObject(with: info) as? [String: Any] {
                imageWidth = infoDict["width"] as? Int
                imageHeight = infoDict["height"] as? Int
            }
        }

        let collectionURL: String
        if let objectNumber {
            collectionURL = "https://www.rijksmuseum.nl/en/collection/\(objectNumber)"
        } else {
            collectionURL = objectURL
        }

        return Candidate(
            source: Self.id,
            sourceId: sourceId,
            title: title,
            artist: artist,
            artistSort: Parse.sortName(artist),
            yearStart: yearStart,
            yearEnd: yearEnd,
            dateDisplay: dateDisplay,
            medium: medium(obj["made_of"]),
            wikidataQID: wikidataQID(obj["equivalent"]),
            inventoryNumber: objectNumber,
            pdEvidence: .museumFlag(field: "public-domain-mark"),
            imageMaxWidth: imageWidth,
            imageMaxHeight: imageHeight,
            imageURLTemplate: "https://iiif.micr.io/\(imageId)/full/{w},/0/default.jpg",
            signals: Signals(museumHighlight: true),
            collectionName: "Rijksmuseum",
            collectionURL: collectionURL
        )
    }

    // MARK: - Linked Art field extraction

    /// Title: prefer an English Name (language aat 300388277); among several
    /// English names take the shortest (long forms append ", artist, date").
    /// Falls back to the first Name, stripping a trailing ", <artist>…".
    private static func title(identifiedBy: [[String: Any]], artist: String?) -> String? {
        let names = identifiedBy.filter { $0["type"] as? String == "Name" }
        let contents = names.compactMap { $0["content"] as? String }
        let english = names.filter(isEnglish).compactMap { $0["content"] as? String }
        guard var title = english.min(by: { $0.count < $1.count }) ?? contents.first else { return nil }
        if let artist, let r = title.range(of: ", \(artist)") {
            title = String(title[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return title.isEmpty ? nil : title
    }

    /// Object number: Identifier classified_as aat 300312355 (e.g. "SK-C-5").
    private static func objectNumber(identifiedBy: [[String: Any]]) -> String? {
        for entry in identifiedBy where entry["type"] as? String == "Identifier" {
            let classIds = dicts(entry["classified_as"]).compactMap { $0["id"] as? String }
            if classIds.contains(where: { $0.contains(aatObjectNumber) }) {
                return entry["content"] as? String
            }
        }
        return nil
    }

    /// First named Person from produced_by.carried_out_by or produced_by.part[].carried_out_by.
    private static func artistName(producedBy: [String: Any]) -> String? {
        var actors = dicts(producedBy["carried_out_by"])
        for part in dicts(producedBy["part"]) {
            actors += dicts(part["carried_out_by"])
        }
        for actor in actors {
            // notation is a JSON-LD language map: [{"@language":"en","@value":"…"}].
            if let name = langMapValue(actor["notation"]) { return name }
            if let label = actor["_label"] as? String, !label.isEmpty { return label }
            if let label = langMapValue(actor["_label"]) { return label }
        }
        return nil
    }

    /// Materials → English notation labels, joined (e.g. "oil paint, canvas").
    private static func medium(_ madeOf: Any?) -> String? {
        let labels = dicts(madeOf).compactMap { langMapValue($0["notation"]) }
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    /// Work-level Wikidata QID from equivalent[] wikidata.org URIs.
    private static func wikidataQID(_ equivalent: Any?) -> String? {
        for entry in dicts(equivalent) {
            guard let uri = entry["id"] as? String, uri.contains("wikidata.org"),
                  let r = uri.range(of: #"Q[0-9]+"#, options: .regularExpression) else { continue }
            return String(uri[r])
        }
        return nil
    }

    /// A Right classified as / named "Public Domain" under subject_to.
    private static func hasPublicDomainRight(_ node: [String: Any]) -> Bool {
        for right in dicts(node["subject_to"]) {
            for cls in dicts(right["classified_as"]) {
                if let id = cls["id"] as? String, id.lowercased().contains("publicdomain") { return true }
                if let label = cls["_label"] as? String, label.lowercased().contains("public domain") { return true }
            }
            for name in dicts(right["identified_by"]) {
                if let content = name["content"] as? String,
                   content.lowercased().contains("public domain") { return true }
            }
        }
        return false
    }

    /// English Name content from a list of Name entries, else the first one.
    private static func preferredName(_ names: [[String: Any]]) -> String? {
        let named = names.filter { $0["type"] as? String == "Name" }
        if let en = named.first(where: isEnglish), let s = en["content"] as? String { return s }
        return named.first?["content"] as? String
    }

    /// language[] contains the AAT English concept.
    private static func isEnglish(_ entry: [String: Any]) -> Bool {
        dicts(entry["language"]).contains {
            ($0["id"] as? String)?.contains(aatEnglish) ?? false
        }
    }

    /// "https://iiif.micr.io/PbGmB/full/max/0/default.jpg" → "PbGmB".
    private static func micrioImageId(_ urlString: String) -> String? {
        guard let url = URL(string: urlString), url.host?.contains("micr.io") == true else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard let first = components.first, !first.isEmpty else { return nil }
        return first
    }

    /// "1885-12-31T23:59:59Z" → 1885.
    private static func isoYear(_ s: String?) -> Int? {
        guard let s, s.count >= 4 else { return nil }
        return Int(s.prefix(4))
    }

    // MARK: - Defensive JSON-LD casts (values are object-or-array-or-scalar)

    private static func asDict(_ v: Any?) -> [String: Any]? { v as? [String: Any] }

    private static func asArray(_ v: Any?) -> [Any] {
        if let a = v as? [Any] { return a }
        if let v, !(v is NSNull) { return [v] }
        return []
    }

    private static func dicts(_ v: Any?) -> [[String: Any]] {
        asArray(v).compactMap { $0 as? [String: Any] }
    }

    /// First "id" from a reference that may be an object, an array of objects,
    /// or a bare URI string.
    private static func firstId(_ v: Any?) -> String? {
        for item in asArray(v) {
            if let d = item as? [String: Any], let id = d["id"] as? String { return id }
            if let s = item as? String { return s }
        }
        return nil
    }

    /// JSON-LD language map ([{"@language":"en","@value":"…"}], possibly mixed
    /// with bare strings). Prefers English, else the first value.
    private static func langMapValue(_ v: Any?, prefer language: String = "en") -> String? {
        var first: String?
        for item in asArray(v) {
            if let s = item as? String, !s.isEmpty {
                if first == nil { first = s }
            } else if let d = item as? [String: Any], let value = d["@value"] as? String, !value.isEmpty {
                if d["@language"] as? String == language { return value }
                if first == nil { first = value }
            }
        }
        return first
    }
}
