import Foundation
import Testing
@testable import ArtbipCore

struct ReviewPromptTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var weekAgo: Date { now.addingTimeInterval(-7 * 86_400) }

    @Test func dueAfterAWeekWithEnoughFavourites() {
        #expect(ReviewPrompt.isDue(favourites: 3, firstUse: weekAgo, now: now,
                                   lastAskedVersion: nil, currentVersion: "0.1.0", hasError: false))
    }

    @Test func notDueTooSoonTooFewOrAfterAnError() {
        #expect(!ReviewPrompt.isDue(favourites: 3, firstUse: now.addingTimeInterval(-6 * 86_400), now: now,
                                    lastAskedVersion: nil, currentVersion: "0.1.0", hasError: false))
        #expect(!ReviewPrompt.isDue(favourites: 2, firstUse: weekAgo, now: now,
                                    lastAskedVersion: nil, currentVersion: "0.1.0", hasError: false))
        #expect(!ReviewPrompt.isDue(favourites: 3, firstUse: weekAgo, now: now,
                                    lastAskedVersion: nil, currentVersion: "0.1.0", hasError: true))
    }

    @Test func oncePerVersion() {
        #expect(!ReviewPrompt.isDue(favourites: 5, firstUse: weekAgo, now: now,
                                    lastAskedVersion: "0.1.0", currentVersion: "0.1.0", hasError: false))
        #expect(ReviewPrompt.isDue(favourites: 5, firstUse: weekAgo, now: now,
                                   lastAskedVersion: "0.1.0", currentVersion: "0.1.1", hasError: false))
    }

    @Test func writeReviewURLNeedsANumericID() {
        #expect(ReviewPrompt.writeReviewURL(appStoreID: nil) == nil)
        #expect(ReviewPrompt.writeReviewURL(appStoreID: "") == nil)
        #expect(ReviewPrompt.writeReviewURL(appStoreID: "id123") == nil)
        #expect(ReviewPrompt.writeReviewURL(appStoreID: "1234567890")?.absoluteString
                == "macappstore://apps.apple.com/app/id1234567890?action=write-review")
    }
}
