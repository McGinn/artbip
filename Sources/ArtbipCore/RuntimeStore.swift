import Foundation

// MARK: - Rotation schedule

/// When to rotate. Sub-daily cadences are plain intervals anchored on the last
/// rotation; daily/weekly/monthly fire at a wall-clock time so the artwork
/// changes at a predictable moment (every morning at 9, say) rather than "24h
/// after whenever it last happened".
public enum RotationSchedule: Sendable, Equatable {
    case interval(minutes: Int)
    case daily(hour: Int, minute: Int)
    case weekly(weekday: Int, hour: Int, minute: Int)   // weekday: 1=Sun … 7=Sat (Calendar)
    case monthly(day: Int, hour: Int, minute: Int)      // day: 1…28

    /// The next instant rotation is due, given when it last happened. For clock
    /// schedules this is the next matching wall-clock time strictly after
    /// `lastShown`; a slot missed while the machine slept lands in the past and
    /// so reads as due immediately.
    public func nextFire(after lastShown: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .interval(let minutes):
            return lastShown.addingTimeInterval(Double(max(1, minutes)) * 60)
        case .daily(let h, let m):
            return calendar.nextDate(after: lastShown, matching: DateComponents(hour: h, minute: m),
                                     matchingPolicy: .nextTime) ?? lastShown.addingTimeInterval(86_400)
        case .weekly(let wd, let h, let m):
            return calendar.nextDate(after: lastShown, matching: DateComponents(hour: h, minute: m, weekday: wd),
                                     matchingPolicy: .nextTime) ?? lastShown.addingTimeInterval(7 * 86_400)
        case .monthly(let day, let h, let m):
            return calendar.nextDate(after: lastShown, matching: DateComponents(day: day, hour: h, minute: m),
                                     matchingPolicy: .nextTime) ?? lastShown.addingTimeInterval(30 * 86_400)
        }
    }

    /// One-line description for `artbip rotate status`.
    public var summary: String {
        func hhmm(_ h: Int, _ m: Int) -> String { String(format: "%02d:%02d", h, m) }
        switch self {
        case .interval(let minutes): return "every \(minutes) min"
        case .daily(let h, let m): return "daily at \(hhmm(h, m))"
        case .weekly(let wd, let h, let m): return "weekly on \(RotationSchedule.weekdayName(wd)) at \(hhmm(h, m))"
        case .monthly(let day, let h, let m): return "monthly on day \(day) at \(hhmm(h, m))"
        }
    }

    /// Full weekday name for a Calendar weekday index (1=Sunday … 7=Saturday).
    public static func weekdayName(_ weekday: Int, calendar: Calendar = .current) -> String {
        let symbols = calendar.weekdaySymbols
        let i = weekday - 1
        return symbols.indices.contains(i) ? symbols[i] : "day \(weekday)"
    }
}

// MARK: - Runtime settings (user-tunable; ~/Library/Application Support/artbip/settings.json)

/// A system-wide keyboard shortcut.
///
/// `code` is a Carbon virtual key code and `modifiers` a Carbon modifier mask
/// (cmdKey/optionKey/…); a negative code means unbound. `label` is the rendered
/// form ("⌥⌘A"), recorded alongside rather than derived, because mapping a key
/// code back to a character depends on the active keyboard layout.
public struct Shortcut: Codable, Sendable, Equatable {
    /// The actions a shortcut can be attached to. Raw values are the keys in
    /// `RuntimeSettings.shortcuts`, so they are part of the settings format.
    public enum Action: String, CaseIterable, Sendable {
        case info, next, favourite

        public var title: String {
            switch self {
            case .info:      return "About This Artwork"
            case .next:      return "Next Artwork"
            case .favourite: return "Favourite / Unfavourite"
            }
        }
    }

    public var code: Int
    public var modifiers: Int
    public var label: String

    public init(code: Int = -1, modifiers: Int = 0, label: String = "None") {
        self.code = code
        self.modifiers = modifiers
        self.label = label
    }

    public var isBound: Bool { code >= 0 && modifiers != 0 }
    public static let unbound = Shortcut()
}

