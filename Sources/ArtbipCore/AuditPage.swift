import Foundation

/// Generates the human-review HTML page: a random sample of manifest entries
/// rendered thumbnail + wall label, for the "does every one belong on a wall"
/// check.
public enum AuditPage {
    public static func html(works: [ManifestWork], sample: Int, seed: UInt64 = 20260714) -> String {
        var rng = SplitMix64(seed: seed)
        let picked = works.shuffled(using: &rng).prefix(sample)

        var cards = ""
        for w in picked {
            let year = w.dateDisplay ?? w.year.map(String.init) ?? ""
            let score = w.significance.llmScore.map { String(format: "%.1f", $0) } ?? "—"
            let signals = [
                w.significance.museumHighlight ? "museum-highlight" : nil,
                w.significance.sitelinks.map { "sitelinks:\($0)" },
                w.significance.canonLists.isEmpty ? nil : "lists:" + w.significance.canonLists.joined(separator: ","),
            ].compactMap { $0 }.joined(separator: " · ")

            cards += """
            <div class="card">
              <a href="\(esc(w.collectionURL))"><img loading="lazy" src="\(esc(auditImageURL(w)))" alt=""></a>
              <div class="label">
                <div class="artist">\(esc(w.artist))</div>
                <div class="title">\(esc(w.title))\(year.isEmpty ? "" : ", \(esc(year))")</div>
                <div class="meta">\(esc(w.collection)) · \(esc(w.medium ?? "")) · score \(score)</div>
                <div class="signals">\(esc(signals)) · <code>\(esc(w.id))</code></div>
                \(w.caption.map { "<div class=\"caption\">\(esc($0))</div>" } ?? "")
              </div>
            </div>

            """
        }

        return """
        <!doctype html>
        <meta charset="utf-8">
        <title>artbip manifest audit — \(picked.count) of \(works.count)</title>
        <style>
          body { font: 14px/1.45 -apple-system, sans-serif; background: #111; color: #ddd; margin: 2rem; }
          h1 { font-weight: 400; }
          .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(360px, 1fr)); gap: 1.5rem; }
          .card { background: #1a1a1a; border-radius: 6px; overflow: hidden; }
          .card img { width: 100%; height: 300px; object-fit: contain; background: #000; display: block; }
          .label { padding: .75rem 1rem 1rem; }
          .artist { font-weight: 600; }
          .title { font-style: italic; }
          .meta, .signals { color: #888; font-size: 12px; margin-top: .25rem; }
          .caption { margin-top: .5rem; color: #bbb; font-size: 13px; }
          code { color: #7a9; }
        </style>
        <h1>artbip manifest audit — \(picked.count) random of \(works.count) works</h1>
        <div class="grid">
        \(cards)
        </div>
        """
    }

    /// Small remote image for the audit page (~640px) to keep it fast.
    static func auditImageURL(_ w: ManifestWork) -> String {
        w.image.url // manifest URLs are already sized; browsers scale down fine
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Deterministic RNG so audit samples are reproducible across runs.
public struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
