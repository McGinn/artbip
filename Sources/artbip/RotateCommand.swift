import ArgumentParser
import ArtbipCore
import Foundation

struct RuntimeOptions: ParsableArguments {
    @Option(help: "Manifest path (default: ./data/manifest.json, then the app-support copy).")
    var manifest: String?
    @Option(help: "Runtime directory (default ~/Library/Application Support/artbip).")
    var dir: String?

    func store() throws -> RuntimeStore {
        try RuntimeStore(dir: dir.map { URL(fileURLWithPath: $0) })
    }
}

let rotateLog: @Sendable (String) -> Void = { line in
    FileHandle.standardError.write(Data("[rotate] \(line)\n".utf8))
}

func advance(_ opts: RuntimeOptions) async throws -> ManifestWork {
    let store = try opts.store()
    let manifest = try store.loadManifest(explicit: opts.manifest)
    return try await WallpaperEngine.advance(store: store, manifest: manifest, log: rotateLog)
}

struct Rotate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Rotate the desktop wallpaper through the curated collection.",
        subcommands: [RotateNext.self, RotateDaemon.self, RotateCurrent.self, RotateRestore.self,
                      RotatePause.self, RotateResume.self, RotateStatus.self, RotateHistory.self,
                      Fav.self, Unfav.self, Block.self, Unblock.self, SyncManifest.self])
}

struct RotateNext: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "next", abstract: "Advance to the next work and set the wallpaper (resumes rotation if paused).")
    @OptionGroup var opts: RuntimeOptions

    func run() async throws {
        let work = try await advance(opts)
        print("now showing: \(WallpaperEngine.describe(work))")
    }
}

struct RotateDaemon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon", abstract: "Rotate on the schedule from settings.json.")
    @OptionGroup var opts: RuntimeOptions
    @Option(help: "Override with a fixed interval in minutes for this run.")
    var interval: Int?

    // Sleep toward the schedule's next fire in short slices rather than one long
    // sleep: day/week/month schedules then survive daemon restarts without
    // resetting the countdown, and settings/pause edits apply within minutes.
    func run() async throws {
        while true {
            let store = try opts.store()
            let settings = store.loadSettings()   // re-read so edits apply live
            let state = store.loadState()
            if state.paused {
                rotateLog("paused — sleeping 60s")
                try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                continue
            }
            let schedule = interval.map { RotationSchedule.interval(minutes: max(1, $0)) } ?? settings.schedule
            // Never shown yet → rotate now; otherwise the schedule's next fire.
            let due = state.history.last.map { schedule.nextFire(after: $0.shownAt) } ?? Date()
            let wait = due.timeIntervalSinceNow
            if wait > 0 {
                try await Task.sleep(nanoseconds: UInt64(min(wait, 300) * 1_000_000_000))
                continue
            }
            do {
                let work = try await advance(opts)
                rotateLog("now showing: \(WallpaperEngine.describe(work))")
            } catch {
                rotateLog("rotation failed: \(error) — retrying in 5 min")
                try await Task.sleep(nanoseconds: 300 * 1_000_000_000)
            }
        }
    }
}

struct RotateRestore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Restore the wallpaper artbip replaced, and pause rotation.")
    @OptionGroup var opts: RuntimeOptions

    func run() async throws {
        let store = try opts.store()
        let n = try await MainActor.run { try WallpaperEngine.restoreOriginal(store: store) }
        var state = store.loadState()
        state.paused = true
        try store.saveState(state)
        print("restored original wallpaper on \(n) screen\(n == 1 ? "" : "s") — rotation paused")
        print("(resume with `artbip rotate resume` or from the menu bar)")
    }
}

struct RotatePause: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pause", abstract: "Pause rotation (timer and daemon stop advancing).")
    @OptionGroup var opts: RuntimeOptions

    func run() async throws {
        try mutateState(opts) { state in
            state.paused = true
            return "rotation paused"
        }
    }
}

struct RotateResume: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resume", abstract: "Resume rotation.")
    @OptionGroup var opts: RuntimeOptions

    func run() async throws {
        try mutateState(opts) { state in
            state.paused = false
            return "rotation resumed"
        }
    }
}

struct RotateCurrent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "current", abstract: "Show the work currently on the desktop.")
    @OptionGroup var opts: RuntimeOptions

    func run() async throws {
        let store = try opts.store()
        let state = store.loadState()
        guard let id = state.current else {
            print("nothing shown yet — run `artbip rotate next`")
            return
        }
        let manifest = try store.loadManifest(explicit: opts.manifest)
        if let work = manifest.works.first(where: { $0.id == id }) {
            print(WallpaperEngine.describe(work))
            if let caption = work.caption { print(caption) }
            print(work.collectionURL)
        } else {
            print(id)
        }
    }
}