public struct RuntimeSettings: Codable, Sendable {
    public var intervalMinutes: Int
    /// "interval" | "daily" | "weekly" | "monthly". Chooses which of the fields
    /// below drive `schedule`; kept as a string so unknown future modes decode
    /// to the interval fallback rather than failing.
    public var scheduleMode: String
    public var scheduleHour: Int           // 0…23, for daily/weekly/monthly
    public var scheduleMinute: Int         // 0…59
    public var scheduleWeekday: Int        // 1=Sun … 7=Sat, for weekly
    public var scheduleDay: Int            // 1…28, for monthly
    public var background: String          // ComposeOptions.Background rawValue
    public var label: Bool
    public var marginFraction: Double
    public var favouritesOnly: Bool
    public var cacheBudgetMB: Int
    public var prefetchCount: Int
    /// System-wide shortcuts, keyed by `Shortcut.Action`.
    ///
    /// Every shortcut this app offers is global. In a menu-bar-only app a
    /// SwiftUI `.keyboardShortcut` becomes an NSMenu key equivalent, which
    /// fires only while the menu is already open — so a menu advertising ⌘N
    /// tells the user something untrue. Anything worth a shortcut here is worth
    /// registering with Carbon; anything not worth that gets no shortcut shown.
    public var shortcuts: [String: Shortcut]
    /// Whether the info panel's period-and-style section is open. Persisted
    /// because the same school text recurs for every work in that tradition —
    /// collapsing it once should stay collapsed.
    public var infoSchoolExpanded: Bool
    /// Same, for the artist section: 60 works share a painter at the top of the
    /// manifest, so this text repeats even harder than the school's.
    public var infoArtistExpanded: Bool
    /// Whether to ask GitHub once a day if a newer release exists.
    ///
    /// On by default: the collection ships inside the app, so a data fix only
    /// reaches people who happen to re-download, and silence is the reason the
    /// Poussin attribution sat wrong on desktops. It is still a network call to
    /// a host that is not a museum, so Settings says so plainly and this turns
    /// it off. Nothing about the user or their usage is sent.
    public var updateCheckEnabled: Bool
    /// When the last check ran, so a relaunch does not re-ask immediately.
    public var lastUpdateCheck: Date?

    /// Opacity of the info panel window, 0.5–1.0. `.ultraThinMaterial` is
    /// already the most translucent standard material, so going further means
    /// dropping the whole window's alpha — which fades the text along with the
    /// background. Exposed as a setting rather than hard-coded because the
    /// readable limit depends on the wallpaper behind it.
    public var infoWindowOpacity: Double

    /// Keep works tagged `nsfw` (explicit nudity, sexual content, graphic
    /// violence) out of rotation and the gallery. On by default: a wallpaper
    /// app ends up on screens at work and in front of children, and nobody
    /// should have to find this switch after the fact.
    public var hideNSFW: Bool

    public init() {
        intervalMinutes = 60
        scheduleMode = "interval"
        scheduleHour = 9
        scheduleMinute = 0
        scheduleWeekday = 2                 // Monday
        scheduleDay = 1
        background = "blur"
        label = true
        marginFraction = 0.045
        favouritesOnly = false
        cacheBudgetMB = 2048
        prefetchCount = 3
        // Only the info panel is bound out of the box. Claiming several global
        // combinations uninvited is rude — the rest are opt-in from Settings.
        shortcuts = [Shortcut.Action.info.rawValue:
                        Shortcut(code: 0, modifiers: 256 | 2048, label: "⌥⌘A")]
        infoSchoolExpanded = true
        infoArtistExpanded = true
        infoWindowOpacity = 0.85
        hideNSFW = true
        updateCheckEnabled = true
        lastUpdateCheck = nil
    }

    /// The flat shortcut triple written before shortcuts became per-action.
    /// Kept only so an existing settings.json does not lose its binding.
    private enum LegacyKeys: String, CodingKey {
        case hotKeyCode, hotKeyModifiers, hotKeyLabel
    }

