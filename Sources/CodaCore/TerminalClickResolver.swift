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

/// A resolved target plus the `Character` range of the logical line it was read from — the
/// exact text ⌘-hover underlines (#87). Trimmed punctuation/markers are outside the range; a
/// markdown link covers the whole `[text](target)`.
public struct ClickMatch: Equatable, Sendable {
    public var target: TerminalClickTarget
    public var range: Range<Int>
    public init(target: TerminalClickTarget, range: Range<Int>) {
        self.target = target
        self.range = range
    }
}

/// A run of columns on one row, `row` indexing the rows handed to `logicalLine`.
public struct RowColumns: Equatable, Sendable {
    public var row: Int
    public var columns: Range<Int>
    public init(row: Int, columns: Range<Int>) {
        self.row = row
        self.columns = columns
    }
}

/// Soft-wrapped screen rows joined into one line of text, with the clicked cell's `offset`
/// and enough cell bookkeeping to map a character range back to screen columns.
public struct LogicalLine: Equatable, Sendable {
    public var text: String
    public var offset: Int
    /// Per character: its row (index into the input rows), first column, and width in cells.
    var cells: [Cell]

    struct Cell: Equatable, Sendable {
        var row: Int
        var column: Int
        var width: Int
    }

    /// The screen cells covering `range` of `text`, one run per row (a wrapped path spans
    /// several). Double-width characters cover both their cells. Out-of-range parts are dropped.
    public func rowColumns(for range: Range<Int>) -> [RowColumns] {
        let clamped = range.clamped(to: 0..<cells.count)
        var runs: [RowColumns] = []
        for cell in cells[clamped] {
            let end = cell.column + cell.width
            if let last = runs.last, last.row == cell.row, last.columns.upperBound == cell.column {
                runs[runs.count - 1].columns = last.columns.lowerBound..<end
            } else {
                runs.append(RowColumns(row: cell.row, columns: cell.column..<end))
            }
        }
        return runs
    }
}

public func logicalLine(rows: [TerminalRowText], row: Int, column: Int) -> LogicalLine? {
    guard rows.indices.contains(row), rows[row].cells.indices.contains(column) else { return nil }
    var first = row
    while first > 0 && rows[first].continuesPrevious { first -= 1 }
    var last = row
    while last + 1 < rows.count && rows[last + 1].continuesPrevious { last += 1 }

    var chars: [Character] = []
    var cells: [LogicalLine.Cell] = []
    var offset = 0
    for r in first...last {
        for (c, cell) in rows[r].cells.enumerated() {
            if r == row && c == column { offset = cell == nil ? max(0, chars.count - 1) : chars.count }
            if let ch = cell {
                chars.append(ch)
                cells.append(.init(row: r, column: c, width: 1))
            } else if let prev = cells.last, prev.row == r {
                cells[cells.count - 1].width += 1   // continuation cell of a wide character
            }
        }
    }
    return LogicalLine(text: String(chars), offset: offset, cells: cells)
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
    resolveClickMatch(line: line, offset: offset, baseDirs: baseDirs, pathKind: pathKind)?.target
}

/// `resolveClickTarget`, plus the range of `line` the target was read from (see `ClickMatch`).
public func resolveClickMatch(line: String, offset: Int, baseDirs: [String],
                              pathKind: (String) -> PathKind?) -> ClickMatch? {
    let chars = Array(line)
    guard chars.indices.contains(offset), !isSeparator(chars[offset]) else { return nil }
    /// Resolve the text at `span`; on a hit, the range is the spelling that matched.
    func resolve(_ span: Range<Int>) -> ClickMatch? {
        guard let (target, sub) = resolveToken(String(chars[span]), baseDirs: baseDirs, pathKind: pathKind)
        else { return nil }
        return ClickMatch(target: target, range: (span.lowerBound + sub.lowerBound)..<(span.lowerBound + sub.upperBound))
    }

    if let link = markdownLink(in: chars, at: offset),
       let (target, _) = resolveToken(link.target, baseDirs: baseDirs, pathKind: pathKind) {
        return ClickMatch(target: target, range: link.extent)
    }

    let tokens = spaceSeparatedTokens(around: offset, in: chars)
    guard let clicked = tokens.firstIndex(where: { $0.contains(offset) }) else { return nil }
    if let hit = resolve(tokens[clicked]) { return hit }

    // Spans of 2…n neighbouring tokens that include the clicked one, shortest first.
    for width in 2...max(2, tokens.count) where width <= tokens.count {
        for start in max(0, clicked - width + 1)...min(clicked, tokens.count - width) {
            if let hit = resolve(tokens[start].lowerBound..<tokens[start + width - 1].upperBound) { return hit }
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

/// The markdown link `[text](target)` whose extent covers `offset`: its target (an optional
/// `"title"` and `<…>` around it dropped) and the character range of the whole link.
private func markdownLink(in chars: [Character], at offset: Int) -> (target: String, extent: Range<Int>)? {
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
            return target.isEmpty ? nil : (target, i..<(end + 1))
        }
        i = end + 1
    }
    return nil
}

private let lightTrim = Set<Character>("\"'`()[]{}<>")
private let leadingNoise = Set<Character>("\"'`([{<*_~")
private let trailingNoise = Set<Character>("\"'`)]}>*_~.,:;!?")

/// Candidate spellings of a raw token, most literal first — as-is, quote/bracket-trimmed, then
/// also emphasis-marker- and sentence-punctuation-trimmed — each with the `Character` range of
/// `raw` it occupies. Each is also tried with `\ ` unescaped to a space (same range: the escape
/// is still on screen).
private func variants(of raw: String) -> [(text: String, range: Range<Int>)] {
    let chars = Array(raw)
    func trimmed(leading: Set<Character>, trailing: Set<Character>) -> Range<Int> {
        var lo = 0, hi = chars.count
        while lo < hi, leading.contains(chars[lo]) { lo += 1 }
        while hi > lo, trailing.contains(chars[hi - 1]) { hi -= 1 }
        return lo..<hi
    }
    var out: [(text: String, range: Range<Int>)] = []
    for r in [0..<chars.count, trimmed(leading: lightTrim, trailing: lightTrim),
              trimmed(leading: leadingNoise, trailing: trailingNoise)] {
        let v = String(chars[r])
        for w in [v, v.replacingOccurrences(of: "\\ ", with: " ")]
        where !w.isEmpty && !out.contains(where: { $0.text == w }) {
            out.append((w, r))
        }
    }
    return out
}

/// The target `raw` names, with the range of `raw` holding the spelling that matched.
private func resolveToken(_ raw: String, baseDirs: [String],
                          pathKind: (String) -> PathKind?) -> (TerminalClickTarget, Range<Int>)? {
    let candidates = variants(of: raw)
    // URLs: judged on the most-trimmed spelling, so `https://x.y/z.` drops the full stop.
    if let (token, range) = candidates.last {
        let lower = token.lowercased()
        if lower.hasPrefix("file://") {
            return resolveHyperlink(token, pathKind: pathKind).map { ($0, range) }
        }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://")
            || lower.hasPrefix("localhost") || lower.hasPrefix("127.0.0.1"),
           !token.contains(" "), let url = firstWebURL(in: token) {
            return (.url(url), range)
        }
    }
    for (token, range) in candidates {
        if let hit = resolvePath(token, baseDirs: baseDirs, pathKind: pathKind) { return (hit, range) }
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
