import ArgumentParser
import ArtbipCore
import Foundation

// Registered source plugins. Adding a museum = one file + one line here.
func allSources() -> [any ArtSource] {
    [ArticSource(), MetSource(), ClevelandSource(), NgaSource(), RijksSource(), WikidataSource()]
}

// MARK: - gather

struct Gather: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fetch candidates from all sources (cached; safe to re-run).")

    @OptionGroup var opts: PipelineOptions
    @Option(help: "Run only this source id (artic|met|cleveland|nga|rijks|wikidata|canon).")
    var only: String?

    func run() async throws {
        let ctx = try opts.context()
        let outDir = opts.workDir.appendingPathComponent("candidates")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        if only == nil || only == "canon" {
            ctx.log("canon: fetching canon lists…")
            let canon = try await CanonLists.fetch(ctx)
            try JSONIO.write(canon, to: opts.workDir.appendingPathComponent("canon.json"))
            ctx.log("canon: \(canon.count) works across lists")
        }

        for source in allSources() {
            let id = type(of: source).id
            if let only, only != id { continue }
            ctx.log("\(id): gathering…")
            do {
                let candidates = try await source.candidates(ctx)
                try JSONIO.write(candidates, to: outDir.appendingPathComponent("\(id).json"))
                ctx.log("\(id): \(candidates.count) candidates")
            } catch {
                ctx.log("\(id): FAILED — \(error)")
                if only != nil { throw error }
            }
        }
    }
}

// MARK: - join

struct Join: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Dedupe candidates across sources into work/joined.json.")

    @OptionGroup var opts: PipelineOptions

    func run() async throws {
        let dir = opts.workDir.appendingPathComponent("candidates")
        var all: [Candidate] = []
        for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        where file.pathExtension == "json" {
            all += try JSONIO.read([Candidate].self, from: file)
        }
        let canonURL = opts.workDir.appendingPathComponent("canon.json")
        let canon = (try? JSONIO.read([String: [String]].self, from: canonURL)) ?? [:]
        let joined = Pipeline.join(all, canonLists: canon)
        try JSONIO.write(joined, to: opts.workDir.appendingPathComponent("joined.json"))
        print("joined: \(all.count) candidates -> \(joined.count) unique works")
    }
}

// MARK: - prefilter (licence + mechanical + significance gates)

struct Prefilter: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Apply licence, mechanical, and significance gates -> work/pool.json.")

    @OptionGroup var opts: PipelineOptions

    func run() async throws {
        let config = try opts.config()
        let joined = try JSONIO.read([JoinedWork].self, from: opts.workDir.appendingPathComponent("joined.json"))

        let (afterLicence, d1) = Pipeline.licenceGate(joined)
        let (afterMech, d2) = Pipeline.mechanicalGates(afterLicence, config: config)
        let (pool, d3) = Pipeline.prefilter(afterMech, config: config)

        try JSONIO.write(pool, to: opts.workDir.appendingPathComponent("pool.json"))
        try JSONIO.write(d1 + d2 + d3, to: opts.workDir.appendingPathComponent("drops-prefilter.json"))
        print("licence: \(joined.count) -> \(afterLicence.count)")
        print("mechanical: \(afterLicence.count) -> \(afterMech.count)")
        print("significance: \(afterMech.count) -> \(pool.count)  (scoring pool)")
    }
}

// MARK: - score-prep (emit pending batch + thumbnails for in-session scoring)

