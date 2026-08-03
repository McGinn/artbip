import AppKit
import CryptoKit
import Foundation

public struct RuntimeError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

/// Shared by the CLI daemon and the menu-bar app: fetch a work, compose it for
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

    /// What is *actually* attached right now. CoreGraphics needs no run loop, so
    /// unlike NSScreen this stays correct in the CLI daemon.
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
    /// detect hotplug/resolution changes. CoreGraphics-based so it stays fresh
    /// in the CLI daemon, which has no AppKit run loop to update NSScreen.
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
    /// AppKit rebuilds its cached screen list from the main run loop. The daemon
    /// is a plain LaunchAgent with no NSApplication, so that refresh can lag by
    /// hours — long enough to compose for a monitor unplugged overnight and hand
    /// it to setDesktopImageURL, which silently does nothing for a detached
    /// screen. Pump the run loop until the two views match; give up rather than
    /// paint a phantom display, so the caller can log a real error and retry.
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
                let seen = screens.compactMap(displayID).map(String.init).sorted().joined(separator: ",")
                let real = attached.map(String.init).sorted().joined(separator: ",")
                throw RuntimeError("stale screen list: AppKit reports displays [\(seen)] but CoreGraphics reports [\(real)]")
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
    public static func restoreOriginal(store: RuntimeStore) throws -> Int {
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

    /// Advance to the next work, set the wallpaper, save state, prefetch ahead.
    /// Pass `cache` to reuse one across rotations (the app does); the CLI lets
    /// each invocation build its own.
    @discardableResult
    public static func advance(store: RuntimeStore, manifest: Manifest,
                               cache existing: ImageCache? = nil,
                               log: (@Sendable (String) -> Void)? = nil) async throws -> ManifestWork {
        let settings = store.loadSettings()
        var state = store.loadState()
        guard let work = Rotator.next(manifest: manifest, state: &state, settings: settings) else {
            throw RuntimeError("no eligible works (manifest empty or everything blocked)")
        }
        let cache = existing ?? makeCache(store: store, settings: settings)
        await cache.setBudget(megabytes: settings.cacheBudgetMB)
        log?("fetching \(work.id) — \(work.title)")
        let data = try await cache.originalData(for: work)
        try await apply(work: work, data: data, store: store, settings: settings)
        // An explicit advance is a clear "keep rotating" signal — without this,
        // restore-original (which pauses) followed by a manual next leaves
        // rotation silently paused forever. The daemon never advances while
        // paused, so this only fires for user-initiated rotations.
        if state.paused {
            state.paused = false
            log?("rotation was paused — resumed")
        }
        try store.saveState(state)

        let ahead = Rotator.upcoming(manifest: manifest, state: state,
                                     settings: settings, count: settings.prefetchCount)
        await cache.prefetch(ahead, log: log)
        return work
    }

    /// Re-compose the current work without advancing (settings changed).
    public static func refresh(store: RuntimeStore, manifest: Manifest,
                               cache existing: ImageCache? = nil) async throws {
        let settings = store.loadSettings()
        guard let id = store.loadState().current,
              let work = manifest.works.first(where: { $0.id == id }) else { return }
        let cache = existing ?? makeCache(store: store, settings: settings)
        let data = try await cache.originalData(for: work)
        try await apply(work: work, data: data, store: store, settings: settings)
    }

    public static func describe(_ work: ManifestWork) -> String {
        var line = "\(work.title) — \(work.artist)"
        if let date = work.dateDisplay { line += ", \(date)" }
        line += "  (\(work.id), \(work.collection))"
        return line
    }
}
