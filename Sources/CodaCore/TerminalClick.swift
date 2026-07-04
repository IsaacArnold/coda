import Foundation

/// First web URL on a terminal line, or nil. Recognizes `http://`/`https://` tokens and
/// bare `localhost`/`127.0.0.1` authorities (optionally `:port` and/or `/path`), returning
/// a fully-schemed URL (schemeless localhost forms are prefixed with `http://`). Tokens are
/// split on whitespace and stripped of surrounding quotes/brackets, mirroring how paths are
/// tokenized elsewhere in the click handler.
public func firstWebURL(in line: String) -> URL? {
    for raw in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
        let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'(),[]{}<>"))
        if token.hasPrefix("http://") || token.hasPrefix("https://") {
            if let url = URL(string: token) { return url }
        } else if isLoopbackAuthority(token) {
            if let url = URL(string: "http://" + token) { return url }
        }
    }
    return nil
}

/// True when `token` is `localhost`/`127.0.0.1`, optionally followed by `:` (port) or `/`
/// (path) — but NOT a longer host that merely starts with those letters (e.g. `localhostx`).
private func isLoopbackAuthority(_ token: String) -> Bool {
    for host in ["localhost", "127.0.0.1"] where token.hasPrefix(host) {
        let rest = token.dropFirst(host.count)
        if rest.isEmpty { return true }
        if let first = rest.first, first == ":" || first == "/" { return true }
    }
    return false
}
