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
        let dates: String
        switch (work.artistBirthYear, work.artistDeathYear) {
        case let (birth?, death?): dates = " (\(birth)–\(death))"
        case let (birth?, nil):    dates = " (b. \(birth))"
        case let (nil, death?):    dates = " (d. \(death))"
        default:                   dates = ""
        }
        print(work.title)
        print([work.artist + dates, work.dateDisplay, work.medium,
               work.dimensions?.display].compactMap(\.self).joined(separator: " · "))
        print("\(work.collection) — \(work.collectionURL)")
        if let caption = work.caption { print("\n\(caption)") }

        var citeOrder: [String] = []
        func mark(_ cites: [String]) -> String {
            let refs = cites.map { cite -> Int in
                if let i = citeOrder.firstIndex(of: cite) { return i + 1 }
                citeOrder.append(cite)
                return citeOrder.count
            }
            return "[" + refs.map(String.init).joined(separator: ",") + "]"
        }

        // Per-work text is the rarest tier (12 of 2,000), so its absence must
        // not skip the artist and school sections below — an early return here
        // left 954 works printing nothing but their titleplate.
        if let entry = infoFile.entries[work.id] {
            for para in entry.context {
                print("\n\(para.text) \(mark(para.cite))")
            }
            if !entry.details.isEmpty {
                print("\nLook for:")
                for para in entry.details {
                    print("• \(para.text) \(mark(para.cite))")
                }
            }
        }

        let symbols = infoFile.symbols(forWorkId: work.id)
        if !symbols.isEmpty {
            print("\nSymbols")
            for s in symbols {
                print("\n\(s.name): \(s.text) \(mark(s.cite))")
            }
        }

        func section(_ title: String, _ subtitle: String?, _ paras: [InfoParagraph]) {
            guard !paras.isEmpty else { return }
            print("\n\(title)\(subtitle.map { " — \($0)" } ?? "")")
            for para in paras { print("\n\(para.text) \(mark(para.cite))") }
        }
        if let artist = infoFile.artist(forSort: work.artistSort) {
            section(artist.name, artist.subtitle, artist.context)
        }
        if let school = infoFile.school(forMovement: work.movement) {
            section(school.name, school.subtitle, school.context)
        }

        if !citeOrder.isEmpty {
            print("\nSources:")
            for (i, cite) in citeOrder.enumerated() {
                print("  [\(i + 1)] \(infoFile.label(forCite: cite))")
            }
        }
    }
}