struct ScorePrep: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "score-prep",
        abstract: "Download thumbnails and emit work/scoring/pending.json for the scoring pass.")

    @OptionGroup var opts: PipelineOptions
    @Option(help: "Max works to prepare this run (0 = all).")
    var limit: Int = 0

    func run() async throws {
        let ctx = try opts.context()
        let config = ctx.config
        let hash = Pipeline.promptHash(config.scorer.prompt)
        let pool = try JSONIO.read([JoinedWork].self, from: opts.workDir.appendingPathComponent("pool.json"))

        let scoringDir = opts.workDir.appendingPathComponent("scoring")
        let thumbsDir = scoringDir.appendingPathComponent("thumbs")
        let resultsDir = scoringDir.appendingPathComponent("results")
        for d in [thumbsDir, resultsDir] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }

        var pending: [[String: String]] = []
        var prepared = 0, cached = 0, failed = 0

        for work in pool {
            let c = work.primary
            // Skip if a valid cached score exists.
            if let existing = try? JSONIO.read(ScoreResult.self, from: resultsDir.appendingPathComponent("\(c.id).json")),
               existing.promptHash == hash {
                cached += 1
                continue
            }
            if limit > 0 && prepared >= limit { continue }

            let thumbFile = thumbsDir.appendingPathComponent("\(c.id).jpg")
            if !FileManager.default.fileExists(atPath: thumbFile.path) {
                guard let url = c.imageURL(width: config.scorer.thumbWidth) else { failed += 1; continue }
                do {
                    let data = try await ctx.http.get(url)
                    guard let thumb = Thumbs.makeThumbnail(from: data, maxDimension: config.scorer.thumbWidth) else {
                        ctx.log("score-prep: cannot decode image for \(c.id)")
                        failed += 1
                        continue
                    }
                    try thumb.write(to: thumbFile)
                } catch {
                    ctx.log("score-prep: fetch failed for \(c.id): \(error)")
                    failed += 1
                    continue
                }
            }
            pending.append([
                "id": c.id,
                "thumb": "thumbs/\(c.id).jpg",
                "metadata": Self.metadata(c),
            ])
            prepared += 1
        }

        try JSONIO.write(pending, to: scoringDir.appendingPathComponent("pending.json"))
        let instructions = """
        artbip scoring batch
        ====================
        prompt_hash: \(hash)
        Each entry in pending.json: view the thumbnail, then write results/<id>.json:
        {"id": "...", "prompt_hash": "\(hash)", "score": 0-10, "caption": "...", "defects": []}
        Defect vocabulary: damage, frame, color-card, skew, crop, not-a-painting.
        Scoring prompt:
        \(config.scorer.prompt)
        """
        try instructions.write(to: scoringDir.appendingPathComponent("INSTRUCTIONS.txt"),
                               atomically: true, encoding: .utf8)
        print("score-prep: \(prepared) pending, \(cached) already scored, \(failed) image failures")
    }

    static func metadata(_ c: Candidate) -> String {
        var parts: [String] = []
        parts.append("Title: \(c.title)")
        if let a = c.artist { parts.append("Artist: \(a)") }
        if let d = c.dateDisplay ?? c.yearStart.map(String.init) { parts.append("Date: \(d)") }
        if let m = c.medium { parts.append("Medium: \(m)") }
        parts.append("Collection: \(c.collectionName)")
        let s = c.signals
        var sig: [String] = []
        if s.museumHighlight { sig.append("museum highlight") }
        if let sl = s.sitelinks { sig.append("\(sl) Wikipedia languages") }
        if !s.canonLists.isEmpty { sig.append("on lists: \(s.canonLists.joined(separator: ", "))") }
        if !sig.isEmpty { parts.append("Signals: \(sig.joined(separator: "; "))") }
        return parts.joined(separator: "\n")
    }
}

// MARK: - emit

