import Foundation

extension ManifestWork {
    /// The subject tag that the `hideNSFW` setting filters on.
    public static let nsfwTag = "nsfw"

    public var isNSFW: Bool { tags?.contains(Self.nsfwTag) ?? false }

    /// Every query word may match a different field (e.g. “Monet landscape”).
    /// Folding makes names searchable without accents; subject aliases accept
    /// common singular/plural spellings without stemming artists' names.
    public func matchesGallerySearch(_ query: String) -> Bool {
        func fold(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                         locale: Locale(identifier: "en_US_POSIX"))
                .replacingOccurrences(of: "-", with: " ")
        }
        let aliases = ["portraits": "portrait", "landscapes": "landscape",
                       "seascapes": "seascape", "cityscapes": "cityscape",
                       "flowers": "flower", "animals": "animal", "nudes": "nude",
                       "interiors": "interior", "still-life": "still life",
                       "religion": "religious"]
        let fields = [title, artist, movement ?? "", region ?? "", collection] + (tags ?? [])
        let haystack = fold(fields.joined(separator: " "))
        return fold(query).split(whereSeparator: { $0.isWhitespace }).allSatisfy { word in
            haystack.contains(aliases[String(word)] ?? String(word))
        }
    }
}
