import XCTest
@testable import CodaCore

final class CodaPathsTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/example")
    private let appSupport = URL(fileURLWithPath: "/Users/example/Library/Application Support")

    func testDefaultsToDotCodaInTheHomeDirectory() {
        let paths = resolveCodaPaths(home: home, applicationSupport: appSupport, environment: [:])
        XCTAssertEqual(paths.dataDirectory.path, "/Users/example/.coda")
    }

    func testDefaultHookSocketLivesInApplicationSupport() {
        let paths = resolveCodaPaths(home: home, applicationSupport: appSupport, environment: [:])
        XCTAssertEqual(paths.hookSocket.path,
                       "/Users/example/Library/Application Support/Coda/hooks.sock")
    }

    func testDataDirEnvOverridesTheDataDirectory() {
        let paths = resolveCodaPaths(home: home, applicationSupport: appSupport,
                                     environment: ["CODA_DATA_DIR": "/tmp/coda-debug"])
        XCTAssertEqual(paths.dataDirectory.path, "/tmp/coda-debug")
    }

    /// The whole point of the override: a second instance must not be able to delete and rebind the
    /// installed app's socket (`AgentHookSocketServer.start()` does exactly that to clear a stale
    /// one), which would silently kill agent badges in the app the user is actually using.
    func testOverriddenInstanceGetsAnIsolatedHookSocket() {
        let paths = resolveCodaPaths(home: home, applicationSupport: appSupport,
                                     environment: ["CODA_DATA_DIR": "/tmp/coda-debug"])
        XCTAssertEqual(paths.hookSocket.path, "/tmp/coda-debug/hooks.sock")
    }

    func testEmptyOverrideIsTreatedAsUnset() {
        let paths = resolveCodaPaths(home: home, applicationSupport: appSupport,
                                     environment: ["CODA_DATA_DIR": ""])
        XCTAssertEqual(paths.dataDirectory.path, "/Users/example/.coda")
        XCTAssertEqual(paths.hookSocket.path,
                       "/Users/example/Library/Application Support/Coda/hooks.sock")
    }

    func testTildeInOverrideExpandsAgainstHome() {
        let paths = resolveCodaPaths(home: home, applicationSupport: appSupport,
                                     environment: ["CODA_DATA_DIR": "~/coda-debug"])
        XCTAssertEqual(paths.dataDirectory.path, "/Users/example/coda-debug")
    }

    /// macOS caps `sockaddr_un.sun_path` at 104 bytes, so a deep override directory yields a socket
    /// that simply cannot bind. Callers get told at resolve time rather than seeing a mystery
    /// failure from `start()`.
    func testFlagsAnOverrideWhoseSocketPathCannotFitInSockaddrUn() {
        let deep = "/tmp/" + String(repeating: "d", count: 120)
        let paths = resolveCodaPaths(home: home, applicationSupport: appSupport,
                                     environment: ["CODA_DATA_DIR": deep])
        XCTAssertFalse(paths.hookSocketFitsInSockaddr)
    }

    func testAReasonableOverrideFitsInSockaddrUn() {
        let paths = resolveCodaPaths(home: home, applicationSupport: appSupport,
                                     environment: ["CODA_DATA_DIR": "/tmp/coda-debug"])
        XCTAssertTrue(paths.hookSocketFitsInSockaddr)
    }
}
