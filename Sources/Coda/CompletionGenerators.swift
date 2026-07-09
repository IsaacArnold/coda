import Foundation
import CodaCore

/// Resolves the *impure* completion sources — filesystem paths (sync, cheap, bounded) and git
/// branches/remotes (async, cached, throttled) — into `[Candidate]`s that the
/// `CompletionController` merges into the static list before `rankCandidates`.
///
/// **Ownership & threading.** The controller owns exactly one of these and drives it from the main
/// thread. All state (the git caches) is **main-thread-confined**: every read and write of the
/// cache dictionaries and the in-flight sets happens on the main thread. The *only* work that ever
/// leaves the main thread is the `ProcessRunner.run` git spawn on `gitQueue`; its result is hopped
/// back to main before it touches any cache. There is therefore no shared mutable state across
/// threads and no lock is needed.
///
/// **No git storm.** `gitBranches`/`gitRemotes` return the cached value immediately (possibly `[]`
/// on a cold cache) and never spawn git synchronously. A background fetch is kicked only when the
/// cache for that cwd is cold or older than `ttl` AND no fetch is already in flight for it — so
/// rapid typing produces at most one git process per cwd per `ttl`. When a fetch lands it calls
/// `onAsyncUpdate` on the main thread; the controller wires that to a (debounced) `refresh()`,
/// which re-reads the now-fresh cache and — because it is fresh — spawns nothing. The loop is
/// therefore: cold read → spawn → update → refresh → warm read → stop. It converges after one
/// spawn.
final class CompletionGenerators {
    /// Fired on the main thread when an async git fetch has populated the cache. The owner wires
    /// this to `refresh()` so the popup fills in ~instantly after the first cold call.
    var onAsyncUpdate: () -> Void = {}

    /// Matches the `gitPath` the rest of the app uses (`AppDelegate`'s `GitWorktree`).
    private let gitPath = "/usr/bin/git"

    /// Freshness window for git caches. A cache entry younger than this is reused as-is; rapid
    /// typing inside this window reuses cached results instead of respawning git.
    private let ttl: TimeInterval = 5.0

    /// A cached git result for one cwd: the parsed candidates and when they were fetched.
    private struct GitCacheEntry { let candidates: [Candidate]; let timestamp: Date }

    // MARK: Git caches — MAIN-THREAD-CONFINED (see class doc). No lock.
    private var branchCache: [String: GitCacheEntry] = [:]
    private var branchInFlight: Set<String> = []
    private var remoteCache: [String: GitCacheEntry] = [:]
    private var remoteInFlight: Set<String> = []

    /// The one background queue git spawns run on. Serial is fine — dedup already caps concurrency.
    private let gitQueue = DispatchQueue(label: "coda.completions.git", qos: .userInitiated)

    /// Total git subprocess spawns, logged behind `CODA_DEBUG_COMPLETIONS` so the "no git storm"
    /// claim is observable during a manual/live verify.
    private var gitSpawnCount = 0

    // MARK: - Filesystem (sync, bounded, never throws)

    /// Candidates for a path fragment `prefix`, listing one directory:
    /// - absolute (`prefix` starts with `/`),
    /// - `~`-expanded (starts with `~`),
    /// - otherwise `cwd` joined with the fragment's directory portion.
    ///
    /// Splits `prefix` into `(dirPart, namePrefix)` via `splitPathPrefix`, enumerates the resolved
    /// directory, and hands the entries to the pure `CodaCore.filesystemCandidates` for filtering
    /// and shaping (see that function for the hidden-file rule and the `name`/`insertion`
    /// convention). Any failure (unreadable/nonexistent directory) yields `[]` — it never throws.
    func filesystemCandidates(prefix: String, cwd: URL, foldersOnly: Bool) -> [Candidate] {
        let (dirPart, namePrefix) = splitPathPrefix(prefix)
        let dirURL = resolveDirectory(dirPart: dirPart, prefix: prefix, cwd: cwd)

        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }

        let entries = urls.map { url -> DirectoryEntry in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return DirectoryEntry(name: url.lastPathComponent, isDirectory: isDir)
        }
        return CodaCore.filesystemCandidates(
            from: entries, dirPart: dirPart, namePrefix: namePrefix, foldersOnly: foldersOnly
        )
    }

    /// Resolve which directory the fragment refers to. `dirPart` is the portion of `prefix` up to
    /// and including its last `/` (see `splitPathPrefix`).
    private func resolveDirectory(dirPart: String, prefix: String, cwd: URL) -> URL {
        if prefix.hasPrefix("/") {
            return URL(fileURLWithPath: dirPart.isEmpty ? "/" : dirPart)
        }
        if prefix.hasPrefix("~") {
            let path = dirPart.isEmpty ? "~" : dirPart
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return cwd.appendingPathComponent(dirPart)
    }

    // MARK: - Git (async, cached, throttled)

    /// Cached local-branch candidates for `cwd`, kicking a background fetch if cold/stale. Returns
    /// immediately; never spawns git on the calling (main) thread.
    func gitBranches(cwd: URL) -> [Candidate] {
        cachedOrFetch(
            cwd: cwd,
            cache: \.branchCache,
            inFlight: \.branchInFlight,
            gitArgs: ["branch", "--format=%(refname:short)"]
        )
    }

    /// Cached remote-name candidates for `cwd`. `git remote` is as cheap as `git branch`, so it uses
    /// the identical cached/throttled path. (Not exercised by the current seed spec, but wired.)
    func gitRemotes(cwd: URL) -> [Candidate] {
        cachedOrFetch(
            cwd: cwd,
            cache: \.remoteCache,
            inFlight: \.remoteInFlight,
            gitArgs: ["remote"]
        )
    }

    /// The shared cached/throttled/deduped git path. Reads the cache for `cwd.path`; if it is cold
    /// or older than `ttl` and no fetch is in flight for it, marks one in flight and dispatches the
    /// git spawn to `gitQueue`, delivering the parsed result back to the main thread (cache write +
    /// in-flight clear + `onAsyncUpdate`). Returns the currently-cached candidates (or `[]`).
    private func cachedOrFetch(
        cwd: URL,
        cache cacheKeyPath: ReferenceWritableKeyPath<CompletionGenerators, [String: GitCacheEntry]>,
        inFlight inFlightKeyPath: ReferenceWritableKeyPath<CompletionGenerators, Set<String>>,
        gitArgs: [String]
    ) -> [Candidate] {
        let key = cwd.path
        let cached = self[keyPath: cacheKeyPath][key]
        let isFresh = cached.map { Date().timeIntervalSince($0.timestamp) < ttl } ?? false

        if !isFresh && !self[keyPath: inFlightKeyPath].contains(key) {
            self[keyPath: inFlightKeyPath].insert(key)
            gitSpawnCount += 1
            if ProcessInfo.processInfo.environment["CODA_DEBUG_COMPLETIONS"] != nil {
                print("[completions] git spawn #\(gitSpawnCount): git \(gitArgs.joined(separator: " ")) (\(key))")
            }
            gitQueue.async { [weak self] in
                guard let self else { return }
                var candidates: [Candidate] = []
                if let result = try? ProcessRunner.run(self.gitPath, ["-C", key] + gitArgs, cwd: nil),
                   result.exitCode == 0 {
                    candidates = gitNameCandidates(from: result.stdout)
                }
                DispatchQueue.main.async {
                    self[keyPath: cacheKeyPath][key] = GitCacheEntry(candidates: candidates, timestamp: Date())
                    self[keyPath: inFlightKeyPath].remove(key)
                    self.onAsyncUpdate()
                }
            }
        }
        return cached?.candidates ?? []
    }
}
