import Foundation
import CryptoKit

public struct HttpError: Error, CustomStringConvertible {
    public let status: Int
    public let url: String
    public let bodyPrefix: String
    public var description: String { "HTTP \(status) for \(url): \(bodyPrefix)" }
}

/// Shared HTTP client for the curation pipeline.
///
/// - Per-host request pacing (museum APIs get generous limits, Wikidata gets
///   conservative ones — see `defaultIntervals`).
/// - Descriptive User-Agent on every request (Wikimedia 403s without one;
///   ARTIC's IIIF host sits behind Cloudflare and wants a browser-ish UA plus
///   their courtesy AIC-User-Agent header — the ARTIC plugin adds that).
/// - Retries with exponential backoff on 429/5xx/Cloudflare challenges.
/// - Disk cache keyed by SHA-256 of method+URL+body, so re-running the
///   pipeline does not re-hit any API.
public actor Http {
    private let cacheDir: URL
    private let userAgent: String
    private let session: URLSession
    private var lastRequest: [String: Date] = [:]
    private var intervals: [String: TimeInterval]

    /// Seconds between requests, per host. Unlisted hosts get `defaultInterval`.
    public static let defaultIntervals: [String: TimeInterval] = [
        "api.artic.edu": 1.1,                    // 60 req/min anonymous limit
        "www.artic.edu": 1.2,                    // image scraping guidance: 1/sec
        // The Met docs permit 80 req/s but the Imperva CDN in front of both
        // hosts bot-blocks far lower rates in practice — stay gentle.
        "collectionapi.metmuseum.org": 0.75,
        "images.metmuseum.org": 0.75,
        "openaccess-api.clevelandart.org": 0.5,
        "openaccess-cdn.clevelandart.org": 0.5,
        "api.nga.gov": 0.5,
        "data.rijksmuseum.nl": 0.4,
        "id.rijksmuseum.nl": 0.4,
        "iiif.micr.io": 0.5,
        "query.wikidata.org": 3.0,               // 60s query budget/min; errors → temp ban
        "www.wikidata.org": 0.3,
        "commons.wikimedia.org": 0.3,
        "en.wikipedia.org": 0.3,
        "upload.wikimedia.org": 0.4,
        "raw.githubusercontent.com": 0.2,
        "media.githubusercontent.com": 0.2,
    ]
    public static let defaultInterval: TimeInterval = 0.5

    /// Contact string sent with polite API requests (museum and Wikimedia
    /// etiquette asks clients to identify themselves).
    public static let contact = "https://github.com/mcginn/artbip"

    /// Default request headers applied per host, before any caller-supplied
    /// headers (which win on conflict). Hosts behind Cloudflare/Imperva reject
    /// bare non-browser requests; these unblock direct image fetches from stages
    /// (score-prep, runtime) that don't go through a source plugin.
    public static let hostHeaders: [String: [String: String]] = [
        // ARTIC's IIIF host filters on UA/headers (not a JS challenge): a
        // browser UA plus their courtesy AIC-User-Agent, Accept and Referer
        // return 200 where a bare request 403s.
        "www.artic.edu": [
            "User-Agent": browserUA,
            "AIC-User-Agent": "artbip/0.1 (\(contact))",
            "Accept": "image/avif,image/webp,image/png,image/jpeg,*/*",
            "Referer": "https://www.artic.edu/",
        ],
        // Imperva in front of the Met hosts blocks obvious non-browser UAs.
        "images.metmuseum.org": [
            "User-Agent": browserUA,
            "Accept": "image/avif,image/webp,image/png,image/jpeg,*/*",
        ],
        "collectionapi.metmuseum.org": [
            "User-Agent": browserUA,
            "Accept": "application/json",
        ],
    ]

    private static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    public init(cacheDir: URL, userAgent: String = "artbip/0.1 (\(Http.contact)) curation-pipeline") {
        self.cacheDir = cacheDir
        self.userAgent = userAgent
        self.intervals = Http.defaultIntervals
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 1800
        cfg.httpAdditionalHeaders = [:]
        self.session = URLSession(configuration: cfg)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    public func get(_ url: URL, headers: [String: String] = [:], cache: Bool = true) async throws -> Data {
        try await request("GET", url, body: nil, headers: headers, cache: cache)
    }

    public func post(_ url: URL, body: Data, headers: [String: String] = [:], cache: Bool = true) async throws -> Data {
        try await request("POST", url, body: body, headers: headers, cache: cache)
    }

    public func getJSON<T: Decodable>(_ type: T.Type, _ url: URL, headers: [String: String] = [:], cache: Bool = true) async throws -> T {
        let data = try await get(url, headers: headers, cache: cache)
        return try JSONDecoder().decode(type, from: data)
    }

    private func request(_ method: String, _ url: URL, body: Data?, headers: [String: String], cache: Bool) async throws -> Data {
        let key = cacheKey(method: method, url: url, body: body, range: headers["Range"])
        let cacheFile = cacheDir.appendingPathComponent(key)
        if cache, let data = try? Data(contentsOf: cacheFile) {
            return data
        }

        var attempt = 0
        while true {
            attempt += 1
            await pace(host: url.host ?? "")
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.httpBody = body
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if let hostDefaults = Http.hostHeaders[url.host ?? ""] {
                for (k, v) in hostDefaults { req.setValue(v, forHTTPHeaderField: k) }
            }
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

            do {
                let (data, resp) = try await session.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if status >= 200 && status < 300 {
                    if cache { try? data.write(to: cacheFile, options: .atomic) }
                    return data
                }
                let retryable = status == 429 || status >= 500 ||
                    (status == 403 && isCloudflareChallenge(resp, data))
                if retryable && attempt < 5 {
                    let backoff = pow(2.0, Double(attempt)) + Double.random(in: 0...1)
                    try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    continue
                }
                let prefix = String(data: data.prefix(300), encoding: .utf8) ?? ""
                throw HttpError(status: status, url: url.absoluteString, bodyPrefix: prefix)
            } catch let e as HttpError {
                throw e
            } catch {
                if attempt < 5 {
                    let backoff = pow(2.0, Double(attempt))
                    try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    continue
                }
                throw error
            }
        }
    }

    private func isCloudflareChallenge(_ resp: URLResponse?, _ data: Data) -> Bool {
        guard let http = resp as? HTTPURLResponse else { return false }
        if http.value(forHTTPHeaderField: "cf-mitigated") != nil { return true }
        let prefix = String(data: data.prefix(200), encoding: .utf8)?.lowercased() ?? ""
        return prefix.contains("just a moment") || prefix.contains("cloudflare")
    }

    private func pace(host: String) async {
        let interval = intervals[host] ?? Http.defaultInterval
        if let last = lastRequest[host] {
            let wait = interval - Date().timeIntervalSince(last)
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        lastRequest[host] = Date()
    }

    private func cacheKey(method: String, url: URL, body: Data?, range: String? = nil) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(method.utf8))
        hasher.update(data: Data(url.absoluteString.utf8))
        if let body { hasher.update(data: body) }
        // A Range request returns a partial body; it must not share a cache key
        // with the full response for the same URL (otherwise a dimension-probe
        // fetch of the first 128 KiB poisons the full-image cache).
        if let range { hasher.update(data: Data("range:\(range)".utf8)) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
