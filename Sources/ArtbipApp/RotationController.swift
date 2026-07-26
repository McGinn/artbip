import AppKit
import ArtbipCore
import SwiftUI

/// Single source of truth for the app: wraps RuntimeStore/Rotator/WallpaperEngine,
/// owns the rotation timer, and republishes state for SwiftUI. The CLI shares the
/// same files on disk, so favourites made in either place appear in both.
@MainActor
final class RotationController: ObservableObject {
    let store: RuntimeStore
    let manifest: Manifest
    let cache: ImageCache
    private(set) var worksById: [String: ManifestWork]

    @Published var settings: RuntimeSettings
    @Published var state: RuntimeState
    @Published var busy = false
    @Published var lastError: String?

    private var timer: Timer?

    init() {
        // A startup failure here means no manifest anywhere — surface it hard;
        // the app is useless without one.
        let store = try! RuntimeStore()
        let bundled = Bundle.main.url(forResource: "manifest", withExtension: "json")
        let manifest = (try? store.loadManifest(bundled: bundled)) ?? Manifest(generatedAt: "", works: [])
        self.store = store
        self.manifest = manifest
        self.worksById = Dictionary(uniqueKeysWithValues: manifest.works.map { ($0.id, $0) })
        self.settings = store.loadSettings()
        self.state = store.loadState()
        self.cache = WallpaperEngine.makeCache(store: store, settings: store.loadSettings())
        scheduleTimer()
        rotateOnLaunchIfDue()
    }

    var currentWork: ManifestWork? {
        state.current.flatMap { worksById[$0] }
    }

    // MARK: Rotation

    func next() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await WallpaperEngine.advance(store: store, manifest: manifest, cache: cache)
                state = store.loadState()
                lastError = nil
                scheduleTimer()   // re-anchor the next rotation on this one
            } catch {
                lastError = "\(error)"
            }
        }
    }

    /// Show one specific work now (gallery "set as wallpaper"). Doesn't consume
    /// the shuffle bag — just records history and current.
    func show(_ work: ManifestWork) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let data = try await cache.originalData(for: work)
                try WallpaperEngine.apply(work: work, data: data, store: store, settings: settings)
                var s = store.loadState()
                s.current = work.id
                s.history.append(HistoryEntry(id: work.id, shownAt: Date()))
                try store.saveState(s)
                state = s
                lastError = nil
                scheduleTimer()
            } catch {
                lastError = "\(error)"
            }
        }
    }

    func togglePause() {
        mutateState { $0.paused.toggle() }
        scheduleTimer()
    }

    /// Pick up edits made by the CLI or daemon since we last touched disk
    /// (pause/resume, rotations, favourites). Called when menus/windows open.
    func reloadFromDisk() {
        settings = store.loadSettings()
        state = store.loadState()
    }

    var hasOriginalWallpaper: Bool {
        !store.loadOriginalWallpapers().isEmpty
    }

    /// Put back the pre-artbip wallpaper and pause rotation so the timer
    /// doesn't overwrite it a tick later.
    func restoreOriginalWallpaper() {
        guard !busy else { return }
        do {
            try WallpaperEngine.restoreOriginal(store: store)
            mutateState { $0.paused = true }
            scheduleTimer()
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    private func rotateOnLaunchIfDue() {
        guard !state.paused else { return }
        let last = state.history.last?.shownAt ?? .distantPast
        if Date().timeIntervalSince(last) >= Double(settings.intervalMinutes) * 60 {
            next()
        }
    }

    /// Fire at (last shown + interval), not (now + interval): with day/week/
    /// month intervals the app restarts many times per cycle, and re-starting
    /// the countdown on every launch would push the rotation out indefinitely.
    private func scheduleTimer() {
        timer?.invalidate()
        let interval = Double(max(1, settings.intervalMinutes)) * 60
        let anchor = state.history.last?.shownAt ?? Date()
        let fireAt = max(anchor.addingTimeInterval(interval), Date().addingTimeInterval(1))
        let t = Timer(fire: fireAt, interval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.timerFired()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// The CLI or daemon may have paused, resumed, or already rotated since
    /// this timer was armed — re-read shared state before acting, otherwise
    /// the app rotates on top of the daemon (halving the interval) or keeps
    /// rotating through a pause set from the terminal.
    private func timerFired() {
        state = store.loadState()
        guard !state.paused else { return }
        let interval = Double(max(1, settings.intervalMinutes)) * 60
        let last = state.history.last?.shownAt ?? .distantPast
        if Date().timeIntervalSince(last) >= interval - 1 {
            next()
        } else {
            scheduleTimer()   // someone else rotated — re-anchor on theirs
        }
    }

    // MARK: Favourites / blocklist

    func isFavourite(_ id: String) -> Bool { state.favourites.contains(id) }
    func isBlocked(_ id: String) -> Bool { state.blocklist.contains(id) }

    func toggleFavourite(_ id: String) {
        mutateState { s in
            if s.favourites.contains(id) {
                s.favourites.removeAll { $0 == id }
            } else {
                s.favourites.append(id)
            }
        }
    }

    func block(_ id: String) {
        let wasCurrent = state.current == id
        mutateState { s in
            if !s.blocklist.contains(id) { s.blocklist.append(id) }
            s.favourites.removeAll { $0 == id }
        }
        if wasCurrent { next() }
    }

    func unblock(_ id: String) {
        mutateState { $0.blocklist.removeAll { $0 == id } }
    }

    /// Load-modify-save against disk so CLI edits between app actions survive.
    private func mutateState(_ body: (inout RuntimeState) -> Void) {
        var s = store.loadState()
        body(&s)
        try? store.saveState(s)
        state = s
    }

    // MARK: Settings

    func updateSettings(_ body: (inout RuntimeSettings) -> Void) {
        var s = settings
        body(&s)
        settings = s
        try? store.saveSettings(s)
        Task { await cache.setBudget(megabytes: s.cacheBudgetMB) }
        scheduleTimer()
    }

    /// Re-compose the current work after appearance settings change.
    func refreshWallpaper() {
        guard !busy, state.current != nil else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await WallpaperEngine.refresh(store: store, manifest: manifest, cache: cache)
                lastError = nil
            } catch {
                lastError = "\(error)"
            }
        }
    }

    // MARK: Thumbnails

    func thumbnail(for work: ManifestWork) async -> NSImage? {
        guard let data = try? await cache.thumbnailData(for: work) else { return nil }
        return NSImage(data: data)
    }
}