struct RotateStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Cache size, queue position, favourites/blocklist counts.")
    @OptionGroup var opts: RuntimeOptions

    func run() async throws {
        let store = try opts.store()
        let settings = store.loadSettings()
        let state = store.loadState()
        let manifest = try? store.loadManifest(explicit: opts.manifest)
        let cache = WallpaperEngine.makeCache(store: store, settings: settings)
        let mb = Double(await cache.sizeBytes()) / 1_048_576
        print("runtime dir: \(store.dir.path)")
        print("manifest: \(manifest?.works.count.description ?? "not found") works")
        print("queue: \(state.queue.count) remaining in this cycle")
        print("history: \(state.history.count) · favourites: \(state.favourites.count) · blocked: \(state.blocklist.count)")
        print("cache: \(String(format: "%.0f", mb)) MB of \(settings.cacheBudgetMB) MB budget")
        print("schedule: \(settings.schedule.summary) · background: \(settings.background) · label: \(settings.label) · paused: \(state.paused)")
    }
}

struct RotateHistory: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history", abstract: "Recently shown works, newest first.")
    @OptionGroup var opts: RuntimeOptions
    @Option(help: "How many entries to show.")
    var limit: Int = 20

    func run() async throws {
        let store = try opts.store()
        let manifest = try? store.loadManifest(explicit: opts.manifest)
        let byId = Dictionary(uniqueKeysWithValues: (manifest?.works ?? []).map { ($0.id, $0) })
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        for entry in store.loadState().history.suffix(limit).reversed() {
            let desc = byId[entry.id].map(WallpaperEngine.describe) ?? entry.id
            print("\(df.string(from: entry.shownAt))  \(desc)")
        }
    }
}

// MARK: - Favourites / blocklist

func mutateState(_ opts: RuntimeOptions, _ body: (inout RuntimeState) -> String) throws {
    let store = try opts.store()
    var state = store.loadState()
    let message = body(&state)
    try store.saveState(state)
    print(message)
}

struct Fav: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Favourite a work (default: the one currently shown).")
    @OptionGroup var opts: RuntimeOptions
    @Argument(help: "Work id (default: current).") var id: String?

    func run() async throws {
        try mutateState(opts) { state in
            guard let target = id ?? state.current else { return "nothing is current" }
            if !state.favourites.contains(target) { state.favourites.append(target) }
            return "favourited \(target)"
        }
    }
}

struct Unfav: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove a work from favourites (default: the one currently shown).")
    @OptionGroup var opts: RuntimeOptions
    @Argument(help: "Work id (default: current).") var id: String?

    func run() async throws {
        try mutateState(opts) { state in
            guard let target = id ?? state.current else { return "nothing is current" }
            state.favourites.removeAll { $0 == target }
            return "unfavourited \(target)"
        }
    }
}

struct Block: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Never show a work again (default: the one currently shown; advances if current).")
    @OptionGroup var opts: RuntimeOptions
    @Argument(help: "Work id (default: current).") var id: String?

    func run() async throws {
        var wasCurrent = false
        try mutateState(opts) { state in
            guard let target = id ?? state.current else { return "nothing is current" }
            if !state.blocklist.contains(target) { state.blocklist.append(target) }
            state.favourites.removeAll { $0 == target }
            wasCurrent = target == state.current
            return "blocked \(target)"
        }
        if wasCurrent {
            let work = try await advance(opts)
            print("now showing: \(WallpaperEngine.describe(work))")
        }
    }
}

struct Unblock: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove a work from the blocklist.")
    @OptionGroup var opts: RuntimeOptions
    @Argument(help: "Work id.") var id: String

    func run() async throws {
        try mutateState(opts) { state in
            state.blocklist.removeAll { $0 == id }
            return "unblocked \(id)"
        }
    }
}

struct SyncManifest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync-manifest",
        abstract: "Copy the manifest into the runtime dir so rotation works outside the repo.")
    @OptionGroup var opts: RuntimeOptions

    func run() async throws {
        let store = try opts.store()
        let manifest = try store.loadManifest(explicit: opts.manifest)
        try JSONIO.write(manifest, to: store.manifestURL)
        print("synced \(manifest.works.count) works -> \(store.manifestURL.path)")
    }
}
