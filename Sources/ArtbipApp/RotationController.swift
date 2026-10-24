import AppKit
import ArtbipCore
import SwiftUI
import OSLog

/// Single source of truth for the app: wraps RuntimeStore/Rotator/WallpaperEngine,
/// owns the rotation timer, and republishes state for SwiftUI. The CLI shares the
/// same files on disk, so favourites made in either place appear in both.
@MainActor
final class RotationController: ObservableObject {
    let store: RuntimeStore
    let manifest: Manifest
    /// Bundled notes on works, artists and styles. Separate from rotation
    /// state: notes never change which wallpapers the user gets.
    let notes: NotesModel
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
    /// Drive the Settings status line, so a "Check Now" always answers —
    /// checking, up to date, newer version, or could not tell.
    @Published var updateCheckInProgress = false
    @Published var updateCheckFailed = false

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
    private var scheduler = RotationScheduler()
    @Published var diagnostics = SchedulerDiagnostics()
    private let logger = Logger(subsystem: "com.mcginn.artbip", category: "rotation")
    private var wakeObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var refreshPending = false
    private var screenDebounce: Task<Void, Never>?
    private var lastDisplaySignature = WallpaperEngine.displaySignature()

    init() {
        // A startup failure here means no manifest anywhere — surface it hard;
        // the app is useless without one.
        // Explicitly isolate preview/UI-test data from the user's installation.
        let runtimeDirectory = ProcessInfo.processInfo.environment["ARTBIP_RUNTIME_DIR"].map { URL(fileURLWithPath: $0) }
        let store = try! RuntimeStore(dir: runtimeDirectory)
        let bundled = Bundle.main.url(forResource: "manifest", withExtension: "json")
        let manifest = (try? store.loadManifest(bundled: bundled)) ?? Manifest(generatedAt: "", works: [])
        self.store = store
        self.manifest = manifest
        self.notes = NotesModel(store: store)
        self.worksById = Dictionary(uniqueKeysWithValues: manifest.works.map { ($0.id, $0) })
        self.settings = store.loadSettings()
        self.state = store.loadState()
        self.cache = WallpaperEngine.makeCache(store: store, settings: store.loadSettings())
        #if ARTBIP_APP_STORE
        if UserDefaults.standard.object(forKey: Self.firstUseKey) == nil {
            UserDefaults.standard.set(Date(), forKey: Self.firstUseKey)
        }
        #endif
        scheduleTimer()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        diagnostics.lastSuccess = state.history.last?.shownAt
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.timerFired() }
            }
        timerFired()
    }

    deinit {
        screenDebounce?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    var currentWork: ManifestWork? {
        state.current.flatMap { worksById[$0] }
    }

    // MARK: Rotation

    func next(scheduled: Bool = false) {
        guard !busy else { scheduleTimer(); return }
        busy = true
        diagnostics.lastAttempt = Date()
        logger.info("Rotation starting; scheduled=\(scheduled)")
        scheduleTimer()
        Task {
            defer { operationFinished() }
            do {
                try await WallpaperEngine.advance(store: store, manifest: manifest, cache: cache, scheduled: scheduled)
                diagnostics.lastSuccess = store.loadState().history.last?.shownAt
                lastError = nil
                scheduler.succeeded()
                logger.info("Rotation succeeded")
            } catch is WallpaperEngine.Superseded {
                logger.info("Rotation superseded by newer state")
            } catch {
                lastError = "\(error)"
                diagnostics.lastFailure = lastError
                scheduler.failed(now: Date())
                logger.error("Rotation failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func operationFinished() {
        busy = false
        // A due timer may have fired while rendering/downloading. Always
        // reevaluate, including failed refreshes; retry backoff remains intact.
        scheduleTimer()
        if refreshPending { refreshPending = false; refreshWallpaper() }
    }

    func show(_ work: ManifestWork) {
        guard !busy else { return }
        busy = true
        diagnostics.lastAttempt = Date()
        scheduleTimer()
        Task {
            defer { operationFinished() }
            do {
                try await WallpaperEngine.show(work: work, store: store, cache: cache)
                diagnostics.lastSuccess = store.loadState().history.last?.shownAt
                scheduler.succeeded()
                lastError = nil
            } catch is WallpaperEngine.Superseded {
                logger.info("Selection superseded by newer state")
            } catch { lastError = "\(error)"; diagnostics.lastFailure = lastError }
        }
    }

    func togglePause() {
        mutateState { $0.paused.toggle() }
        scheduleTimer()
    }

    /// Pick up edits made by the CLI since we last touched disk
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
        busy = true
        scheduleTimer()
        Task {
            defer { operationFinished() }
            do {
                await cache.cancelPrefetch()
                try await WallpaperEngine.restoreOriginal(store: store)
                lastError = nil
            } catch { lastError = "\(error)"; diagnostics.lastFailure = lastError }
        }
    }

    /// Displays changed (hotplug, resolution): re-apply the current work so new
    /// screens show it immediately. Debounced — macOS fires this several times
    /// per hotplug. Runs even while paused (paused means "don't advance"), but
    /// not after restore-original (ownsDesktop is false then).
    private func screensChanged() {
        screenDebounce?.cancel()
        screenDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            let sig = WallpaperEngine.displaySignature()
            guard sig != self.lastDisplaySignature else { return }
            self.lastDisplaySignature = sig
            guard WallpaperEngine.ownsDesktop(store: self.store) else { return }
            self.reloadFromDisk()     // a CLI command may have rotated since last read
            self.refreshWallpaper()   // no advance, no history entry
        }
    }

    private func scheduleTimer() {
        reloadFromDisk()
        let now = Date()
        let decision = scheduler.decision(state: state, settings: settings, busy: busy, now: now)
        switch decision {
        case .advance: armTimer(at: now.addingTimeInterval(1))
        case .wait(let date): armTimer(at: date)
        }
    }

    private func armTimer(at date: Date) {
        timer?.invalidate()
        let t = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.timerFired() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        diagnostics.nextCheck = date
        logger.debug("Timer armed for \(date.description, privacy: .public); pending=\(self.scheduler.pending)")
        publishDiagnostics()
    }

    private func timerFired() {
        timer?.invalidate()
        reloadFromDisk()
        switch scheduler.decision(state: state, settings: settings, busy: busy, now: Date()) {
        case .advance: next(scheduled: true)
        case .wait(let date): armTimer(at: date)
        }
    }

    private func publishDiagnostics() {
        diagnostics.observedAt = Date()
        diagnostics.busy = busy
        diagnostics.pending = scheduler.pending
        diagnostics.lastSuccess = store.loadState().history.last?.shownAt
        diagnostics.nextRotation = state.paused ? nil : max(
            state.history.last.map { settings.schedule.nextFire(after: $0.shownAt) } ?? Date(),
            scheduler.retryNotBefore ?? .distantPast)
        do { try store.saveDiagnostics(diagnostics) }
        catch { logger.error("Cannot save scheduler diagnostics: \(String(describing: error), privacy: .public)") }
    }

    // MARK: Favourites / blocklist

    func isFavourite(_ id: String) -> Bool { state.favourites.contains(id) }
    func isBlocked(_ id: String) -> Bool { state.blocklist.contains(id) }

    func toggleFavourite(_ id: String) {
        let adding = !state.favourites.contains(id)
        mutateState { s in
            if s.favourites.contains(id) {
                s.favourites.removeAll { $0 == id }
            } else {
                s.favourites.append(id)
            }
        }
        if adding { noteEngagement() }
    }

    // MARK: Rating prompt

    /// Set when the user has just done something that suggests they enjoy the
    /// app; the menu-bar label, which lives all session, turns it into Apple's
    /// rating prompt and clears it.
    @Published var reviewPromptDue = false

    /// Favouriting a work or opening its info panel. Only the App Store build
    /// asks for ratings; the direct build has no App Store page to rate.
    func noteEngagement() {
        #if ARTBIP_APP_STORE
        let defaults = UserDefaults.standard
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard !reviewPromptDue, !busy,
              let firstUse = defaults.object(forKey: Self.firstUseKey) as? Date,
              ReviewPrompt.isDue(favourites: state.favourites.count, firstUse: firstUse,
                                 lastAskedVersion: defaults.string(forKey: Self.reviewAskedKey),
                                 currentVersion: version, hasError: lastError != nil)
        else { return }
        defaults.set(version, forKey: Self.reviewAskedKey)
        reviewPromptDue = true
        #endif
    }

    #if ARTBIP_APP_STORE
    // Kept in the app's own defaults rather than RuntimeState: the CLI shares
    // that file and has no business with App Store prompts.
    private static let firstUseKey = "reviewPromptFirstUse"
    private static let reviewAskedKey = "reviewPromptAskedVersion"
    #endif

    func block(_ id: String) {
        let wasCurrent = state.current == id
        mutateState { s in
            if !s.blocklist.contains(id) { s.blocklist.append(id) }
            s.favourites.removeAll { $0 == id }
        }
        if wasCurrent { next() }
    }

    /// Turning the filter on while an NSFW work is on the desktop replaces it
    /// straight away rather than leaving it up until the next rotation.
    func setHideNSFW(_ hide: Bool) {
        updateSettings { $0.hideNSFW = hide }
        if hide, currentWork?.isNSFW == true { next() }
    }

    func unblock(_ id: String) {
        mutateState { $0.blocklist.removeAll { $0 == id } }
    }

    /// Load-modify-save against disk so CLI edits between app actions survive.
    private func mutateState(_ body: (inout RuntimeState) -> Void) {
        do { state = try store.updateState(body) }
        catch { lastError = "\(error)" }
    }

    // MARK: Personal collections

    func createCollection(name: String, works: [ManifestWork]) throws -> UUID {
        var id = UUID()
        state = try store.updateState { id = try $0.createCollection(name: name, workIDs: works.map(\.id)) }
        return id
    }

    func renameCollection(_ id: UUID, name: String) throws {
        state = try store.updateState { try $0.renameCollection(id, name: name) }
    }

    func deleteCollection(_ id: UUID) {
        if state.rotationCollectionID == id { updateSettings { $0.favouritesOnly = false } }
        mutateState { $0.deleteCollection(id) }
        scheduleTimer()
    }

    func setMembership(_ id: UUID, workID: String, included: Bool) {
        do { state = try store.updateState { try $0.setCollectionMembership(id, workID: workID, included: included) } }
        catch { lastError = error.localizedDescription }
    }

    var rotationSource: String {
        if let id = state.rotationCollectionID { return id.uuidString }
        return settings.favouritesOnly ? "favourites" : "all"
    }

    var rotationSourceName: String {
        if let id = state.rotationCollectionID {
            return state.collections.first(where: { $0.id == id })?.name ?? "Unavailable collection"
        }
        return settings.favouritesOnly ? "Favourites" : "All artworks"
    }

    func selectRotationSource(_ source: String) {
        // A collection takes precedence over the legacy favourites setting.
        updateSettings { $0.favouritesOnly = source == "favourites" }
        mutateState { $0.rotationCollectionID = UUID(uuidString: source) }
        scheduleTimer()
    }

    // MARK: Download storage

    @Published var cacheBytes: Int64?
    @Published var clearingCache = false
    @Published var cacheMessage: String?

    func refreshCacheUsage() async {
        cacheBytes = await cache.sizeBytes()
    }

    func clearDownloads() async {
        guard !clearingCache, !busy else { return }
        clearingCache = true
        cacheMessage = nil
        defer { clearingCache = false }
        do {
            try await cache.clearDownloads()
            cacheMessage = "Downloaded images cleared. Images download again as you use them."
        } catch {
            cacheMessage = "Some downloads could not be cleared: \(error.localizedDescription)"
        }
        await refreshCacheUsage()
    }

    // MARK: Settings

    // MARK: Updates

    /// Ask GitHub whether there is a newer release. `force` bypasses the daily
    /// throttle for the Settings button; the automatic call on launch respects
    /// it so a relaunch does not re-ask. `announce` (the menu's Check for
    /// Updates…) reports the outcome in a dialog, including "up to date".
    func checkForUpdate(force: Bool = false, announce: Bool = false) {
        #if ARTBIP_APP_STORE
        // App Store builds update only through the App Store.
        _ = (force, announce)
        #else
        guard force || settings.updateCheckEnabled else { return }
        if !force, let last = settings.lastUpdateCheck,
           Date().timeIntervalSince(last) < UpdateCheck.minimumInterval { return }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "dev"
        guard !updateCheckInProgress else { return }
        updateCheckInProgress = true
        updateCheckFailed = false
        Task { [weak self] in
            guard let self else { return }
            defer { self.updateCheckInProgress = false }
            do {
                let latest = try await UpdateCheck.fetchLatest()
                let result = UpdateCheck.compare(current: current, against: latest)
                self.availableUpdate = result
                self.updateSettings { $0.lastUpdateCheck = Date() }
                if announce { Self.announce(result, current: current) }
            } catch {
                // A failed check is not worth an error banner on a wallpaper
                // app; it simply means we still do not know. Settings says so
                // quietly, so "Check Now" never appears to do nothing.
                self.availableUpdate = nil
                self.updateCheckFailed = true
                if announce { Self.announce(nil, current: current) }
            }
        }
        #endif
    }

    #if !ARTBIP_APP_STORE
    /// The standard Mac "Check for Updates…" answer. An accessory app has to
    /// come forward first or the dialog opens behind other windows.
    private static func announce(_ result: UpdateCheck.Result?, current: String) {
        let alert = NSAlert()
        switch result {
        case .updateAvailable(let v, _):
            alert.messageText = "artbip \(v) is available"
            alert.informativeText = "You have \(current). Download the new version from the release page."
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "Later")
        case .upToDate:
            alert.messageText = "You're up to date"
            alert.informativeText = AppVersion(current) == nil
                ? "This is a development build, so it isn't compared with releases."
                : "artbip \(current) is the latest version."
        case nil:
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = "GitHub couldn't be reached. Try again later."
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, result?.newVersion != nil {
            Feedback.openLatestRelease()
        }
    }
    #endif

    func updateSettings(_ body: (inout RuntimeSettings) -> Void) {
        do {
            settings = try store.updateSettings(body)
            let budget = settings.cacheBudgetMB
            Task {
                await cache.setBudget(megabytes: budget)
                await refreshCacheUsage()
            }
            scheduleTimer()
        } catch { lastError = "\(error)" }
    }

    /// Re-compose the current work after appearance settings change.
    func refreshWallpaper() {
        guard !busy else { refreshPending = true; return }
        reloadFromDisk()
        guard state.current != nil, !state.desktopRestored else { return }
        busy = true
        scheduleTimer()
        Task {
            defer { operationFinished() }
            do {
                try await WallpaperEngine.refresh(store: store, manifest: manifest, cache: cache)
                lastError = nil
            } catch {
                lastError = "\(error)"
                diagnostics.lastFailure = lastError
            }
        }
    }

    // MARK: Thumbnails

    func thumbnail(for work: ManifestWork) async -> NSImage? {
        guard let data = try? await cache.thumbnailData(for: work) else { return nil }
        return NSImage(data: data)
    }
}
