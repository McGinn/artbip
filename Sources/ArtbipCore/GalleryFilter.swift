import Foundation

public enum GalleryPeriod: String, CaseIterable, Sendable {
    case all, before1500, sixteenth, seventeenth, eighteenth, nineteenth, twentieth

    public var title: String {
        switch self {
        case .all: return "Any period"
        case .before1500: return "Before 1500"
        case .sixteenth: return "1500–1599"
        case .seventeenth: return "1600–1699"
        case .eighteenth: return "1700–1799"
        case .nineteenth: return "1800–1899"
        case .twentieth: return "1900 onwards"
        }
    }

    func matches(_ work: ManifestWork) -> Bool {
        guard self != .all else { return true }
        guard let year = work.year else { return false }
        let range: ClosedRange<Int>
        switch self {
        case .all: return true
        case .before1500: range = Int.min...1499
        case .sixteenth: range = 1500...1599
        case .seventeenth: range = 1600...1699
        case .eighteenth: range = 1700...1799
        case .nineteenth: range = 1800...1899
        case .twentieth: range = 1900...Int.max
        }
        return range.contains(year)
    }
}

/// Filter on whether a work has its own notes.
public enum GalleryNotes: String, CaseIterable, Sendable {
    case all, with, without
    public var title: String {
        switch self {
        case .all: return "Any"
        case .with: return "With notes"
        case .without: return "Without notes"
        }
    }
}

/// Filters combine with search and the selected library/collection.
public struct GalleryFilter: Equatable, Sendable {
    public var query = ""
    public var artist = ""
    public var movement = ""
    public var subject = ""
    public var museum = ""
    public var period = GalleryPeriod.all
    public var notes = GalleryNotes.all

    public init() {}
    public var facetCount: Int {
        [!artist.isEmpty, !movement.isEmpty, !subject.isEmpty, !museum.isEmpty,
         period != .all, notes != .all].filter { $0 }.count
    }
    public var isActive: Bool { !query.isEmpty || facetCount > 0 }

    public func matches(_ work: ManifestWork, hasNotes: Bool) -> Bool {
        work.matchesGallerySearch(query)
            && (artist.isEmpty || work.artist == artist)
            && (movement.isEmpty || work.movement == movement)
            && (subject.isEmpty || (work.tags ?? []).contains(subject))
            && (museum.isEmpty || work.collection == museum)
            && period.matches(work)
            && (notes == .all || (notes == .with ? hasNotes : !hasNotes))
    }
}
