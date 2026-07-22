import Foundation

/// Pipeline configuration, read from data/curate.json. Everything tunable
/// (thresholds, prompts, canon list pages, scorer) lives here, not in code.
public struct CurateConfig: Codable, Sendable {
    public struct Display: Codable, Sendable {
        public var width: Int
        public var height: Int
    }

    public struct Gates: Codable, Sendable {
        /// Reject if long/short aspect exceeds this.
        public var maxAspectRatio: Double
        /// Tolerance factor on the fill-without-upscaling resolution rule
        /// (image passes if w >= width*f || h >= height*f).
        public var resolutionTolerance: Double
    }

    public struct Prefilter: Codable, Sendable {
        /// Work sitelinks that alone qualify a candidate.
        public var minSitelinks: Int
        /// Creator sitelinks that qualify when combined with a museum signal
        /// (highlight or on-view).
        public var minCreatorSitelinksWithMuseumSignal: Int
    }

    public struct Scorer: Codable, Sendable {
        /// "session" (Claude Code, subscription) or "openrouter".
        public var provider: String
        /// Model id for openrouter, e.g. "z-ai/glm-4.6". Ignored for session.
        public var model: String?
        /// Accept works with llm score >= this.
        public var minScore: Double
        /// Thumbnail width sent to the scorer.
        public var thumbWidth: Int
        /// The scoring prompt. {metadata} is replaced per work.
        public var prompt: String
    }

    public struct Selection: Codable, Sendable {
        public var targetCount: Int
        /// Max share of the collection a single artist may occupy (0.03 = 3%).
        public var maxArtistShare: Double
    }

    /// Wikipedia list articles mined for canon membership. slug -> page title.
    public var canonListPages: [String: String]
    public var display: Display
    public var gates: Gates
    public var prefilter: Prefilter
    public var scorer: Scorer
    public var selection: Selection
    /// Width requested when the manifest's image URL is materialized.
    public var manifestImageWidth: Int

    public static func load(from url: URL) throws -> CurateConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CurateConfig.self, from: data)
    }
}
