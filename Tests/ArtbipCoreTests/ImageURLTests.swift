import Foundation
import Testing
@testable import ArtbipCore

struct ImageURLTests {
    private func commons(_ file: String, width: Int = 8000) -> ManifestImage {
        ManifestImage(url: "https://commons.wikimedia.org/wiki/Special:FilePath/\(file)",
                      urlTemplate: "https://commons.wikimedia.org/wiki/Special:FilePath/\(file)?width={w}",
                      sourceMaxWidth: width, sourceMaxHeight: 6000)
    }

    @Test func commonsThumbSnapsToStandardWidth() {
        let image = commons("Vincent%20van%20Gogh%20-%20The%20Starry%20Night.jpg")
        #expect(image.url(width: 480)?.absoluteString == "https://upload.wikimedia.org/wikipedia/commons/thumb/8/82/"
                       + "Vincent_van_Gogh_-_The_Starry_Night.jpg/500px-Vincent_van_Gogh_-_The_Starry_Night.jpg")
        #expect(image.url(width: 1300)!.absoluteString.hasSuffix("/1920px-Vincent_van_Gogh_-_The_Starry_Night.jpg"))
        // Past Commons's largest rendition, its largest is what it serves.
        #expect(image.url(width: 5000)!.absoluteString.hasSuffix("/3840px-Vincent_van_Gogh_-_The_Starry_Night.jpg"))
    }

    @Test func commonsOriginalWhenStepIsNoSmaller() {
        let image = commons("Vincent_van_Gogh_-_The_Starry_Night.jpg", width: 1000)
        #expect(image.url(width: 980)?.absoluteString == "https://upload.wikimedia.org/wikipedia/commons/8/82/Vincent_van_Gogh_-_The_Starry_Night.jpg")
    }

    @Test func commonsTiffThumbIsJpegAndNameIsEncoded() {
        let url = commons("Caf%C3%A9_Terrace.tif").url(width: 500)!.absoluteString
        #expect(url == "https://upload.wikimedia.org/wikipedia/commons/thumb/9/9c/"
                       + "Caf%C3%A9_Terrace.tif/500px-Caf%C3%A9_Terrace.tif.jpg")
    }

    @Test func fallbackIsTheManifestTemplate() {
        let image = commons("Caf%C3%A9_Terrace.tif")
        #expect(image.fallbackURL(width: 480)?.absoluteString == "https://commons.wikimedia.org/wiki/Special:FilePath/Caf%C3%A9_Terrace.tif?width=480")
    }

    @Test func otherCommonsFormatsUseTheTemplate() {
        #expect(commons("Plan.svg").url(width: 500)?.host == "commons.wikimedia.org")
    }

    @Test func museumSmallRenditionsOnlyForThumbnails() {
        let met = ManifestImage(url: "https://images.metmuseum.org/CRDImages/ep/original/DT1567.jpg",
                                sourceMaxWidth: 4000, sourceMaxHeight: 3000)
        #expect(met.url(width: 460)?.absoluteString == "https://images.metmuseum.org/CRDImages/ep/web-large/DT1567.jpg")
        #expect(met.url(width: 1000)?.absoluteString == met.url)
        let cma = ManifestImage(url: "https://openaccess-cdn.clevelandart.org/1958.32/1958.32_print.jpg",
                                sourceMaxWidth: 4000, sourceMaxHeight: 3000)
        #expect(cma.url(width: 500)?.absoluteString == "https://openaccess-cdn.clevelandart.org/1958.32/1958.32_web.jpg")
        #expect(cma.url(width: 900)?.absoluteString == cma.url)
    }
}
