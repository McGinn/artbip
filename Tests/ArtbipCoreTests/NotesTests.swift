@testable import ArtbipCore
import Foundation
import Testing

private func paragraph(_ text: String, cite: String = "book:src:1") -> InfoParagraph {
    InfoParagraph(text: text, cite: [cite])
}

/// A notes file for `works`, sharing one artist and one symbol so shared
/// records are exercised.
private func notesInfo(_ works: [String]) -> InfoFile {
    var info = InfoFile()
    info.sources["src"] = InfoSource(title: "Source", author: "Author")
    for w in works {
        info.entries[w] = WorkInfo(context: [paragraph("Commentary \(w)")], details: [paragraph("Detail \(w)")])
        info.workSymbols[w] = ["skull"]
    }
    info.artists["Painter"] = ArtistInfo(name: "Painter", context: [paragraph("Biography")])
    info.symbols["skull"] = SymbolInfo(name: "Skull", text: "Mortality", cite: ["url:https://example.org/s"])
    return info
}

private func encode(_ notes: NotesFile) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(notes)
}

@Suite struct NotesTests {
    @Test func validFileDecodes() throws {
        let data = try encode(NotesFile(version: 3, works: ["a", "b"], info: notesInfo(["a", "b"])))
        let notes = try NotesFile.validate(data)
        #expect(notes.version == 3)
        #expect(notes.info.entries.count == 2)
    }

    @Test func oversizedWrongFormatAndMismatchedFilesAreRejected() throws {
        let huge = Data(count: NotesFile.maxBytes + 1)
        #expect(throws: NotesError.tooLarge(huge.count)) { try NotesFile.validate(huge) }
        #expect(throws: NotesError.badFormat("undecodable JSON")) { try NotesFile.validate(Data("{}".utf8)) }
        var other = NotesFile(version: 1, works: ["a"], info: notesInfo(["a"]))
        other.format = "something-else"
        #expect(throws: NotesError.badFormat("unsupported format something-else v1")) {
            try NotesFile.validate(encode(other))
        }
        // Lists a work it carries no entry for.
        let mismatch = NotesFile(version: 1, works: ["a", "b"], info: notesInfo(["a"]))
        #expect(throws: NotesError.badFormat("works and entries disagree")) { try NotesFile.validate(encode(mismatch)) }
    }

    @Test func missingRecordsAndUnsafeLinksAreRejected() throws {
        var info = InfoFile()
        info.entries["a"] = WorkInfo(context: [paragraph("x", cite: "url:javascript:alert(1)")])
        #expect(throws: NotesError.unsafeLink("url:javascript:alert(1)")) {
            try NotesFile.validate(encode(NotesFile(version: 1, works: ["a"], info: info)))
        }
        info.entries["a"] = WorkInfo(context: [paragraph("x", cite: "url:http://example.org")])
        #expect(throws: NotesError.unsafeLink("url:http://example.org")) {
            try NotesFile.validate(encode(NotesFile(version: 1, works: ["a"], info: info)))
        }
        info.entries["a"] = WorkInfo(context: [paragraph("x")])
        #expect(throws: NotesError.missingDependency("source for book:src:1")) {
            try NotesFile.validate(encode(NotesFile(version: 1, works: ["a"], info: info)))
        }
        info.sources["src"] = InfoSource(title: "S", author: "A")
        info.workSymbols["a"] = ["missing"]
        #expect(throws: NotesError.missingDependency("symbol missing")) {
            try NotesFile.validate(encode(NotesFile(version: 1, works: ["a"], info: info)))
        }
        info.workSymbols = [:]
        info.artistAliases["Painter, A."] = "Painter"
        #expect(throws: NotesError.missingDependency("artist Painter for Painter, A.")) {
            try NotesFile.validate(encode(NotesFile(version: 1, works: ["a"], info: info)))
        }
    }

    @Test func mergeKeepsTheFirstCopyOfSharedRecords() {
        var first = notesInfo(["a"])
        first.artists["Painter"]?.name = "First"
        let merged = InfoFile.merged([first, notesInfo(["b"])])
        #expect(merged.entries.count == 2)
        #expect(merged.artists["Painter"]?.name == "First")
    }

    /// The shipped notes: exactly 100 distinct works, each with commentary
    /// and details, every record resolving inside the file itself.
    @Test func shippedNotesCoverExactly100CompleteWorks() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("data/education/starter.json")
        let notes = try NotesFile.load(from: url)
        #expect(Set(notes.works).count == 100)
        #expect(notes.info.entries.count == 100)
        for work in notes.works {
            let entry = try #require(notes.info.entries[work])
            #expect(!entry.context.isEmpty && !entry.details.isEmpty)
        }
    }
}
