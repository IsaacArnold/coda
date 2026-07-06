import Foundation

public enum DiffChangeKind: String, Equatable { case added, modified, deleted, renamed }
public enum DiffLineKind: Equatable { case context, addition, deletion }

public struct DiffLine: Equatable {
    public let kind: DiffLineKind
    public let text: String
    public init(kind: DiffLineKind, text: String) { self.kind = kind; self.text = text }
}

public struct DiffHunk: Equatable {
    public let header: String
    public let lines: [DiffLine]
    public init(header: String, lines: [DiffLine]) { self.header = header; self.lines = lines }
}

public struct DiffFile: Equatable {
    public let path: String
    public let oldPath: String?
    public let kind: DiffChangeKind
    public let isBinary: Bool
    public let hunks: [DiffHunk]
    public init(path: String, oldPath: String?, kind: DiffChangeKind,
                isBinary: Bool, hunks: [DiffHunk]) {
        self.path = path; self.oldPath = oldPath; self.kind = kind
        self.isBinary = isBinary; self.hunks = hunks
    }
    public var insertions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .addition }.count } }
    public var deletions: Int  { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .deletion  }.count } }
}

public enum DiffRenderLimits { public static let maxLinesPerFile = 2_000 }

public func isLargeDiff(_ file: DiffFile) -> Bool {
    file.hunks.reduce(0) { $0 + $1.lines.count } > DiffRenderLimits.maxLinesPerFile
}

/// Parse `git diff` unified output into files. Tolerant: unrecognised lines are skipped and a
/// malformed input yields whatever files parsed cleanly (possibly none). Never throws.
public func parseUnifiedDiff(_ text: String) -> [DiffFile] {
    var files: [DiffFile] = []

    // Per-file accumulators.
    var headerA: String?          // path from "a/..." on the diff --git line
    var headerB: String?          // path from "b/..." on the diff --git line
    var oldPath: String?          // rename from
    var newPath: String?          // rename to
    var isBinary = false
    var isNew = false
    var isDeleted = false
    var isRename = false
    var hunks: [DiffHunk] = []
    var curHeader: String?
    var curLines: [DiffLine] = []
    var inFile = false

    func flushHunk() {
        if let h = curHeader { hunks.append(DiffHunk(header: h, lines: curLines)) }
        curHeader = nil; curLines = []
    }

    func flushFile() {
        flushHunk()
        guard inFile else { return }
        let path = newPath ?? headerB ?? headerA ?? oldPath ?? ""
        guard !path.isEmpty else { return }
        let kind: DiffChangeKind =
            isRename ? .renamed :
            isNew    ? .added   :
            isDeleted ? .deleted : .modified
        files.append(DiffFile(path: path, oldPath: isRename ? oldPath : nil,
                              kind: kind, isBinary: isBinary, hunks: hunks))
    }

    func resetFile() {
        headerA = nil; headerB = nil; oldPath = nil; newPath = nil
        isBinary = false; isNew = false; isDeleted = false; isRename = false
        hunks = []; curHeader = nil; curLines = []
    }

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        if line.hasPrefix("diff --git ") {
            flushFile(); resetFile(); inFile = true
            // "diff --git a/<A> b/<B>" — split off the a/ and b/ paths.
            let rest = line.dropFirst("diff --git ".count)
            if let bRange = rest.range(of: " b/") {
                headerA = String(rest[rest.startIndex..<bRange.lowerBound]).replacingOccurrences(of: "a/", with: "", options: .anchored)
                headerB = String(rest[bRange.upperBound...])
            }
            continue
        }
        guard inFile else { continue }
        if line.hasPrefix("new file mode") { isNew = true }
        else if line.hasPrefix("deleted file mode") { isDeleted = true }
        else if line.hasPrefix("rename from ") { isRename = true; oldPath = String(line.dropFirst("rename from ".count)) }
        else if line.hasPrefix("rename to ")   { isRename = true; newPath = String(line.dropFirst("rename to ".count)) }
        else if line.hasPrefix("Binary files") { isBinary = true }
        else if line.hasPrefix("--- ") { /* old-file header; path already known */ }
        else if line.hasPrefix("+++ ") { /* new-file header; path already known */ }
        else if line.hasPrefix("@@") {
            flushHunk(); curHeader = line
        } else if curHeader != nil {
            if line.hasPrefix("\\") { continue }               // "\ No newline at end of file"
            if line.hasPrefix("+") { curLines.append(DiffLine(kind: .addition, text: String(line.dropFirst()))) }
            else if line.hasPrefix("-") { curLines.append(DiffLine(kind: .deletion, text: String(line.dropFirst()))) }
            else if line.hasPrefix(" ") { curLines.append(DiffLine(kind: .context, text: String(line.dropFirst()))) }
            // any other line inside a hunk is ignored
        }
    }
    flushFile()
    return files
}
