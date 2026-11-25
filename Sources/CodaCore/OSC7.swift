import Foundation

/// The directory a shell reported via OSC 7, or nil if the payload isn't one.
///
/// The standard payload is `file://<host><percent-encoded path>` (Coda's zsh integration sends
/// exactly that, #84); some tools send a bare absolute path instead. Both are accepted and
/// percent-decoded. The host is ignored — it's always this machine for a local PTY. Parsed by
/// hand rather than via `URL(string:)`, so a sloppy emitter's unencoded space doesn't make the
/// whole cwd silently vanish.
public func directoryPath(fromOSC7 payload: String) -> String? {
    var rest = Substring(payload)
    if rest.lowercased().hasPrefix("file://") {
        rest = rest.dropFirst("file://".count)
        // Skip the authority (host): the path starts at the first "/" after it.
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        rest = rest[slash...]
    }
    guard rest.hasPrefix("/") else { return nil }
    return String(rest).removingPercentEncoding ?? String(rest)
}
