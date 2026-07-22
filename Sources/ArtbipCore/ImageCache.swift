import Foundation

/// Disk cache for full-size originals (and gallery thumbnails), kept under a
/// byte budget with LRU eviction. Files are named by work id; last-use is the
/// file's modification time, touched on every hit — no separate index to drift.
public actor ImageCache {
    private let originalsDir: URL
    private let thumbsDir: URL
    private let http: Http
    private var budgetBytes: Int64

    public init(store: RuntimeStore, http: Http, budgetMB: Int) {
        self.originalsDir = store.originalsDir
        self.thumbsDir = store.thumbsDir
        self.http = http
        self.budgetBytes = Int64(budgetMB) * 1_048_576
    }

    public func setBudget(megabytes: Int) {
        budgetBytes = Int64(megabytes) * 1_048_576
    }

    // MARK: Originals

    public func originalData(for work: ManifestWork) async throws -> Data {
        let file = originalsDir.appendingPathComponent("\(work.id).img")
        if let data = try? Data(contentsOf: file) {
            touch(file)
            return data
        }
        guard let url = URL(string: work.image.url) else {
            throw NSError(domain: "artbip", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "bad image URL for \(work.id)"])
        }
        // Http's own cache is bypassed — this cache owns eviction.
        let data = try await http.get(url, cache: false)
        try data.write(to: file, options: .atomic)
        enforceBudget()
        return data
    }

    public func hasOriginal(for id: String) -> Bool {
        FileManager.default.fileExists(atPath: originalsDir.appendingPathComponent("\(id).img").path)
    }

    /// Warm the cache for upcoming works. Failures are logged and skipped —
    /// prefetch must never break rotation.
    public func prefetch(_ works: [ManifestWork], log: (@Sendable (String) -> Void)? = nil) async {
        for work in works where !hasOriginal(for: work.id) {
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
            return data
        }
        // If the full original is already cached, downsample locally instead of
        // hitting the network again.
        if hasOriginal(for: work.id) {
            let original = try Data(contentsOf: originalsDir.appendingPathComponent("\(work.id).img"))
            if let thumb = Thumbs.makeThumbnail(from: original, maxDimension: width) {
                try? thumb.write(to: file, options: .atomic)
                return thumb
            }
        }
        guard let url = work.image.url(width: width) else {
            throw NSError(domain: "artbip", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "bad image URL for \(work.id)"])
        }
        let data = try await http.get(url, cache: false)
        // Sources without a size template return the full derivative — shrink
        // before storing so 2,000 thumbs stay a few hundred MB, not gigabytes.
        let thumb = Thumbs.makeThumbnail(from: data, maxDimension: width) ?? data
        try thumb.write(to: file, options: .atomic)
        return thumb
    }

    // MARK: Budget

    public func sizeBytes() -> Int64 {
        listFiles().reduce(0) { $0 + $1.size }
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
