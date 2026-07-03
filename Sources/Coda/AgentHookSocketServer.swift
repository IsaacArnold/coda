import Foundation
import CodaCore
import Darwin

/// Receives Claude Code hook events over a Unix domain socket and forwards validated ones
/// on the main thread. See spec Security §2–§4.
final class AgentHookSocketServer {
    private let socketURL: URL
    private let isKnownSurface: (String, String) -> Bool
    private let onEvent: (AgentHookEvent) -> Void

    // `acceptLoop()` blocks forever in `accept()`, so it gets its own dedicated queue. Reads are
    // dispatched onto a *different, serial* queue so a blocked/slow client can never starve
    // the accept loop. The queue is serial (not concurrent) so `readClient` — and therefore the
    // supplied `isKnownSurface` closure — is always invoked one-at-a-time, never from multiple
    // threads at once; that keeps no undocumented thread-safety contract on the closure's caller.
    private let acceptQueue = DispatchQueue(label: "coda.hook.socket.accept")
    private let readQueue = DispatchQueue(label: "coda.hook.socket.read")

    // `running`/`listenFD` are written from `start()`/`stop()` (caller thread) and read from
    // `acceptLoop()` (accept-queue thread); guard them with a lock so there's no unsynchronized
    // shared mutable access.
    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false

    var socketPath: String { socketURL.path }

    init(socketURL: URL,
         isKnownSurface: @escaping (String, String) -> Bool,
         onEvent: @escaping (AgentHookEvent) -> Void) {
        self.socketURL = socketURL
        self.isKnownSurface = isKnownSurface
        self.onEvent = onEvent
    }

    func start() throws {
        let dir = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // `attributes:` above only applies when createDirectory actually creates the directory;
        // an already-existing app-support dir keeps whatever perms it had. Enforce 0700
        // unconditionally so Security §2's directory protection holds either way.
        guard chmod(dir.path, 0o700) == 0 else { throw NSError(domain: "coda.hook", code: 5) }
        // Remove a stale socket only if we own it (Security §2).
        if FileManager.default.fileExists(atPath: socketURL.path) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: socketURL.path)
            if (attrs?[.ownerAccountID] as? NSNumber)?.uintValue == UInt(getuid()) {
                try? FileManager.default.removeItem(at: socketURL)
            } else {
                throw NSError(domain: "coda.hook", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "socket path not owned by us"])
            }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "coda.hook", code: 2) }
        stateLock.lock(); listenFD = fd; stateLock.unlock()
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        _ = socketURL.path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: sunPathSize) {
                    strncpy($0, src, sunPathSize - 1)
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else {
            close(fd)
            stateLock.lock(); listenFD = -1; stateLock.unlock()
            throw NSError(domain: "coda.hook", code: 3)
        }
        chmod(socketURL.path, 0o600)               // Security §2
        guard listen(fd, 16) == 0 else {
            close(fd)
            stateLock.lock(); listenFD = -1; stateLock.unlock()
            throw NSError(domain: "coda.hook", code: 4)
        }
        stateLock.lock(); running = true; stateLock.unlock()
        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        stateLock.lock()
        running = false
        let fd = listenFD
        listenFD = -1
        stateLock.unlock()
        if fd >= 0 { close(fd) }
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func isRunning() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    private func currentListenFD() -> Int32 {
        stateLock.lock(); defer { stateLock.unlock() }
        return listenFD
    }

    private func acceptLoop() {
        while isRunning() {
            let fd = currentListenFD()
            guard fd >= 0 else { break }
            let clientFD = accept(fd, nil, nil)
            if clientFD < 0 {
                // Security §4: a persistent accept() error (e.g. EMFILE) must not busy-spin
                // this loop at 100% CPU. A few ms of backoff keeps it well-behaved without
                // meaningfully delaying recovery once the error condition clears.
                if isRunning() { usleep(5_000); continue } else { break }
            }
            // Security §4: bound how long a connected-but-silent client can occupy the read
            // queue. Without this, a client that connects and never sends would block the
            // SERIAL readQueue forever, wedging every subsequent hook event (and therefore
            // every badge update) behind it. A timed-out read() returns -1 and the loop below
            // breaks + closes the fd, same as any other short read.
            var tv = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            // Dispatched onto `readQueue`, NOT `acceptQueue` — reads must never share a serial
            // lane with the accept loop, or a pending/slow read would block future accepts.
            readQueue.async { [weak self] in self?.readClient(clientFD) }
        }
    }

    private func readClient(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        let maxBytes = 128_000
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count < maxBytes {               // Security §4: bounded
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            let room = maxBytes - buffer.count
            buffer.append(contentsOf: chunk[0..<min(n, room)])
            if chunk[0..<n].contains(0x0A) { break }  // got a newline; one message per connection
        }
        guard let text = String(data: buffer, encoding: .utf8) else { return }  // §4 non-UTF-8 → drop
        for raw in text.split(separator: "\n") {
            guard let event = decodeHookMessage(String(raw)),
                  isKnownSurface(event.worktreeID, event.surfaceID) else { continue }  // §3 allowlist
            DispatchQueue.main.async { [weak self] in self?.onEvent(event) }
        }
    }
}
