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
    let info: InfoFile
    let cache: ImageCache
    private(set) var worksById: [String: ManifestWork]

    @Published var settings: RuntimeSettings
    @Published var state: RuntimeState
    @Published var busy = false
    @Published var lastError: String?
    /// A newer release, once a check has found one. In-memory only: it is a
    /// fact about the world, not a preference, and re-checking on launch is
    /// cheap enough that persisting it would only risk showing a stale banner.
    @Published var availableUpdate: UpdateCheck.Result?

    /// Actions whose shortcut the system refused because another app already
    /// owns the combination, keyed by `Shortcut.Action.rawValue`, so Settings
    /// can say so instead of appearing to work.
    @Published var shortcutRejected: [String: Bool] = [:]
    /// The info panel's window, handed over by the panel itself — SwiftUI gives
    /// a scene's NSWindow no identifier matching its scene id, so the global
    /// shortcut cannot otherwise find the window it needs to close.
    weak var infoWindow: NSWindow?
    /// One registration per action, owned here rather than in a @State on the
    /// menu-bar label: SwiftUI re-evaluates a @State's initial value on every
    /// view init, and each discarded GlobalHotKey deinits — clearing the shared
    /// action table and silently unregistering the live shortcut after its
    /// first use.
    private var hotKeys: [String: GlobalHotKey] = [:]

    /// Hot key registration for an action, created on first use. Ids must be
    /// stable and distinct across actions, since the Carbon event handler looks
    /// the action up by id.
    func hotKey(for action: Shortcut.Action) -> GlobalHotKey {
        if let existing = hotKeys[action.rawValue] { return existing }
        let index = Shortcut.Action.allCases.firstIndex(of: action) ?? 0
        let key = GlobalHotKey(id: UInt32(index + 1))
        hotKeys[action.rawValue] = key
        return key
    }

    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var screenDebounce: Task<Void, Never>?
    private var lastDisplaySignature = WallpaperEngine.displaySignature()

    init() {
        // A startup failure here means no manifest anywhere — surface it hard;
        // the app is useless without one.
        let store = try! RuntimeStore()
        let bundled = Bundle.main.url(forResource: "manifest", withExtension: "json")
        let manifest = (try? store.loadManifest(bundled: bundled)) ?? Manifest(generatedAt: "", works: [])
        self.store = store
        self.manifest = manifest
        self.info = store.loadInfo(bundled: Bundle.main.url(forResource: "info", withExtension: "json"))
        self.worksById = Dictionary(uniqueKeysWithValues: manifest.works.map { ($0.id, $0) })
        self.settings = store.loadSettings()
        self.state = store.loadState()
        self.cache = WallpaperEngine.makeCache(store: store, settings: store.loadSettings())
        scheduleTimer()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        rotateOnLaunchIfDue()
    }

    deinit {
        screenDebounce?.cancel()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
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

    /// Displays changed (hotplug, resolution): re-apply the current work so new
    /// screens show it immediately. Debounced — macOS fires this several times
    /// per hotplug. Runs even while paused (paused means "don't advance"), but
    /// not after restore-original (ownsDesktop is false then). The daemon may
    /// also refresh; refresh is idempotent so double-driving is harmless.
    private func screensChanged() {
        screenDebounce?.cancel()
        screenDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            let sig = WallpaperEngine.displaySignature()
            guard sig != self.lastDisplaySignature else { return }
            self.lastDisplaySignature = sig
            guard WallpaperEngine.ownsDesktop(store: self.store) else { return }
            self.reloadFromDisk()     // daemon may have rotated since last read
            self.refreshWallpaper()   // no advance, no history entry
        }
    }

    private func rotateOnLaunchIfDue() {
        guard !state.paused else { return }
        guard let last = state.history.last?.shownAt else { next(); return }
        if settings.schedule.nextFire(after: last) <= Date() { next() }
    }

    /// Arm a one-shot timer for the schedule's next fire, anchored on the last
    /// rotation — not (now + interval). With day/week/month schedules the app
    /// restarts many times per cycle, and restarting the countdown on every
    /// launch would push the rotation out indefinitely. Re-armed after each
    /// fire (and by settings changes) rather than repeating on a fixed period,
    /// since clock schedules don't have one.
    private func scheduleTimer() {
        timer?.invalidate()
        let now = Date()
        let fireAt: Date
        if state.paused {
            fireAt = now.addingTimeInterval(60)      // poll so a CLI/daemon resume takes effect
        } else if let last = state.history.last?.shownAt {
            fireAt = max(settings.schedule.nextFire(after: last), now.addingTimeInterval(1))
        } else {
            fireAt = now.addingTimeInterval(1)       // never shown — rotate right away
        }
        let t = Timer(fire: fireAt, interval: 0, repeats: false) { [weak self] _ in
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
        guard !state.paused else { scheduleTimer(); return }   // re-arm the resume poll
        let due: Bool
        if let last = state.history.last?.shownAt {
            due = settings.schedule.nextFire(after: last) <= Date().addingTimeInterval(1)
        } else {
            due = true
        }
        if due {
            next()            // next() re-anchors the timer on this rotation
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

    // MARK: Updates

    /// Ask GitHub whether there is a newer release. `force` bypasses the daily
    /// throttle for the Settings button; the automatic call on launch respects
    /// it so a relaunch does not re-ask.
    func checkForUpdate(force: Bool = false) {
        guard force || settings.updateCheckEnabled else { return }
        if !force, let last = settings.lastUpdateCheck,
           Date().timeIntervalSince(last) < UpdateCheck.minimumInterval { return }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "dev"
        Task { [weak self] in
            guard let self else { return }
            do {
                let latest = try await UpdateCheck.fetchLatest()
                let result = UpdateCheck.compare(current: current, against: latest)
                self.availableUpdate = result
                self.updateSettings { $0.lastUpdateCheck = Date() }
            } catch {
                // A failed check is not worth an error banner on a wallpaper
                // app; it simply means we still do not know.
                self.availableUpdate = nil
            }
        }
    }

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
