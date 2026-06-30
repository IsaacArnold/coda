import Foundation

/// Create a throwaway git repo with one commit on branch `main`. Returns its path.
func makeTempRepo() throws -> String {
    let dir = NSTemporaryDirectory() + "coda-test-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    func git(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
    }
    try git(["init", "-b", "main"])
    try git(["config", "user.email", "test@coda.local"])
    try git(["config", "user.name", "Coda Test"])
    try "hello".write(toFile: dir + "/README.md", atomically: true, encoding: .utf8)
    try git(["add", "."])
    try git(["commit", "-m", "init"])
    return dir
}

/// Create a throwaway git repo with NO commits — HEAD points to an unborn branch `master`.
/// Mirrors a freshly `git init`'d project (see the celestial-crater bug). Returns its path.
func makeTempRepoNoCommits() throws -> String {
    let dir = NSTemporaryDirectory() + "coda-test-unborn-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["init", "-b", "master", dir]
    p.standardOutput = Pipe(); p.standardError = Pipe()
    try p.run(); p.waitUntilExit()
    return dir
}
