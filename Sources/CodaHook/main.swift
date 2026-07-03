import Foundation
import CodaCore
#if canImport(Darwin)
import Darwin
#endif

// Security §5: no-op fast if not launched inside a Coda terminal.
let env = ProcessInfo.processInfo.environment
guard let socketPath = env[HookEnv.socketPath],
      let worktreeID = env[HookEnv.worktreeID],
      let surfaceID  = env[HookEnv.surfaceID],
      !socketPath.isEmpty else { exit(0) }

// Read the event JSON Claude Code delivers on stdin (bounded).
let stdinData = FileHandle.standardInput.readDataToEndOfFile()
guard stdinData.count <= 256_000,
      let obj = (try? JSONSerialization.jsonObject(with: stdinData)) as? [String: Any],
      let name = obj["hook_event_name"] as? String,
      let event = HookEventName(rawValue: name) else { exit(0) }
// Copy only what Coda needs onto the wire; do NOT read the transcript here (Security §5).
let message = obj["message"] as? String                 // present on Notification events
let transcriptPath = obj["transcript_path"] as? String  // present on every event

let line = encodeHookMessage(worktreeID: worktreeID, surfaceID: surfaceID,
                             event: event, message: message, transcriptPath: transcriptPath) + "\n"

// Connect to the Unix stream socket with a short send timeout; fail silently+fast.
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }
defer { close(fd) }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
_ = socketPath.withCString { src in
    withUnsafeMutablePointer(to: &addr.sun_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: addr.sun_path)) {
            strncpy($0, src, MemoryLayout.size(ofValue: addr.sun_path) - 1)
        }
    }
}
var tv = timeval(tv_sec: 1, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

let len = socklen_t(MemoryLayout<sockaddr_un>.size)
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
}
guard connected == 0 else { exit(0) }
_ = line.withCString { send(fd, $0, strlen($0), 0) }
exit(0)
