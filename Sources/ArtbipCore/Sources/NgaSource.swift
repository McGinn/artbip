import Foundation

/// National Gallery of Art (Washington, DC). No REST metadata API — the museum
/// publishes its collection as CSV dumps in the NationalGalleryOfArt/opendata
/// GitHub repo. We download four CSVs (disk-cached by Http), join them in
/// memory, and emit one Candidate per open-access painting.
///
/// Verified 2026-07-14:
/// - raw.githubusercontent.com serves the real CSV bytes (not Git LFS
///   pointers) for all four files, so no media.githubusercontent.com fallback
///   is needed.
/// - objects.csv: filter `classification == "Painting"` and `isvirtual == "0"`.
/// - published_images.csv: filter `viewtype == "primary"` and
///   `openaccess == "1"`; join `depictstmsobjectid` -> `objectid`. Open-access
///   rows have an empty `maxpixels`. `width`/`height` are the native pixel
///   dimensions.
/// - Artist death year: objects_constituents.csv rows with
///   `roletype == "artist"` join to constituents.csv, whose `endyear` column
///   is the person's death year (empty for living artists).
/// - IIIF at api.nga.gov caps /full/ requests at 4096 px long side, so the
///   `!{w},{w}` size form is always safe.
public struct NgaSource: ArtSource {
    public static let id = "nga"

    public init() {}

    private static let base = "https://raw.githubusercontent.com/NationalGalleryOfArt/opendata/main/data/"

    private static func csvURL(_ name: String) -> URL {
        URL(string: base + name + ".csv")!
    }

    // MARK: - ArtSource

    public func candidates(_ ctx: SourceContext) async throws -> [Candidate] {
        // objects.csv (~82 MB): keep only real (non-virtual) paintings.
        let objectRows = CSV.parse(try await ctx.http.get(Self.csvURL("objects")))
        var paintings: [String: [String: String]] = [:]  // objectid -> row
        for row in objectRows {
            guard row["classification"] == "Painting",
                  row["isvirtual"] == "0",
                  let oid = row["objectid"], !oid.isEmpty else { continue }
            paintings[oid] = row
        }
        ctx.log("nga: objects.csv \(objectRows.count) rows, \(paintings.count) paintings kept")

        // published_images.csv (~89 MB): primary open-access image per object.
        // A few objects have multiple primary rows; keep the lowest sequence.
        let imageRows = CSV.parse(try await ctx.http.get(Self.csvURL("published_images")))
        var images: [String: [String: String]] = [:]  // objectid -> image row
        for row in imageRows {
            guard row["viewtype"] == "primary",
                  row["openaccess"] == "1",
                  let oid = row["depictstmsobjectid"], !oid.isEmpty,
                  paintings[oid] != nil,
                  let iiif = row["iiifurl"], !iiif.isEmpty else { continue }
            if let existing = images[oid] {
                let a = Int(row["sequence"] ?? "") ?? Int.max
                let b = Int(existing["sequence"] ?? "") ?? Int.max
                if a < b { images[oid] = row }
            } else {
                images[oid] = row
            }
        }
        ctx.log("nga: published_images.csv \(imageRows.count) rows, \(images.count) paintings with a primary open-access image")

        // constituents.csv: constituentid -> death year (endyear column).
        let constituentRows = CSV.parse(try await ctx.http.get(Self.csvURL("constituents")))
        var deathYearByConstituent: [String: Int] = [:]
        for row in constituentRows {
            guard let cid = row["constituentid"],
                  let year = Int(row["endyear"] ?? "") else { continue }
            deathYearByConstituent[cid] = year
        }

        // objects_constituents.csv: first-listed artist per object.
        let linkRows = CSV.parse(try await ctx.http.get(Self.csvURL("objects_constituents")))
        var artistLink: [String: (order: Int, constituentid: String)] = [:]
        for row in linkRows {
            guard row["roletype"] == "artist",
                  let oid = row["objectid"], paintings[oid] != nil,
                  let cid = row["constituentid"], !cid.isEmpty else { continue }
            let order = Int(row["displayorder"] ?? "") ?? Int.max
            if let existing = artistLink[oid], existing.order <= order { continue }
            artistLink[oid] = (order, cid)
        }
        ctx.log("nga: constituents \(constituentRows.count) rows, artist links for \(artistLink.count) paintings")

        // Build candidates for every painting that has a usable image.
        var out: [Candidate] = []
        for (oid, obj) in paintings {
            guard let img = images[oid] else { continue }
            guard let title = Self.nonEmpty(obj["title"]) else { continue }

            let artist = Self.nonEmpty(obj["attribution"])
            let artistSort = Self.nonEmpty(obj["attributioninverted"]) ?? Parse.sortName(artist)
            let deathYear = artistLink[oid].flatMap { deathYearByConstituent[$0.constituentid] }
            let iiifurl = img["iiifurl"]!  // guaranteed non-empty by the image filter

            out.append(Candidate(
                source: Self.id,
                sourceId: oid,
                title: title,
                artist: artist,
                artistSort: artist != nil ? artistSort : nil,
                artistDeathYear: deathYear,
                yearStart: Int(obj["beginyear"] ?? ""),
                yearEnd: Int(obj["endyear"] ?? ""),
                dateDisplay: Self.nonEmpty(obj["displaydate"]),
                medium: Self.nonEmpty(obj["medium"]),
                region: nil,
                wikidataQID: Self.nonEmpty(obj["wikidataid"]),
                inventoryNumber: Self.nonEmpty(obj["accessionnum"]),
                pdEvidence: .museumFlag(field: "openaccess"),
                imageMaxWidth: Int(img["width"] ?? ""),
                imageMaxHeight: Int(img["height"] ?? ""),
                imageURLTemplate: "\(iiifurl)/full/!{w},{w}/0/default.jpg",
                signals: Signals(),
                collectionName: "National Gallery of Art",
                collectionURL: "https://www.nga.gov/artworks/\(oid)"
            ))
        }

        // Deterministic order: numeric by objectid, string fallback.
        out.sort { a, b in
            if let ai = Int(a.sourceId), let bi = Int(b.sourceId) { return ai < bi }
            return a.sourceId < b.sourceId
        }
        ctx.log("nga: done, \(out.count) candidates")
        return out
    }

    // MARK: - Helpers

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
