import Foundation
import Testing
@testable import ArtbipCore

struct CollectionTests {
    @Test func legacyPersonalStateSurvivesAndCollectionsRoundTrip() throws {
        let legacy = Data(#"{"favourites":["a"],"blocklist":["b"],"current":"a","paused":true}"#.utf8)
        var state = try JSONDecoder().decode(RuntimeState.self, from: legacy)
        #expect(state.collections.isEmpty)
        #expect(state.rotationCollectionID == nil)
        let id = try state.createCollection(name: "  Quiet mornings  ", workIDs: ["a", "c", "a"])
        state.rotationCollectionID = id
        let decoded = try JSONDecoder().decode(RuntimeState.self, from: JSONEncoder().encode(state))
        #expect(decoded.collections == [SavedCollection(id: id, name: "Quiet mornings", workIDs: ["a", "c"])])
        #expect(decoded.rotationCollectionID == id)
        #expect(decoded.favourites == ["a"])
        #expect(decoded.blocklist == ["b"])
        #expect(decoded.current == "a")
        #expect(decoded.paused)
    }

    @Test func collectionEditsValidateNamesAndPreservePersonalState() throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        var id = UUID()
        try store.updateState {
            $0.favourites = ["a"]
            id = try $0.createCollection(name: "Landscapes", workIDs: ["a"])
            $0.rotationCollectionID = id
        }
        #expect(throws: CollectionError.self) { try store.updateState { try $0.createCollection(name: " landscapes ", workIDs: []) } }
        #expect(throws: CollectionError.self) { try store.updateState { try $0.renameCollection(id, name: "  ") } }
        try store.updateState { $0.blocklist.append("b") }
        try store.updateState { try $0.setCollectionMembership(id, workID: "c", included: true) }
        try store.updateState { try $0.setCollectionMembership(id, workID: "c", included: true) }
        try store.updateState { try $0.setCollectionMembership(id, workID: "a", included: false) }
        try store.updateState { try $0.renameCollection(id, name: "Evening") }
        var state = try store.readState()
        #expect(state.collections.first?.workIDs == ["c"])
        #expect(state.collections.first?.name == "Evening")
        try store.updateState { $0.deleteCollection(id) }
        state = try store.readState()
        #expect(state.collections.isEmpty)
        #expect(state.rotationCollectionID == nil)
        #expect(state.favourites == ["a"])
        #expect(state.blocklist == ["b"])
    }

    @Test func collectionRotationRestrictsBagAndNeverFallsBackToUnrelatedWorks() throws {
        let manifest = try fixture(["a", "b", "c", "d"])
        var state = RuntimeState()
        var settings = RuntimeSettings()
        settings.favouritesOnly = true
        state.favourites = ["d"]
        let id = try state.createCollection(name: "Pair", workIDs: ["a", "b", "missing"])
        state.rotationCollectionID = id
        state.queue = ["c", "d", "b", "a"]
        state.cycleMembers = ["a", "b", "c", "d"]
        for _ in 0..<12 {
            let next = try #require(Rotator.next(manifest: manifest, state: &state, settings: settings))
            #expect(["a", "b"].contains(next.id))
        }
        state.blocklist = ["a", "b"]
        #expect(Rotator.next(manifest: manifest, state: &state, settings: settings) == nil)
        state.blocklist = []
        try state.setCollectionMembership(id, workID: "a", included: false)
        try state.setCollectionMembership(id, workID: "b", included: false)
        #expect(Rotator.eligible(manifest, state: state, settings: settings).isEmpty)
        state.rotationCollectionID = UUID()
        #expect(Rotator.eligible(manifest, state: state, settings: settings).isEmpty)
        state.rotationCollectionID = nil
        state.favourites = []
        #expect(Rotator.eligible(manifest, state: state, settings: settings).isEmpty)
    }

    @Test func hideNSFWIsOnByDefaultAndKeepsTaggedWorksOutOfRotation() throws {
        var manifest = try fixture(["a", "b", "c"])
        manifest.works[1].tags = ["nude", "nsfw"]
        var state = RuntimeState()
        var settings = RuntimeSettings()
        #expect(settings.hideNSFW)
        #expect(Set(Rotator.eligible(manifest, state: state, settings: settings).map(\.id)) == ["a", "c"])
        for _ in 0..<6 {
            #expect(try #require(Rotator.next(manifest: manifest, state: &state, settings: settings)).id != "b")
        }
        // Collections and favourites do not bring a hidden work back.
        state.rotationCollectionID = try state.createCollection(name: "Only b", workIDs: ["b"])
        #expect(Rotator.eligible(manifest, state: state, settings: settings).isEmpty)
        settings.hideNSFW = false
        #expect(Rotator.eligible(manifest, state: state, settings: settings).map(\.id) == ["b"])
        // Settings files written before the switch existed decode with it on.
        let old = try JSONDecoder().decode(RuntimeSettings.self, from: Data(#"{"favouritesOnly":true}"#.utf8))
        #expect(old.hideNSFW && old.favouritesOnly)
    }

    @Test func filtersCombineAndRespectStoredYearsWithoutInventingMissingDates() throws {
        var work = try fixture(["filter"]).works[0]
        work.artist = "Claude Monet"
        work.movement = "Impressionism"
        work.tags = ["landscape"]
        work.year = 1899
        var filters = GalleryFilter()
        filters.query = "Monet"
        filters.artist = "Claude Monet"
        filters.movement = "Impressionism"
        filters.subject = "landscape"
        filters.museum = "Test"
        filters.period = .nineteenth
        filters.notes = .with
        #expect(filters.facetCount == 6)
        #expect(filters.matches(work, hasNotes: true))
        #expect(!filters.matches(work, hasNotes: false))
        filters.period = .twentieth
        #expect(!filters.matches(work, hasNotes: true))
        work.year = 1901
        #expect(filters.matches(work, hasNotes: true))
        filters.subject = "portrait"
        #expect(!filters.matches(work, hasNotes: true))
        filters.subject = "landscape"
        work.year = nil
        #expect(!filters.matches(work, hasNotes: true))
        filters = GalleryFilter()
        #expect(!filters.isActive)
        #expect(filters.matches(work, hasNotes: false))
    }
}
