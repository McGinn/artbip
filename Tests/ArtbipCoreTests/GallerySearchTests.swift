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

struct GallerySearchIndexTests {
    func works() throws -> [ManifestWork] {
        var a = try fixture(["search"]).works[0]
        a.id = "a"; a.title = "Mona Lisa"; a.artist = "Leonardo da Vinci"; a.tags = ["portrait"]
        a.caption = "A woman sits before a winding landscape."
        var b = a
        b.id = "b"; b.title = "The Night Watch"; b.artist = "Rembrandt van Rijn"; b.tags = []
        b.caption = "A militia company steps out, a small dog barking at the drummer."
        var c = a
        c.id = "c"; c.title = "Olympia"; c.artist = "Édouard Manet"; c.caption = "A cat arches its back."
        var d = a
        d.id = "d"; d.title = "Water Lilies"; d.artist = "Claude Monet"; d.caption = "Lilies float on the pond."
        return [a, b, c, d]
    }

    @Test func namesMayRunTogetherOrBeMisspelt() throws {
        let works = try works()
        let search = GallerySearch(works: works)
        #expect(search.rank(works[0], "davinci") == 0)
        #expect(search.rank(works[0], "Da Vinci") == 0)
        #expect(search.rank(works[1], "rembrant") == 0)
        #expect(search.rank(works[1], "rembradnt") == 0)
        // A real name is never widened to its neighbours.
        #expect(search.rank(works[3], "monet") == 0)
        #expect(search.rank(works[2], "monet") == nil)
    }

    @Test func captionsAndNotesFindWhatIsInThePainting() throws {
        let works = try works()
        var notes = InfoFile()
        notes.entries["c"] = WorkInfo(context: [InfoParagraph(text: "Her black servant holds a bouquet.", cite: [])],
                                      details: [])
        let search = GallerySearch(works: works, notes: notes)
        #expect(search.rank(works[1], "dog") == 1)
        #expect(search.rank(works[1], "dogs") == 1)
        #expect(search.rank(works[1], "rembrandt dog") == 1)
        #expect(search.rank(works[2], "bouquet") == 1)
        // Prose matches whole words or their beginnings only.
        #expect(search.rank(works[2], "arch") == 1)
        #expect(search.rank(works[2], "rches") == nil)
        var filter = GalleryFilter()
        filter.query = "lilies"
        #expect(filter.apply(works, search: search, hasNotes: { _ in false }).map(\.id) == ["d"])
        filter.query = "a"
        #expect(filter.apply(works, search: search, hasNotes: { _ in false }).first?.id == "a")
    }
}
