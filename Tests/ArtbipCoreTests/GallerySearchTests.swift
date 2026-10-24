import Foundation
import Testing
@testable import ArtbipCore

struct GallerySearchTests {
    @Test func tagsAndNamesCanBeCombined() throws {
        var work = try fixture(["search"]).works[0]
        work.title = "The Garden"
        work.artist = "Claude Monet"
        work.tags = ["landscape", "flowers"]
        #expect(work.matchesGallerySearch("MONET landscapes"))
        #expect(work.matchesGallerySearch("  flowers\nMonet "))
        #expect(!work.matchesGallerySearch("Monet portraits"))
        work.artist = "Paul Cézanne"
        #expect(work.matchesGallerySearch("cezanne landscape"))
        work.tags = ["still-life"]
        #expect(work.matchesGallerySearch("still life"))
        #expect(work.matchesGallerySearch("still-life"))
    }

    @Test func oldManifestsStillDecodeAndTagsRoundTrip() throws {
        let original = try fixture(["legacy"]).works[0]
        let data = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "tags")
        let legacy = try JSONDecoder().decode(ManifestWork.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.tags == nil)
        #expect(legacy.matchesGallerySearch(legacy.title))
        var tagged = legacy
        tagged.tags = ["portrait", "self-portrait"]
        let decoded = try JSONDecoder().decode(ManifestWork.self, from: JSONEncoder().encode(tagged))
        #expect(decoded.tags == tagged.tags)
    }
}
