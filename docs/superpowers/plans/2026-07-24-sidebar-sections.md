# Sidebar Sections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add user-created, collapsible, nameable sidebar sections that repos can be dragged into, letting users group repos however they like.

**Architecture:** Sections are a pure *organizational overlay* on top of the existing `LocalState`. `repositories`/`worktrees` stay the source of truth for what exists; two new fields — `sections: [SidebarSection]` and `rootOrder: [RootRef]` — capture grouping and interleaved top-level ordering. A reconciliation pass guarantees "every repo appears exactly once," making upgrade zero-migration and the layout self-healing. All mutations go through new `WorktreeStore` methods; the `NSOutlineView` grows from two tiers (repo → worktree) to three (section → repo → worktree).

**Tech Stack:** Swift 6, AppKit (`NSOutlineView`), XCTest. Two targets: `CodaCore` (pure model/store, unit-tested) and `Coda` (AppKit UI, verified by build + manual launch).

## Global Constraints

- **macOS 13 floor** — no APIs newer than macOS 13.0 (matches the existing badge/notification code that deliberately avoids macOS-14+ calls).
- **Persistence is centralized** — every state change flows through `WorktreeStore` and is saved to `~/.coda/local.json` via `Config.save`. No other code writes that file.
- **Sections never touch disk** — creating/deleting/renaming/moving sections or repos NEVER runs git or moves files. It is purely Coda-side display metadata (same contract as `moveRepository` and `removeRepository`).
- **Backward compatible** — an old `local.json` with no `sections`/`rootOrder` must decode and render pixel-identically to today. Use `decodeIfPresent` with empty-collection defaults for every new field.
- **Keyboard-shortcut notation in any user-facing text** — space out modifiers, e.g. `⌃ ⌘ N`, never `⌃⌘N`.
- **Build (release toolchain, CommandLineTools):** `DEVELOPER_DIR=$(xcode-select -p) swift build`
- **Tests (full Xcode toolchain, separate build path):** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest` — CommandLineTools has no XCTest; sharing `.build` across the two toolchains triggers a Swift-version module clash.

---

## File Structure

**Modify:**
- `Sources/CodaCore/Models.swift` — add `SidebarSection`, `RootRef`; add `isCollapsed` to `Repository`; add `sections`/`rootOrder` to `LocalState` (all Codable-back-compatible).
- `Sources/CodaCore/WorktreeStore.swift` — new section lifecycle / membership / ordering / collapse mutations; new `sectionNotFound` error case.
- `Sources/CodaCore/Keybindings.swift` — add `.newSection` command.
- `Sources/Coda/SidebarController.swift` — `SectionNode`, three-tier data source, section header cell, collapse honoring + persistence, extended drag grammar, inline rename, section context menu.
- `Sources/Coda/AppDelegate.swift` — wire section closures to the store, switch the sidebar to `buildSidebarTree`, land new repos loose, add the "New Section" menu item.

**Create:**
- `Sources/CodaCore/SidebarLayout.swift` — `SidebarRootItem`, `SectionDisplay`, `ReconciledLayout`, `reconcileSidebarLayout(...)`, `buildSidebarTree(...)` (pure, fully unit-tested).
- `Tests/CodaCoreTests/SidebarLayoutTests.swift` — reconciliation + tree-build tests.

**Extend (tests):**
- `Tests/CodaCoreTests/ModelsCodableTests.swift` — new-field round-trip + old-JSON back-compat.
- `Tests/CodaCoreTests/WorktreeStoreTests.swift` — section CRUD / membership / collapse.
- `Tests/CodaCoreTests/KeybindingsTests.swift` — bump command count; assert `.newSection` chord/category.

---

## Task 1: Model types — `SidebarSection`, `RootRef`, `LocalState` fields, `Repository.isCollapsed`

**Files:**
- Modify: `Sources/CodaCore/Models.swift`
- Modify: `Sources/CodaCore/Config.swift:3-29` (the `LocalState` struct)
- Test: `Tests/CodaCoreTests/ModelsCodableTests.swift`

**Interfaces:**
- Produces:
  - `struct SidebarSection: Codable, Equatable, Identifiable { var id: String; var name: String; var isCollapsed: Bool; var repoIDs: [String] }`
  - `enum RootRef: Codable, Equatable { case section(String); case repo(String) }` — serialized as a single string `"section:<id>"` / `"repo:<id>"`.
  - `Repository.isCollapsed: Bool` (default `false`)
  - `LocalState.sections: [SidebarSection]` and `LocalState.rootOrder: [RootRef]` (both default `[]`)

- [ ] **Step 1: Write the failing tests** — append to `Tests/CodaCoreTests/ModelsCodableTests.swift` (inside the existing `final class ModelsCodableTests`):

```swift
    // MARK: - Sidebar sections (Task 1)

    func testRepositoryDecodesOldJSONWithoutIsCollapsed() throws {
        let json = #"{"id":"r1","path":"/tmp/repo","name":"repo"}"#
        let repo = try JSONDecoder().decode(Repository.self, from: Data(json.utf8))
        XCTAssertFalse(repo.isCollapsed)
    }

    func testRepositoryRoundTripsIsCollapsed() throws {
        var repo = Repository(id: "r1", path: "/tmp/repo", name: "repo")
        repo.isCollapsed = true
        let back = try JSONDecoder().decode(Repository.self, from: JSONEncoder().encode(repo))
        XCTAssertTrue(back.isCollapsed)
        XCTAssertEqual(back, repo)
    }

    func testSidebarSectionRoundTrips() throws {
        let s = SidebarSection(id: "s1", name: "Work", isCollapsed: true, repoIDs: ["r1", "r2"])
        let back = try JSONDecoder().decode(SidebarSection.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testRootRefSerializesAsTaggedString() throws {
        let data = try JSONEncoder().encode([RootRef.section("s1"), RootRef.repo("r9")])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("section:s1"))
        XCTAssertTrue(text.contains("repo:r9"))
        let back = try JSONDecoder().decode([RootRef].self, from: data)
        XCTAssertEqual(back, [.section("s1"), .repo("r9")])
    }

    func testLocalStateDecodesOldJSONWithoutSections() throws {
        let json = #"{"repositories":[{"id":"r1","path":"/tmp/r","name":"r"}],"worktrees":[]}"#
        let state = try JSONDecoder().decode(LocalState.self, from: Data(json.utf8))
        XCTAssertTrue(state.sections.isEmpty)
        XCTAssertTrue(state.rootOrder.isEmpty)
        XCTAssertEqual(state.repositories.count, 1)
    }

    func testLocalStateRoundTripsSectionsAndRootOrder() throws {
        var state = LocalState(repositories: [Repository(id: "r1", path: "/tmp/r", name: "r")],
                               worktrees: [])
        state.sections = [SidebarSection(id: "s1", name: "Work", isCollapsed: false, repoIDs: ["r1"])]
        state.rootOrder = [.section("s1")]
        let back = try JSONDecoder().decode(LocalState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back.sections, state.sections)
        XCTAssertEqual(back.rootOrder, state.rootOrder)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter ModelsCodableTests`
Expected: FAIL to compile — `cannot find 'SidebarSection'`, `cannot find 'RootRef'`, `value of type 'Repository' has no member 'isCollapsed'`, etc.

- [ ] **Step 3: Add `SidebarSection` and `RootRef` to `Models.swift`**

Append to the end of `Sources/CodaCore/Models.swift`:

```swift
/// A user-created sidebar group holding an ordered list of repo ids. Purely
/// organizational display metadata — never affects git or on-disk state.
public struct SidebarSection: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var isCollapsed: Bool
    public var repoIDs: [String]

    public init(id: String, name: String, isCollapsed: Bool = false, repoIDs: [String] = []) {
        self.id = id; self.name = name; self.isCollapsed = isCollapsed; self.repoIDs = repoIDs
    }
}

/// One entry in the interleaved top-level sidebar order: either a section or a
/// loose (ungrouped) repo. Serialized as a tagged string ("section:<id>" /
/// "repo:<id>") so the pretty-printed local.json stays human-readable.
public enum RootRef: Codable, Equatable {
    case section(String)
    case repo(String)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let id = raw.dropPrefixIfPresent("section:") { self = .section(id) }
        else if let id = raw.dropPrefixIfPresent("repo:") { self = .repo(id) }
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Unrecognized RootRef: \(raw)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .section(let id): try c.encode("section:\(id)")
        case .repo(let id):    try c.encode("repo:\(id)")
        }
    }
}

