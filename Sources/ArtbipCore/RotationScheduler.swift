import Foundation

/// Pure scheduling decisions, shared by production timers and deterministic tests.
public struct RotationScheduler {
    public enum Decision: Equatable { case advance, wait(until: Date) }
    public private(set) var pending = false
    public private(set) var failures = 0
    public private(set) var retryNotBefore: Date?

    public init() {}

    public static func isDue(state: RuntimeState, settings: RuntimeSettings, now: Date) -> Bool {
        !state.paused && (state.history.last.map { settings.schedule.nextFire(after: $0.shownAt) <= now } ?? true)
    }

    public mutating func decision(state: RuntimeState, settings: RuntimeSettings,
                                  busy: Bool, now: Date) -> Decision {
        let poll = now.addingTimeInterval(60)
        guard !state.paused else { pending = false; return .wait(until: poll) }
        let due = Self.isDue(state: state, settings: settings, now: now)
        if busy {
            pending = due
            return .wait(until: poll)
        }
        if let retryNotBefore, retryNotBefore > now {
            return .wait(until: min(retryNotBefore, poll))
        }
        pending = false
        if due { return .advance }
        return .wait(until: min(settings.schedule.nextFire(after: state.history.last!.shownAt), poll))
    }

    public mutating func failed(now: Date) {
        failures += 1
        retryNotBefore = now.addingTimeInterval(failures <= 5 ? 180 : 1800)
    }

    public mutating func succeeded() {
        failures = 0
        retryNotBefore = nil
        pending = false
    }
}

/// The heartbeat prevents a stopped app's last timer from masquerading as live.
public struct SchedulerDiagnostics: Codable, Sendable {
    public var processID = ProcessInfo.processInfo.processIdentifier
    public var observedAt = Date()
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var nextCheck: Date?
    public var nextRotation: Date?
    public var busy = false
    public var pending = false
    public var lastFailure: String?

    public init() {}
    public func isFresh(now: Date = Date()) -> Bool {
        now.timeIntervalSince(observedAt) >= 0 && now.timeIntervalSince(observedAt) < 120
    }
    public var summary: String {
        func date(_ value: Date?) -> String { value?.formatted(date: .abbreviated, time: .standard) ?? "none" }
        return """
        Scheduler heartbeat: \(isFresh() ? "recent" : "stale — app may be stopped or asleep") (PID \(processID))
        Last attempt: \(date(lastAttempt))
        Last success: \(date(lastSuccess))
        Next check: \(date(nextCheck))
        Next rotation: \(date(nextRotation))
        Busy: \(busy) · pending: \(pending)
        Last failure: \(lastFailure ?? "none")
        """
    }
}

extension RuntimeStore {
    public var diagnosticsURL: URL { dir.appendingPathComponent("scheduler.json") }
    public func loadDiagnostics() -> SchedulerDiagnostics? {
        try? JSONIO.read(SchedulerDiagnostics.self, from: diagnosticsURL)
    }
    public func saveDiagnostics(_ value: SchedulerDiagnostics) throws {
        try JSONIO.write(value, to: diagnosticsURL)
    }
}
