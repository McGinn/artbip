import Foundation
import Testing
@testable import ArtbipCore

private final class HoldingProtocol: URLProtocol, @unchecked Sendable {
    static var entered = Gate()
    static var stopped = Gate()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { await Self.entered.open() }
        if request.url?.lastPathComponent == "fail" {
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { Task { await Self.stopped.open() } }
}

private final class DelayedImageProtocol: URLProtocol, @unchecked Sendable {
    static var entered = Gate()
    static var finish = Gate()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task {
            await Self.entered.open()
            await Self.finish.wait()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data([1, 2, 3]))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct CacheTests {
    @Test(.timeLimit(.minutes(1))) func clearingDuringDownloadDoesNotRefillCache() async throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        DelayedImageProtocol.entered = Gate()
        DelayedImageProtocol.finish = Gate()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DelayedImageProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let cache = ImageCache(store: store,
            http: Http(cacheDir: store.dir.appendingPathComponent("http"), session: session), budgetMB: 10)
        let work = try fixture(["inflight"]).works[0]
        let request = Task { try await cache.originalData(for: work) }
        await DelayedImageProtocol.entered.wait()
        try await cache.clearDownloads()
        await DelayedImageProtocol.finish.open()
        #expect(try await request.value == Data([1, 2, 3]))
        #expect(await cache.sizeBytes() == 0)
        #expect(!(await cache.hasOriginal(for: work.id)))
        // A new request after clearing may cache the image normally.
        _ = try await cache.originalData(for: work)
        #expect(await cache.hasOriginal(for: work.id))
    }

    @Test func clearDownloadsPreservesPersonalStateAndWallpaper() async throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        let cache = ImageCache(store: store, http: Http(cacheDir: store.dir.appendingPathComponent("http")), budgetMB: 10)
        try store.updateState {
            $0.favourites = ["a"]
            _ = try $0.createCollection(name: "Keep me", workIDs: ["a"])
        }
        try Data([1, 2, 3]).write(to: store.originalsDir.appendingPathComponent("a.img"))
        try Data([4, 5, 6]).write(to: store.thumbsDir.appendingPathComponent("a.jpg"))
        let wallpaper = store.wallpapersDir.appendingPathComponent("current.jpg")
        try Data([7, 8, 9]).write(to: wallpaper)
        let stateBefore = try Data(contentsOf: store.stateURL)
        try await cache.clearDownloads()
        #expect(await cache.sizeBytes() == 0)
        #expect(try Data(contentsOf: store.stateURL) == stateBefore)
        #expect(try Data(contentsOf: wallpaper) == Data([7, 8, 9]))
        try await cache.clearDownloads() // Empty caches are safe to clear again.
    }

    @Test func budgetReductionAndThumbnailAccessOrder() async throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        let http = Http(cacheDir: store.dir.appendingPathComponent("http"))
        let cache = ImageCache(store: store, http: http, budgetMB: 10)
        let original = store.originalsDir.appendingPathComponent("a.img")
        let thumb = store.thumbsDir.appendingPathComponent("b.jpg")
        try Data(repeating: 1, count: 700_000).write(to: original)
        try Data(repeating: 2, count: 700_000).write(to: thumb)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: thumb.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 20)], ofItemAtPath: original.path)
        _ = try await cache.thumbnailData(for: fixture(["b"]).works[0])
        await cache.setBudget(megabytes: 1)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(FileManager.default.fileExists(atPath: thumb.path))
        #expect(await cache.sizeBytes() <= 1_048_576)
        await cache.setBudget(megabytes: 0)
        #expect(await cache.sizeBytes() == 0)
    }

    @Test func localThumbnailWriteEnforcesBudget() async throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        let cache = ImageCache(store: store, http: Http(cacheDir: store.dir.appendingPathComponent("http")), budgetMB: 0)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        try png.write(to: store.originalsDir.appendingPathComponent("a.img"))
        let thumb = try await cache.thumbnailData(for: fixture(["a"]).works[0])
        #expect(!thumb.isEmpty)
        #expect(await cache.sizeBytes() == 0)
    }

    @Test(.timeLimit(.minutes(1))) func prefetchIsNonblockingAndCancellable() async throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.dir) }
        HoldingProtocol.entered = Gate()
        HoldingProtocol.stopped = Gate()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [HoldingProtocol.self]
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        let cache = ImageCache(store: store,
            http: Http(cacheDir: store.dir.appendingPathComponent("http"), session: session), budgetMB: 1)
        await cache.startPrefetch(try fixture(["hold"]).works)
        await HoldingProtocol.entered.wait()
        // This succeeds while the prefetch HTTP request has no response.
        let bytes = Data([1, 2, 3])
        try bytes.write(to: store.originalsDir.appendingPathComponent("cached.img"))
        #expect(try await cache.originalData(for: fixture(["cached"]).works[0]) == bytes)
        await cache.cancelPrefetch()
        await HoldingProtocol.stopped.wait()
        #expect(!(await cache.hasOriginal(for: "hold")))
        await cache.prefetch(try fixture(["fail"]).works)
        #expect(!(await cache.hasOriginal(for: "fail")))
        #expect(try await cache.originalData(for: fixture(["cached"]).works[0]) == bytes)
    }
}
