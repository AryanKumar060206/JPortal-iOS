import Foundation
import Observation

/// what a screen renders: whatever data we have, how old it is, and whether a
/// refresh is in flight or just failed. data and error can both be set, that's
/// the "offline, showing yesterday's numbers" case.
struct Resource<T> {
    var data: T? = nil
    var fetchedAt: Date? = nil
    var refreshing = false
    var error: Error? = nil
    /// false until the disk cache has been looked at, nothing is worth drawing before that
    var checked = false

    var isEmptyLoading: Bool { data == nil && refreshing }

    func map<R>(_ f: (T) -> R) -> Resource<R> {
        Resource<R>(data: data.map(f), fetchedAt: fetchedAt, refreshing: refreshing, error: error, checked: checked)
    }
}

/// last good response per key, so every screen can paint before the network answers.
/// one small file per key, kept out of backups.
final class Cache: @unchecked Sendable {
    struct Entry {
        let data: Data
        let fetchedAt: Date
    }

    private let dir: URL
    private let lock = NSLock()

    init(name: String = "cache") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        var d = dir
        try? d.setResourceValues(v)
    }

    private func file(_ key: String) -> URL {
        let safe = key.map { c -> String in
            c.isLetter || c.isNumber || c == "_" || c == "-" ? String(c) : String(format: "%%%02X", c.asciiValue ?? 0x5F)
        }.joined()
        return dir.appendingPathComponent(safe + ".json")
    }

    func get(_ key: String) -> Entry? {
        lock.withLock {
            let url = file(key)
            guard let data = try? Data(contentsOf: url),
                  let at = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
            return Entry(data: data, fetchedAt: at)
        }
    }

    func put(_ key: String, _ data: Data, at: Date = Date()) {
        lock.withLock {
            let url = file(key)
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.modificationDate: at], ofItemAtPath: url.path)
        }
    }

    func clear() {
        lock.withLock {
            for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }
}

/// at most n portal calls at once, the portal gets cranky with a dozen in parallel
actor Limiter {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ permits: Int) { self.permits = permits }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { permits += 1 } else { waiters.removeFirst().resume() }
    }
}

/// one cached portal answer. starts from disk, refreshes over the network,
/// never throws the old data away on failure. concurrent refreshes collapse
/// into one request.
@MainActor
@Observable
final class Store<T: Codable & Sendable> {
    private(set) var state = Resource<T>()

    let key: String
    @ObservationIgnored private let maxAge: TimeInterval
    @ObservationIgnored private let fetch: @Sendable (Portal) async throws -> T
    @ObservationIgnored private unowned let repo: Repository
    @ObservationIgnored private let limiter: Limiter
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var inflight: Task<Void, Never>?

    init(key: String, maxAge: TimeInterval, repo: Repository, limiter: Limiter? = nil, fetch: @escaping @Sendable (Portal) async throws -> T) {
        self.key = key
        self.maxAge = maxAge
        self.repo = repo
        self.limiter = limiter ?? repo.limiter
        self.fetch = fetch
    }

    private func loadDisk() async {
        if loaded { return }
        loaded = true
        let cache = repo.cache
        let key = key
        // a marks report or a semester of class lists is a lot of json, decoding it on main drops frames
        let found: (T, Date)? = await Task.detached(priority: .userInitiated) {
            guard let e = cache.get(key), let v = try? JSONDecoder().decode(T.self, from: e.data) else { return nil }
            return (v, e.fetchedAt)
        }.value
        if state.data == nil, let (v, at) = found {
            state.data = v
            state.fetchedAt = at
        }
        state.checked = true
    }

    /// paint from disk, then hit the network if stale or forced
    @discardableResult
    func refresh(force: Bool = false) -> Task<Void, Never> {
        if let t = inflight { return t }
        let t = Task { @MainActor in
            await self.run(force: force)
            self.inflight = nil
        }
        inflight = t
        return t
    }

    private func run(force: Bool) async {
        await loadDisk()
        let age = state.fetchedAt.map { Date().timeIntervalSince($0) }
        if !repo.live() { return }
        if !force, let age, age < maxAge { return }
        state.refreshing = true
        do {
            let value = try await fetchQueued()
            let now = Date()
            let cache = repo.cache
            let key = key
            Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(value) { cache.put(key, data, at: now) }
            }
            state = Resource(data: value, fetchedAt: now, refreshing: false, error: nil, checked: true)
        } catch is CancellationError {
            state.refreshing = false
        } catch {
            DebugLog.record(String(key.split(separator: ":").first ?? ""), error)
            state.refreshing = false
            state.error = error
        }
    }

    /// one portal call through the limiter. a read that times out goes to the back of the queue
    /// for one more try: the portal answers a burst like a first load's class lists slowly, one after
    /// another, and by the time the retry's turn comes round the rush has usually passed
    private func fetchQueued() async throws -> T {
        let fetch = self.fetch
        var attempt = 0
        while true {
            await limiter.acquire()
            do {
                let value = try await repo.sessions.call(fetch)
                await limiter.release()
                return value
            } catch {
                await limiter.release()
                guard attempt == 0, (error as? PortalError)?.timedOut == true, !Task.isCancelled else { throw error }
                DebugLog.note(String(key.split(separator: ":").first ?? ""), "network timeout, trying once more")
                attempt += 1
            }
        }
    }

    /// refreshes (if needed) and hands back what's there once it's done
    func value(force: Bool = false) async -> Resource<T> {
        await refresh(force: force).value
        return state
    }
}
