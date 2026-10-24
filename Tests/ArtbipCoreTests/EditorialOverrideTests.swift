import Foundation
import Testing
@testable import ArtbipCore

struct EditorialOverrideTests {
    @Test func incorrectCanonMembershipSurvivesNeitherCorrectionNorRebuild() throws {
        var candidate = Candidate(source: "wikidata", sourceId: "Q3234845", title: "Models",
                                  imageURLTemplate: "https://example.org/image.jpg",
                                  collectionName: "Barnes Foundation", collectionURL: "https://example.org/record")
        candidate.signals.canonLists = ["most-expensive"]
        let config = CurateConfig(canonListPages: [:], display: .init(width: 3840, height: 2160),
                                  gates: .init(maxAspectRatio: 3, resolutionTolerance: 1),
                                  prefilter: .init(minSitelinks: 1, minCreatorSitelinksWithMuseumSignal: 1),
                                  scorer: .init(minScore: 1, thumbWidth: 512, prompt: ""),
                                  selection: .init(targetCount: 1, maxArtistShare: 1), manifestImageWidth: 3840)
        let joined = JoinedWork(primary: candidate)
        let correction = try JSONDecoder().decode(Override.self, from: Data(#"{"canonLists":[]}"#.utf8))
        let corrected = Pipeline.manifestWork(from: joined, score: nil, override: correction, config: config)
        #expect(corrected.significance.canonLists.isEmpty)
        let unchanged = Pipeline.manifestWork(from: joined, score: nil, override: Override(), config: config)
        #expect(unchanged.significance.canonLists == ["most-expensive"])
    }

    @Test func correctedAttributionSurvivesManifestGeneration() throws {
        let candidate = Candidate(source: "wikidata", sourceId: "Q4429116", title: "The Magpie",
                                  artist: "Pablo Picasso", artistSort: "Picasso, Pablo", artistDeathYear: 1973,
                                  yearStart: 1868, dateDisplay: "1868", imageURLTemplate: "https://example.org/image.jpg",
                                  collectionName: "Museum", collectionURL: "https://example.org/record")
        let correction = try JSONDecoder().decode(Override.self, from: Data(#"{"artist":"Claude Monet","artistDeathYear":1926,"year":1868,"dateDisplay":"1868–1869","collection":"Mauritshuis","collectionURL":"https://example.org/museum","tags":["landscape"]}"#.utf8))
        let config = CurateConfig(canonListPages: [:], display: .init(width: 3840, height: 2160),
                                  gates: .init(maxAspectRatio: 3, resolutionTolerance: 1),
                                  prefilter: .init(minSitelinks: 1, minCreatorSitelinksWithMuseumSignal: 1),
                                  scorer: .init(minScore: 1, thumbWidth: 512, prompt: ""),
                                  selection: .init(targetCount: 1, maxArtistShare: 1), manifestImageWidth: 3840)
        let work = Pipeline.manifestWork(from: JoinedWork(primary: candidate), score: nil, override: correction, config: config)
        #expect(work.artist == "Claude Monet")
        #expect(work.artistSort == "Monet, Claude")
        #expect(work.artistDeathYear == 1926)
        #expect(work.dateDisplay == "1868–1869")
        #expect(work.collection == "Mauritshuis")
        #expect(work.collectionURL == "https://example.org/museum")
        #expect(work.tags == ["landscape"])
        // The attribution's source and the image-rights evidence are distinct.
        #expect(work.license.sourceURL == candidate.collectionURL)
    }
}