    /// Convenience accessor; unbound actions simply have no entry.
    public func shortcut(_ action: Shortcut.Action) -> Shortcut {
        shortcuts[action.rawValue] ?? .unbound
    }

    public mutating func setShortcut(_ action: Shortcut.Action, to value: Shortcut) {
        if value.isBound {
            shortcuts[action.rawValue] = value
        } else {
            shortcuts.removeValue(forKey: action.rawValue)
        }
    }

    // Missing keys fall back to defaults so old settings files survive new fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RuntimeSettings()
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? d.intervalMinutes
        scheduleMode = try c.decodeIfPresent(String.self, forKey: .scheduleMode) ?? d.scheduleMode
        scheduleHour = try c.decodeIfPresent(Int.self, forKey: .scheduleHour) ?? d.scheduleHour
        scheduleMinute = try c.decodeIfPresent(Int.self, forKey: .scheduleMinute) ?? d.scheduleMinute
        scheduleWeekday = try c.decodeIfPresent(Int.self, forKey: .scheduleWeekday) ?? d.scheduleWeekday
        scheduleDay = try c.decodeIfPresent(Int.self, forKey: .scheduleDay) ?? d.scheduleDay
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? d.background
        label = try c.decodeIfPresent(Bool.self, forKey: .label) ?? d.label
        marginFraction = try c.decodeIfPresent(Double.self, forKey: .marginFraction) ?? d.marginFraction
        favouritesOnly = try c.decodeIfPresent(Bool.self, forKey: .favouritesOnly) ?? d.favouritesOnly
        cacheBudgetMB = try c.decodeIfPresent(Int.self, forKey: .cacheBudgetMB) ?? d.cacheBudgetMB
        prefetchCount = try c.decodeIfPresent(Int.self, forKey: .prefetchCount) ?? d.prefetchCount
        if let stored = try c.decodeIfPresent([String: Shortcut].self, forKey: .shortcuts) {
            shortcuts = stored
        } else if let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
                  let code = try? legacy.decodeIfPresent(Int.self, forKey: .hotKeyCode) {
            // Settings written before shortcuts became per-action carried a
            // single flat triple, which was always the info panel's.
            shortcuts = [Shortcut.Action.info.rawValue: Shortcut(
                code: code,
                modifiers: (try? legacy.decode(Int.self, forKey: .hotKeyModifiers)) ?? 0,
                label: (try? legacy.decode(String.self, forKey: .hotKeyLabel)) ?? "None")]
        } else {
            shortcuts = d.shortcuts
        }
        infoSchoolExpanded = try c.decodeIfPresent(Bool.self, forKey: .infoSchoolExpanded) ?? d.infoSchoolExpanded
        infoArtistExpanded = try c.decodeIfPresent(Bool.self, forKey: .infoArtistExpanded) ?? d.infoArtistExpanded
        // Clamped: a stray 0 in settings.json would make the panel invisible
        // and there is no UI to get it back.
        infoWindowOpacity = min(1.0, max(0.5,
            try c.decodeIfPresent(Double.self, forKey: .infoWindowOpacity) ?? d.infoWindowOpacity))
        hideNSFW = try c.decodeIfPresent(Bool.self, forKey: .hideNSFW) ?? d.hideNSFW
        updateCheckEnabled = try c.decodeIfPresent(Bool.self, forKey: .updateCheckEnabled) ?? d.updateCheckEnabled
        lastUpdateCheck = try c.decodeIfPresent(Date.self, forKey: .lastUpdateCheck) ?? d.lastUpdateCheck
    }

    /// The active schedule, assembled from `scheduleMode` and its fields.
    public var schedule: RotationSchedule {
        switch scheduleMode {
        case "daily":   return .daily(hour: scheduleHour, minute: scheduleMinute)
        case "weekly":  return .weekly(weekday: scheduleWeekday, hour: scheduleHour, minute: scheduleMinute)
        case "monthly": return .monthly(day: scheduleDay, hour: scheduleHour, minute: scheduleMinute)
        default:        return .interval(minutes: intervalMinutes)
        }
    }

    public var composeOptions: ComposeOptions {
        ComposeOptions(background: ComposeOptions.Background(rawValue: background) ?? .blur,
                       marginFraction: marginFraction, shadow: true, label: nil)
    }
}

