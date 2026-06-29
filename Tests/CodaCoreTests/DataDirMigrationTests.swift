import XCTest
@testable import CodaCore

final class DataDirMigrationTests: XCTestCase {
    private var root: URL!
    private var fm: FileManager { .default }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("coda-migration-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testMigratesSettingsWhenDestinationEmpty() throws {
        let old = root.appendingPathComponent(".conductor")
        let new = root.appendingPathComponent(".coda")
        try write("prefs", to: old.appendingPathComponent("preferences.json"))
        try write("keys", to: old.appendingPathComponent("keybindings.json"))
        try write("theme", to: old.appendingPathComponent("themes/Dracula.itermcolors"))

        let moved = DataDirMigration.migrateSettings(from: old, to: new, fileManager: fm)

        XCTAssertEqual(Set(moved), ["preferences.json", "keybindings.json", "themes"])
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("preferences.json"), encoding: .utf8), "prefs")
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("keybindings.json"), encoding: .utf8), "keys")
        XCTAssertTrue(fm.fileExists(atPath: new.appendingPathComponent("themes/Dracula.itermcolors").path))
    }

    func testNeverOverwritesExistingDestinationFiles() throws {
        let old = root.appendingPathComponent(".conductor")
        let new = root.appendingPathComponent(".coda")
        try write("OLD", to: old.appendingPathComponent("preferences.json"))
        try write("OLD-keys", to: old.appendingPathComponent("keybindings.json"))
        try write("NEW", to: new.appendingPathComponent("preferences.json"))

        let moved = DataDirMigration.migrateSettings(from: old, to: new, fileManager: fm)

        // preferences.json already existed at destination → left untouched, not reported.
        XCTAssertFalse(moved.contains("preferences.json"))
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("preferences.json"), encoding: .utf8), "NEW")
        XCTAssertTrue(moved.contains("keybindings.json"))
    }

    func testDoesNotMigrateWorktreesOrLocalState() throws {
        let old = root.appendingPathComponent(".conductor")
        let new = root.appendingPathComponent(".coda")
        try write("prefs", to: old.appendingPathComponent("preferences.json"))
        try write("{}", to: old.appendingPathComponent("local.json"))
        try write("wt", to: old.appendingPathComponent("worktrees/repo/branch/.git"))

        _ = DataDirMigration.migrateSettings(from: old, to: new, fileManager: fm)

        XCTAssertFalse(fm.fileExists(atPath: new.appendingPathComponent("local.json").path),
                       "local.json holds absolute paths that can't survive the move — must not migrate")
        XCTAssertFalse(fm.fileExists(atPath: new.appendingPathComponent("worktrees").path),
                       "worktrees are git-linked by absolute path — must not migrate")
    }

    func testNoOpWhenLegacyDirectoryAbsent() throws {
        let old = root.appendingPathComponent(".conductor")
        let new = root.appendingPathComponent(".coda")

        let moved = DataDirMigration.migrateSettings(from: old, to: new, fileManager: fm)

        XCTAssertEqual(moved, [])
        XCTAssertFalse(fm.fileExists(atPath: new.path))
    }

    func testLeavesLegacyOriginalsInPlace() throws {
        // Copy, not move: the legacy dir stays as a backup until the user removes it.
        let old = root.appendingPathComponent(".conductor")
        let new = root.appendingPathComponent(".coda")
        try write("prefs", to: old.appendingPathComponent("preferences.json"))

        _ = DataDirMigration.migrateSettings(from: old, to: new, fileManager: fm)

        XCTAssertTrue(fm.fileExists(atPath: old.appendingPathComponent("preferences.json").path))
    }
}
