import XCTest
import Foundation
@testable import ConductorCore

final class ProcessRunnerTests: XCTestCase {
    func testRunCapturesStdoutAndExitZero() throws {
        let r = try ProcessRunner.run("/bin/echo", ["hello world"], cwd: nil)
        XCTAssertEqual(r.stdout, "hello world\n")
        XCTAssertEqual(r.exitCode, 0)
    }

    func testRunReportsNonZeroExit() throws {
        let r = try ProcessRunner.run("/bin/sh", ["-c", "exit 3"], cwd: nil)
        XCTAssertEqual(r.exitCode, 3)
    }

    func testRunHonorsWorkingDirectory() throws {
        let tmp = NSTemporaryDirectory()
        let r = try ProcessRunner.run("/bin/pwd", [], cwd: tmp)
        let expected = tmp.hasSuffix("/") ? String(tmp.dropLast()) : tmp
        XCTAssertTrue(r.stdout.contains(expected))
    }

    func testCapturesStderrSeparatelyFromStdout() throws {
        let r = try ProcessRunner.run("/bin/sh", ["-c", "echo out; echo err >&2"], cwd: nil)
        XCTAssertEqual(r.stdout, "out\n")
        XCTAssertEqual(r.stderr, "err\n")
        XCTAssertEqual(r.exitCode, 0)
    }
}
