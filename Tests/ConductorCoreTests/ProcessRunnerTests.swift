import Testing
import Foundation
@testable import ConductorCore

@Test func runCapturesStdoutAndExitZero() throws {
    let r = try ProcessRunner.run("/bin/echo", ["hello world"], cwd: nil)
    #expect(r.stdout == "hello world\n")
    #expect(r.exitCode == 0)
}

@Test func runReportsNonZeroExit() throws {
    let r = try ProcessRunner.run("/bin/sh", ["-c", "exit 3"], cwd: nil)
    #expect(r.exitCode == 3)
}

@Test func runHonorsWorkingDirectory() throws {
    let tmp = NSTemporaryDirectory()
    let r = try ProcessRunner.run("/bin/pwd", [], cwd: tmp)
    #expect(r.stdout.contains(tmp.hasSuffix("/") ? String(tmp.dropLast()) : tmp))
}
