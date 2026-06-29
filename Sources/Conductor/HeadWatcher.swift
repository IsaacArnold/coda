import Foundation

/// Watches each registered repo's `.git/HEAD` and calls `onChange(repoID)` (on the main queue)
/// when the checked-out branch changes — e.g. an external `git checkout`. git rewrites HEAD via
/// an atomic rename, which invalidates the original file descriptor, so the source re-arms itself
/// on every delete/rename event.
final class HeadWatcher {
    /// Called on the main queue with the repoID whose HEAD changed.
    var onChange: ((String) -> Void)?

    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var paths: [String: String] = [:]
    private let queue = DispatchQueue(label: "conductor.headwatcher")

    /// Start (or restart) watching a repo's HEAD. Call on the main thread.
    func watch(repoID: String, repoPath: String) {
        unwatch(repoID: repoID)
        paths[repoID] = repoPath
        arm(repoID)
    }

    /// Stop watching a repo. Call on the main thread.
    func unwatch(repoID: String) {
        paths[repoID] = nil
        sources[repoID]?.cancel()
        sources[repoID] = nil
    }

    func unwatchAll() {
        for id in Array(paths.keys) { unwatch(repoID: id) }
    }

    private func arm(_ repoID: String) {
        guard let repoPath = paths[repoID] else { return }
        let headPath = (repoPath as NSString).appendingPathComponent(".git/HEAD")
        let fd = open(headPath, O_EVTONLY)
        guard fd >= 0 else { return }   // no .git/HEAD (e.g. a non-git folder): silently skip
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend], queue: queue)
        src.setEventHandler { [weak self] in
            let needsRearm = src.data.contains(.delete) || src.data.contains(.rename)
            DispatchQueue.main.async {
                guard let self, self.paths[repoID] != nil else { return }
                self.onChange?(repoID)
                if needsRearm {
                    // The watched inode was replaced; cancel (closes fd) and re-open the new one.
                    self.sources[repoID]?.cancel()
                    self.sources[repoID] = nil
                    self.arm(repoID)
                }
            }
        }
        src.setCancelHandler { close(fd) }
        sources[repoID] = src
        src.resume()
    }
}
