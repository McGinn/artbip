import AppKit
import ArtbipCore
import Foundation

/// Deep links into the project's GitHub issue templates.
///
/// GitHub Issues rather than a mailto: or a form, because it needs no server —
/// this app deliberately has no backend to phone home to — while still being
/// public, searchable, and threaded, so duplicate reports resolve themselves.
/// Nothing is sent from here: the app only opens a URL, and the user sees and
/// submits the report themselves.
enum Feedback {
    static let repo = "https://github.com/McGinn/artbip"

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
    }

    /// The templates are issue forms, which GitHub pre-fills by field `id`
    /// (`work`, `detail`, … in .github/ISSUE_TEMPLATE) — a `body` parameter
    /// is ignored for forms.
    private static func url(template: String, title: String, fields: [String: String]) -> URL? {
        var c = URLComponents(string: "\(repo)/issues/new")
        c?.queryItems = [
            URLQueryItem(name: "template", value: template),
            URLQueryItem(name: "title", value: title),
        ] + fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c?.url
    }

    private static func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Everything a report needs that the user should not have to look up.
    private static func context(_ work: ManifestWork) -> String {
        var lines = [
            "Work id: \(work.id)",
            "Title: \(work.title)",
            "Artist: \(work.artist)",
            "Collection: \(work.collection)",
            "Source: \(work.collectionURL)",
        ]
        if let wd = work.wikidata { lines.append("Wikidata: \(wd)") }
        lines.append("artbip \(version) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        return lines.joined(separator: "\n")
    }

    static func reportArtwork(_ work: ManifestWork) {
        open(url(template: "bad-artwork.yml",
                 title: "[artwork] \(work.id) — \(work.title)",
                 fields: ["work": work.id, "detail": context(work) + "\n\nWhat is wrong:\n"]))
    }

    static func reportInfoText(_ work: ManifestWork) {
        open(url(template: "bad-info.yml",
                 title: "[info] \(work.id) — \(work.title)",
                 fields: ["work": work.id, "detail": context(work) + "\n\nWhat is wrong:\n"]))
    }

    static func requestFeature() {
        open(url(template: "feature-request.yml", title: "",
                 fields: ["version": version]))
    }

    #if !ARTBIP_APP_STORE
    // Direct build only: the Mac App Store build has no external payment
    // links and updates only through the App Store.
    static func sponsor() {
        open(URL(string: "https://github.com/sponsors/McGinn"))
    }

    static func openLatestRelease() {
        open(UpdateCheck.releasesPage)
    }
    #endif

    #if ARTBIP_APP_STORE
    /// Set once App Store Connect assigns the app its numeric Apple ID; until
    /// then the "Rate artbip" items stay hidden rather than open a dead page.
    static let appStoreID: String? = "6828039900"

    static var writeReviewURL: URL? { ReviewPrompt.writeReviewURL(appStoreID: appStoreID) }

    static func rateOnAppStore() {
        open(writeReviewURL)
    }
    #endif

    static func browseIssues() {
        open(URL(string: "\(repo)/issues"))
    }
}
