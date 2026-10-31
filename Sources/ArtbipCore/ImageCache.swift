import Foundation

/// The source no longer serves this work's image: the file was removed or
/// renamed, or a page came back in place of an image. Rotation skips the work
/// and tries it again next cycle. Temporary failures (offline, timeouts, 5xx)
/// are not this error, so they keep retrying the same work.
public struct ImageUnavailable: Error, CustomStringConvertible {
    public let workID: String
    public let title: String
    public let reason: String
    public var description: String { "The image for “\(title)” is not available from its source (\(reason))." }

    init(_ work: ManifestWork, _ reason: String) {
        workID = work.id
        title = work.title
        self.reason = reason
    }

    /// 408 and 429 are the client-side statuses worth retrying.
    static func isPermanent(status: Int) -> Bool {
        (400..<500).contains(status) && status != 408 && status != 429
    }
}

/// Disk cache for full-size originals (and gallery thumbnails), kept under a
/// byte budget with LRU eviction. Files are named by work id; last-use is the
/// file's modification time, touched on every hit — no separate index to drift.
public actor ImageCache {
    private let originalsDir: URL
    private let thumbsDir: URL
    private let http: Http
    private var budgetBytes: Int64
    private var prefetchTask: Task<Void, Never>?
    private var downloadGeneration = 0

    public init(store: RuntimeStore, http: Http, budgetMB: Int) {
        self.originalsDir = store.originalsDir
        self.thumbsDir = store.thumbsDir
        self.http = http
        self.budgetBytes = Int64(max(0, min(budgetMB, 1_000_000))) * 1_048_576
    }

    public func setBudget(megabytes: Int) {
        budgetBytes = Int64(max(0, min(megabytes, 1_000_000))) * 1_048_576
        enforceBudget()
    }

    // MARK: Originals

    public func originalData(for work: ManifestWork) async throws -> Data {
        let file = originalsDir.appendingPathComponent("\(work.id).img")
        if let data = try? Data(contentsOf: file) {
            if Thumbs.imageSize(of: data) != nil {
                touch(file)
                return data
            }
            // A damaged cached file would fail every rotation; fetch it again.
            try? FileManager.default.removeItem(at: file)
        }
        guard let url = URL(string: work.image.url) else { throw ImageUnavailable(work, "bad image URL") }
        // Http's own cache is bypassed — this cache owns eviction.
        let generation = downloadGeneration
        let data = try await download(url, for: work)
        guard Thumbs.imageSize(of: data) != nil else { throw ImageUnavailable(work, "not an image") }
        try Task.checkCancellation()
        guard generation == downloadGeneration else { return data }
        try data.write(to: file, options: .atomic)
        enforceBudget()
        return data
    }

    public func hasOriginal(for id: String) -> Bool {
        FileManager.default.fileExists(atPath: originalsDir.appendingPathComponent("\(id).img").path)
    }

    public func cancelPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    public func startPrefetch(_ works: [ManifestWork], log: (@Sendable (String) -> Void)? = nil) {
        cancelPrefetch()
        prefetchTask = Task { [weak self] in
            await self?.prefetch(works, log: log)
        }
    }

    /// Warm the cache for upcoming works. Failures are logged and skipped —
    /// prefetch must never break rotation.
    public func prefetch(_ works: [ManifestWork], log: (@Sendable (String) -> Void)? = nil) async {
        for work in works where !hasOriginal(for: work.id) {
            guard !Task.isCancelled else { return }
            do {
                _ = try await originalData(for: work)
                log?("prefetched \(work.id)")
            } catch {
                log?("prefetch failed for \(work.id): \(error)")
            }
        }
    }

    // MARK: Thumbnails (gallery browsing)

    public func thumbnailData(for work: ManifestWork, width: Int = 640) async throws -> Data {
        let file = thumbsDir.appendingPathComponent("\(work.id).jpg")
        if let data = try? Data(contentsOf: file) {
            touch(file)
            return data
        }
        // If the full original is already cached, downsample locally instead of
        // hitting the network again.
        if hasOriginal(for: work.id) {
            let original = try Data(contentsOf: originalsDir.appendingPathComponent("\(work.id).img"))
            if let thumb = Thumbs.makeThumbnail(from: original, maxDimension: width) {
                try Task.checkCancellation()
                try thumb.write(to: file, options: .atomic)
                enforceBudget()
                return thumb
            }
        }
        guard let url = work.image.url(width: width) else { throw ImageUnavailable(work, "bad image URL") }
        let generation = downloadGeneration
        let data = try await download(url, for: work)
        // Sources without a size template return the full derivative — shrink
        // before storing so 2,000 thumbs stay a few hundred MB, not gigabytes.
        guard let thumb = Thumbs.makeThumbnail(from: data, maxDimension: width) else {
            throw ImageUnavailable(work, "not an image")
        }
        try Task.checkCancellation()
        guard generation == downloadGeneration else { return thumb }
        try thumb.write(to: file, options: .atomic)
        enforceBudget()
        return thumb
    }

    private func download(_ url: URL, for work: ManifestWork) async throws -> Data {
        do {
            return try await http.get(url, cache: false)
        } catch let error as HttpError where ImageUnavailable.isPermanent(status: error.status) {
            throw ImageUnavailable(work, "HTTP \(error.status)")
        }
    }

    // MARK: Budget

    public func sizeBytes() -> Int64 {
        listFiles().reduce(0) { $0 + $1.size }
    }

    /// Removes only downloaded originals/thumbnails, never personal state or
    /// composed wallpapers. In-flight requests may display but cannot refill
    /// the cache after the user clears it.
    public func clearDownloads() throws {
        cancelPrefetch()
        downloadGeneration += 1
        var firstError: Error?
        for file in listFiles() {
            do { try FileManager.default.removeItem(at: file.url) }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    private struct CachedFile {
        var url: URL
        var size: Int64
        var lastUsed: Date
    }

    private func listFiles() -> [CachedFile] {
        var files: [CachedFile] = []
        for dir in [originalsDir, thumbsDir] {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
            for url in entries {
                let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                files.append(CachedFile(url: url,
                                        size: Int64(vals?.fileSize ?? 0),
                                        lastUsed: vals?.contentModificationDate ?? .distantPast))
            }
        }
        return files
    }

    private func enforceBudget() {
        var files = listFiles().sorted { $0.lastUsed < $1.lastUsed }
        var total = files.reduce(0) { $0 + $1.size }
        while total > budgetBytes, let oldest = files.first {
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
            files.removeFirst()
        }
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }
}
