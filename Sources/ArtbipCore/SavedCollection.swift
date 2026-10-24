import Foundation

/// A personal selection of works, independent of downloaded image files.
public struct SavedCollection: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var workIDs: [String]

    public init(id: UUID = UUID(), name: String, workIDs: [String] = []) {
        self.id = id
        self.name = name
        var seen = Set<String>()
        self.workIDs = workIDs.filter { seen.insert($0).inserted }
    }
}

public enum CollectionError: LocalizedError {
    case emptyName, duplicateName, missingCollection
    public var errorDescription: String? {
        switch self {
        case .emptyName: return "Give the collection a name."
        case .duplicateName: return "A collection with that name already exists. Choose another name."
        case .missingCollection: return "This collection no longer exists."
        }
    }
}

extension RuntimeState {
    private func validatedCollectionName(_ name: String, excluding id: UUID? = nil) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CollectionError.emptyName }
        guard !collections.contains(where: {
            $0.id != id && $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else { throw CollectionError.duplicateName }
        return trimmed
    }

    @discardableResult
    public mutating func createCollection(name: String, workIDs: [String]) throws -> UUID {
        let collection = SavedCollection(name: try validatedCollectionName(name), workIDs: workIDs)
        collections.append(collection)
        return collection.id
    }

    public mutating func renameCollection(_ id: UUID, name: String) throws {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { throw CollectionError.missingCollection }
        collections[index].name = try validatedCollectionName(name, excluding: id)
    }

    public mutating func setCollectionMembership(_ id: UUID, workID: String, included: Bool) throws {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { throw CollectionError.missingCollection }
        collections[index].workIDs.removeAll { $0 == workID }
        if included { collections[index].workIDs.append(workID) }
    }

    public mutating func deleteCollection(_ id: UUID) {
        collections.removeAll { $0.id == id }
        if rotationCollectionID == id { rotationCollectionID = nil }
    }
}
