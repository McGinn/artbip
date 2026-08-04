import ArgumentParser
import ArtbipCore
import Foundation

@main
struct Artbip: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "artbip",
        abstract: "Art rotator for the macOS desktop — curation pipeline and (later) rotation daemon.",
        subcommands: [Curate.self, Compose.self, Rotate.self, Info.self, SettingsCmd.self],
        defaultSubcommand: nil
    )
}

struct PipelineOptions: ParsableArguments {
    @Option(help: "Repo root (defaults to current directory).")
    var root: String = FileManager.default.currentDirectoryPath

    var rootURL: URL { URL(fileURLWithPath: root) }
    var dataDir: URL { rootURL.appendingPathComponent("data") }
    var workDir: URL { rootURL.appendingPathComponent("work") }

    func config() throws -> CurateConfig {
        try CurateConfig.load(from: dataDir.appendingPathComponent("curate.json"))
    }

    func context() throws -> SourceContext {
        let cfg = try config()
        let http = Http(cacheDir: workDir.appendingPathComponent("cache"))
        return SourceContext(
            http: http,
            workDir: workDir.appendingPathComponent("sources"),
            config: cfg,
            log: { line in
                FileHandle.standardError.write(Data(("[\(Self.timestamp())] " + line + "\n").utf8))
            }
        )
    }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

struct Curate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build manifest.json from museum APIs, Wikidata, and Commons.",
        subcommands: [Gather.self, Join.self, Prefilter.self, ScorePrep.self,
                      ScoreOpenRouter.self, Emit.self, Audit.self, Status.self]
    )
}
