import Foundation
import CodaCore
import Darwin

/// Receives Claude Code hook events over a Unix domain socket and forwards validated ones
/// on the main thread. See spec Security §2–§4.
final class AgentHookSocketServer {
    private let socketURL: URL
    private let isKnownSurface: (String, String) -> Bool
    private let onEvent: (AgentHookEvent) -> Void
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "coda.hook.socket")
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
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw NSError(domain: "coda.hook", code: 2) }
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
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, len) }
        }
        guard bound == 0 else { close(listenFD); throw NSError(domain: "coda.hook", code: 3) }
        chmod(socketURL.path, 0o600)               // Security §2
        guard listen(listenFD, 16) == 0 else { close(listenFD); throw NSError(domain: "coda.hook", code: 4) }
        running = true
        queue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        running = false
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 { if running { continue } else { break } }
            queue.async { [weak self] in self?.readClient(clientFD) }
        }
    }

    private func readClient(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count <= 128_000 {              // Security §4: bounded
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
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
