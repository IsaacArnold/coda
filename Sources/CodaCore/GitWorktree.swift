import Foundation

public struct WorktreeInfo: Equatable {
    public let path: String
    public let branch: String?
}

public enum GitError: Error, CustomStringConvertible {
    case command(String, Int32, String)
    public var description: String {
        switch self { case .command(let c, let code, let err): return "git \(c) failed (\(code)): \(err)" }
    }
}

public struct GitWorktree {
    private let gitPath: String
    public init(gitPath: String) { self.gitPath = gitPath }

    @discardableResult
    private func git(_ repo: String, _ args: [String]) throws -> String {
        let r = try ProcessRunner.run(gitPath, ["-C", repo] + args, cwd: nil)
        guard r.exitCode == 0 else {
            throw GitError.command(args.joined(separator: " "), r.exitCode, r.stderr)
        }
        return r.stdout
    }

    public func currentBranch(repo: String) throws -> String {
        try git(repo, ["rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The branch HEAD points at, via `symbolic-ref`. Unlike `rev-parse --abbrev-ref HEAD`, this
    /// works on an *unborn* branch (a freshly `git init`'d repo with no commits). It throws on a
    /// detached HEAD, where there is no symbolic ref to resolve.
    public func symbolicRef(repo: String) throws -> String {
        try git(repo, ["symbolic-ref", "--short", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The abbreviated SHA of HEAD (used to label a detached-HEAD checkout).
    public func shortHead(repo: String) throws -> String {
        try git(repo, ["rev-parse", "--short", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func add(repo: String, path: String, branch: String, base: String) throws {
        try git(repo, ["worktree", "add", "-b", branch, path, base])
    }

    public func remove(repo: String, path: String) throws {
        try git(repo, ["worktree", "remove", path, "--force"])
    }

    public func deleteBranch(repo: String, branch: String) throws {
        try git(repo, ["branch", "-D", branch])
    }

    /// Parse `git worktree list --porcelain` into (path, branch) pairs.
    public func list(repo: String) throws -> [WorktreeInfo] {
        let out = try git(repo, ["worktree", "list", "--porcelain"])
        var result: [WorktreeInfo] = []
        var currentPath: String?
        var currentBranch: String?
        func flush() {
            if let p = currentPath {
                let resolved = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
                result.append(WorktreeInfo(path: resolved, branch: currentBranch))
            }
            currentPath = nil; currentBranch = nil
        }
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                flush()
                currentPath = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch ") {
                // value like "refs/heads/feature-x"
                let ref = String(line.dropFirst("branch ".count))
                currentBranch = ref.replacingOccurrences(of: "refs/heads/", with: "")
            }
        }
        flush()
        return result
    }

    /// Local branch names, one per line, via `git branch --format=%(refname:short)`.
    /// No `refs/heads/` prefix, no `*` current-branch marker — just names.
    public func localBranches(repo: String) throws -> [String] {
        try git(repo, ["branch", "--format=%(refname:short)"])
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
