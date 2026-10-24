import ArtbipCore
import Foundation
import OSLog

/// Notes on works, artists and styles, bundled with the app. Nothing here
/// touches rotation — wallpapers, scheduling, favourites and every other
/// feature work the same whether or not a work has notes.
@MainActor
final class NotesModel: ObservableObject {
    @Published private(set) var info = InfoFile()

    init(store: RuntimeStore) {
        var info = Self.loadBundled()?.info ?? InfoFile()
        // Development only: ARTBIP_DEV_EDUCATION=<path or empty> merges the
        // full private editorial file, so unreleased notes can be read in
        // context. Release builds never set it.
        if let explicit = ProcessInfo.processInfo.environment["ARTBIP_DEV_EDUCATION"],
           let dev = store.loadDevelopmentInfo(explicit: explicit.isEmpty ? nil : explicit) {
            info = InfoFile.merged([info, dev])
        }
        self.info = info
    }

    /// The notes ship inside the app bundle (Resources/notes.json). A
    /// `swift run` from a checkout reads the same file from data/education.
    static func loadBundled() -> NotesFile? {
        let candidates = [Bundle.main.url(forResource: "notes", withExtension: "json"),
                          URL(fileURLWithPath: "data/education/starter.json")]
        for case let url? in candidates where FileManager.default.fileExists(atPath: url.path) {
            do { return try NotesFile.load(from: url) } catch {
                Logger(subsystem: "com.mcginn.artbip", category: "notes")
                    .error("Notes at \(url.path, privacy: .public) unreadable: \(error.localizedDescription, privacy: .public)")
            }
        }
        return nil
    }

    /// A work's own notes, if it has any.
    func entry(for workID: String) -> WorkInfo? { info.entries[workID] }
}