// MARK: - Runtime state (rotation queue, history, favourites, blocklist)

public struct HistoryEntry: Codable, Sendable {
    public var id: String
    public var shownAt: Date

    public init(id: String, shownAt: Date) {
        self.id = id
        self.shownAt = shownAt
    }
}

public struct RuntimeState: Codable, Sendable {
    public var collections: [SavedCollection]
    public var rotationCollectionID: UUID?
    /// Shuffle bag: every eligible work is shown once before any repeats.
    public var queue: [String]
    /// Eligible IDs in this cycle, including those already consumed.
    public var cycleMembers: [String]
    /// Changes whenever pause is edited, including a pause/resume round trip.
    public var pauseGeneration: Int
    /// Persisted so a queued refresh cannot undo a CLI restore.
    public var desktopRestored: Bool
    public var current: String?
    public var history: [HistoryEntry]
    public var favourites: [String]
    public var blocklist: [String]
    public var paused: Bool

    public init() {
        collections = []
        rotationCollectionID = nil
        queue = []
        cycleMembers = []
        pauseGeneration = 0
        desktopRestored = false
        current = nil
        history = []
        favourites = []
        blocklist = []
        paused = false
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collections = try c.decodeIfPresent([SavedCollection].self, forKey: .collections) ?? []
        rotationCollectionID = try c.decodeIfPresent(UUID.self, forKey: .rotationCollectionID)
        cycleMembers = try c.decodeIfPresent([String].self, forKey: .cycleMembers) ?? []
        pauseGeneration = try c.decodeIfPresent(Int.self, forKey: .pauseGeneration) ?? 0
        desktopRestored = try c.decodeIfPresent(Bool.self, forKey: .desktopRestored) ?? false
        queue = cycleMembers.isEmpty ? [] : (try c.decodeIfPresent([String].self, forKey: .queue) ?? [])
        current = try c.decodeIfPresent(String.self, forKey: .current)
        history = try c.decodeIfPresent([HistoryEntry].self, forKey: .history) ?? []
        favourites = try c.decodeIfPresent([String].self, forKey: .favourites) ?? []
        blocklist = try c.decodeIfPresent([String].self, forKey: .blocklist) ?? []
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
    }
}

// MARK: - Store

/// Owns the runtime directory layout and settings/state persistence. CLI
/// commands and the app share this, so favourites made in one show up in the other.
public struct RuntimeStore: Sendable {
    public let dir: URL

    public init(dir: URL? = nil) throws {
        self.dir = dir ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("artbip")
        for sub in ["", "cache/originals", "cache/thumbs", "wallpapers"] {
            try FileManager.default.createDirectory(at: self.dir.appendingPathComponent(sub),
                                                    withIntermediateDirectories: true)
        }
    }

    public var settingsURL: URL { dir.appendingPathComponent("settings.json") }
    public var stateURL: URL { dir.appendingPathComponent("state.json") }
    public var originalWallpaperURL: URL { dir.appendingPathComponent("original-wallpaper.json") }
    public var manifestURL: URL { dir.appendingPathComponent("manifest.json") }
    public var originalsDir: URL { dir.appendingPathComponent("cache/originals") }
    public var thumbsDir: URL { dir.appendingPathComponent("cache/thumbs") }
    public var wallpapersDir: URL { dir.appendingPathComponent("wallpapers") }

    public func loadSettings() -> RuntimeSettings {
        (try? JSONIO.read(RuntimeSettings.self, from: settingsURL)) ?? RuntimeSettings()
    }

    public func saveSettings(_ s: RuntimeSettings) throws {
        let lease = try FileLease.acquireSync(dir.appendingPathComponent("settings.lock"))
        defer { lease.release() }
        try JSONIO.write(s, to: settingsURL)
    }

    /// The wallpaper each screen showed before artbip first replaced it,
    /// keyed by screen id. Written once per screen; restore reads it back.
    public func loadOriginalWallpapers() -> [String: String] {
        (try? JSONIO.read([String: String].self, from: originalWallpaperURL)) ?? [:]
    }

