import XCTest
import Foundation
@testable import ConductorCore

final class FileCopyTests: XCTestCase {
    private func makeDir() throws -> String {
        let d = NSTemporaryDirectory() + "fc-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    func testCopiesExistingFileAndSkipsMissing() throws {
        let src = try makeDir(), dst = try makeDir()
        try "SECRET=1".write(toFile: src + "/.env", atomically: true, encoding: .utf8)
        let copied = try copyAllowlistedFiles(from: src, to: dst, allowlist: [".env", "missing.txt"])
        XCTAssertEqual(copied, [".env"])
        XCTAssertEqual(try String(contentsOfFile: dst + "/.env", encoding: .utf8), "SECRET=1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst + "/missing.txt"))
    }

    func testCopiesNestedPathCreatingParentDirs() throws {
        let src = try makeDir(), dst = try makeDir()
        try FileManager.default.createDirectory(atPath: src + "/apps/web", withIntermediateDirectories: true)
        try "X=1".write(toFile: src + "/apps/web/.env.local", atomically: true, encoding: .utf8)
        let copied = try copyAllowlistedFiles(from: src, to: dst, allowlist: ["apps/web/.env.local"])
        XCTAssertEqual(copied, ["apps/web/.env.local"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst + "/apps/web/.env.local"))
    }

    func testCopiesDirectoryRecursively() throws {
        let src = try makeDir(), dst = try makeDir()
        try FileManager.default.createDirectory(atPath: src + "/config", withIntermediateDirectories: true)
        try "a".write(toFile: src + "/config/a.txt", atomically: true, encoding: .utf8)
        let copied = try copyAllowlistedFiles(from: src, to: dst, allowlist: ["config"])
        XCTAssertEqual(copied, ["config"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst + "/config/a.txt"))
    }
}
