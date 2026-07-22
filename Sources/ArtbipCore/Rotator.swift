import Foundation

/// Pure rotation logic over RuntimeState — no I/O, so the CLI daemon and the
/// app drive the same behaviour and it stays trivially testable.
public enum Rotator {
    /// Works allowed in rotation under the current state and settings.
    public static func eligible(_ manifest: Manifest, state: RuntimeState,
                                settings: RuntimeSettings) -> [ManifestWork] {
        let blocked = Set(state.blocklist)
        var works = manifest.works.filter { !blocked.contains($0.id) }
        if settings.favouritesOnly {
            let favs = Set(state.favourites)
            let favWorks = works.filter { favs.contains($0.id) }
            // An empty favourites list would black-screen rotation — fall back.
            if !favWorks.isEmpty { works = favWorks }
        }
        return works
    }

    /// Advance the shuffle bag and return the next work. Every eligible work is
    /// shown once per cycle; the bag reshuffles when empty, avoiding an
    /// immediate repeat of the current work.
    public static func next(manifest: Manifest, state: inout RuntimeState,
                            settings: RuntimeSettings) -> ManifestWork? {
        let works = eligible(manifest, state: state, settings: settings)
        guard !works.isEmpty else { return nil }
        let byId = Dictionary(uniqueKeysWithValues: works.map { ($0.id, $0) })
        let ids = Set(byId.keys)

        // Reconcile the persisted bag with the current eligible set: drop
        // vanished ids, deal newly eligible ones into random positions.
        var queue = state.queue.filter { ids.contains($0) }
        let inQueue = Set(queue)
        for id in ids.subtracting(inQueue).shuffled() {
            queue.insert(id, at: Int.random(in: 0...queue.count))
        }
        if queue.isEmpty {
            queue = ids.shuffled()
            if queue.count > 1, let current = state.current, queue.first == current {
                queue.swapAt(0, Int.random(in: 1..<queue.count))
            }
        }

        let id = queue.removeFirst()
        state.queue = queue
        state.current = id
        state.history.append(HistoryEntry(id: id, shownAt: Date()))
        if state.history.count > 500 {
            state.history.removeFirst(state.history.count - 500)
        }
        return byId[id]
    }

    /// The upcoming works, for prefetch.
    public static func upcoming(manifest: Manifest, state: RuntimeState,
                                settings: RuntimeSettings, count: Int) -> [ManifestWork] {
        let works = eligible(manifest, state: state, settings: settings)
        let byId = Dictionary(uniqueKeysWithValues: works.map { ($0.id, $0) })
        return state.queue.prefix(count).compactMap { byId[$0] }
    }
}
