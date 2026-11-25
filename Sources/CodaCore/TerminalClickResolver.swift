import Foundation

// Pure resolver behind ⌘ + click and the ⌘-hover pointer on terminal text (issue #79).
//
// The terminal view turns the clicked cell into a *logical line* (wrapped screen rows joined,
// see `logicalLine`) plus a character offset, and hands it here together with the directories
// to resolve relative paths against and a filesystem probe. Keeping this free of SwiftTerm and
// the real filesystem is what makes every punctuation/markdown/wrapping case unit-testable.

/// What a path on disk is, as reported by the caller's filesystem probe.
public enum PathKind: Equatable, Sendable { case file, directory }

/// A ⌘-clickable target. iTerm parity: URLs open in the browser, files in the editor
/// (optionally at a line), directories in Finder.
public enum TerminalClickTarget: Equatable, Sendable {
    case url(URL)
    case file(path: String, line: Int?)
    case directory(path: String)
}

/// One screen row as the terminal view sees it: one entry per column, `nil` for the trailing
/// continuation cell of a double-width character, and whether this row is a soft-wrap
/// continuation of the row above.
public struct TerminalRowText: Equatable, Sendable {
    public var cells: [Character?]
    public var continuesPrevious: Bool
    public init(cells: [Character?], continuesPrevious: Bool) {
        self.cells = cells
        self.continuesPrevious = continuesPrevious
    }
}

/// Join the soft-wrapped rows around `row` into one logical line, and map the clicked
/// `column` of `row` to a `Character` offset in it. A continuation cell of a wide character
/// maps to that character. Nil when the row/column is out of range.
public func logicalLine(rows: [TerminalRowText], row: Int, column: Int) -> (text: String, offset: Int)? {
    guard rows.indices.contains(row), rows[row].cells.indices.contains(column) else { return nil }
    var first = row
    while first > 0 && rows[first].continuesPrevious { first -= 1 }
    var last = row
    while last + 1 < rows.count && rows[last + 1].continuesPrevious { last += 1 }

    var chars: [Character] = []
    var offset = 0
    for r in first...last {
        for (c, cell) in rows[r].cells.enumerated() {
            if r == row && c == column { offset = cell == nil ? max(0, chars.count - 1) : chars.count }
            if let ch = cell { chars.append(ch) }
        }
    }
    return (String(chars), offset)
}

/// The target under the character at `offset` in `line`, or nil.
///
/// Only the text *under the click* is considered (never another path elsewhere on the line):
/// 1. a markdown link `[text](target)` spanning the click opens its target;
/// 2. otherwise the token under the click — split on whitespace, `|` and box-drawing table
///    borders — with surrounding quotes/brackets/backticks, `*`/`_`/`~` emphasis markers and
///    trailing sentence punctuation tolerated (the raw token is tried first, so names like
///    `__init__.py` survive);
/// 3. failing that, progressively longer space-joined spans around the click, so paths with
///    spaces (plain or `\ `-escaped) resolve.
/// Paths accept `:line[:col]` suffixes and `~`; relative paths are tried against `baseDirs`
/// in order. `pathKind` reports whether a candidate exists and what it is.
public func resolveClickTarget(line: String, offset: Int, baseDirs: [String],
                               pathKind: (String) -> PathKind?) -> TerminalClickTarget? {
    let chars = Array(line)
    guard chars.indices.contains(offset), !isSeparator(chars[offset]) else { return nil }
    func resolve(_ raw: String) -> TerminalClickTarget? {
        resolveToken(raw, baseDirs: baseDirs, pathKind: pathKind)
    }

    if let target = markdownLinkTarget(in: chars, at: offset), let hit = resolve(target) {
        return hit
    }

    let tokens = spaceSeparatedTokens(around: offset, in: chars)
    guard let clicked = tokens.firstIndex(where: { $0.contains(offset) }) else { return nil }
    if let hit = resolve(String(chars[tokens[clicked]])) { return hit }

    // Spans of 2…n neighbouring tokens that include the clicked one, shortest first.
    for width in 2...max(2, tokens.count) where width <= tokens.count {
        for start in max(0, clicked - width + 1)...min(clicked, tokens.count - width) {
            let span = tokens[start].lowerBound..<tokens[start + width - 1].upperBound
            if let hit = resolve(String(chars[span])) { return hit }
        }
    }
    return nil
}

/// An OSC 8 hyperlink's URI as a click target: `file://` URIs become a file/directory (when
/// it exists), anything else with a scheme opens as a URL.
public func resolveHyperlink(_ link: String, pathKind: (String) -> PathKind?) -> TerminalClickTarget? {
    guard let url = URL(string: link), let scheme = url.scheme?.lowercased() else { return nil }
    guard scheme == "file" else { return .url(url) }
    let path = url.path
    switch path.isEmpty ? nil : pathKind(path) {
    case .file: return .file(path: path, line: nil)
    case .directory: return .directory(path: path)
    case nil: return nil
    }
}

// MARK: - Internals

/// How many neighbouring tokens on each side of the click are joined when looking for a
/// path with spaces. Bounded because the ⌘-hover pointer runs this on every mouse move.
private let maxSpanNeighbours = 3

private func isSeparator(_ c: Character) -> Bool {
    if c == " " || c == "\t" || c == "|" { return true }
    // Box-drawing block (U+2500–U+257F): `│ ─ ┼ …` table borders drawn by TUIs.
    if let s = c.unicodeScalars.first, c.unicodeScalars.count == 1, (0x2500...0x257F).contains(s.value) {
        return true
    }
    return false
}