private extension String {
    /// Returns the remainder after `prefix` if `self` starts with it, else nil.
    func dropPrefixIfPresent(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
```

- [ ] **Step 4: Add `isCollapsed` to `Repository` in `Models.swift`**

Make three edits to the `Repository` struct:

1. Add the stored property after `color` (after line 15):
```swift
    /// Sidebar expand/collapse state; persisted so a collapsed repo stays collapsed
    /// across reloads. Default false (expanded), matching prior always-expanded behavior.
    public var isCollapsed: Bool
```

2. Extend the `init` — add a parameter and assignment. Replace the existing initializer signature/body (lines 17-25) with:
```swift
    public init(id: String, path: String, name: String,
                setupScript: String = "", copyAllowlist: [String] = [],
                autoLaunchClaude: Bool = false,
                displayName: String? = nil, color: String? = nil,
                isCollapsed: Bool = false) {
        self.id = id; self.path = path; self.name = name
        self.setupScript = setupScript; self.copyAllowlist = copyAllowlist
        self.autoLaunchClaude = autoLaunchClaude
        self.displayName = displayName; self.color = color
        self.isCollapsed = isCollapsed
    }
```

3. Add `isCollapsed` to `CodingKeys` (line 27) and decode it back-compatibly in `init(from:)` (after the `color` decode, line 39):
```swift
    private enum CodingKeys: String, CodingKey { case id, path, name, setupScript, copyAllowlist, autoLaunchClaude, displayName, color, isCollapsed }
```
```swift
        isCollapsed = try c.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
```

- [ ] **Step 5: Add `sections` and `rootOrder` to `LocalState` in `Config.swift`**

Edit `Sources/CodaCore/Config.swift`. Replace the `LocalState` struct (lines 3-29) with:

```swift
public struct LocalState: Codable, Equatable {
    public var repositories: [Repository]
    public var worktrees: [Worktree]
    /// User-created sidebar groups (Task 1). Empty for pre-sections configs.
    public var sections: [SidebarSection]
    /// Interleaved top-level order of sections and loose repos (Task 1). Empty
    /// for pre-sections configs — reconciliation then appends every repo as loose.
    public var rootOrder: [RootRef]

    public init(repositories: [Repository], worktrees: [Worktree],
                sections: [SidebarSection] = [], rootOrder: [RootRef] = []) {
        self.repositories = repositories; self.worktrees = worktrees
        self.sections = sections; self.rootOrder = rootOrder
    }

    private enum CodingKeys: String, CodingKey { case repositories, worktrees, sessions, sections, rootOrder }

    // Custom decode so configs written before the Session→Worktree rename
    // (which used the "sessions" key) — and before sidebar sections — still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repositories = try c.decodeIfPresent([Repository].self, forKey: .repositories) ?? []
        if let wt = try c.decodeIfPresent([Worktree].self, forKey: .worktrees) {
            worktrees = wt
        } else {
            worktrees = try c.decodeIfPresent([Worktree].self, forKey: .sessions) ?? []
        }
        sections = try c.decodeIfPresent([SidebarSection].self, forKey: .sections) ?? []
        rootOrder = try c.decodeIfPresent([RootRef].self, forKey: .rootOrder) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(repositories, forKey: .repositories)
        try c.encode(worktrees, forKey: .worktrees)
        try c.encode(sections, forKey: .sections)
        try c.encode(rootOrder, forKey: .rootOrder)
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter ModelsCodableTests`
Expected: PASS (all `ModelsCodableTests`, old and new).

- [ ] **Step 7: Commit**

```bash
git add Sources/CodaCore/Models.swift Sources/CodaCore/Config.swift Tests/CodaCoreTests/ModelsCodableTests.swift
git commit -m "feat(sidebar): add SidebarSection/RootRef models + LocalState overlay fields"
```

---

## Task 2: Reconciliation — `reconcileSidebarLayout`

Guarantees the core invariant "every existing repo appears exactly once (loose OR in exactly one section), and every section appears exactly once at root," while dropping dangling ids. This is what makes upgrades zero-migration and the layout self-healing.

**Files:**
- Create: `Sources/CodaCore/SidebarLayout.swift`
- Create: `Tests/CodaCoreTests/SidebarLayoutTests.swift`

**Interfaces:**
- Consumes: `Repository`, `SidebarSection`, `RootRef` (Task 1).
- Produces:
  - `struct ReconciledLayout: Equatable { var sections: [SidebarSection]; var rootOrder: [RootRef] }`
  - `func reconcileSidebarLayout(repositories: [Repository], sections: [SidebarSection], rootOrder: [RootRef]) -> ReconciledLayout`

- [ ] **Step 1: Write the failing tests** — create `Tests/CodaCoreTests/SidebarLayoutTests.swift`:

```swift
import XCTest
@testable import CodaCore

final class SidebarLayoutTests: XCTestCase {
    private func repo(_ id: String) -> Repository {
        Repository(id: id, path: "/tmp/\(id)", name: id)
    }

    // MARK: reconcileSidebarLayout

    func testFreshUpgradeAppendsAllReposLooseInOrder() {
        // No sections, empty rootOrder → every repo becomes a loose .repo ref in array order.
        let r = reconcileSidebarLayout(repositories: [repo("r1"), repo("r2"), repo("r3")],
                                       sections: [], rootOrder: [])
        XCTAssertEqual(r.rootOrder, [.repo("r1"), .repo("r2"), .repo("r3")])
        XCTAssertTrue(r.sections.isEmpty)
    }

    func testRepoInSectionIsNotAlsoLoose() {
        let sections = [SidebarSection(id: "s1", name: "Work", repoIDs: ["r1"])]
        let r = reconcileSidebarLayout(repositories: [repo("r1"), repo("r2")],
                                       sections: sections,
                                       rootOrder: [.section("s1")])
        // r1 lives in s1; only r2 is appended loose. s1 stays at root, r2 after it.
        XCTAssertEqual(r.rootOrder, [.section("s1"), .repo("r2")])
        XCTAssertEqual(r.sections.first?.repoIDs, ["r1"])
    }

    func testDanglingRepoIDsAreDroppedFromSections() {
        let sections = [SidebarSection(id: "s1", name: "Work", repoIDs: ["r1", "gone"])]
        let r = reconcileSidebarLayout(repositories: [repo("r1")],
                                       sections: sections, rootOrder: [.section("s1")])
        XCTAssertEqual(r.sections.first?.repoIDs, ["r1"])
    }

    func testDanglingRootRefsAreDropped() {
        // rootOrder references a missing section and a missing repo.
        let r = reconcileSidebarLayout(repositories: [repo("r1")],
                                       sections: [],
                                       rootOrder: [.section("ghost"), .repo("missing"), .repo("r1")])
        XCTAssertEqual(r.rootOrder, [.repo("r1")])
    }

    func testRepoClaimedByFirstSectionWhenListedInTwo() {
        let sections = [
            SidebarSection(id: "s1", name: "A", repoIDs: ["r1"]),
            SidebarSection(id: "s2", name: "B", repoIDs: ["r1"]),
        ]
        let r = reconcileSidebarLayout(repositories: [repo("r1")],
                                       sections: sections,
                                       rootOrder: [.section("s1"), .section("s2")])
        XCTAssertEqual(r.sections.first(where: { $0.id == "s1" })?.repoIDs, ["r1"])
        XCTAssertEqual(r.sections.first(where: { $0.id == "s2" })?.repoIDs, [])
    }

    func testUnreferencedSectionAppendedAtRoot() {
        let sections = [SidebarSection(id: "s1", name: "Orphan", repoIDs: [])]
        let r = reconcileSidebarLayout(repositories: [repo("r1")],
                                       sections: sections, rootOrder: [.repo("r1")])
        XCTAssertEqual(r.rootOrder, [.repo("r1"), .section("s1")])
    }

    func testInterleavedOrderPreserved() {
        let sections = [SidebarSection(id: "s1", name: "Work", repoIDs: ["r2"])]
        let r = reconcileSidebarLayout(repositories: [repo("r1"), repo("r2"), repo("r3")],
                                       sections: sections,
                                       rootOrder: [.repo("r1"), .section("s1"), .repo("r3")])
        XCTAssertEqual(r.rootOrder, [.repo("r1"), .section("s1"), .repo("r3")])
    }

    func testDuplicateRootRefsCollapseToFirst() {
        let r = reconcileSidebarLayout(repositories: [repo("r1")],
                                       sections: [],
                                       rootOrder: [.repo("r1"), .repo("r1")])
        XCTAssertEqual(r.rootOrder, [.repo("r1")])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter SidebarLayoutTests`
Expected: FAIL to compile — `cannot find 'reconcileSidebarLayout'`.

- [ ] **Step 3: Implement `reconcileSidebarLayout`** — create `Sources/CodaCore/SidebarLayout.swift`:

```swift
import Foundation

/// The cleaned, invariant-satisfying sidebar layout (Task 2).
public struct ReconciledLayout: Equatable {
    public var sections: [SidebarSection]
    public var rootOrder: [RootRef]
    public init(sections: [SidebarSection], rootOrder: [RootRef]) {
        self.sections = sections; self.rootOrder = rootOrder
    }
}

/// Clean a persisted (sections, rootOrder) overlay against the set of repos that
/// actually exist, enforcing: every existing repo appears exactly once (loose OR
/// in one section), every section appears exactly once at root, and no ref points
/// at a missing id. Unreferenced repos/sections are appended deterministically
/// (repos in `repositories` array order), which reproduces today's exact layout
/// for a pre-sections config (empty sections + empty rootOrder).
public func reconcileSidebarLayout(repositories: [Repository],
                                   sections: [SidebarSection],
                                   rootOrder: [RootRef]) -> ReconciledLayout {
    let existingRepoIDs = Set(repositories.map { $0.id })

    // 1. Clean section membership: keep only existing, not-yet-claimed repo ids
    //    (first section listing a repo wins), preserving each section's order.
    var claimed = Set<String>()
    let cleanSections: [SidebarSection] = sections.map { section in
        var kept: [String] = []
        for id in section.repoIDs where existingRepoIDs.contains(id) && !claimed.contains(id) {
            kept.append(id); claimed.insert(id)
        }
        var copy = section
        copy.repoIDs = kept
        return copy
    }
    let sectionIDs = Set(cleanSections.map { $0.id })

    // 2. Rebuild rootOrder: keep valid, first-seen refs; a repo claimed by a
    //    section can't also be loose.
    var seenSections = Set<String>()
    var seenLoose = Set<String>()
    var cleanRoot: [RootRef] = []
    for ref in rootOrder {
        switch ref {
        case .section(let id):
            if sectionIDs.contains(id), !seenSections.contains(id) {
                cleanRoot.append(ref); seenSections.insert(id)
            }
        case .repo(let id):
            if existingRepoIDs.contains(id), !claimed.contains(id), !seenLoose.contains(id) {
                cleanRoot.append(ref); seenLoose.insert(id)
            }
        }
    }

    // 3. Append any section not referenced at root (in sections array order).
    for section in cleanSections where !seenSections.contains(section.id) {
        cleanRoot.append(.section(section.id))
    }

    // 4. Append any repo neither claimed by a section nor already loose,
    //    in repositories array order (deterministic; matches pre-sections order).
    for repo in repositories where !claimed.contains(repo.id) && !seenLoose.contains(repo.id) {
        cleanRoot.append(.repo(repo.id))
    }

    return ReconciledLayout(sections: cleanSections, rootOrder: cleanRoot)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter SidebarLayoutTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodaCore/SidebarLayout.swift Tests/CodaCoreTests/SidebarLayoutTests.swift
git commit -m "feat(sidebar): add reconcileSidebarLayout invariant pass"
```

---

## Task 3: Display tree — `buildSidebarTree`

Turns the reconciled overlay + worktrees into the ordered tree the outline renders. This is the pure value the UI walks, so it carries the ordering/grouping tests instead of the (untestable) `NSOutlineView`.

**Files:**
- Modify: `Sources/CodaCore/SidebarLayout.swift`
- Modify: `Tests/CodaCoreTests/SidebarLayoutTests.swift`

**Interfaces:**
- Consumes: `reconcileSidebarLayout` (Task 2); `RepositorySection` and the main-checkout logic from `WorktreeGrouping.swift:4,27`; `Worktree.mainCheckout(for:branch:)` (`Models.swift:94`).
- Produces:
  - `struct SectionDisplay: Equatable { let section: SidebarSection; let repos: [RepositorySection] }`
  - `enum SidebarRootItem: Equatable { case section(SectionDisplay); case repo(RepositorySection) }`
  - `func buildSidebarTree(repositories: [Repository], worktrees: [Worktree], sections: [SidebarSection], rootOrder: [RootRef], branchForRepo: [String: String]) -> [SidebarRootItem]`

- [ ] **Step 1: Write the failing tests** — append to `SidebarLayoutTests.swift`:

```swift
    // MARK: buildSidebarTree

    private func wt(_ id: String, _ repoID: String) -> Worktree {
        Worktree(id: id, repoID: repoID, title: id, branch: id, worktreePath: "/tmp/wt/\(id)")
    }

    func testTreeGroupsReposUnderSectionsAndKeepsLooseReposAtRoot() {
        let repos = [repo("r1"), repo("r2"), repo("r3")]
        let sections = [SidebarSection(id: "s1", name: "Work", repoIDs: ["r1", "r2"])]
        let tree = buildSidebarTree(repositories: repos, worktrees: [],
                                    sections: sections,
                                    rootOrder: [.section("s1"), .repo("r3")],
                                    branchForRepo: ["r1": "main", "r2": "main", "r3": "main"])
        guard case let .section(sd) = tree[0] else { return XCTFail("expected section first") }
        XCTAssertEqual(sd.section.name, "Work")
        XCTAssertEqual(sd.repos.map { $0.repository.id }, ["r1", "r2"])
        guard case let .repo(rs) = tree[1] else { return XCTFail("expected loose repo second") }
        XCTAssertEqual(rs.repository.id, "r3")
    }

    func testTreeReposCarryMainCheckoutFirst() {
        let tree = buildSidebarTree(repositories: [repo("r1")], worktrees: [wt("w1", "r1")],
                                    sections: [], rootOrder: [.repo("r1")],
                                    branchForRepo: ["r1": "main"])
        guard case let .repo(rs) = tree[0] else { return XCTFail() }
        XCTAssertEqual(rs.worktrees.map { $0.id }, ["r1#main", "w1"])
        XCTAssertTrue(rs.worktrees[0].isMain)
        XCTAssertEqual(rs.worktrees[0].branch, "main")
    }

    func testTreeReconcilesUnreferencedRepoAsLoose() {
        // r2 exists but is referenced nowhere → appears loose at the end.
        let tree = buildSidebarTree(repositories: [repo("r1"), repo("r2")], worktrees: [],
                                    sections: [], rootOrder: [.repo("r1")],
                                    branchForRepo: [:])
        XCTAssertEqual(tree.count, 2)
        guard case let .repo(rs) = tree[1] else { return XCTFail() }
        XCTAssertEqual(rs.repository.id, "r2")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter SidebarLayoutTests`
Expected: FAIL to compile — `cannot find 'buildSidebarTree'`.

- [ ] **Step 3: Implement `buildSidebarTree`** — append to `Sources/CodaCore/SidebarLayout.swift`:

```swift
/// A section together with the display sections of the repos it contains.
public struct SectionDisplay: Equatable {
    public let section: SidebarSection
    public let repos: [RepositorySection]
    public init(section: SidebarSection, repos: [RepositorySection]) {
        self.section = section; self.repos = repos
    }
}

/// One top-level row group: a section (with its repos) or a loose repo.
public enum SidebarRootItem: Equatable {
    case section(SectionDisplay)
    case repo(RepositorySection)
}

/// Build the ordered three-tier sidebar tree (section → repo → worktree). Runs
/// reconciliation first so the result always satisfies the exactly-once invariant.
/// Each repo carries its synthesized main-checkout row first, then its real worktrees.
public func buildSidebarTree(repositories: [Repository],
                             worktrees: [Worktree],
                             sections: [SidebarSection],
                             rootOrder: [RootRef],
                             branchForRepo: [String: String]) -> [SidebarRootItem] {
    let layout = reconcileSidebarLayout(repositories: repositories,
                                        sections: sections, rootOrder: rootOrder)
    let repoByID = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0) })
    let sectionByID = Dictionary(uniqueKeysWithValues: layout.sections.map { ($0.id, $0) })

    func repoSection(_ repo: Repository) -> RepositorySection {
        let main = Worktree.mainCheckout(for: repo, branch: branchForRepo[repo.id] ?? "")
        let real = worktrees.filter { $0.repoID == repo.id }
        return RepositorySection(repository: repo, worktrees: [main] + real)
    }

    return layout.rootOrder.compactMap { ref in
        switch ref {
        case .repo(let id):
            return repoByID[id].map { .repo(repoSection($0)) }
        case .section(let id):
            guard let section = sectionByID[id] else { return nil }
            let repos = section.repoIDs.compactMap { repoByID[$0].map(repoSection) }
            return .section(SectionDisplay(section: section, repos: repos))
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter SidebarLayoutTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodaCore/SidebarLayout.swift Tests/CodaCoreTests/SidebarLayoutTests.swift
git commit -m "feat(sidebar): add buildSidebarTree three-tier display builder"
```

---

## Task 4: Store — section lifecycle + collapse setters

**Files:**
- Modify: `Sources/CodaCore/WorktreeStore.swift`
- Test: `Tests/CodaCoreTests/WorktreeStoreTests.swift`

**Interfaces:**
- Consumes: `WorktreeStore` (`WorktreeStore.swift:14`), `SidebarSection`, `RootRef` (Task 1). Note `store.addRepository(path:)` needs no real git repo (it only dedupes by path, derives the name, appends), so tests can pass arbitrary `/tmp/...` paths.
- Produces (all `throws`, all persist via `config.save(state)`, all `@discardableResult` where they return state):
  - `func createSection(name: String) throws -> SidebarSection`
  - `func renameSection(id: String, name: String) throws -> SidebarSection`
  - `func deleteSection(id: String) throws`
  - `func setSectionCollapsed(id: String, collapsed: Bool) throws`
  - `func setRepositoryCollapsed(id: String, collapsed: Bool) throws`
  - new error case `WorktreeStoreError.sectionNotFound(String)`

- [ ] **Step 1: Write the failing tests** — append to `WorktreeStoreTests.swift`:

```swift
    // MARK: - Sections: lifecycle + collapse (Task 4)

    func testCreateSectionAppendsToStateAndRootOrder() throws {
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let s = try store.createSection(name: "Work")
        XCTAssertEqual(s.name, "Work")
        XCTAssertTrue(s.repoIDs.isEmpty)
        XCTAssertFalse(s.isCollapsed)
        let loaded = cfg.load()
        XCTAssertTrue(loaded.sections.contains { $0.id == s.id })
        XCTAssertEqual(loaded.rootOrder, [.section(s.id)])
    }

    func testRenameSectionPersists() throws {
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let s = try store.createSection(name: "Work")
        _ = try store.renameSection(id: s.id, name: "Side Projects")
        XCTAssertEqual(cfg.load().sections.first { $0.id == s.id }?.name, "Side Projects")
    }

    func testRenameSectionIgnoresBlankName() throws {
        let (store, _) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let s = try store.createSection(name: "Work")
        let back = try store.renameSection(id: s.id, name: "   ")
        XCTAssertEqual(back.name, "Work")   // blank reverts to previous
    }

    func testDeleteSectionReleasesReposLooseAtFormerPosition() throws {
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r1 = try store.addRepository(path: "/tmp/sec-r1")
        let r2 = try store.addRepository(path: "/tmp/sec-r2")
        let s = try store.createSection(name: "Work")
        try store.moveRepo(id: r1.id, toSection: s.id, atIndex: 0)
        try store.moveRepo(id: r2.id, toSection: s.id, atIndex: 1)
        // rootOrder is now [.section(s)]; r1,r2 live inside it.
        try store.deleteSection(id: s.id)
        let loaded = cfg.load()
        XCTAssertFalse(loaded.sections.contains { $0.id == s.id })
        // Both repos released loose, in the section's slot, preserving their order.
        XCTAssertEqual(loaded.rootOrder, [.repo(r1.id), .repo(r2.id)])
    }

    func testSetSectionCollapsedPersists() throws {
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let s = try store.createSection(name: "Work")
        try store.setSectionCollapsed(id: s.id, collapsed: true)
        XCTAssertEqual(cfg.load().sections.first { $0.id == s.id }?.isCollapsed, true)
    }

    func testSetRepositoryCollapsedPersists() throws {
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: "/tmp/collapse-r")
        try store.setRepositoryCollapsed(id: r.id, collapsed: true)
        XCTAssertEqual(cfg.load().repositories.first { $0.id == r.id }?.isCollapsed, true)
    }

    func testDeleteMissingSectionThrows() throws {
        let (store, _) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        XCTAssertThrowsError(try store.deleteSection(id: "nope"))
    }
```

> Note: `moveRepo` (used by `testDeleteSectionReleasesReposLooseAtFormerPosition`) is implemented in Task 5. If executing tasks strictly in order, that one test will not compile until Task 5 lands — either implement Task 5's `moveRepo` signature stub first, or run this task's `--filter` against the other six tests via individual `::testName` filters. The remaining tests in this task pass independently.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter WorktreeStoreTests`
Expected: FAIL to compile — `value of type 'WorktreeStore' has no member 'createSection'`, etc.

- [ ] **Step 3: Add the `sectionNotFound` error case**

In `Sources/CodaCore/WorktreeStore.swift`, edit the `WorktreeStoreError` enum (lines 3-12) to add a case and its description:

```swift
public enum WorktreeStoreError: Error, CustomStringConvertible {
    case repoNotFound(String)
    case worktreeNotFound(String)
    case sectionNotFound(String)
    public var description: String {
        switch self {
        case .repoNotFound(let id): return "Repository not found: \(id)"
        case .worktreeNotFound(let id): return "Worktree not found: \(id)"
        case .sectionNotFound(let id): return "Section not found: \(id)"
        }
    }
}
```

- [ ] **Step 4: Implement the lifecycle + collapse methods**

Add to `WorktreeStore` (before the closing brace and the private `uniqueBranch` at line 197). NOTE: `createSection` uses `UUID().uuidString` mirroring `addRepository` (`WorktreeStore.swift:30`).

```swift
    // MARK: - Sidebar sections (display metadata only; never touches disk)

    /// Create an empty section, appended to the top-level order. Purely display metadata.
    @discardableResult
    public func createSection(name: String) throws -> SidebarSection {
        let section = SidebarSection(id: UUID().uuidString, name: name)
        state.sections.append(section)
        state.rootOrder.append(.section(section.id))
        try config.save(state)
        return section
    }

    /// Rename a section. A blank/whitespace name is ignored (keeps the previous name).
    @discardableResult
    public func renameSection(id: String, name: String) throws -> SidebarSection {
        guard let idx = state.sections.firstIndex(where: { $0.id == id }) else {
            throw WorktreeStoreError.sectionNotFound(id)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { state.sections[idx].name = trimmed }
        try config.save(state)
        return state.sections[idx]
    }

    /// Delete a section, releasing its repos as loose repos at the section's former
    /// top-level position (preserving their order). Never removes any repo.
    public func deleteSection(id: String) throws {
        guard let sIdx = state.sections.firstIndex(where: { $0.id == id }) else {
            throw WorktreeStoreError.sectionNotFound(id)
        }
        let freed = state.sections[sIdx].repoIDs.map { RootRef.repo($0) }
        state.sections.remove(at: sIdx)
        if let rIdx = state.rootOrder.firstIndex(of: .section(id)) {
            state.rootOrder.replaceSubrange(rIdx...rIdx, with: freed)
        } else {
            state.rootOrder.append(contentsOf: freed)
        }
        try config.save(state)
    }

    public func setSectionCollapsed(id: String, collapsed: Bool) throws {
        guard let idx = state.sections.firstIndex(where: { $0.id == id }) else {
            throw WorktreeStoreError.sectionNotFound(id)
        }
        state.sections[idx].isCollapsed = collapsed
        try config.save(state)
    }

    public func setRepositoryCollapsed(id: String, collapsed: Bool) throws {
        guard let idx = state.repositories.firstIndex(where: { $0.id == id }) else {
            throw WorktreeStoreError.repoNotFound(id)
        }
        state.repositories[idx].isCollapsed = collapsed
        try config.save(state)
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter WorktreeStoreTests`
Expected: PASS for the six lifecycle/collapse tests (the `deleteSection` release test needs Task 5's `moveRepo`; it passes once Task 5 lands).

- [ ] **Step 6: Commit**

```bash
git add Sources/CodaCore/WorktreeStore.swift Tests/CodaCoreTests/WorktreeStoreTests.swift
git commit -m "feat(sidebar): add section lifecycle + collapse mutations to WorktreeStore"
```

---

## Task 5: Store — repo/section movement (`moveRepo`, `moveSection`)

Implements all membership/reordering drag operations. These operate solely on the `sections`/`rootOrder` overlay — the `repositories` array order is no longer the display order.

**Files:**
- Modify: `Sources/CodaCore/WorktreeStore.swift`
- Test: `Tests/CodaCoreTests/WorktreeStoreTests.swift`

**Interfaces:**
- Consumes: the section lifecycle methods (Task 4).
- Produces:
  - `func moveRepo(id: String, toSection sectionID: String?, atIndex: Int) throws` — move a repo into a section (`sectionID != nil`) or to the loose root (`sectionID == nil`). `atIndex` is the desired final index within the destination container (section's `repoIDs`, or the top-level `rootOrder`). Removes the repo from wherever it currently lives first, adjusting `atIndex` when the removal was before the target in the same container.
  - `func moveSection(id: String, toIndex: Int) throws` — reorder a section among the top-level items (its repos travel with it).

- [ ] **Step 1: Write the failing tests** — append to `WorktreeStoreTests.swift`:

```swift
    // MARK: - Sections: movement (Task 5)

    func testMoveRepoIntoSection() throws {
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: "/tmp/mv-r1")
        let s = try store.createSection(name: "Work")
        try store.moveRepo(id: r.id, toSection: s.id, atIndex: 0)
        let loaded = cfg.load()
        XCTAssertEqual(loaded.sections.first { $0.id == s.id }?.repoIDs, [r.id])
        // The repo's loose root ref is gone; only the section remains at root.
        XCTAssertEqual(loaded.rootOrder, [.section(s.id)])
    }

    func testMoveRepoOutOfSectionToRoot() throws {
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: "/tmp/mv-r1")
        let s = try store.createSection(name: "Work")
        try store.moveRepo(id: r.id, toSection: s.id, atIndex: 0)
        try store.moveRepo(id: r.id, toSection: nil, atIndex: 0)   // back to loose, at root index 0
        let loaded = cfg.load()
        XCTAssertEqual(loaded.sections.first { $0.id == s.id }?.repoIDs, [])
        XCTAssertEqual(loaded.rootOrder, [.repo(r.id), .section(s.id)])
    }

    func testMoveRepoBetweenSections() throws {
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: "/tmp/mv-r1")
        let a = try store.createSection(name: "A")
        let b = try store.createSection(name: "B")
        try store.moveRepo(id: r.id, toSection: a.id, atIndex: 0)
        try store.moveRepo(id: r.id, toSection: b.id, atIndex: 0)
        let loaded = cfg.load()
        XCTAssertEqual(loaded.sections.first { $0.id == a.id }?.repoIDs, [])
        XCTAssertEqual(loaded.sections.first { $0.id == b.id }?.repoIDs, [r.id])
    }

    func testReorderReposWithinSection() throws {
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r1 = try store.addRepository(path: "/tmp/mv-r1")
        let r2 = try store.addRepository(path: "/tmp/mv-r2")
        let s = try store.createSection(name: "Work")
        try store.moveRepo(id: r1.id, toSection: s.id, atIndex: 0)
        try store.moveRepo(id: r2.id, toSection: s.id, atIndex: 1)   // [r1, r2]
        try store.moveRepo(id: r1.id, toSection: s.id, atIndex: 2)   // move r1 to the end
        XCTAssertEqual(cfg.load().sections.first { $0.id == s.id }?.repoIDs, [r2.id, r1.id])
    }

    func testReorderLooseReposAtRoot() throws {
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r1 = try store.addRepository(path: "/tmp/mv-r1")
        let r2 = try store.addRepository(path: "/tmp/mv-r2")
        // Prime rootOrder to [r1, r2] via reconciliation-independent explicit moves.
        try store.moveRepo(id: r1.id, toSection: nil, atIndex: 0)
        try store.moveRepo(id: r2.id, toSection: nil, atIndex: 1)
        try store.moveRepo(id: r1.id, toSection: nil, atIndex: 2)   // r1 to the end
        XCTAssertEqual(cfg.load().rootOrder, [.repo(r2.id), .repo(r1.id)])
    }

    func testMoveSectionReordersAmongRootItems() throws {
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: "/tmp/mv-r1")
        try store.moveRepo(id: r.id, toSection: nil, atIndex: 0)     // rootOrder: [repo r]
        let s = try store.createSection(name: "Work")               // rootOrder: [repo r, section s]
        try store.moveSection(id: s.id, toIndex: 0)                 // section to the front
        XCTAssertEqual(cfg.load().rootOrder, [.section(s.id), .repo(r.id)])
    }

    func testMoveRepoMissingThrows() throws {
        let (store, _) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        XCTAssertThrowsError(try store.moveRepo(id: "nope", toSection: nil, atIndex: 0))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter WorktreeStoreTests`
Expected: FAIL to compile — `has no member 'moveRepo'` / `moveSection`.

- [ ] **Step 3: Implement `moveRepo` and `moveSection`**

Add to `WorktreeStore` (alongside the Task 4 methods). These enforce the exactly-once invariant directly on the overlay.

```swift
    /// Move a repo into a section (`sectionID != nil`) or to the loose top level
    /// (`sectionID == nil`). `atIndex` is the final index within the destination
    /// container. Removes the repo from its current location first. Display only.
    public func moveRepo(id: String, toSection sectionID: String?, atIndex: Int) throws {
        guard state.repositories.contains(where: { $0.id == id }) else {
            throw WorktreeStoreError.repoNotFound(id)
        }
        if let sectionID, !state.sections.contains(where: { $0.id == sectionID }) {
            throw WorktreeStoreError.sectionNotFound(sectionID)
        }

        // Where is it now? A section's repoIDs, or a loose .repo ref in rootOrder.
        let sourceSectionIdx = state.sections.firstIndex { $0.repoIDs.contains(id) }
        let sourceRootIdx = state.rootOrder.firstIndex(of: .repo(id))

        // Adjust the target index if we're removing from the SAME container at a
        // position before the insertion point (the classic drop-index correction).
        var dest = atIndex
        if let sectionID, let sourceSectionIdx,
           state.sections[sourceSectionIdx].id == sectionID,
           let from = state.sections[sourceSectionIdx].repoIDs.firstIndex(of: id),
           from < atIndex {
            dest -= 1
        } else if sectionID == nil, let sourceRootIdx, sourceRootIdx < atIndex {
            dest -= 1
        }

        // Remove from current location.
        if let sourceSectionIdx {
            state.sections[sourceSectionIdx].repoIDs.removeAll { $0 == id }
        }
        if let sourceRootIdx {
            state.rootOrder.remove(at: sourceRootIdx)
        }

        // Insert into destination.
        if let sectionID, let dIdx = state.sections.firstIndex(where: { $0.id == sectionID }) {
            let clamped = max(0, min(dest, state.sections[dIdx].repoIDs.count))
            state.sections[dIdx].repoIDs.insert(id, at: clamped)
        } else {
            let clamped = max(0, min(dest, state.rootOrder.count))
            state.rootOrder.insert(.repo(id), at: clamped)
        }
        try config.save(state)
    }

    /// Reorder a section among the top-level items. Its repos travel with it (they
    /// live in the section, not in rootOrder). Display only.
    public func moveSection(id: String, toIndex: Int) throws {
        guard let current = state.rootOrder.firstIndex(of: .section(id)) else {
            throw WorktreeStoreError.sectionNotFound(id)
        }
        state.rootOrder.remove(at: current)
        var dest = current < toIndex ? toIndex - 1 : toIndex
        dest = max(0, min(dest, state.rootOrder.count))
        state.rootOrder.insert(.section(id), at: dest)
        try config.save(state)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter WorktreeStoreTests`
Expected: PASS — all `WorktreeStoreTests`, including Task 4's `testDeleteSectionReleasesReposLooseAtFormerPosition`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodaCore/WorktreeStore.swift Tests/CodaCoreTests/WorktreeStoreTests.swift
git commit -m "feat(sidebar): add moveRepo/moveSection overlay reordering to WorktreeStore"
```

---

## Task 6: Keybinding command — `.newSection`

**Files:**
- Modify: `Sources/CodaCore/Keybindings.swift:89-95,99-127,130-143,145-176`
- Test: `Tests/CodaCoreTests/KeybindingsTests.swift:43` (and add an assertion)

**Interfaces:**
- Produces: `ShortcutCommand.newSection` — display name "New Section", category `.view`, default chord `⌃ ⌘ N` (`KeyChord("n", command: true, control: true)`; free — `toggleSidebar` is `⌃ ⌘ S`, `toggleDiff` is `⌃ ⌘ D`).

- [ ] **Step 1: Update the failing test** — in `Tests/CodaCoreTests/KeybindingsTests.swift`, change the count assertion at line 43 from `28` to `29`, and add a new test method to the class:

```swift
    func testNewSectionCommand() {
        XCTAssertEqual(ShortcutCommand.newSection.defaultChord,
                       KeyChord("n", command: true, control: true))
        XCTAssertEqual(ShortcutCommand.newSection.category, .view)
        XCTAssertEqual(ShortcutCommand.newSection.title, "New Section")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter KeybindingsTests`
Expected: FAIL — `type 'ShortcutCommand' has no member 'newSection'` (and the count test would fail at 28).

- [ ] **Step 3: Add the case** — three edits in `Sources/CodaCore/Keybindings.swift`:

1. Add to the enum cases (line 91), e.g. append to that line:
```swift
    case addRepository, toggleSidebar, toggleDiff, openSettings, newSection
```

2. Add the `title` (in the `switch self` around line 106, next to `toggleDiff`):
```swift
        case .newSection: return "New Section"
```

3. Add the `category` (line 140) and `defaultChord` (line 154). In `category`:
```swift
        case .toggleSidebar, .toggleDiff, .newSection: return .view
```
In `defaultChord`:
```swift
        case .newSection:      return KeyChord("n", command: true, control: true)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter "Keybinding"`
Expected: PASS — `KeybindingsTests` and `KeybindingConflictsTests` (the conflicts test iterates `allCases`; `⌃ ⌘ N` must not collide — it doesn't).

- [ ] **Step 5: Commit**

```bash
git add Sources/CodaCore/Keybindings.swift Tests/CodaCoreTests/KeybindingsTests.swift
git commit -m "feat(sidebar): add New Section keyboard command (⌃ ⌘ N)"
```

---

## Task 7: SidebarController — three-tier data source, section header cell, collapse

Grows the outline from two tiers to three. UI is verified by build + manual launch (no unit tests for `NSOutlineView` interaction — the model/store tasks carry the logic tests). Tasks 7–11 all target `Sources/Coda/SidebarController.swift` and `AppDelegate.swift`.

**Files:**
- Modify: `Sources/Coda/SidebarController.swift` (node types, data source, cell, collapse, reload)

**Interfaces:**
- Consumes: `SidebarRootItem`, `SectionDisplay`, `RepositorySection` (Task 3); `WorktreeStore` section/collapse methods (Tasks 4–5).
- Produces (new/changed on `SidebarController`):
  - `func reload(rootItems: [SidebarRootItem], selectedWorktreeID: String?, selectedRepoID: String?)` — replaces the current `reload(sections:selectedWorktreeID:selectedRepoID:)`.
  - closures: `var onToggleSectionCollapsed: ((_ id: String, _ collapsed: Bool) -> Void)?`, `var onToggleRepoCollapsed: ((_ id: String, _ collapsed: Bool) -> Void)?`

- [ ] **Step 1: Add a `SectionNode` class and change root storage**

At the top of `SidebarController.swift`, after the `WorktreeNode` class (line 22), add:

```swift
/// Reference-type node for a sidebar section header (stable identity across reloads).
private final class SectionNode: NSObject {
    let section: SidebarSection
    let children: [RepoNode]
    init(section: SidebarSection, children: [RepoNode]) {
        self.section = section
        self.children = children
    }
}
```

Change the stored node list. Replace `private var repoNodes: [RepoNode] = []` (line 129) with:

```swift
    /// Ordered top-level nodes: each is a SectionNode or a RepoNode (loose repo).
    private var rootNodes: [NSObject] = []
    /// All repo nodes anywhere in the tree, for id lookups (loose + inside sections).
    private var allRepoNodes: [RepoNode] { rootNodes.flatMap { node -> [RepoNode] in
        if let s = node as? SectionNode { return s.children }
        if let r = node as? RepoNode { return [r] }
        return []
    } }
```

- [ ] **Step 2: Add the collapse-toggle closures**

After `onReorderRepos` (line 166), add:

```swift
    /// User expanded/collapsed a section header → persist its state.
    var onToggleSectionCollapsed: ((_ id: String, _ collapsed: Bool) -> Void)?
    /// User expanded/collapsed a repo row → persist its state.
    var onToggleRepoCollapsed: ((_ id: String, _ collapsed: Bool) -> Void)?
```

- [ ] **Step 3: Rewrite `reload(...)` to consume the tree and honor collapse state**

Replace the entire `reload(sections:...)` method (lines 326-362) with:

```swift
    func reload(rootItems: [SidebarRootItem], selectedWorktreeID: String?,
                selectedRepoID: String? = nil) {
        func repoNode(_ rs: RepositorySection) -> RepoNode {
            RepoNode(repository: rs.repository,
                     children: rs.worktrees.map { WorktreeNode($0, repoColorHex: rs.repository.color) })
        }
        rootNodes = rootItems.map { item -> NSObject in
            switch item {
            case .repo(let rs): return repoNode(rs)
            case .section(let sd):
                return SectionNode(section: sd.section, children: sd.repos.map(repoNode))
            }
        }
        outline.reloadData()

        // Honor persisted collapse state. Expand sections first (so nested repo rows
        // exist), then repos. `isReloading` gates the didExpand/didCollapse handlers
        // so these programmatic changes don't write back to the store.
        isReloading = true
        for node in rootNodes {
            if let s = node as? SectionNode, !s.section.isCollapsed { outline.expandItem(s) }
        }
        for repo in allRepoNodes where !repo.repository.isCollapsed {
            outline.expandItem(repo)
        }

        let selectedItem: Any? = worktreeNode(id: selectedWorktreeID)
            ?? repoNode(id: selectedRepoID)
        if let selectedItem {
            let row = outline.row(forItem: selectedItem)
            if row >= 0 {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    self.isReloading = false
                    self.outline.scrollRowToVisible(row)
                }
            } else {
                isReloading = false
            }
        } else {
            DispatchQueue.main.async { [weak self] in self?.isReloading = false }
        }
    }
```

- [ ] **Step 4: Update the private lookup helpers**

Replace `worktreeNode(id:)` and `repoNode(id:)` (lines 381-392) with versions that traverse `allRepoNodes`:

```swift
    private func worktreeNode(id: String?) -> WorktreeNode? {
        guard let id else { return nil }
        for repo in allRepoNodes {
            if let match = repo.children.first(where: { $0.worktree.id == id }) { return match }
        }
        return nil
    }

    private func repoNode(id: String?) -> RepoNode? {
        guard let id else { return nil }
        return allRepoNodes.first(where: { $0.repository.id == id })
    }
```

Also update `clickedRepoID()` (line 247), `currentRepoID()` (line 373), and the `pasteboardWriterForItem`/`validateDrop`/`acceptDrop` references that used `repoNodes` — those drag methods are rewritten in Task 8, so for now just make `clickedRepoID()`/`currentRepoID()` compile by matching on the new node types:

`clickedRepoID()` body:
```swift
        switch outline.item(atRow: row) {
        case let repo as RepoNode: return repo.repository.id
        case let wt as WorktreeNode: return wt.worktree.repoID
        default: return nil   // SectionNode → no repo
        }
```

`currentRepoID()` body:
```swift
        switch outline.item(atRow: outline.selectedRow) {
        case let wt as WorktreeNode: return wt.worktree.repoID
        case let repo as RepoNode: return repo.repository.id
        default: return allRepoNodes.first?.repository.id
        }
```

- [ ] **Step 5: Update the data-source methods for three tiers**

Replace `numberOfChildrenOfItem` (lines 449-455) and `child:ofItem:` (lines 457-460):

```swift
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil: return rootNodes.count
        case let section as SectionNode: return section.children.count
        case let repo as RepoNode: return repo.children.count
        default: return 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        switch item {
        case let section as SectionNode: return section.children[index]
        case let repo as RepoNode: return repo.children[index]
        default: return rootNodes[index]
        }
    }
```

Replace `isItemExpandable` (lines 506-508):

```swift
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        switch item {
        case let section as SectionNode: return !section.children.isEmpty
        case let repo as RepoNode: return !repo.children.isEmpty
        default: return false
        }
    }
```

Update `heightOfRowByItem` (lines 511-513) — section headers get a slightly taller, distinct row:

```swift
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if item is WorktreeNode { return metrics.length(38) }
        if item is SectionNode { return metrics.length(28) }
        return metrics.length(24)   // repo header
    }
```

- [ ] **Step 6: Render the section header cell (chevron handled by the outline; name + count)**

In `outlineView(_:viewFor:item:)`, add a `SectionNode` branch at the very top of the method (before the `RepoNode` branch, line 526):

```swift
        if let section = item as? SectionNode {
            let cell = makeCell(identifier: "section", symbol: nil)
            let count = section.children.count
            cell.textField?.stringValue = section.section.name
            cell.textField?.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            cell.textField?.textColor = (chrome?.color(.secondaryText).nsColor) ?? .secondaryLabelColor
            cell.textField?.lineBreakMode = .byTruncatingTail
            cell.textField?.isEditable = false      // enabled on demand for inline rename (Task 9)
            // Dimmed trailing count so a collapsed section shows how much it hides.
            let badge = sectionCountLabel(for: cell)
            badge.stringValue = "\(count)"
            badge.isHidden = false
            return cell
        }
```

Add a small helper near `makeCell` (line 668) that lazily attaches a trailing count label to the reused section cell:

```swift
    /// Trailing dimmed count label for a section header cell (added once, reused).
    private func sectionCountLabel(for cell: NSTableCellView) -> NSTextField {
        if let existing = cell.viewWithTag(9911) as? NSTextField { return existing }
        let label = NSTextField(labelWithString: "")
        label.tag = 9911
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .tertiaryLabelColor
        label.alignment = .right
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if let tf = cell.textField {
            tf.trailingAnchor.constraint(lessThanOrEqualTo: label.leadingAnchor, constant: -6).isActive = true
        }
        return label
    }
```

- [ ] **Step 7: Make section headers non-selectable and persist collapse via delegate**

Add these `NSOutlineViewDelegate` methods to the extension (near `outlineViewSelectionDidChange`, line 594):

```swift
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        // Section headers aren't terminal-selectable; clicking one toggles collapse (Task 7),
        // never clears/steals the detail surface.
        !(item is SectionNode)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isReloading, let item = notification.userInfo?["NSObject"] else { return }
        if let s = item as? SectionNode { onToggleSectionCollapsed?(s.section.id, false) }
        else if let r = item as? RepoNode { onToggleRepoCollapsed?(r.repository.id, false) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isReloading, let item = notification.userInfo?["NSObject"] else { return }
        if let s = item as? SectionNode { onToggleSectionCollapsed?(s.section.id, true) }
        else if let r = item as? RepoNode { onToggleRepoCollapsed?(r.repository.id, true) }
    }
```

Wire whole-row click on a section header to toggle collapse. In `loadView()` (after line 238, `outline.menu = rowMenu`), add:

```swift
        outline.target = self
        outline.action = #selector(handleOutlineClick)
```

Add the handler in the main class body (near `clickedRepoID()`, line 246):

```swift
    /// Single-click on a section header row toggles its collapse (big hit target).
    /// Repo/worktree rows are handled by normal selection. Double-click on a section
    /// enters rename (Task 9) via `outline.doubleAction`.
    @objc private func handleOutlineClick() {
        let row = outline.clickedRow
        guard row >= 0, let section = outline.item(atRow: row) as? SectionNode else { return }
        if (NSApp.currentEvent?.clickCount ?? 1) > 1 { return }   // let doubleAction handle rename
        if outline.isItemExpanded(section) { outline.collapseItem(section) }
        else { outline.expandItem(section) }
    }
```

- [ ] **Step 8: Build and manually verify**

Run: `DEVELOPER_DIR=$(xcode-select -p) swift build`
Expected: builds clean. (This task's callers in `AppDelegate` are updated in Task 11; until then, `reload(rootItems:...)` is unused and `AppDelegate` still calls the old `reload(sections:...)` — so **do Task 11's `refreshSidebar` switch-over as part of verifying this task, or expect a compile error on the old call site**. Recommended: land Tasks 7–10 first, then Task 11 flips the wiring and the whole thing builds + runs.)

Because Tasks 7–10 leave `AppDelegate` mid-migration, defer the build/launch check to Task 11. For now, verify the file compiles in isolation by reading it back for the node-type branches. Commit the structural change.

- [ ] **Step 9: Commit**

```bash
git add Sources/Coda/SidebarController.swift
git commit -m "feat(sidebar): three-tier outline data source + section header + collapse"
```

---

## Task 8: SidebarController — full drag grammar

Implements all 7 drag operations: repo into/out of/between sections, reorder within a section, reorder loose repos, reorder a whole section; worktrees stay non-draggable.

**Files:**
- Modify: `Sources/Coda/SidebarController.swift` (drag registration + pasteboard type + the three drag methods)

**Interfaces:**
- Consumes: `rootNodes`, `SectionNode`, `RepoNode`, `WorktreeNode` (Task 7).
- Produces: new closures replacing `onReorderRepos`:
  - `var onMoveRepo: ((_ repoID: String, _ toSectionID: String?, _ atIndex: Int) -> Void)?`
  - `var onMoveSection: ((_ sectionID: String, _ toIndex: Int) -> Void)?`
- New pasteboard type `.codaSectionRow` alongside `.codaRepoRow`.

- [ ] **Step 1: Add the section pasteboard type and register it**

At the bottom of the file, extend the private pasteboard extension (line 707):

```swift
private extension NSPasteboard.PasteboardType {
    static let codaRepoRow = NSPasteboard.PasteboardType("com.coda.sidebar.repo-row")
    static let codaSectionRow = NSPasteboard.PasteboardType("com.coda.sidebar.section-row")
}
```

In `loadView()`, update registration (line 235):

```swift
        outline.registerForDraggedTypes([.codaRepoRow, .codaSectionRow])
```

- [ ] **Step 2: Replace the `onReorderRepos` closure declaration**

Replace `var onReorderRepos: ...` (lines 164-166) with:

```swift
    /// Drag a repo row → move it into a section (`toSectionID != nil`) or to the
    /// loose top level (`nil`), at the given index within that container.
    var onMoveRepo: ((_ repoID: String, _ toSectionID: String?, _ atIndex: Int) -> Void)?
    /// Drag a section header → reorder it among the top-level items.
    var onMoveSection: ((_ sectionID: String, _ toIndex: Int) -> Void)?
```

- [ ] **Step 3: Rewrite `pasteboardWriterForItem` to allow repo AND section drags**

Replace the method (lines 464-470):

```swift
    func outlineView(_ outlineView: NSOutlineView,
                     pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        let pb = NSPasteboardItem()
        if let repo = item as? RepoNode {
            pb.setString(repo.repository.id, forType: .codaRepoRow)
            return pb
        }
        if let section = item as? SectionNode {
            pb.setString(section.section.id, forType: .codaSectionRow)
            return pb
        }
        return nil   // worktrees are not draggable
    }
```

- [ ] **Step 4: Rewrite `validateDrop` for the 3 target zones**

Target zones: (a) top-level between items; (b) into a section (onto its header or between its repos); (c) between repos inside a section. Replace the method (lines 472-492):

```swift
    func outlineView(_ outlineView: NSOutlineView,
                     validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        let pb = info.draggingPasteboard

        // --- Dragging a SECTION: only valid dropped between top-level items. ---
        if pb.availableType(from: [.codaSectionRow]) != nil {
            if item == nil {
                let target = index == NSOutlineViewDropOnItemIndex ? rootNodes.count : index
                outlineView.setDropItem(nil, dropChildIndex: target)
                return .move
            }
            // Onto/into anything else → retarget to the nearest top-level slot.
            outlineView.setDropItem(nil, dropChildIndex: rootNodes.count)
            return .move
        }

        // --- Dragging a REPO. ---
        guard pb.availableType(from: [.codaRepoRow]) != nil else { return [] }

        // Onto a section header, or between its repos → into that section.
        if let section = item as? SectionNode {
            let target = index == NSOutlineViewDropOnItemIndex ? section.children.count : index
            outlineView.setDropItem(section, dropChildIndex: target)
            return .move
        }
        // Onto/inside a repo that lives in a section → drop into that section after it.
        if let repo = item as? RepoNode ?? (item as? WorktreeNode).flatMap({ wt in
            allRepoNodes.first { $0.repository.id == wt.worktree.repoID } }) {
            if let (section, idx) = enclosingSection(of: repo.repository.id) {
                outlineView.setDropItem(section, dropChildIndex: idx + 1)
                return .move
            }
            // Loose repo target → top-level slot next to it.
            let target = rootNodes.firstIndex { ($0 as? RepoNode)?.repository.id == repo.repository.id }
                ?? rootNodes.count
            outlineView.setDropItem(nil, dropChildIndex: target)
            return .move
        }
        // Top-level between-items drop (loose).
        let target = index == NSOutlineViewDropOnItemIndex ? rootNodes.count : index
        outlineView.setDropItem(nil, dropChildIndex: target)
        return .move
    }

    /// The SectionNode that contains `repoID` and the repo's index within it, if any.
    private func enclosingSection(of repoID: String) -> (SectionNode, Int)? {
        for node in rootNodes {
            if let s = node as? SectionNode,
               let idx = s.children.firstIndex(where: { $0.repository.id == repoID }) {
                return (s, idx)
            }
        }
        return nil
    }
```

- [ ] **Step 5: Rewrite `acceptDrop` to dispatch to the right store call**

Replace the method (lines 494-504):

```swift
    func outlineView(_ outlineView: NSOutlineView,
                     acceptDrop info: NSDraggingInfo,
                     item: Any?,
                     childIndex index: Int) -> Bool {
        let pb = info.draggingPasteboard

        if let sectionID = pb.string(forType: .codaSectionRow) {
            let dropIndex = index == NSOutlineViewDropOnItemIndex ? rootNodes.count : index
            onMoveSection?(sectionID, dropIndex)
            return true
        }
        if let repoID = pb.string(forType: .codaRepoRow) {
            if let section = item as? SectionNode {
                let dropIndex = index == NSOutlineViewDropOnItemIndex ? section.children.count : index
                onMoveRepo?(repoID, section.section.id, dropIndex)
            } else {
                let dropIndex = index == NSOutlineViewDropOnItemIndex ? rootNodes.count : index
                onMoveRepo?(repoID, nil, dropIndex)
            }
            return true
        }
        return false
    }
```

- [ ] **Step 6: Build**

Run: `DEVELOPER_DIR=$(xcode-select -p) swift build`
Expected: `SidebarController.swift` compiles (the `onReorderRepos` wiring in `AppDelegate` is removed in Task 11; expect the build to fully succeed only after Task 11).

- [ ] **Step 7: Commit**

```bash
git add Sources/Coda/SidebarController.swift
git commit -m "feat(sidebar): full drag grammar (repo in/out/between sections, reorder sections)"
```

---

## Task 9: SidebarController — inline section rename

**Files:**
- Modify: `Sources/Coda/SidebarController.swift`

**Interfaces:**
- Consumes: `SectionNode`, the section header cell (Task 7).
- Produces: `var onRenameSection: ((_ id: String, _ name: String) -> Void)?`; `func beginEditingSection(id: String)` (called by AppDelegate right after creating a section so the new header opens in edit mode).

- [ ] **Step 1: Add the closure and conform to `NSTextFieldDelegate`**

After the collapse closures (Task 7 step 2), add:

```swift
    /// Inline-committed section rename (double-click header, or on-create edit).
    var onRenameSection: ((_ id: String, _ name: String) -> Void)?
    /// The section id currently being edited inline (so the delegate can route the commit).
    private var editingSectionID: String?
```

- [ ] **Step 2: Wire the double-click action and a public begin-editing entry**

In `loadView()`, after the `outline.action` line (Task 7 step 7), add:

```swift
        outline.doubleAction = #selector(handleOutlineDoubleClick)
```

Add methods to the class body (near `handleOutlineClick`):

```swift
    @objc private func handleOutlineDoubleClick() {
        let row = outline.clickedRow
        guard row >= 0, let section = outline.item(atRow: row) as? SectionNode else { return }
        beginEditing(section: section, row: row)
    }

    /// Open a freshly created section's header for inline editing (called by AppDelegate).
    func beginEditingSection(id: String) {
        guard let node = rootNodes.compactMap({ $0 as? SectionNode }).first(where: { $0.section.id == id })
        else { return }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        beginEditing(section: node, row: row)
    }

    private func beginEditing(section: SectionNode, row: Int) {
        guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        editingSectionID = section.section.id
        field.isEditable = true
        field.delegate = self
        field.isSelectable = true
        outline.window?.makeFirstResponder(field)
        field.selectText(nil)
    }
```

- [ ] **Step 3: Commit the rename on end-editing**

Add an `NSTextFieldDelegate` conformance extension at the end of the file (before the pasteboard extension):

```swift
extension SidebarController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let id = editingSectionID else { return }
        editingSectionID = nil
        field.isEditable = false
        field.delegate = nil
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Blank reverts (store ignores empty names and refreshSidebar repaints the old name).
        onRenameSection?(id, name)
    }
}
```

- [ ] **Step 4: Build**

Run: `DEVELOPER_DIR=$(xcode-select -p) swift build`
Expected: `SidebarController.swift` compiles (full success after Task 11).

- [ ] **Step 5: Commit**

```bash
git add Sources/Coda/SidebarController.swift
git commit -m "feat(sidebar): inline section rename (double-click + on-create edit)"
```

---

## Task 10: Section context menu — New / Rename / Delete + "Move to Section ▸"

**Files:**
- Modify: `Sources/Coda/SidebarController.swift` (the `NSMenuDelegate.menuNeedsUpdate`, plus new closures + `@objc` handlers)

**Interfaces:**
- Consumes: `onRenameSection` (Task 9), `SectionNode`/`RepoNode` (Task 7).
- Produces closures: `var onNewSection: (() -> Void)?`, `var onDeleteSection: ((_ id: String) -> Void)?`, `var onBeginRenameSection: ((_ id: String) -> Void)?` (asks AppDelegate to trigger inline edit — routes back to `beginEditingSection`); reuse `onMoveRepo` (Task 8) for "Move to Section ▸". Also expose the current sections so the submenu can list them: `private var currentSections: [(id: String, name: String)]` derived from `rootNodes`.

- [ ] **Step 1: Add the menu closures**

Near the other `on...` closures, add:

```swift
    var onNewSection: (() -> Void)?
    var onDeleteSection: ((_ id: String) -> Void)?
    /// Ask AppDelegate to begin inline rename of a section (so it can route to `beginEditingSection`).
    var onBeginRenameSection: ((_ id: String) -> Void)?
```

- [ ] **Step 2: Add `@objc` handlers**

Near the other `@objc private func context...` methods (line 271+):

```swift
    @objc private func contextNewSection(_ sender: NSMenuItem) { onNewSection?() }

    @objc private func contextRenameSection(_ sender: NSMenuItem) {
        (sender.representedObject as? String).map { onBeginRenameSection?($0) }
    }

    @objc private func contextDeleteSection(_ sender: NSMenuItem) {
        (sender.representedObject as? String).map { onDeleteSection?($0) }
    }

    @objc private func contextMoveRepoToSection(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String?],
              let repoID = info["repoID"] ?? nil else { return }
        // sectionID nil-value key means "None (Top Level)".
        let sectionID = info["sectionID"] ?? nil
        onMoveRepo?(repoID, sectionID, Int.max)   // append; store clamps to the end
    }
```

- [ ] **Step 3: Rebuild `menuNeedsUpdate` to branch on the clicked node**

Replace the `menuNeedsUpdate(_:)` method (lines 397-445). It now handles three cases: right-click on a section header, on a repo (header or its worktree), or on empty space:

```swift
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        let clicked = row >= 0 ? outline.item(atRow: row) : nil

        // Always offer "New Section".
        let newSection = NSMenuItem(title: "New Section",
                                    action: #selector(contextNewSection(_:)), keyEquivalent: "")
        newSection.target = self
        menu.addItem(newSection)

        // --- Section header right-click: Rename / Delete. ---
        if let section = clicked as? SectionNode {
            menu.addItem(.separator())
            let rename = NSMenuItem(title: "Rename Section…",
                                    action: #selector(contextRenameSection(_:)), keyEquivalent: "")
            rename.target = self; rename.representedObject = section.section.id
            menu.addItem(rename)
            let delete = NSMenuItem(title: "Delete Section",
                                    action: #selector(contextDeleteSection(_:)), keyEquivalent: "")
            delete.target = self; delete.representedObject = section.section.id
            menu.addItem(delete)
            return
        }

        // --- Repo / worktree right-click: existing repo actions + Move to Section. ---
        guard let repoID = clickedRepoID() else { return }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Repository Settings…",
                                  action: #selector(contextRepoSettings(_:)), keyEquivalent: "")
        settings.target = self; settings.representedObject = repoID
        menu.addItem(settings)
        let newWorktree = NSMenuItem(title: "New Worktree",
                                     action: #selector(contextNewWorktree(_:)), keyEquivalent: "")
        newWorktree.target = self; newWorktree.representedObject = repoID
        menu.addItem(newWorktree)

        if clickedWorktreeID() == nil {
            menu.addItem(.separator())
            menu.addItem(makeMoveToSectionItem(repoID: repoID))
            let rename = NSMenuItem(title: "Rename…",
                                    action: #selector(contextRenameRepo(_:)), keyEquivalent: "")
            rename.target = self; rename.representedObject = repoID
            menu.addItem(rename)
            if let theme = activeTheme {
                menu.addItem(ColorMenu.makeSetColorItem(
                    targetID: repoID, theme: theme, target: self,
                    setColor: #selector(contextSetRepoColor(_:)),
                    customColor: #selector(contextCustomRepoColor(_:)),
                    removeColor: #selector(contextRemoveRepoColor(_:))))
            }
            menu.addItem(.separator())
            let remove = NSMenuItem(title: "Remove Repository…",
                                    action: #selector(contextRemoveRepo(_:)), keyEquivalent: "")
            remove.target = self; remove.representedObject = repoID
            menu.addItem(remove)
        }

        if let worktreeID = clickedWorktreeID(), clickedWorktree()?.isMain == false,
           let theme = activeTheme {
            menu.addItem(.separator())
            menu.addItem(ColorMenu.makeSetColorItem(
                targetID: worktreeID, theme: theme, target: self,
                setColor: #selector(contextSetColor(_:)),
                customColor: #selector(contextCustomColor(_:)),
                removeColor: #selector(contextRemoveColor(_:))))
        }
    }

    /// A "Move to Section ▸" submenu listing every section plus "None (Top Level)".
    private func makeMoveToSectionItem(repoID: String) -> NSMenuItem {
        let parent = NSMenuItem(title: "Move to Section", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let currentSection = enclosingSection(of: repoID)?.0.section.id
        let none = NSMenuItem(title: "None (Top Level)",
                              action: #selector(contextMoveRepoToSection(_:)), keyEquivalent: "")
        none.target = self
        none.representedObject = ["repoID": repoID, "sectionID": nil] as [String: String?]
        none.state = (currentSection == nil) ? .on : .off
        sub.addItem(none)
        let sections = rootNodes.compactMap { $0 as? SectionNode }
        if !sections.isEmpty { sub.addItem(.separator()) }
        for s in sections {
            let mi = NSMenuItem(title: s.section.name,
                                action: #selector(contextMoveRepoToSection(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = ["repoID": repoID, "sectionID": s.section.id] as [String: String?]
            mi.state = (currentSection == s.section.id) ? .on : .off
            sub.addItem(mi)
        }
        parent.submenu = sub
        return parent
    }
```

- [ ] **Step 4: Build**

Run: `DEVELOPER_DIR=$(xcode-select -p) swift build`
Expected: `SidebarController.swift` compiles (full success after Task 11).

- [ ] **Step 5: Commit**

```bash
git add Sources/Coda/SidebarController.swift
git commit -m "feat(sidebar): section context menu + Move to Section submenu"
```

---

## Task 11: AppDelegate wiring + menu item + integration verify

Flips the app over to the new tree, wires every new closure to the store, lands new repos loose, adds the "New Section" menu item, and does the end-to-end manual verification.

**Files:**
- Modify: `Sources/Coda/AppDelegate.swift`

**Interfaces:**
- Consumes: everything from Tasks 3–10 (`buildSidebarTree`, store methods, new `Sidebar` closures).

- [ ] **Step 1: Switch the sidebar data feed to `buildSidebarTree`**

Replace `displaySections()` (lines 510-514) and `refreshSidebar(select:)` (lines 527-529). Rename `displaySections()` → `displayRootItems()`:

```swift
    /// The ordered three-tier sidebar tree: sections/loose repos → repos → worktrees.
    private func displayRootItems() -> [SidebarRootItem] {
        buildSidebarTree(repositories: store.state.repositories,
                         worktrees: store.state.worktrees,
                         sections: store.state.sections,
                         rootOrder: store.state.rootOrder,
                         branchForRepo: currentBranches)
    }

    private func refreshSidebar(select id: String?) {
        sidebar.reload(rootItems: displayRootItems(), selectedWorktreeID: id)
    }
```

Update `allDisplayWorktrees()` (lines 517-519), which used `displaySections()`:

```swift
    private func allDisplayWorktrees() -> [Worktree] {
        displayRootItems().flatMap { item -> [Worktree] in
            switch item {
            case .repo(let rs): return rs.worktrees
            case .section(let sd): return sd.repos.flatMap { $0.worktrees }
            }
        }
    }
```

- [ ] **Step 2: Rewire the sidebar closures (remove `onReorderRepos`, add the new ones)**

In the block at lines 452-461, replace the `sidebar.onReorderRepos = ...` line (461) with the new wiring:

```swift
        sidebar.onMoveRepo = { [weak self] repoID, sectionID, idx in self?.moveRepo(repoID, toSection: sectionID, atIndex: idx) }
        sidebar.onMoveSection = { [weak self] id, idx in self?.moveSection(id, toIndex: idx) }
        sidebar.onToggleSectionCollapsed = { [weak self] id, collapsed in self?.setSectionCollapsed(id, collapsed) }
        sidebar.onToggleRepoCollapsed = { [weak self] id, collapsed in self?.setRepoCollapsed(id, collapsed) }
        sidebar.onNewSection = { [weak self] in self?.newSection() }
        sidebar.onDeleteSection = { [weak self] id in self?.deleteSection(id) }
        sidebar.onRenameSection = { [weak self] id, name in self?.renameSection(id, name: name) }
        sidebar.onBeginRenameSection = { [weak self] id in self?.sidebar.beginEditingSection(id: id) }
```

- [ ] **Step 3: Add the AppDelegate handler methods**

Replace the old `reorderRepo(_:toIndex:)` (lines 499-507) with the new handlers (delete the old method):

```swift
    /// Move a repo into a section / to the loose top level and persist. Display only.
    private func moveRepo(_ repoID: String, toSection sectionID: String?, atIndex: Int) {
        do {
            try store.moveRepo(id: repoID, toSection: sectionID, atIndex: atIndex)
            refreshSidebar(select: selectedWorktree?.id)
        } catch { presentError(error) }
    }

    private func moveSection(_ id: String, toIndex: Int) {
        do {
            try store.moveSection(id: id, toIndex: toIndex)
            refreshSidebar(select: selectedWorktree?.id)
        } catch { presentError(error) }
    }

    private func setSectionCollapsed(_ id: String, _ collapsed: Bool) {
        do { try store.setSectionCollapsed(id: id, collapsed: collapsed) }
        catch { presentError(error) }
    }

    private func setRepoCollapsed(_ id: String, _ collapsed: Bool) {
        do { try store.setRepositoryCollapsed(id: id, collapsed: collapsed) }
        catch { presentError(error) }
    }

    /// Create a new empty section and open its header for inline naming.
    private func newSection() {
        do {
            let s = try store.createSection(name: "New Section")
            refreshSidebar(select: selectedWorktree?.id)
            // Defer so the row exists after reloadData before we begin editing.
            DispatchQueue.main.async { [weak self] in self?.sidebar.beginEditingSection(id: s.id) }
        } catch { presentError(error) }
    }

    private func renameSection(_ id: String, name: String) {
        do {
            _ = try store.renameSection(id: id, name: name)
            refreshSidebar(select: selectedWorktree?.id)
        } catch { presentError(error) }
    }

    /// Delete a section (no confirm): its repos fall back to the root. Display only.
    private func deleteSection(_ id: String) {
        do {
            try store.deleteSection(id: id)
            refreshSidebar(select: selectedWorktree?.id)
        } catch { presentError(error) }
    }
```

- [ ] **Step 4: New repos land loose at the root**

`addRepository` already appends to `state.repositories`, and reconciliation appends any unreferenced repo loose at the end — so a newly added repo automatically appears loose at the bottom. No code change needed beyond confirming `addRepo()` (line 657) still calls `refreshSidebar`. Verify by reading `addRepo()`; it calls `refreshSidebar(select: mainID)` at line 668 — correct, leave as-is.

- [ ] **Step 5: Add the "New Section" menu item under the View menu**

In `buildMenu()`, in the View-menu block (after the "Toggle Diff" line, line 1381), add:

```swift
        viewMenu.addItem(.separator())
        addItem(to: viewMenu, "New Section", #selector(newSectionAction), command: .newSection)
```

Add the action near the other `@objc` actions (line 1450+):

```swift
    @objc private func newSectionAction() { newSection() }
```

- [ ] **Step 6: Full build**

Run: `DEVELOPER_DIR=$(xcode-select -p) swift build`
Expected: **builds clean** — this is the first task where `AppDelegate` and `SidebarController` are consistent. Fix any remaining references to the removed `displaySections()`/`onReorderRepos`/old `reload(sections:)` signature (grep for them: `grep -rn "displaySections\|onReorderRepos\|reload(sections" Sources/Coda`).

- [ ] **Step 7: Run the full test suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest`
Expected: PASS, all green (≈495 existing + the new CodaCore tests).

- [ ] **Step 8: Manual launch verification**

Use the `/run` skill (or `DEVELOPER_DIR=$(xcode-select -p) swift run Coda`) and walk this checklist against a scratch `~/.coda/local.json` (back up the real one first: `cp ~/.coda/local.json ~/.coda/local.json.bak`):

1. **Zero-migration:** launch with your existing repos — the sidebar looks exactly as before (all repos loose, in prior order).
2. **Create:** View ▸ New Section (and `⌃ ⌘ N`, and right-click ▸ New Section) — a "New Section" header appears at the bottom, editable; type a name, press Return; it sticks.
3. **Drag into section:** drag a repo onto the section header → repo nests under it. Drag another between its repos → order respected.
4. **Drag out / between / reorder section:** drag a repo out to the root; drag a repo from one section to another; drag the section header to a new top-level position (its repos travel with it); reorder loose repos.
5. **Collapse persists:** collapse the section (click its header row) and a repo (disclosure triangle); the count badge shows the hidden repo count; quit and relaunch → both stay collapsed. A collapsed section holding a `working` agent still shows the Dock badge count.
6. **Active terminal survives collapse:** select a worktree, collapse its section → the terminal stays running/focused; expand → still selected.
7. **Delete:** right-click section ▸ Delete Section (no confirm) → repos fall back to the root at that spot; no repo lost.
8. **Move to Section submenu:** right-click a repo ▸ Move to Section ▸ pick a section / "None (Top Level)" → repo moves; checkmark shows current membership.

Restore your config afterward: `mv ~/.coda/local.json.bak ~/.coda/local.json`.

- [ ] **Step 9: Commit**

```bash
git add Sources/Coda/AppDelegate.swift
git commit -m "feat(sidebar): wire sections end-to-end (tree feed, closures, New Section menu)"
```

---

## Self-Review

**1. Spec coverage** (against the locked design):
- Optional/mixed root → reconciliation appends unreferenced repos loose (Task 2); `SidebarRootItem` interleaves sections + loose repos (Task 3). ✓
- Freely interleaved → single `rootOrder` list (Task 1), preserved through moves (Task 5). ✓
- One level only → `SectionNode.children` are `RepoNode`s; no section-in-section node (Task 7). ✓
- Create via context menu + View menu, empty sections legal → Task 10 (`New Section`), Task 11 (View menu + `⌃ ⌘ N`), `createSection` makes an empty section (Task 4). ✓
- Inline rename, dup names OK, blank reverts → Task 9 (inline), `renameSection` ignores blank (Task 4); dup names allowed (id-keyed, no uniqueness check). ✓
- Delete = metadata only, no confirm, repos survive at former slot → `deleteSection` (Task 4), no alert (Task 11). ✓
- No section color in v1 → section cell uses neutral chrome text only (Task 7). ✓
- Header: distinct row, click toggles, not selectable, count badge → Task 7. ✓
- Collapse both, persisted, purely visual → `isCollapsed` on section + repo (Task 1), setters (Task 4), honored + persisted on toggle (Task 7); Dock badge counts globally (unchanged code, verified step 8.5). ✓
- 7 drag ops → Task 8 `validateDrop`/`acceptDrop`; worktrees non-draggable (`pasteboardWriterForItem` returns nil for `WorktreeNode`). ✓
- Move to Section submenu → Task 10. ✓
- New repos loose → reconciliation append + no wiring change (Task 11 step 4). ✓
- Data model + reconciliation + zero migration → Tasks 1–2, back-compat tests. ✓

**2. Placeholder scan:** no "TBD"/"add error handling"/"similar to Task N" — every code step has complete code. ✓

**3. Type consistency:** `SidebarSection`, `RootRef`, `SidebarRootItem`, `SectionDisplay`, `ReconciledLayout`, `reconcileSidebarLayout`, `buildSidebarTree` used identically across tasks. Store methods `createSection`/`renameSection`/`deleteSection`/`setSectionCollapsed`/`setRepositoryCollapsed`/`moveRepo(id:toSection:atIndex:)`/`moveSection(id:toIndex:)` match their call sites in Task 11. Controller closures `onMoveRepo`/`onMoveSection`/`onToggleSectionCollapsed`/`onToggleRepoCollapsed`/`onNewSection`/`onDeleteSection`/`onRenameSection`/`onBeginRenameSection` match Task 11 wiring. `reload(rootItems:...)` signature matches `refreshSidebar`. ✓

**Note on task ordering:** Tasks 7–10 leave `Sources/Coda` in a non-compiling intermediate state (AppDelegate still references the old API); the build only goes green at Task 11 step 6. This is intentional — the UI refactor is coherent only as a set. Reviewers of Tasks 7–10 should review the code diff, not require a green build until Task 11.
