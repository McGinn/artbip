import AppKit
import CryptoKit
import Foundation

public struct RuntimeError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

/// AppKit's screen list disagrees with CoreGraphics about what is attached.
///
/// Its own type rather than a `RuntimeError`, because a caller has to be able to
/// tell it apart from a failed download or a compositor error. Matching on
/// message text would break as soon as someone reworded the string.
public struct StaleScreenListError: Error, CustomStringConvertible {
    public let appKit: [CGDirectDisplayID]
    public let coreGraphics: [CGDirectDisplayID]
    public var description: String {
        func list(_ ids: [CGDirectDisplayID]) -> String {
            ids.map(String.init).sorted().joined(separator: ",")
        }
        return "stale screen list: AppKit reports displays [\(list(appKit))] "
            + "but CoreGraphics reports [\(list(coreGraphics))]"
    }
}

/// Shared by one-shot CLI commands and the menu-bar app: fetch a work, compose it for
/// every attached screen, set the wallpaper, persist state, prefetch ahead.
public enum WallpaperEngine {
    public static func makeCache(store: RuntimeStore, settings: RuntimeSettings) -> ImageCache {
        let http = Http(cacheDir: store.dir.appendingPathComponent("cache/http"),
                        userAgent: "artbip/0.1 (\(Http.contact)) runtime")
        return ImageCache(store: store, http: http, budgetMB: settings.cacheBudgetMB)
    }

