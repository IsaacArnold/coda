import Foundation

/// Where one running Coda instance keeps its state.
///
/// Exists so a second instance can be launched *alongside* an installed Coda without touching it.
/// Both the settings/worktree directory and the hook socket are otherwise fixed paths, and sharing
/// either is destructive rather than merely confusing: two instances race on `local.json` (last
/// writer wins, so sidebar state can be lost), and `AgentHookSocketServer.start()` deletes any
/// socket it owns before binding — so a second instance silently steals the first one's socket and
/// kills its agent badges.
public struct CodaPaths: Equatable {
    /// Settings, worktree config, themes — `~/.coda` unless overridden.
    public let dataDirectory: URL
    /// The Claude Code hook socket this instance listens on.
    public let hookSocket: URL
    /// Whether `hookSocket` is short enough to bind. `sockaddr_un.sun_path` is 104 bytes on macOS,
    /// and a deep override directory overruns it — reported here so the caller can say so plainly
    /// instead of surfacing an opaque bind failure.
    public let hookSocketFitsInSockaddr: Bool
}

/// The environment variable that isolates an instance. Set it to a (short) directory to get a
/// throwaway Coda that shares nothing with the installed one — intended for debug builds.
public let codaDataDirEnvKey = "CODA_DATA_DIR"

/// macOS `sockaddr_un.sun_path` capacity, including the NUL terminator.
private let sunPathCapacity = 104

/// Resolves this instance's paths. Pure: the caller supplies `home`, the application-support
/// directory and the environment.
///
/// With `CODA_DATA_DIR` unset (or empty) this reproduces the historical layout exactly —
/// `~/.coda` plus `Application Support/Coda/hooks.sock`. When it *is* set, the socket moves inside
/// the override directory too, so a single variable isolates an instance completely; leaving the
/// socket in Application Support would still let a debug build clobber the real one.
public func resolveCodaPaths(home: URL, applicationSupport: URL,
                             environment: [String: String]) -> CodaPaths {
    let defaultDataDir = home.appendingPathComponent(".coda")
    let defaultSocket = applicationSupport.appendingPathComponent("Coda/hooks.sock")

    guard let raw = environment[codaDataDirEnvKey], !raw.isEmpty else {
        return CodaPaths(dataDirectory: defaultDataDir, hookSocket: defaultSocket,
                         hookSocketFitsInSockaddr: fits(defaultSocket))
    }

    let dataDir: URL
    if raw == "~" {
        dataDir = home
    } else if raw.hasPrefix("~/") {
        dataDir = home.appendingPathComponent(String(raw.dropFirst(2)))
    } else {
        dataDir = URL(fileURLWithPath: raw)
    }
    let socket = dataDir.appendingPathComponent("hooks.sock")
    return CodaPaths(dataDirectory: dataDir, hookSocket: socket,
                     hookSocketFitsInSockaddr: fits(socket))
}

private func fits(_ socket: URL) -> Bool {
    socket.path.utf8.count < sunPathCapacity
}
