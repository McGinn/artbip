import Foundation
import Testing
@testable import ArtbipCore

/// The editorial source is private (artbip-private, checked out as
/// ../marketing); without it this test is skipped.
private let infoURL: URL = {
    if let env = ProcessInfo.processInfo.environment["ARTBIP_CONTENT_DIR"], !env.isEmpty {
        return URL(fileURLWithPath: env).appendingPathComponent("info.json")
    }
    return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("marketing/content/info.json")
}()

struct CatalogueDecodeTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath: infoURL.path),
                   "private editorial source not checked out"))
    func shippingCommentaryDecodesWithoutSilentFallback() throws {
        let data = try Data(contentsOf: infoURL)
        let raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let expected = raw["entries"] as! [String: Any]
        let decoded = try JSONDecoder().decode(InfoFile.self, from: data)
        #expect(decoded.entries.count == expected.count)
        #expect(!decoded.entries.isEmpty)
        #expect(decoded.entries["wikidata-Q3630741"]?.details.isEmpty == false)
    }
}