/// The clicked token plus up to `maxSpanNeighbours` tokens either side that are separated
/// from it only by spaces (a table border or tab ends the run), as ranges into `chars`.
private func spaceSeparatedTokens(around offset: Int, in chars: [Character]) -> [Range<Int>] {
    func token(containing i: Int) -> Range<Int> {
        var s = i, e = i + 1
        while s > 0 && !isSeparator(chars[s - 1]) { s -= 1 }
        while e < chars.count && !isSeparator(chars[e]) { e += 1 }
        return s..<e
    }
    let clicked = token(containing: offset)
    var tokens = [clicked]

    var cursor = clicked.lowerBound
    for _ in 0..<maxSpanNeighbours {
        var gap = cursor
        while gap > 0 && chars[gap - 1] == " " { gap -= 1 }
        guard gap < cursor, gap > 0, !isSeparator(chars[gap - 1]) else { break }
        let t = token(containing: gap - 1)
        tokens.insert(t, at: 0)
        cursor = t.lowerBound
    }
    cursor = clicked.upperBound
    for _ in 0..<maxSpanNeighbours {
        var gap = cursor
        while gap < chars.count && chars[gap] == " " { gap += 1 }
        guard gap > cursor, gap < chars.count, !isSeparator(chars[gap]) else { break }
        let t = token(containing: gap)
        tokens.append(t)
        cursor = t.upperBound
    }
    return tokens
}

/// The `target` of a markdown link `[text](target)` whose extent covers `offset`. An
/// optional `"title"` after the target is dropped, as are `<…>` around it.
private func markdownLinkTarget(in chars: [Character], at offset: Int) -> String? {
    var i = 0
    while i < chars.count {
        guard chars[i] == "[", i <= offset,
              let close = chars[(i + 1)...].firstIndex(of: "]"),
              close + 1 < chars.count, chars[close + 1] == "(",
              let end = chars[(close + 2)...].firstIndex(of: ")") else { i += 1; continue }
        if offset <= end {
            var target = String(chars[(close + 2)..<end]).trimmingCharacters(in: .whitespaces)
            if let space = target.firstIndex(of: " ") { target = String(target[..<space]) }
            if target.hasPrefix("<") && target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
            return target.isEmpty ? nil : target
        }
        i = end + 1
    }
    return nil
}

private let lightTrim = CharacterSet(charactersIn: "\"'`()[]{}<>")
private let leadingNoise = Set<Character>("\"'`([{<*_~")
private let trailingNoise = Set<Character>("\"'`)]}>*_~.,:;!?")

/// Candidate spellings of a raw token, most literal first: as-is, quote/bracket-trimmed,
/// then also emphasis-marker- and sentence-punctuation-trimmed. Each is also tried with
/// `\ ` unescaped to a space.
private func variants(of raw: String) -> [String] {
    var full = Substring(raw)
    while let c = full.first, leadingNoise.contains(c) { full = full.dropFirst() }
    while let c = full.last, trailingNoise.contains(c) { full = full.dropLast() }

    var out: [String] = []
    for v in [raw, raw.trimmingCharacters(in: lightTrim), String(full)] {
        for w in [v, v.replacingOccurrences(of: "\\ ", with: " ")] where !w.isEmpty && !out.contains(w) {
            out.append(w)
        }
    }
    return out
}

private func resolveToken(_ raw: String, baseDirs: [String],
                          pathKind: (String) -> PathKind?) -> TerminalClickTarget? {
    let candidates = variants(of: raw)
    // URLs: judged on the most-trimmed spelling, so `https://x.y/z.` drops the full stop.
    if let token = candidates.last {
        let lower = token.lowercased()
        if lower.hasPrefix("file://") { return resolveHyperlink(token, pathKind: pathKind) }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://")
            || lower.hasPrefix("localhost") || lower.hasPrefix("127.0.0.1"),
           !token.contains(" "), let url = firstWebURL(in: token) {
            return .url(url)
        }
    }
    for token in candidates {
        if let hit = resolvePath(token, baseDirs: baseDirs, pathKind: pathKind) { return hit }
    }
    return nil
}

/// `path`, `path:line` or `path:line:col` → an existing file/directory, else nil.
private func resolvePath(_ token: String, baseDirs: [String],
                         pathKind: (String) -> PathKind?) -> TerminalClickTarget? {
    var parts = token.components(separatedBy: ":")
    var lineNo: Int?
    if parts.count >= 3, Int(parts[parts.count - 1]) != nil, let l = Int(parts[parts.count - 2]) {
        lineNo = l; parts.removeLast(2)
    } else if parts.count >= 2, let l = Int(parts[parts.count - 1]) {
        lineNo = l; parts.removeLast()
    }
    let pathPart = parts.joined(separator: ":")
    guard !pathPart.isEmpty else { return nil }

    let expanded = (pathPart as NSString).expandingTildeInPath
    let candidates = expanded.hasPrefix("/")
        ? [expanded]
        : baseDirs.map { ($0 as NSString).appendingPathComponent(expanded) }
    for candidate in candidates {
        switch pathKind(candidate) {
        case .file: return .file(path: candidate, line: lineNo)
        case .directory: return .directory(path: candidate)
        case nil: continue
        }
    }
    return nil
}
