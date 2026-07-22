import Foundation
import CryptoKit

/// A work after cross-source dedup: the chosen best record plus provenance.
public struct JoinedWork: Codable, Sendable {
    public var primary: Candidate
    public var duplicateIds: [String]

    public init(primary: Candidate, duplicateIds: [String] = []) {
        self.primary = primary
        self.duplicateIds = duplicateIds
    }
}

public struct DropRecord: Codable, Sendable {
    public var id: String
    public var title: String
    public var artist: String?
    public var stage: String
    public var reason: String
}

public enum Pipeline {

    // MARK: Join & dedupe

    /// Merge candidates across sources. Primary key: Wikidata QID. Fallback:
    /// normalized artist+title+year-decade. Museum records are preferred over
    /// Commons/Wikidata records unless the Commons scan is dramatically larger.
    public static func join(_ all: [Candidate], canonLists: [String: [String]]) -> [JoinedWork] {
        // Annotate canon-list membership by QID first.
        var candidates = all
        for i in candidates.indices {
            if let qid = candidates[i].wikidataQID, let lists = canonLists[qid] {
                candidates[i].signals.canonLists = Array(Set(candidates[i].signals.canonLists + lists)).sorted()
            }
        }

        var groups: [String: [Candidate]] = [:]
        for c in candidates {
            groups[joinKey(c), default: []].append(c)
        }

        // Second pass: absorb non-QID groups into QID groups that share a
        // fuzzy key (artist|title|decade) or an inventory-number key
        // (accession no. + collection). Wikidata may carry several inventory
        // numbers ("A||B") when a painting moved between collections.
        var aliasIndex: [String: String] = [:] // alias -> QID group key
        for (key, members) in groups where key.hasPrefix("qid:") {
            for m in members {
                aliasIndex[fuzzyKey(m)] = key
                for inv in invKeys(m) { aliasIndex[inv] = key }
            }
        }
        for (key, members) in groups where key.hasPrefix("fuzzy:") {
            var target: String? = aliasIndex[String(key.dropFirst(6))]
            if target == nil {
                target = members.lazy.flatMap(invKeys).compactMap { aliasIndex[$0] }.first
            }
            if let target {
                groups[target, default: []].append(contentsOf: members)
                groups.removeValue(forKey: key)
            }
        }

        return groups.values.map { members in
            let primary = pickPrimary(members)
            var merged = primary
            merged.signals = mergeSignals(members.map(\.signals))
            for m in members where m.id != primary.id {
                if merged.wikidataQID == nil { merged.wikidataQID = m.wikidataQID }
                if merged.movement == nil { merged.movement = m.movement }
                if merged.artistDeathYear == nil { merged.artistDeathYear = m.artistDeathYear }
                if merged.region == nil { merged.region = m.region }
                if merged.yearStart == nil { merged.yearStart = m.yearStart; merged.yearEnd = m.yearEnd }
                if merged.dominantHSL == nil { merged.dominantHSL = m.dominantHSL }
            }
            let dups = members.map(\.id).filter { $0 != primary.id }.sorted()
            return JoinedWork(primary: merged, duplicateIds: dups)
        }
        .sorted { $0.primary.id < $1.primary.id }
    }

    static func joinKey(_ c: Candidate) -> String {
        if let qid = c.wikidataQID, !qid.isEmpty { return "qid:\(qid)" }
        return "fuzzy:\(fuzzyKey(c))"
    }

    static func fuzzyKey(_ c: Candidate) -> String {
        let artist = normalize(c.artist ?? "anon")
        let title = normalize(c.title)
        let decade = (c.yearStart ?? 0) / 10
        return "\(artist)|\(title)|\(decade)"
    }

