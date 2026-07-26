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
    /// Shuffle bag: every eligible work is shown once before any repeats.
    public var queue: [String]
    public var current: String?
    public var history: [HistoryEntry]
    public var favourites: [String]
    public var blocklist: [String]
    public var paused: Bool

    public init() {
        queue = []
        current = nil
        history = []
        favourites = []
        blocklist = []
        paused = false
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        queue = try c.decodeIfPresent([String].self, forKey: .queue) ?? []
        current = try c.decodeIfPresent(String.self, forKey: .current)
        history = try c.decodeIfPresent([HistoryEntry].self, forKey: .history) ?? []
        favourites = try c.decodeIfPresent([String].self, forKey: .favourites) ?? []
        blocklist = try c.decodeIfPresent([String].self, forKey: .blocklist) ?? []
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
    }
}

// MARK: - Store

/// Owns the runtime directory layout and settings/state persistence. The CLI
/// daemon and the app share this, so favourites made in one show up in the other.
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
        try JSONIO.write(s, to: stateURL)
    }

    /// Manifest resolution: explicit path > repo checkout (dev) > app-support
    /// copy (synced by `artbip rotate sync-manifest` or the app on first run).
    /// A repo manifest also refreshes the app-support copy so the app and any
    /// launchd daemon see curation updates.
    public func loadManifest(explicit: String? = nil, bundled: URL? = nil) throws -> Manifest {
        if let explicit {
            return try JSONIO.read(Manifest.self, from: URL(fileURLWithPath: explicit))
        }
        let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("data/manifest.json")
        if FileManager.default.fileExists(atPath: repo.path) {
            let manifest = try JSONIO.read(Manifest.self, from: repo)
            try? FileManager.default.removeItem(at: manifestURL)
            try? FileManager.default.copyItem(at: repo, to: manifestURL)
            return manifest
        }
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            return try JSONIO.read(Manifest.self, from: manifestURL)
        }
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) {
            try? FileManager.default.copyItem(at: bundled, to: manifestURL)
            return try JSONIO.read(Manifest.self, from: bundled)
        }
        throw NSError(domain: "artbip", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "no manifest found — run from the repo, pass --manifest, or sync one to \(manifestURL.path)"])
    }
}