    public func saveOriginalWallpapers(_ wallpapers: [String: String]) throws {
        try JSONIO.write(wallpapers, to: originalWallpaperURL)
    }

    public func loadState() -> RuntimeState {
        (try? JSONIO.read(RuntimeState.self, from: stateURL)) ?? RuntimeState()
    }

    public func saveState(_ s: RuntimeState) throws {
        try updateState { $0 = s }
    }

    /// Callers must use transactions for edits, never save a snapshot read before an await.
    @discardableResult
    public func updateState(_ body: (inout RuntimeState) throws -> Void) throws -> RuntimeState {
        let lease = try FileLease.acquireSync(dir.appendingPathComponent("state.lock"))
        defer { lease.release() }
        var state = try readState()
        let wasPaused = state.paused
        let generation = state.pauseGeneration
        try body(&state)
        state.pauseGeneration = generation + (wasPaused == state.paused ? 0 : 1)
        try JSONIO.write(state, to: stateURL)
        return state
    }

    public func readState() throws -> RuntimeState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return RuntimeState() }
        return try JSONIO.read(RuntimeState.self, from: stateURL)
    }

    @discardableResult
    public func updateSettings(_ body: (inout RuntimeSettings) throws -> Void) throws -> RuntimeSettings {
        let lease = try FileLease.acquireSync(dir.appendingPathComponent("settings.lock"))
        defer { lease.release() }
        var settings = FileManager.default.fileExists(atPath: settingsURL.path)
            ? try JSONIO.read(RuntimeSettings.self, from: settingsURL) : RuntimeSettings()
        try body(&settings)
        try JSONIO.write(settings, to: settingsURL)
        return settings
    }

    /// One wallpaper operation at a time, even across the CLI and app.
    public func acquireWallpaperLease() async throws -> FileLease {
        try await FileLease.acquire(dir.appendingPathComponent("wallpaper.lock"))
    }

    /// Manifest resolution: explicit path > repo checkout (dev) > bundle > app-support
    /// copy (synced by `artbip rotate sync-manifest` or the app on first run).
    /// A repo manifest also refreshes the app-support copy for one-shot CLI commands.
    public func loadManifest(explicit: String? = nil, bundled: URL? = nil,
                             developmentDirectory: URL? = nil) throws -> Manifest {
        if let explicit {
            return try JSONIO.read(Manifest.self, from: URL(fileURLWithPath: explicit))
        }
        let repo = (developmentDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .appendingPathComponent("data/manifest.json")
        if FileManager.default.fileExists(atPath: repo.path) {
            let manifest = try JSONIO.read(Manifest.self, from: repo)
            try JSONIO.write(manifest, to: manifestURL)
            return manifest
        }
        if let bundled, let manifest = try? JSONIO.read(Manifest.self, from: bundled) {
            try JSONIO.write(manifest, to: manifestURL)
            return manifest
        }
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            return try JSONIO.read(Manifest.self, from: manifestURL)
        }
        throw NSError(domain: "artbip", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "no manifest found — run from the repo, pass --manifest, or sync one to \(manifestURL.path)"])
    }

    /// The full editorial file, for development and the CLI only: an explicit
    /// path, else `info.json` in the private content checkout
    /// (`$ARTBIP_CONTENT_DIR`, or `../marketing/content` from the repo root).
    /// It is not in the public repository. Release apps read only the notes
    /// bundled with them (`NotesFile`), never this file, and nothing is cached.
    public func loadDevelopmentInfo(explicit: String? = nil) -> InfoFile? {
        let url = explicit.map { URL(fileURLWithPath: $0) }
            ?? Self.developmentContentDir().appendingPathComponent("info.json")
        return try? JSONIO.read(InfoFile.self, from: url)
    }

    /// The private editorial source directory; see `scripts/content_paths.py`.
    public static func developmentContentDir() -> URL {
        if let env = ProcessInfo.processInfo.environment["ARTBIP_CONTENT_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("../marketing/content").standardizedFileURL
    }
}