    /// Inventory-number join keys: accession number scoped by collection name
    /// to avoid cross-museum accession collisions. Wikidata records may carry
    /// several "inv@Collection" pairs (the P217 qualifier collection), joined
    /// with "||"; an empty collection after "@" falls back to the record's
    /// display collection.
    static func invKeys(_ c: Candidate) -> [String] {
        guard let inv = c.inventoryNumber, !inv.isEmpty else { return [] }
        let defaultColl = normalize(c.collectionName)
        return inv.components(separatedBy: "||").compactMap { part in
            let pieces = part.components(separatedBy: "@")
            let num = normalize(pieces[0])
            guard !num.isEmpty else { return nil }
            let coll = pieces.count > 1 && !pieces[1].isEmpty ? normalize(pieces[1]) : defaultColl
            return "inv:\(num)|\(coll)"
        }
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en"))
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func pickPrimary(_ members: [Candidate]) -> Candidate {
        func area(_ c: Candidate) -> Int { (c.imageMaxWidth ?? 0) * (c.imageMaxHeight ?? 0) }
        let museums = members.filter { $0.source != "wikidata" }
        let commons = members.filter { $0.source == "wikidata" }
        guard let bestMuseum = museums.max(by: { area($0) < area($1) }) else {
            return commons.max(by: { area($0) < area($1) })!
        }
        if let bestCommons = commons.max(by: { area($0) < area($1) }),
           area(bestCommons) > area(bestMuseum) * 3 / 2 {
            return bestCommons
        }
        return bestMuseum
    }

    static func mergeSignals(_ all: [Signals]) -> Signals {
        var s = Signals()
        s.sitelinks = all.compactMap(\.sitelinks).max()
        s.creatorSitelinks = all.compactMap(\.creatorSitelinks).max()
        s.museumHighlight = all.contains { $0.museumHighlight }
        s.boostRank = all.compactMap(\.boostRank).min()
        s.onView = all.contains { $0.onView }
        s.canonLists = Array(Set(all.flatMap(\.canonLists))).sorted()
        return s
    }

    // MARK: Gates

    public static func licenceGate(_ works: [JoinedWork]) -> (kept: [JoinedWork], dropped: [DropRecord]) {
        split(works, stage: "licence") { w in
            switch w.primary.pdEvidence {
            case .museumFlag: return nil
            case .commons(_, let copyrighted):
                return copyrighted.lowercased() == "false" ? nil : "commons Copyrighted != False"
            case .none: return "no public-domain evidence"
            }
        }
    }

    public static func mechanicalGates(_ works: [JoinedWork], config: CurateConfig) -> (kept: [JoinedWork], dropped: [DropRecord]) {
        split(works, stage: "mechanical") { w in
            guard let mw = w.primary.imageMaxWidth, let mh = w.primary.imageMaxHeight, mw > 0, mh > 0 else {
                return "unknown image dimensions"
            }
            let long = Double(max(mw, mh)), short = Double(min(mw, mh))
            if long / short > config.gates.maxAspectRatio {
                return "aspect \(String(format: "%.2f", long / short)) exceeds \(config.gates.maxAspectRatio)"
            }
            let needW = Double(config.display.width) * config.gates.resolutionTolerance
            let needH = Double(config.display.height) * config.gates.resolutionTolerance
            if Double(mw) < needW && Double(mh) < needH {
                return "resolution \(mw)x\(mh) below display fill \(config.display.width)x\(config.display.height)"
            }
            return nil
        }
    }

    /// Aggressive significance prefilter — a candidate must carry at least one
    /// strong canon signal before we spend LLM attention on it.
    public static func prefilter(_ works: [JoinedWork], config: CurateConfig) -> (kept: [JoinedWork], dropped: [DropRecord]) {
        split(works, stage: "prefilter") { w in
            let s = w.primary.signals
            if s.museumHighlight { return nil }
            if !s.canonLists.isEmpty { return nil }
            if let sl = s.sitelinks, sl >= config.prefilter.minSitelinks { return nil }
            // Creator-canon rule: famous artist AND the work itself shows some
            // presence (hanging in a gallery, or a nontrivial Wikipedia
            // footprint). Requiring sitelinks >= 4 keeps this from admitting
            // every 3-sitelink minor work by a famous name.
            if let cs = s.creatorSitelinks,
               cs >= config.prefilter.minCreatorSitelinksWithMuseumSignal,
               s.onView || (s.sitelinks ?? 0) >= 4 {
                return nil
            }
            return "no significance signal (sitelinks=\(s.sitelinks ?? 0), creator=\(s.creatorSitelinks ?? 0), onView=\(s.onView))"
        }
    }

    static func split(_ works: [JoinedWork], stage: String, reason: (JoinedWork) -> String?) -> ([JoinedWork], [DropRecord]) {
        var kept: [JoinedWork] = []
        var dropped: [DropRecord] = []
        for w in works {
            if let r = reason(w) {
                dropped.append(DropRecord(id: w.primary.id, title: w.primary.title,
                                          artist: w.primary.artist, stage: stage, reason: r))
            } else {
                kept.append(w)
            }
        }
        return (kept, dropped)
    }

    // MARK: Scoring support

    public static func promptHash(_ prompt: String) -> String {
        SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
    }

    // MARK: Selection & emit

    public static func select(_ works: [JoinedWork], scores: [String: ScoreResult],
                              overrides: Overrides, config: CurateConfig,
                              generatedAt: String) -> (manifest: Manifest, dropped: [DropRecord]) {
        var dropped: [DropRecord] = []
        var scored: [(JoinedWork, ScoreResult?)] = []

        for w in works {
            let id = w.primary.id
            let ov = overrides[id]
            if ov?.exclude == true {
                dropped.append(.init(id: id, title: w.primary.title, artist: w.primary.artist,
                                     stage: "select", reason: "override: exclude"))
                continue
            }
            if let artist = w.primary.artist, overrides["artist:\(artist)"]?.exclude == true {
                dropped.append(.init(id: id, title: w.primary.title, artist: artist,
                                     stage: "select", reason: "override: artist excluded"))
                continue
            }
            let score = scores[id]
            let pinned = ov?.pin == true
            if !pinned {
                guard let s = score else {
                    dropped.append(.init(id: id, title: w.primary.title, artist: w.primary.artist,
                                         stage: "select", reason: "unscored"))
                    continue
                }
                if !s.defects.isEmpty {
                    dropped.append(.init(id: id, title: w.primary.title, artist: w.primary.artist,
                                         stage: "select", reason: "defects: \(s.defects.joined(separator: ","))"))
                    continue
                }
                if s.score < config.scorer.minScore {
                    dropped.append(.init(id: id, title: w.primary.title, artist: w.primary.artist,
                                         stage: "select", reason: "score \(s.score) < \(config.scorer.minScore)"))
                    continue
                }
            }
            scored.append((w, score))
        }

        // Rank: pinned first, then LLM score, then canon-list count, sitelinks, highlight.
        func rankKey(_ pair: (JoinedWork, ScoreResult?)) -> (Double, Double, Double, Double) {
            let (w, s) = pair
            let pinned = overrides[w.primary.id]?.pin == true ? 1.0 : 0.0
            return (pinned, s?.score ?? 0,
                    Double(w.primary.signals.canonLists.count),
                    Double(w.primary.signals.sitelinks ?? 0))
        }
        scored.sort { rankKey($0) > rankKey($1) }

        // Per-artist cap + target count.
        let cap = max(1, Int(Double(config.selection.targetCount) * config.selection.maxArtistShare))
        var byArtist: [String: Int] = [:]
        var selected: [(JoinedWork, ScoreResult?)] = []
        for (w, s) in scored {
            if selected.count >= config.selection.targetCount { break }
            let artist = w.primary.artist ?? "Unknown"
            if byArtist[artist, default: 0] >= cap, overrides[w.primary.id]?.pin != true {
                dropped.append(.init(id: w.primary.id, title: w.primary.title, artist: artist,
                                     stage: "select", reason: "artist cap (\(cap))"))
                continue
            }
            byArtist[artist, default: 0] += 1
            selected.append((w, s))
        }

        let manifestWorks = selected.map { (w, s) -> ManifestWork in
            manifestWork(from: w, score: s, override: overrides[w.primary.id], config: config)
        }.sorted { $0.id < $1.id }

        return (Manifest(generatedAt: generatedAt, works: manifestWorks), dropped)
    }

    static func manifestWork(from w: JoinedWork, score: ScoreResult?, override ov: Override?,
                             config: CurateConfig) -> ManifestWork {
        let c = w.primary
        let maxW = c.imageMaxWidth ?? config.manifestImageWidth
        let width = min(config.manifestImageWidth, maxW)
        let url = c.imageURLTemplate.replacingOccurrences(of: "{w}", with: String(width))

        let licenseStatus: String
        let evidence: String
        switch c.pdEvidence {
        case .museumFlag(let field):
            licenseStatus = "CC0"
            evidence = "\(c.source):\(field)"
        case .commons(let license, _):
            licenseStatus = "PD"
            evidence = "commons:\(license)"
        case .none:
            licenseStatus = "UNKNOWN"
            evidence = "none"
        }

        return ManifestWork(
            id: c.id,
            wikidata: c.wikidataQID,
            title: ov?.title ?? c.title,
            artist: ov?.artist ?? c.artist ?? "Unknown",
            artistSort: c.artistSort ?? Parse.sortName(ov?.artist ?? c.artist) ?? "Unknown",
            artistDeathYear: c.artistDeathYear,
            dateDisplay: c.dateDisplay,
            year: c.yearStart,
            movement: ov?.movement ?? c.movement,
            region: ov?.region ?? c.region,
            medium: c.medium,
            collection: c.collectionName,
            collectionURL: c.collectionURL,
            image: ManifestImage(url: url,
                                 urlTemplate: c.imageURLTemplate.contains("{w}") ? c.imageURLTemplate : nil,
                                 sourceMaxWidth: c.imageMaxWidth ?? 0,
                                 sourceMaxHeight: c.imageMaxHeight ?? 0),
            license: ManifestLicense(status: licenseStatus, evidence: evidence,
                                     sourceURL: c.collectionURL),
            paletteDominantHSL: c.dominantHSL,
            significance: ManifestSignificance(sitelinks: c.signals.sitelinks,
                                               museumHighlight: c.signals.museumHighlight,
                                               canonLists: c.signals.canonLists,
                                               llmScore: score?.score),
            caption: ov?.caption ?? score?.caption
        )
    }
}