    /// Compose `work` for every attached screen and set it as the wallpaper.
    @MainActor
    public static func apply(work: ManifestWork, data: Data, store: RuntimeStore,
                             settings: RuntimeSettings) throws {
        guard let art = Compositor.decode(data) else {
            throw RuntimeError("cannot decode cached image for \(work.id)")
        }
        var options = settings.composeOptions
        if settings.label {
            var detail = work.artist
            if let date = work.dateDisplay { detail += ", \(date)" }
            options.label = ComposeLabel(title: work.title, detail: detail)
        }

        let screens = try currentScreens()
        captureOriginals(store: store, screens: screens)
        // macOS treats setDesktopImageURL as a no-op when the URL matches the
        // current wallpaper, even if the file's contents changed — so the name
        // must change whenever the composition would look different.
        let sig = composeSignature(options)
        var written: [URL] = []
        for screen in screens {
            let scale = screen.backingScaleFactor
            let w = Int(screen.frame.width * scale)
            let h = Int(screen.frame.height * scale)
            // setDesktopImageURL is a silent no-op for a screen macOS no longer
            // considers attached, and reading the wallpaper back to confirm is
            // not an option (NSWorkspace caches it per process and will not
            // reflect our own write) — so re-check CoreGraphics, which stays
            // live, before spending a compose on a display that just left.
            guard let id = displayID(screen), activeDisplayIDs().contains(id) else {
                throw RuntimeError("display detached while composing \(work.id) at \(w)x\(h)")
            }
            guard let composed = Compositor.compose(art: art, targetWidth: w, targetHeight: h,
                                                    dominantHSL: work.paletteDominantHSL,
                                                    options: options),
                  let png = Compositor.png(composed) else {
                throw RuntimeError("compositor failed for \(work.id) at \(w)x\(h)")
            }
            let file = store.wallpapersDir.appendingPathComponent("\(work.id)-\(w)x\(h)-\(sig).png")
            try png.write(to: file, options: .atomic)
            try NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: [:])
            written.append(file)
        }
        cleanWallpapers(dir: store.wallpapersDir, keeping: written)
    }

    private static func composeSignature(_ o: ComposeOptions) -> String {
        let source = "\(o.background.rawValue)|\(o.marginFraction)|\(o.shadow)|\(o.label?.title ?? "")|\(o.label?.detail ?? "")"
        return SHA256.hash(data: Data(source.utf8))
            .prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// What is *actually* attached right now. CoreGraphics does not depend on
    /// AppKit's cached screen list.
    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(UInt32(ids.count), &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// The CoreGraphics display a screen belongs to, or nil for the rare screen
    /// that reports no NSScreenNumber.
    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    /// Stable fingerprint of the attached displays (id + pixel size), used to
    /// detect hotplug/resolution changes independently of AppKit's cached list.
    public static func displaySignature() -> String {
        activeDisplayIDs()
            .map { id -> String in
                let mode = CGDisplayCopyDisplayMode(id)
                return "\(id):\(mode?.pixelWidth ?? 0)x\(mode?.pixelHeight ?? 0)"
            }
            .sorted().joined(separator: ",")
    }

    /// NSScreen.screens, but only once AppKit agrees with CoreGraphics about
    /// which displays exist.
    ///
    /// AppKit rebuilds its cached screen list from the main run loop, so it can
    /// briefly lag behind CoreGraphics during a display change. Pump the run loop
    /// until the two views match; give up rather than paint a phantom display.
    @MainActor
    public static func currentScreens(timeout: TimeInterval = 2) throws -> [NSScreen] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let attached = Set(activeDisplayIDs())
            guard !attached.isEmpty else {
                throw RuntimeError("no screens available (is a GUI session running?)")
            }
            let screens = NSScreen.screens
            if Set(screens.compactMap(displayID)) == attached { return screens }
            guard Date() < deadline else {
                throw StaleScreenListError(appKit: screens.compactMap(displayID),
                                           coreGraphics: Array(attached))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// True when at least one screen currently shows a wallpaper artbip composed.
    /// Display-change refresh only fires then — after restore-original, artbip
    /// is not in control and must not overwrite the user's wallpaper.
    @MainActor
    public static func ownsDesktop(store: RuntimeStore) -> Bool {
        let own = store.wallpapersDir.standardizedFileURL.path + "/"
        // Best effort: a stale list here only risks a redundant re-apply, so fall
        // back to whatever AppKit has rather than reporting "not ours".
        let screens = (try? currentScreens()) ?? NSScreen.screens
        return screens.contains {
            NSWorkspace.shared.desktopImageURL(for: $0)?
                .standardizedFileURL.path.hasPrefix(own) == true
        }
    }

    private static func screenKey(_ screen: NSScreen) -> String {
        displayID(screen).map(String.init) ?? screen.localizedName
    }

    /// Record what each screen showed before artbip touches it, once per
    /// screen. Skips wallpapers artbip itself composed, so an entry is always
    /// the user's own background.
    @MainActor
    static func captureOriginals(store: RuntimeStore, screens: [NSScreen]) {
        var saved = store.loadOriginalWallpapers()
        let own = store.wallpapersDir.standardizedFileURL.path + "/"
        var changed = false
        for screen in screens {
            let key = screenKey(screen)
            guard saved[key] == nil,
                  let url = NSWorkspace.shared.desktopImageURL(for: screen),
                  !url.standardizedFileURL.path.hasPrefix(own) else { continue }
            saved[key] = url.path
            changed = true
        }
        if changed { try? store.saveOriginalWallpapers(saved) }
    }

    /// Put back the wallpaper each screen had before artbip first replaced it.
    /// Returns the number of screens restored. Callers should pause rotation
    /// afterwards, or the next tick immediately overwrites the restoration.
    @MainActor
    @discardableResult
    private static func restoreOriginalImages(store: RuntimeStore) throws -> Int {
        let saved = store.loadOriginalWallpapers()
        guard !saved.isEmpty else {
            throw RuntimeError("no original wallpaper recorded — artbip saves it the first time it changes the desktop")
        }
        var restored = 0
        for screen in try currentScreens() {
            guard let path = saved[screenKey(screen)] ?? saved.values.first,
                  FileManager.default.fileExists(atPath: path) else { continue }
            try NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: [:])
            restored += 1
        }
        guard restored > 0 else {
            throw RuntimeError("the saved wallpaper file(s) no longer exist on disk")
        }
        return restored
    }

    /// Old composed files linger so recent Spaces don't lose their image, but
    /// the directory must not grow without bound.
    static func cleanWallpapers(dir: URL, keeping: [URL], maxFiles: Int = 8) {
        let keep = Set(keeping.map(\.lastPathComponent))
        let entries = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { !keep.contains($0.lastPathComponent) }
            .sorted { (a, b) in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da > db
            }
        for url in entries.dropFirst(max(0, maxFiles - keeping.count)) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// A request superseded by a pause, eligibility change, or another rotation.
    public struct Superseded: Error, CustomStringConvertible {
        public var description: String { "rotation superseded by newer settings or state" }
    }

    @discardableResult
    public static func advance(store: RuntimeStore, manifest: Manifest,
                               cache existing: ImageCache? = nil, scheduled: Bool = false,
                               log: (@Sendable (String) -> Void)? = nil) async throws -> ManifestWork {
        let settings = store.loadSettings()
        let cache = existing ?? makeCache(store: store, settings: settings)
        await cache.cancelPrefetch()
        await cache.setBudget(megabytes: settings.cacheBudgetMB)
        let work = try await advanceUsing(store: store, manifest: manifest, scheduled: scheduled,
            fetch: { work in
                log?("fetching \(work.id) — \(work.title)")
                return try await cache.originalData(for: work)
            }, render: { work, data, settings in
                try apply(work: work, data: data, store: store, settings: settings)
            })
        // The app owns a long-lived cache. A one-shot CLI need not stay alive
        // downloading images after its requested wallpaper has been applied.
        if existing != nil {
            let ahead = Rotator.upcoming(manifest: manifest, state: store.loadState(),
                                         settings: store.loadSettings(), count: settings.prefetchCount)
            await cache.startPrefetch(ahead, log: log)
        }
        return work
    }

    /// Injectable I/O keeps concurrency tests off the real desktop and network.
    static func advanceUsing(store: RuntimeStore, manifest: Manifest, scheduled: Bool,
                             fetch: (ManifestWork) async throws -> Data,
                             render: @MainActor (ManifestWork, Data, RuntimeSettings) throws -> Void) async throws -> ManifestWork {
        let lease = try await store.acquireWallpaperLease()
        defer { lease.release() }
        let initial = try store.readState()
        let settings = store.loadSettings()
        if scheduled && !RotationScheduler.isDue(state: initial, settings: settings, now: Date()) {
            throw Superseded()
        }
        var selection = initial
        guard let work = Rotator.next(manifest: manifest, state: &selection, settings: settings) else {
            throw RuntimeError("No works available for rotation. Add works to the selected collection or choose another rotation source in Settings.")
        }
        let data = try await fetch(work)
        try Task.checkCancellation()
        try await MainActor.run {
            // Recheck on the rendering actor, after its queued UI events. No
            // actor hop may open a gap between this check and applying the image.
            let fresh = try store.readState()
            let freshSettings = store.loadSettings()
            guard fresh.pauseGeneration == initial.pauseGeneration,
                  Rotator.eligible(manifest, state: fresh, settings: freshSettings).contains(where: { $0.id == work.id }),
                  !scheduled || RotationScheduler.isDue(state: fresh, settings: freshSettings, now: Date()) else {
                throw Superseded()
            }
            try render(work, data, freshSettings)
        }
        try store.updateState { state in
            state.queue = selection.queue
            state.cycleMembers = selection.cycleMembers
            state.current = work.id
            state.desktopRestored = false
            state.history.append(HistoryEntry(id: work.id, shownAt: Date()))
            state.history = Array(state.history.suffix(500))
            // An explicit Next resumes only the pause it originally observed.
            // A pause made during rendering must survive.
            if !scheduled && state.pauseGeneration == initial.pauseGeneration { state.paused = false }
        }
        return work
    }

    public static func show(work: ManifestWork, store: RuntimeStore, cache: ImageCache) async throws {
        await cache.cancelPrefetch()
        let lease = try await store.acquireWallpaperLease()
        defer { lease.release() }
        let initial = try store.readState()
        let data = try await cache.originalData(for: work)
        try await MainActor.run {
            let fresh = try store.readState()
            guard fresh.pauseGeneration == initial.pauseGeneration,
                  !fresh.blocklist.contains(work.id) else { throw Superseded() }
            try apply(work: work, data: data, store: store, settings: store.loadSettings())
        }
        try store.updateState { state in
            state.current = work.id
            state.desktopRestored = false
            state.history.append(HistoryEntry(id: work.id, shownAt: Date()))
            state.history = Array(state.history.suffix(500))
        }
    }

    @discardableResult
    public static func restoreOriginal(store: RuntimeStore) async throws -> Int {
        let lease = try await store.acquireWallpaperLease()
        defer { lease.release() }
        let count = try await restoreOriginalImages(store: store)
        try store.updateState { $0.paused = true; $0.desktopRestored = true }
        return count
    }

    /// Re-compose the latest current work under the same operation lease as Next.
    public static func refresh(store: RuntimeStore, manifest: Manifest,
                               cache existing: ImageCache? = nil) async throws {
        let lease = try await store.acquireWallpaperLease()
        defer { lease.release() }
        let settings = store.loadSettings()
        let state = try store.readState()
        guard !state.desktopRestored, let id = state.current,
              let work = manifest.works.first(where: { $0.id == id }) else { return }
        let cache = existing ?? makeCache(store: store, settings: settings)
        let data = try await cache.originalData(for: work)
        try await apply(work: work, data: data, store: store, settings: store.loadSettings())
    }

    public static func describe(_ work: ManifestWork) -> String {
        var line = "\(work.title) — \(work.artist)"
        if let date = work.dateDisplay { line += ", \(date)" }
        line += "  (\(work.id), \(work.collection))"
        return line
    }
}
