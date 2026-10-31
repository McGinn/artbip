import Foundation
import Testing
@testable import ArtbipCore

func fixture(_ ids: [String] = ["a", "b", "c"]) throws -> Manifest {
    let works = try ids.map { id -> ManifestWork in
        let json = """
        {"id":"\(id)","title":"\(id)","artist":"Artist","artistSort":"Artist",
         "collection":"Test","collectionURL":"https://example.invalid",
         "image":{"url":"https://example.invalid/\(id)","sourceMaxWidth":1,"sourceMaxHeight":1,"format":"png"},
         "license":{"status":"PD","evidence":"test","sourceURL":"https://example.invalid"},
         "significance":{"museumHighlight":false,"canonLists":[]}}
        """
        return try JSONDecoder().decode(ManifestWork.self, from: Data(json.utf8))
    }
    return Manifest(generatedAt: "test", works: works)
}

func temporaryStore() throws -> RuntimeStore {
    try RuntimeStore(dir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
}

actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

struct RotationTests {
    @Test func testShuffleCyclesAndBoundaryRepeats() throws {
        let manifest = try fixture()
        var state = RuntimeState()
        let settings = RuntimeSettings()
        for _ in 0..<30 {
            let previous = state.current
            var cycle: [String] = []
            for i in 0..<3 {
                let work = try #require(Rotator.next(manifest: manifest, state: &state, settings: settings))
                cycle.append(work.id)
                if i == 0 { #expect((work.id) != (previous)) }
                #expect((state.queue.count) == (2 - i))
            }
            #expect((Set(cycle)) == (Set(["a", "b", "c"])))
        }
    }

    @Test func testEligibilityAndLegacyMigration() throws {
        let legacy = Data(#"{"queue":["a","b"],"current":"c","favourites":["b"],"blocklist":["a"],"paused":true}"#.utf8)
        var state = try JSONDecoder().decode(RuntimeState.self, from: legacy)
        #expect(state.queue.isEmpty)
        #expect(state.paused)
        #expect((state.favourites) == (["b"]))
        let manifest = try fixture()
        let settings = RuntimeSettings()
        #expect((Rotator.next(manifest: manifest, state: &state, settings: settings)?.id) == ("b"))
        state.blocklist = []
        _ = Rotator.next(manifest: manifest, state: &state, settings: settings)
        #expect(state.cycleMembers.contains("a"))
        #expect(!(state.queue.contains("b")))
        state.blocklist = ["a", "b", "c"]
        #expect((Rotator.next(manifest: manifest, state: &state, settings: settings)) == nil)
    }

    @Test func testBusyTimerAndFailedRefreshDoNotLoseDueWork() {
        let now = Date(timeIntervalSince1970: 1000)
        var scheduler = RotationScheduler()
        var state = RuntimeState()
        let settings = RuntimeSettings()
        #expect((scheduler.decision(state: state, settings: settings, busy: true, now: now)) == (.wait(until: now.addingTimeInterval(60))))
        #expect(scheduler.pending)
        // Both successful and failed refreshes leave history unchanged.
        #expect((scheduler.decision(state: state, settings: settings, busy: false, now: now)) == (.advance))
        state.history = [HistoryEntry(id: "a", shownAt: now)]
        for _ in 0..<5 {
            #expect((scheduler.decision(state: state, settings: settings, busy: false, now: now)) == (.wait(until: now.addingTimeInterval(60))))
        }
    }

    @Test func testBackoffPauseAndExternalScheduleChanges() {
        let now = Date(timeIntervalSince1970: 10000)
        var scheduler = RotationScheduler()
        var state = RuntimeState()
        var settings = RuntimeSettings()
        for _ in 0..<6 { scheduler.failed(now: now) }
        #expect((scheduler.retryNotBefore) == (now.addingTimeInterval(1800)))
        #expect((scheduler.decision(state: state, settings: settings, busy: false, now: now)) == (.wait(until: now.addingTimeInterval(60))))
        state.paused = true
        #expect(!(RotationScheduler.isDue(state: state, settings: settings, now: now)))
        scheduler.succeeded()
        state.paused = false
        state.history = [HistoryEntry(id: "a", shownAt: now.addingTimeInterval(-120))]
        #expect(!(RotationScheduler.isDue(state: state, settings: settings, now: now)))
        settings.intervalMinutes = 1
        #expect((scheduler.decision(state: state, settings: settings, busy: false, now: now)) == (.advance))
    }

    @Test func testMissedDailySlotAndNextDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let last = calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 23))!
        let next = RotationSchedule.daily(hour: 9, minute: 0).nextFire(after: last, calendar: calendar)
        #expect((next) == (calendar.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 9))))
        let woke = next.addingTimeInterval(7200)
        #expect((next) < (woke))
        #expect((RotationSchedule.daily(hour: 9, minute: 0).nextFire(after: woke, calendar: calendar)) == (next.addingTimeInterval(86400)))
    }

    @Test func testEditsDuringDownloadSurvive() async throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        let manifest = try fixture(["a"])
        let entered = Gate(), proceed = Gate()
        let operation = Task {
            try await WallpaperEngine.advanceUsing(store: store, manifest: manifest, scheduled: false,
                fetch: { _ in await entered.open(); await proceed.wait(); return Data() },
                render: { _, _, _ in })
        }
        await entered.wait()
        try store.updateState { $0.favourites.append("a"); $0.blocklist.append("other") }
        await proceed.open()
        _ = try await operation.value
        let result = try store.readState()
        #expect((result.current) == ("a"))
        #expect((result.favourites) == (["a"]))
        #expect((result.blocklist) == (["other"]))
        #expect((result.history.count) == (1))
    }

    @Test func testPauseOrBlockDuringDownloadCancelsBeforeApply() async throws {
        for pause in [true, false] {
            let store = try temporaryStore()
            defer { try? FileManager.default.removeItem(at: store.dir) }
            let manifest = try fixture(["a"])
            do {
                _ = try await WallpaperEngine.advanceUsing(store: store, manifest: manifest, scheduled: false,
                    fetch: { _ in
                        try store.updateState { if pause { $0.paused = true } else { $0.blocklist = ["a"] } }
                        return Data()
                    }, render: { _, _, _ in Issue.record("Superseded request must not touch the desktop") })
                Issue.record("Expected superseded")
            } catch is WallpaperEngine.Superseded { }
            #expect((try store.readState().current) == nil)
        }
    }

    @Test func testPauseDuringRenderSurvivesAndFailedRenderDoesNotConsumeQueue() async throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        let manifest = try fixture(["a"])
        _ = try await WallpaperEngine.advanceUsing(store: store, manifest: manifest, scheduled: false,
            fetch: { _ in Data() }, render: { _, _, _ in try store.updateState { $0.paused = true } })
        #expect(try store.readState().paused)
        let count = try store.readState().history.count
        do {
            _ = try await WallpaperEngine.advanceUsing(store: store, manifest: manifest, scheduled: false,
                fetch: { _ in Data() }, render: { _, _, _ in throw RuntimeError("render failed") })
            Issue.record("Expected render error")
        } catch { }
        #expect((try store.readState().history.count) == (count))
    }

    @Test func testManualNextResumesOnlyTheOriginalPause() async throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        let manifest = try fixture(["a"])
        try store.updateState { $0.paused = true }
        _ = try await WallpaperEngine.advanceUsing(store: store, manifest: manifest, scheduled: false,
            fetch: { _ in Data() }, render: { _, _, _ in })
        #expect(!(try store.readState().paused))
        do {
            _ = try await WallpaperEngine.advanceUsing(store: store, manifest: manifest, scheduled: false,
                fetch: { _ in
                    try store.updateState { $0.paused = true }
                    try store.updateState { $0.paused = false }
                    return Data()
                }, render: { _, _, _ in Issue.record("Pause/resume during download must supersede the old request") })
            Issue.record("Expected superseded")
        } catch is WallpaperEngine.Superseded { }
        #expect(try store.readState().history.count == 1)
    }

    @Test func testConcurrentScheduledRequestsAdvanceOnlyOnce() async throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        let manifest = try fixture()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    do {
                        _ = try await WallpaperEngine.advanceUsing(store: store, manifest: manifest, scheduled: true,
                            fetch: { _ in try await Task.sleep(nanoseconds: 10_000_000); return Data() },
                            render: { _, _, _ in })
                    } catch is WallpaperEngine.Superseded { }
                    catch { Issue.record("\(error)") }
                }
            }
        }
        #expect((try store.readState().history.count) == (1))
    }

    @Test func testUnavailableImageIsSkippedForTheCycle() async throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        let manifest = try fixture()
        var broken: String?
        let work = try await WallpaperEngine.advanceUsing(store: store, manifest: manifest, scheduled: false,
            fetch: { work in
                if broken == nil { broken = work.id }
                if work.id == broken { throw ImageUnavailable(work, "HTTP 404") }
                return Data()
            }, render: { _, _, _ in })
        let state = try store.readState()
        #expect(work.id != broken)
        #expect(state.current == work.id)
        #expect(state.history.map(\.id) == [work.id])
        #expect(!state.queue.contains(broken!))
        #expect(state.queue.count == 1)
    }

    @Test func testAllUnavailableFailsWithoutLooping() async throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        var attempts = 0
        await #expect(throws: ImageUnavailable.self) {
            try await WallpaperEngine.advanceUsing(store: store, manifest: try fixture(["a"]), scheduled: false,
                fetch: { work in attempts += 1; throw ImageUnavailable(work, "HTTP 410") },
                render: { _, _, _ in Issue.record("Nothing to render") })
        }
        #expect(attempts == WallpaperEngine.maxUnavailableSkips)
        #expect(try store.readState().history.isEmpty)
    }
}