struct Emit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Rebuild data/manifest.json from the pipeline (refuses unless --discard-reviewed-corrections).",
        discussion: """
        data/manifest.json is no longer regenerated. It is maintained by targeted, \
        reviewed corrections (attributions, dates, titles, withdrawals) applied to the \
        file itself. Emit rebuilds it from work/pool.json and the scores, which silently \
        discards every one of those corrections. It therefore refuses to run unless \
        --discard-reviewed-corrections is given, and even then is only for starting a \
        catalogue over from scratch.
        """)

    @OptionGroup var opts: PipelineOptions

    @Flag(name: .customLong("discard-reviewed-corrections"),
          help: "Really rebuild data/manifest.json, discarding the reviewed corrections in it.")
    var discardReviewedCorrections = false

    static let refusal = """
    curate emit: refusing to rebuild data/manifest.json.
    The manifest is maintained by targeted, reviewed corrections applied to the file \
    itself; emit regenerates it from the pipeline and would discard every one of them. \
    Make changes with a targeted correction instead. To rebuild from scratch anyway, \
    rerun with --discard-reviewed-corrections.
    """

    func validate() throws {
        guard discardReviewedCorrections else { throw ValidationError(Self.refusal) }
    }

    func run() async throws {
        let config = try opts.config()
        let pool = try JSONIO.read([JoinedWork].self, from: opts.workDir.appendingPathComponent("pool.json"))
        // Durable committed scores first; per-file scratch results (a newer
        // in-session pass) overlay them.
        var scores: [String: ScoreResult] = [:]
        if let file = try? JSONIO.read(ScoresFile.self, from: opts.dataDir.appendingPathComponent("scores.json")) {
            scores = file.asResults()
        }
        let resultsDir = opts.workDir.appendingPathComponent("scoring/results")
        if let files = try? FileManager.default.contentsOfDirectory(at: resultsDir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "json" {
                if let r = try? JSONIO.read(ScoreResult.self, from: f) { scores[r.id] = r }
            }
        }
        let overridesURL = opts.dataDir.appendingPathComponent("overrides.json")
        let overrides = (try? JSONIO.read(Overrides.self, from: overridesURL)) ?? [:]

        let iso = ISO8601DateFormatter().string(from: Date())
        let (manifest, dropped) = Pipeline.select(pool, scores: scores, overrides: overrides,
                                                  config: config, generatedAt: iso)
        try JSONIO.write(manifest, to: opts.dataDir.appendingPathComponent("manifest.json"))
        try JSONIO.write(dropped, to: opts.workDir.appendingPathComponent("drops-select.json"))
        print("emit: \(manifest.works.count) works -> data/manifest.json (\(scores.count) scored, \(dropped.count) dropped at selection)")
    }
}

// MARK: - audit

struct Audit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Generate work/audit.html — a random sample for human review.")

    @OptionGroup var opts: PipelineOptions
    @Option(help: "Sample size.")
    var sample: Int = 100
    @Option(help: "RNG seed (change to get a different sample).")
    var seed: UInt64 = 20260714

    func run() async throws {
        let manifest = try JSONIO.read(Manifest.self, from: opts.dataDir.appendingPathComponent("manifest.json"))
        let html = AuditPage.html(works: manifest.works, sample: sample, seed: seed)
        let out = opts.workDir.appendingPathComponent("audit.html")
        try html.write(to: out, atomically: true, encoding: .utf8)
        print("audit: \(out.path)")
    }
}

// MARK: - status

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show pipeline artifact counts.")

    @OptionGroup var opts: PipelineOptions

    func run() async throws {
        let fm = FileManager.default
        func count(_ rel: String) -> String {
            let url = opts.workDir.appendingPathComponent(rel)
            guard fm.fileExists(atPath: url.path) else { return "—" }
            if rel.hasSuffix(".json"),
               let data = try? Data(contentsOf: url),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                return String(arr.count)
            }
            if let entries = try? fm.contentsOfDirectory(atPath: url.path) {
                return String(entries.filter { $0.hasSuffix(".json") }.count)
            }
            return "?"
        }
        for source in ["artic", "met", "cleveland", "nga", "rijks", "wikidata"] {
            print("candidates/\(source): \(count("candidates/\(source).json"))")
        }
        print("joined: \(count("joined.json"))")
        print("pool: \(count("pool.json"))")
        print("scoring pending: \(count("scoring/pending.json"))")
        print("scoring results: \(count("scoring/results"))")
        let manifestURL = opts.dataDir.appendingPathComponent("manifest.json")
        if let m = try? JSONIO.read(Manifest.self, from: manifestURL) {
            print("manifest: \(m.works.count)")
        } else {
            print("manifest: —")
        }
    }
}
