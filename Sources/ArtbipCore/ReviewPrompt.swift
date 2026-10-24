import Foundation

/// When the Mac App Store build may ask for a rating.
///
/// The ask itself is always Apple's own prompt (App Review 5.6.1 disallows
/// custom ones), and macOS decides whether it actually appears, at most three
/// times a year. This only decides when it is worth offering: someone who has
/// used artbip for a week and kept a few works is likely enjoying it, while a
/// new user or one who just hit an error is not.
public enum ReviewPrompt {
    public static let minimumFavourites = 3
    public static let minimumDaysOfUse = 7

    /// - Parameters:
    ///   - favourites: how many works the user has favourited now.
    ///   - firstUse: when this installation first ran.
    ///   - lastAskedVersion: the app version that last offered the prompt.
    ///   - hasError: whether the app is currently showing an error.
    public static func isDue(favourites: Int, firstUse: Date, now: Date = Date(),
                             lastAskedVersion: String?, currentVersion: String,
                             hasError: Bool) -> Bool {
        guard !hasError, favourites >= minimumFavourites else { return false }
        guard now.timeIntervalSince(firstUse) >= Double(minimumDaysOfUse) * 86_400 else { return false }
        // Once per version, so a user who dismissed it is not asked again
        // until there is something new to rate.
        return lastAskedVersion != currentVersion
    }

    /// The App Store page's write-review link, or nil until the app has an
    /// App Store Connect ID.
    public static func writeReviewURL(appStoreID: String?) -> URL? {
        guard let id = appStoreID, !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        return URL(string: "macappstore://apps.apple.com/app/id\(id)?action=write-review")
    }
}
