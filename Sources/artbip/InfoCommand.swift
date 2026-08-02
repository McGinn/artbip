import ArgumentParser
import ArtbipCore
import Foundation

struct Info: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "About a work: titleplate, context, and details, with sources.")
    @OptionGroup var opts: RuntimeOptions
    @Option(help: "Work id (default: the work currently on the desktop).")
    var id: String?
    @Option(help: "Info path (default: ./data/info.json, then the app-support copy).")
    var info: String?

    func run() async throws {
        let store = try opts.store()
        let manifest = try store.loadManifest(explicit: opts.manifest)
        let infoFile = store.loadInfo(explicit: info)

        let workId: String
        if let id {
            workId = id
        } else if let current = store.loadState().current {
            workId = current
        } else {
            print("nothing shown yet — run `artbip rotate next` or pass --id")
            return
        }
        guard let work = manifest.works.first(where: { $0.id == workId }) else {
            throw ValidationError("\(workId) is not in the manifest")
        }

        // Titleplate — always available, straight from the manifest.
        var artistLine = work.artist
        if let death = work.artistDeathYear { artistLine += " (d. \(death))" }
        print(work.title)
        print([artistLine, work.dateDisplay, work.medium].compactMap(\.self).joined(separator: " · "))
        print("\(work.collection) — \(work.collectionURL)")
        if let caption = work.caption { print("\n\(caption)") }

        guard let entry = infoFile.entries[work.id] else { return }
        var citeOrder: [String] = []
        func mark(_ cites: [String]) -> String {
            let refs = cites.map { cite -> Int in
                if let i = citeOrder.firstIndex(of: cite) { return i + 1 }
                citeOrder.append(cite)
                return citeOrder.count
            }
            return "[" + refs.map(String.init).joined(separator: ",") + "]"
        }
        for para in entry.context {
            print("\n\(para.text) \(mark(para.cite))")
        }
        if !entry.details.isEmpty {
            print("\nLook for:")
            for para in entry.details {
                print("• \(para.text) \(mark(para.cite))")
            }
        }
        if !citeOrder.isEmpty {
            print("\nSources:")
            for (i, cite) in citeOrder.enumerated() {
                print("  [\(i + 1)] \(infoFile.label(forCite: cite))")
            }
        }
    }
}
