import AppKit
import SwiftTerm
import ConductorCore

/// A LocalProcessTerminalView that adds iTerm-style ⌘+click-to-open-file.
///
/// SwiftTerm's built-in link detection only recognizes URLs, so file paths like
/// `Sources/main.swift:12` are handled here: on a ⌘-click we read the clicked line
/// out of the terminal buffer, pull a path-like token from it, resolve it against
/// the worktree dir, and hand it to `onOpenFile` (which routes to the default editor).
final class ClickableTerminalView: LocalProcessTerminalView {
    /// cwd to resolve relative paths against (the worktree directory).
    var fallbackDirectory: String = FileManager.default.currentDirectoryPath
    /// Latest cwd reported by the shell via OSC 7, when available.
    var currentDirectory: String?
    /// Opens a resolved file (absolute path) at an optional line in the default editor.
    var onOpenFile: ((String, Int?) -> Void)?
    /// Fired when this terminal becomes first responder (click or programmatic focus),
    /// so the owning SplitSurface can mark this pane focused.
    var onBecomeFirstResponder: (() -> Void)?
    override var hasFocus: Bool {
        didSet {
            if hasFocus != oldValue, hasFocus { onBecomeFirstResponder?() }
        }
    }

    /// Give a focused terminal first crack at ⌘-combos it owns (clear, line-kill) before
    /// the main menu's key-equivalents see them — otherwise e.g. ⌘⌫ would hit the menu's
    /// "Archive Worktree". AppKit consults a view's `performKeyEquivalent` ahead of the
    /// menu, so consuming the event here (returning true) keeps it out of the menu; passing
    /// through (returning false) lets the menu act, including when another view is focused.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, isFocusedSurface else {
            return super.performKeyEquivalent(with: event)
        }
        let mods = event.modifierFlags
        switch terminalKeyAction(charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                                 command: mods.contains(.command), shift: mods.contains(.shift)) {
        case .clear:
            send(txt: "\u{0c}")          // Ctrl-L: the shell clears the screen and redraws
            return true
        case .deleteToLineStart:
            send(txt: "\u{15}")          // Ctrl-U: kill input line back to the prompt
            return true
        case .passThrough:
            return super.performKeyEquivalent(with: event)
        }
    }

    /// True only for the visible terminal that currently holds keyboard focus — AppKit
    /// calls `performKeyEquivalent` on every view in the window, including hidden surfaces.
    private var isFocusedSurface: Bool {
        guard !isHiddenOrHasHiddenAncestor, let window, window.isKeyWindow,
              let responder = window.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    /// Whether `event`'s location falls inside this (visible) terminal. Used to gate
    /// the app's ⌘+click monitor so it only acts on the focused surface.
    func containsClick(_ event: NSEvent) -> Bool {
        guard !isHiddenOrHasHiddenAncestor, window != nil else { return false }
        return bounds.contains(convert(event.locationInWindow, from: nil))
    }

    /// Called by the app's ⌘+click monitor (SwiftTerm's `mouseDown`/`requestOpenLink`
    /// are `public` but not `open`, so we can't override them). Returns true if it
    /// opened something.
    @discardableResult
    func handleCommandClick(_ event: NSEvent) -> Bool {
        guard containsClick(event) else { return false }
        let point = convert(event.locationInWindow, from: nil)

        let term = getTerminal()
        let cols = term.cols, rows = term.rows
        guard rows > 0, cols > 0, bounds.height > 0 else { return false }

        let cellHeight = bounds.height / CGFloat(rows)
        let yFromTop = isFlipped ? point.y : (bounds.height - point.y)
        let screenRow = max(0, min(rows - 1, Int(yFromTop / cellHeight)))

        // Scan the clicked row plus neighbors: row math is approximate and a path can
        // wrap. Assumes no scrollback offset (screen row == buffer row).
        for dr in [0, -1, 1] {
            let rr = screenRow + dr
            guard rr >= 0, rr < rows else { continue }
            let line = term.getText(start: Position(col: 0, row: rr),
                                    end: Position(col: cols - 1, row: rr))
            if let (path, lineNo) = resolvePath(in: line) {
                onOpenFile?(path, lineNo)
                return true
            }
            if let url = firstURL(in: line) {
                NSWorkspace.shared.open(url)
                return true
            }
        }
        return false
    }

    private var baseDirs: [String] {
        var dirs: [String] = []
        if let cwd = currentDirectory {
            if cwd.hasPrefix("file://"), let u = URL(string: cwd) {
                dirs.append(u.path)
            } else {
                dirs.append((cwd as NSString).removingPercentEncoding ?? cwd)
            }
        }
        dirs.append(fallbackDirectory)
        return dirs
    }

    /// First token on the line that resolves to a file that exists. Supports
    /// `path`, `path:line`, and `path:line:col`.
    private func resolvePath(in line: String) -> (path: String, line: Int?)? {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        for raw in tokens {
            var token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'(),[]{}<>"))
            if let r = token.range(of: "\\") { token = String(token[..<r.lowerBound]) }
            if token.isEmpty { continue }

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
            if token.hasPrefix("http://") || token.hasPrefix("https://"), let url = URL(string: token) {
                return url
            }
        }
        return nil
    }
}
