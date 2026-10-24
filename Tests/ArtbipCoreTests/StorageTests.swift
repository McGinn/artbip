import Foundation
import Testing
@testable import ArtbipCore

struct StorageTests {
    @Test func manifestBundleBeatsStaleAndCorruptCache() throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        let bundle = store.dir.appendingPathComponent("bundled.json")
        try JSONIO.write(try fixture(["new"]), to: bundle)
        try JSONIO.write(try fixture(["old"]), to: store.manifestURL)
        // Suppress the development checkout override without changing process CWD.
        let loaded = try store.loadManifest(bundled: bundle, developmentDirectory: store.dir)
        #expect(loaded.works.map(\.id) == ["new"])
        #expect(try JSONIO.read(Manifest.self, from: store.manifestURL).works.map(\.id) == ["new"])
        try Data("broken".utf8).write(to: store.manifestURL)
        #expect(try store.loadManifest(bundled: bundle, developmentDirectory: store.dir).works.map(\.id) == ["new"])
        let explicit = store.dir.appendingPathComponent("explicit.json")
        try JSONIO.write(try fixture(["explicit"]), to: explicit)
        #expect(try store.loadManifest(explicit: explicit.path, bundled: bundle).works.map(\.id) == ["explicit"])
        let dataDir = store.dir.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try JSONIO.write(try fixture(["dev"]), to: dataDir.appendingPathComponent("manifest.json"))
        #expect(try store.loadManifest(bundled: bundle, developmentDirectory: store.dir).works.map(\.id) == ["dev"])
    }

    @Test func concurrentTransactionsAndPauseGeneration() async throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                group.addTask { try store.updateState { $0.favourites.append("\(i)") } }
            }
            try await group.waitForAll()
        }
        #expect(try store.readState().favourites.count == 40)
        try store.updateState { $0.paused = true }
        try store.updateState { $0.paused = false }
        #expect(try store.readState().pauseGeneration == 2)
        try store.updateSettings { $0.label = false }
        try store.updateSettings { $0.intervalMinutes = 15 }
        #expect(!store.loadSettings().label)
    }

    @Test func lockExcludesAnotherProcess() throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        let lockURL = store.dir.appendingPathComponent("state.lock")
        let lease = try FileLease.acquireSync(lockURL)
        defer { lease.release() }
        func probe() throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", """
            import fcntl,sys
            with open(sys.argv[1], 'a') as f:
                try: fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError: sys.exit(2)
            """, lockURL.path]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        #expect(try probe() == 2)
        lease.release()
        #expect(try probe() == 0)
    }

    @Test func corruptedStateIsNotSilentlyOverwritten() throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        let corrupt = Data("invalid".utf8)
        try corrupt.write(to: store.stateURL)
        #expect(throws: (any Error).self) { try store.updateState { $0.paused = true } }
        #expect(try Data(contentsOf: store.stateURL) == corrupt)
        try FileManager.default.removeItem(at: store.stateURL)
        try FileManager.default.createDirectory(at: store.stateURL, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try store.updateState { $0.paused = true } }
    }

    @Test func diagnosticsBecomeStale() {
        var diagnostics = SchedulerDiagnostics()
        let now = Date()
        diagnostics.observedAt = now
        #expect(diagnostics.isFresh(now: now))
        #expect(!diagnostics.isFresh(now: now.addingTimeInterval(121)))
    }
}
