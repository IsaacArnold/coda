import AppKit
import SwiftTerm

/// A LocalProcessTerminalView that adds iTerm-style cmd+click-to-open-file.
///
/// SwiftTerm's built-in implicit link detection only recognizes URLs (Ghostty's
/// URL regex), so file paths like `Sources/Spike/main.swift:12` are handled here:
/// on a command-click we read the clicked line out of the public terminal buffer,
/// pull a path-like token from it, resolve it against the shell's cwd, and open it
/// in VS Code at the given line.
final class ClickableTerminalView: LocalProcessTerminalView {

    /// Latest cwd reported by the shell via OSC 7 (see hostCurrentDirectoryUpdate).
    var currentDirectory: String?
    /// Fallback cwd if the shell hasn't reported one (OSC 7 not configured).
    var fallbackDirectory: String = FileManager.default.currentDirectoryPath
    /// Status reporter so clicks show up in the window's status bar.
    var log: ((String) -> Void)?

    /// Called by the app's event monitor on a ⌘+click (SwiftTerm's `mouseDown`
    /// is `public` but not `open`, so we can't override it from outside the module).
    func handleCommandClick(_ event: NSEvent) {
        let term = getTerminal()
        let cols = term.cols
        let rows = term.rows
        guard rows > 0, cols > 0, bounds.height > 0 else { return }

        let point = convert(event.locationInWindow, from: nil)
        let cellHeight = bounds.height / CGFloat(rows)
        let yFromTop = isFlipped ? point.y : (bounds.height - point.y)
        let screenRow = max(0, min(rows - 1, Int(yFromTop / cellHeight)))

        // Scan the clicked row plus its neighbors: row-math from the click point is
        // approximate (SwiftTerm's precise hit-test helpers are internal), and a path
        // can wrap across rows. Assumes no scrollback offset (screen row == buffer row).
        for dr in [0, -1, 1] {
            let rr = screenRow + dr
            guard rr >= 0, rr < rows else { continue }
            let line = term.getText(start: Position(col: 0, row: rr),
                                    end: Position(col: cols - 1, row: rr))
            if dr == 0 {
                log?("cmd+click row \(rr): \"\(line.trimmingCharacters(in: .whitespaces))\"")
            }
            if let (path, lineNo) = resolvePath(in: line) {
                openInEditor(path: path, line: lineNo)
                return
            }
            if let url = firstURL(in: line) {
                NSWorkspace.shared.open(url)
                log?("  → opened URL in browser: \(url.absoluteString)")
                return
            }
        }
        log?("  → no file path or URL found near that row (bases: \(baseDirs))")
    }

    /// Candidate working directories to resolve relative paths against. We try the
    /// OSC 7-reported cwd (normalized — it may arrive as a `file://…` URL) and the
    /// fallback, because either can be wrong/missing.
    private var baseDirs: [String] {
        var dirs: [String] = []
        if let cwd = currentDirectory {
            if cwd.hasPrefix("file://"), let u = URL(string: cwd) {
                dirs.append(u.path)                      // strip file://host
            } else {
                dirs.append((cwd as NSString).removingPercentEncoding ?? cwd)
            }
        }
        dirs.append(fallbackDirectory)
        return dirs
    }

    /// Find the first token on the line that resolves to a file that exists.
    /// Supports `path`, `path:line`, and `path:line:col`.
    private func resolvePath(in line: String) -> (path: String, line: Int?)? {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        for raw in tokens {
            // Trim surrounding punctuation and any stray backslash-escapes (e.g. \n').
            var token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'(),[]{}<>"))
            if let r = token.range(of: "\\") { token = String(token[..<r.lowerBound]) }
            if token.isEmpty { continue }

            // Split optional :line:col suffix.
            let parts = token.split(separator: ":", maxSplits: 2).map(String.init)
            let pathPart = parts[0]
            let lineNo = parts.count > 1 ? Int(parts[1]) : nil

            let expanded = (pathPart as NSString).expandingTildeInPath
            let candidates = expanded.hasPrefix("/")
                ? [expanded]
                : baseDirs.map { ($0 as NSString).appendingPathComponent(expanded) }
            for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
                return (candidate, lineNo)
            }
        }
        return nil
    }

    private func firstURL(in line: String) -> URL? {
        for raw in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'(),[]{}<>"))
            if token.hasPrefix("http://") || token.hasPrefix("https://"),
               let url = URL(string: token) {
                return url
            }
        }
        return nil
    }

    private func openInEditor(path: String, line: Int?) {
        // Exec VS Code's `code` binary directly. We can't rely on LaunchServices
        // (`open` / NSWorkspace) here because a `swift run` executable isn't a real
        // .app bundle, which makes those calls flaky (the source of the earlier -50).
        // VS Code's --goto wants file:line:column; supply column 1 so the line jump lands.
        let target = line.map { "\(path):\($0):1" } ?? path
        log?("  → code --goto \(target)")
        let codeBin = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
        if FileManager.default.isExecutableFile(atPath: codeBin) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: codeBin)
            task.arguments = ["--goto", target]
            do {
                try task.run()
                log?("  → opened in VS Code: \(target)")
                return
            } catch {
                log?("  → code launch failed: \(error)")
            }
        }
        // Fallback: default app for the file type.
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        log?("  → opened \(path) with default app")
    }
}
