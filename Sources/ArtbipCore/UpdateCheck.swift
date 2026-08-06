import Foundation

/// A dotted release version, compared numerically rather than as a string.
///
/// String comparison gets this wrong exactly when it starts to matter: "0.1.9"
/// sorts after "0.1.10", so the first two-digit patch release would look like a
/// downgrade and never be offered.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let components: [Int]

    /// Parses "0.1.15", "v0.1.15" and "0.1.15-beta.2" alike; anything after the
    /// first non-numeric component is ignored, so a pre-release tag compares as
    /// its base version rather than failing to parse.
    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
            .drop(while: { $0 == "v" || $0 == "V" })
        var parts: [Int] = []
        for piece in trimmed.split(separator: ".") {
            let digits = piece.prefix(while: \.isNumber)
            guard !digits.isEmpty, let n = Int(digits) else { break }
            parts.append(n)
            if digits.count != piece.count { break }   // "15-beta" ends the run
        }
        guard !parts.isEmpty else { return nil }
        components = parts
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.components.count, b.components.count) {
            // A missing component is zero: 0.1 and 0.1.0 are the same release.
            let l = i < a.components.count ? a.components[i] : 0
            let r = i < b.components.count ? b.components[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    public var description: String { components.map(String.init).joined(separator: ".") }
}

/// The newest published release, as GitHub reports it.
public struct ReleaseInfo: Sendable {
    public let version: AppVersion
    public let tag: String
    public let url: URL
}

/// Asks GitHub whether a newer release exists.
///
/// artbip has no backend, and this does not add one: the request goes to the
/// same GitHub that already hosts the downloads, carries nothing about the
/// user or their machine beyond what any HTTP request reveals, and reports no
/// usage. It is still a network call to a non-museum host, so it is disclosed
/// in Settings and can be switched off there.
public enum UpdateCheck {
    public static let releasesAPI =
        URL(string: "https://api.github.com/repos/McGinn/artbip/releases/latest")!
    public static let releasesPage =
        URL(string: "https://github.com/McGinn/artbip/releases/latest")!

    /// Don't ask more than once a day; a wallpaper app has no business polling.
    public static let minimumInterval: TimeInterval = 24 * 60 * 60

    public enum Result: Sendable, Equatable {
        case upToDate(current: String)
        case updateAvailable(version: String, url: URL)

        public var newVersion: String? {
            if case .updateAvailable(let v, _) = self { return v }
            return nil
        }
    }

    /// Fetch the latest release. Throws on network or decoding failure so the
    /// caller can distinguish "no update" from "could not tell".
    public static func fetchLatest(
        session: URLSession = .shared, api: URL = releasesAPI
    ) async throws -> ReleaseInfo {
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("artbip (\(Http.contact))", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HttpError(status: http.statusCode, url: api.absoluteString,
                            bodyPrefix: String(decoding: data.prefix(200), as: UTF8.self))
        }
        struct Payload: Decodable {
            let tag_name: String
            let html_url: String
            let draft: Bool?
            let prerelease: Bool?
        }
        let p = try JSONDecoder().decode(Payload.self, from: data)
        guard p.draft != true, p.prerelease != true else {
            throw UpdateError.noStableRelease
        }
        guard let version = AppVersion(p.tag_name) else {
            throw UpdateError.unparsableTag(p.tag_name)
        }
        return ReleaseInfo(version: version, tag: p.tag_name,
                           url: URL(string: p.html_url) ?? releasesPage)
    }

    /// Compare a fetched release against the running build.
    public static func compare(current: String, against latest: ReleaseInfo) -> Result {
        guard let mine = AppVersion(current) else {
            // An unparsable local version ("dev") means a build from source;
            // claiming it is out of date would be noise.
            return .upToDate(current: current)
        }
        return latest.version > mine
            ? .updateAvailable(version: latest.version.description, url: latest.url)
            : .upToDate(current: current)
    }

    public enum UpdateError: Error, CustomStringConvertible {
        case noStableRelease
        case unparsableTag(String)

        public var description: String {
            switch self {
            case .noStableRelease: return "latest release is a draft or pre-release"
            case .unparsableTag(let t): return "could not read a version from tag \(t)"
            }
        }
    }
}
