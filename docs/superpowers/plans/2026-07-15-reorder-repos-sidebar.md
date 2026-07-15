# Reorder Repos in the Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user reorder the repositories in the sidebar by dragging a repo header row, with the new order persisting across launches.

**Architecture:** Repo order is already fully determined by the order of the `state.repositories` array, which flows unchanged through `sectionsWithMainCheckouts` → `RepositorySection` → the sidebar's `NSOutlineView`. Reordering is therefore: mutate that array's order (in `WorktreeStore`) → persist via the existing `config.save` → reload the sidebar. A new `NSOutlineView` drag-and-drop handler on the sidebar, scoped to repo header rows, drives it through a callback into `AppDelegate`.

**Tech Stack:** Swift, AppKit (`NSOutlineView` drag-and-drop), XCTest, Swift Package Manager. Two modules: `CodaCore` (model/store, unit-tested) and `Coda` (AppKit UI, live-verified).

## Global Constraints

- **Test runner:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest` — the full Xcode toolchain is required (CommandLineTools has no XCTest); use the separate `.build-xctest` build path to avoid a Swift 6.3.2 vs 6.2.3 module clash with the release build.
- **Release build check:** `DEVELOPER_DIR=$(xcode-select -p) swift build` (CommandLineTools) — used only to confirm the app target compiles.
- **macOS floor:** macOS 13. Do not use APIs newer than macOS 13.
- **No schema change:** repo order persists for free via the existing `LocalState.repositories` array encoding — do NOT add a model field or migration.
- **Scope:** repo header rows only. Worktrees stay non-draggable. No menu-based fallback.
- **Keyboard-shortcut copy (if any appears in commit/PR text):** space out modifier symbols, e.g. `⌘ / ⇧ + Enter` — not the tightly-packed form.

---

### Task 1: `WorktreeStore.moveRepository(id:toIndex:)`

The pure, unit-tested core: reorder the `repositories` array using the standard `NSOutlineView` drop-index convention, and persist.

**Files:**
- Modify: `Sources/CodaCore/WorktreeStore.swift` (add method near the other `Repository` mutators, e.g. after `setRepositoryDisplayName` at `Sources/CodaCore/WorktreeStore.swift:169-176`)
- Test: `Tests/CodaCoreTests/WorktreeStoreTests.swift` (add cases to the existing `WorktreeStoreTests` class)

**Interfaces:**
- Consumes: existing `WorktreeStore` internals — `state.repositories: [Repository]`, `config.save(_:)`, `WorktreeStoreError.repoNotFound(String)`, and the test helpers `makeTempRepo()` (`Tests/CodaCoreTests/TestSupport.swift`) and the local `makeStore(worktreeRoot:) -> (WorktreeStore, Config)`.
- Produces: `@discardableResult public func moveRepository(id: String, toIndex: Int) throws -> [Repository]`. `toIndex` is the `NSOutlineView` drop child index (the insertion slot computed BEFORE removal). Later tasks call this from `AppDelegate`.

- [ ] **Step 1: Write the failing tests**

Add these to `Tests/CodaCoreTests/WorktreeStoreTests.swift`, inside the `WorktreeStoreTests` class (before the final closing brace at line 329). They use three real temp repos so ordering is unambiguous.

```swift
    // MARK: - reorder repositories (drag-and-drop)

    /// Three added repos, in a known order, for reorder tests.
    private func makeThreeRepos() throws -> (WorktreeStore, Config, [Repository]) {
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let a = try store.addRepository(path: try makeTempRepo())
        let b = try store.addRepository(path: try makeTempRepo())
        let c = try store.addRepository(path: try makeTempRepo())
        return (store, cfg, [a, b, c])
    }

    func testMoveRepositoryDownUsesDropIndexConvention() throws {
        let (store, cfg, repos) = try makeThreeRepos()   // [A, B, C]
        // Drop A into the slot after B: NSOutlineView reports childIndex 2 (before A is removed).
        _ = try store.moveRepository(id: repos[0].id, toIndex: 2)
        XCTAssertEqual(store.state.repositories.map(\.id), [repos[1].id, repos[0].id, repos[2].id]) // [B, A, C]
        XCTAssertEqual(cfg.load().repositories.map(\.id), [repos[1].id, repos[0].id, repos[2].id])
    }

    func testMoveRepositoryUp() throws {
        let (store, _, repos) = try makeThreeRepos()   // [A, B, C]
        // Drop C into the slot before B: childIndex 1, source is after → no adjustment.
        _ = try store.moveRepository(id: repos[2].id, toIndex: 1)
        XCTAssertEqual(store.state.repositories.map(\.id), [repos[0].id, repos[2].id, repos[1].id]) // [A, C, B]
    }

    func testMoveRepositoryToFirst() throws {
        let (store, _, repos) = try makeThreeRepos()   // [A, B, C]
        _ = try store.moveRepository(id: repos[2].id, toIndex: 0)
        XCTAssertEqual(store.state.repositories.map(\.id), [repos[2].id, repos[0].id, repos[1].id]) // [C, A, B]
    }

    func testMoveRepositoryToLast() throws {
        let (store, _, repos) = try makeThreeRepos()   // [A, B, C]
        // Drop A into the end slot: childIndex 3 (== count, before removal).
        _ = try store.moveRepository(id: repos[0].id, toIndex: 3)
        XCTAssertEqual(store.state.repositories.map(\.id), [repos[1].id, repos[2].id, repos[0].id]) // [B, C, A]
    }

    func testMoveRepositoryNoOpKeepsOrderAndSaves() throws {
        let (store, cfg, repos) = try makeThreeRepos()   // [A, B, C]
        // Drop B into its own slot (childIndex 1): order unchanged, still persists cleanly.
        _ = try store.moveRepository(id: repos[1].id, toIndex: 1)
        let ids = [repos[0].id, repos[1].id, repos[2].id]
        XCTAssertEqual(store.state.repositories.map(\.id), ids)
        XCTAssertEqual(cfg.load().repositories.map(\.id), ids)
    }

    func testMoveRepositoryClampsOutOfRangeIndex() throws {
        let (store, _, repos) = try makeThreeRepos()   // [A, B, C]
        // An index past the end must clamp to last, not crash.
        _ = try store.moveRepository(id: repos[0].id, toIndex: 99)
        XCTAssertEqual(store.state.repositories.map(\.id), [repos[1].id, repos[2].id, repos[0].id]) // [B, C, A]
    }

    func testMoveRepositoryUnknownIDThrows() throws {
        let (store, _, _) = try makeThreeRepos()
        XCTAssertThrowsError(try store.moveRepository(id: "nope", toIndex: 0))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter WorktreeStoreTests/testMoveRepository`
Expected: FAIL — compile error `value of type 'WorktreeStore' has no member 'moveRepository'`.

- [ ] **Step 3: Write the minimal implementation**

Add to `Sources/CodaCore/WorktreeStore.swift`, right after `setRepositoryDisplayName(...)` (which ends at line 176):

```swift
    /// Reorder a repository within the sidebar list. `toIndex` is the `NSOutlineView`
    /// drop child index — the insertion slot computed BEFORE the dragged item is removed —
    /// so it's adjusted for the removal and clamped to valid bounds. A no-op move still saves.
    /// NEVER touches the repo on disk; this is purely the sidebar's display order.
    @discardableResult
    public func moveRepository(id: String, toIndex: Int) throws -> [Repository] {
        guard let current = state.repositories.firstIndex(where: { $0.id == id }) else {
            throw WorktreeStoreError.repoNotFound(id)
        }
        let repo = state.repositories.remove(at: current)
        // Drop index counts the pre-removal array; if the item came from before the
        // target slot, everything after it shifts down by one.
        var dest = current < toIndex ? toIndex - 1 : toIndex
        dest = max(0, min(dest, state.repositories.count))
        state.repositories.insert(repo, at: dest)
        try config.save(state)
        return state.repositories
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter WorktreeStoreTests/testMoveRepository`
Expected: PASS — all 7 `testMoveRepository*` cases green.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodaCore/WorktreeStore.swift Tests/CodaCoreTests/WorktreeStoreTests.swift
git commit -m "feat(core): WorktreeStore.moveRepository for sidebar reorder

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Sidebar drag-and-drop for repo header rows

Make repo header rows draggable and accept top-level drops, surfacing the result through a new callback. Worktrees stay non-draggable.

**Files:**
- Modify: `Sources/Coda/SidebarController.swift`
  - `loadView()` (`Sources/Coda/SidebarController.swift:222-239`) — register drag type + source mask
  - the callback declarations block (near `onRemoveRepo` at `Sources/Coda/SidebarController.swift:162-163`) — add `onReorderRepos`
  - the `NSOutlineViewDataSource` extension (`Sources/Coda/SidebarController.swift:443` onward) — add the three drag methods
  - add a private `NSPasteboard.PasteboardType` extension at the bottom of the file

**Interfaces:**
- Consumes: private `RepoNode` (has `repository: Repository`), `WorktreeNode` (has `worktree: Worktree` with `.repoID`), and `repoNodes: [RepoNode]` — all already in this file.
- Produces: `var onReorderRepos: ((_ id: String, _ toIndex: Int) -> Void)?` — invoked on a valid repo drop with the dragged repo's id and the drop child index (pass straight to `WorktreeStore.moveRepository`).

- [ ] **Step 1: Add the callback declaration**

In `Sources/Coda/SidebarController.swift`, immediately after the `onRemoveRepo` declaration (line 163):

```swift
    /// Drag a repo header row to a new position → reorder the top-level repo list.
    /// Args: the dragged repo's id, and the drop child index (NSOutlineView convention).
    var onReorderRepos: ((_ id: String, _ toIndex: Int) -> Void)?
```

- [ ] **Step 2: Register the drag type and source mask in `loadView()`**

In `loadView()`, immediately after `outline.delegate = self` (line 231), add:

```swift
        outline.registerForDraggedTypes([.codaRepoRow])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
```

- [ ] **Step 3: Add the pasteboard type extension**

At the very bottom of `Sources/Coda/SidebarController.swift` (after the final closing brace of the file), add:

```swift
private extension NSPasteboard.PasteboardType {
    /// Private drag type carrying a dragged repo header row's repository id.
    static let codaRepoRow = NSPasteboard.PasteboardType("com.coda.sidebar.repo-row")
}
```

- [ ] **Step 4: Add the three drag methods**

Inside the `extension SidebarController: NSOutlineViewDataSource, NSOutlineViewDelegate` block (the one starting at line 443), add these three methods (place them after `outlineView(_:child:ofItem:)`):

```swift
    // MARK: - Drag to reorder repo header rows (repos only; worktrees not draggable)

    func outlineView(_ outlineView: NSOutlineView,
                     pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let repo = item as? RepoNode else { return nil }   // worktrees: nil → not draggable
        let pbItem = NSPasteboardItem()
        pbItem.setString(repo.repository.id, forType: .codaRepoRow)
        return pbItem
    }

    func outlineView(_ outlineView: NSOutlineView,
                     validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        // Only our repo-row drags are eligible.
        guard info.draggingPasteboard.availableType(from: [.codaRepoRow]) != nil else { return [] }
        // A between-rows drop at the top level is already valid.
        if item == nil && index != NSOutlineViewDropOnItemIndex { return .move }
        // Anything else (onto a repo, or inside a repo's children) retargets to a
        // top-level slot so the user always sees valid between-rows feedback.
        let target: Int
        if let repo = item as? RepoNode {
            target = repoNodes.firstIndex { $0.repository.id == repo.repository.id } ?? repoNodes.count
        } else if let wt = item as? WorktreeNode {
            target = repoNodes.firstIndex { $0.repository.id == wt.worktree.repoID } ?? repoNodes.count
        } else {
            target = repoNodes.count
        }
        outlineView.setDropItem(nil, dropChildIndex: target)
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView,
                     acceptDrop info: NSDraggingInfo,
                     item: Any?,
                     childIndex index: Int) -> Bool {
        guard let id = info.draggingPasteboard.string(forType: .codaRepoRow) else { return false }
        // On-item drops (index == NSOutlineViewDropOnItemIndex, -1) shouldn't reach here after
        // validateDrop retargets, but guard anyway: treat as append.
        let dropIndex = index == NSOutlineViewDropOnItemIndex ? repoNodes.count : index
        onReorderRepos?(id, dropIndex)
        return true
    }
```

- [ ] **Step 5: Build to verify it compiles**

Run: `DEVELOPER_DIR=$(xcode-select -p) swift build`
Expected: build succeeds with no errors. (`onReorderRepos` is unused for now — that's fine; Swift does not warn on an unset optional stored property.)

- [ ] **Step 6: Commit**

```bash
git add Sources/Coda/SidebarController.swift
git commit -m "feat(sidebar): drag-and-drop reorder for repo header rows

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Wire the reorder into `AppDelegate` and verify live

Connect the sidebar callback to the store, reloading while preserving the current selection. This is the task whose deliverable makes Task 2 exercisable, so it ends with live verification.

**Files:**
- Modify: `Sources/Coda/AppDelegate.swift`
  - the sidebar-callback wiring block (`Sources/Coda/AppDelegate.swift:444-452`) — add `onReorderRepos`
  - add a `reorderRepo(_:toIndex:)` method near the other repo mutators (e.g. after `setRepoColor` around `Sources/Coda/AppDelegate.swift:479-488`)

**Interfaces:**
- Consumes: `SidebarController.onReorderRepos` (from Task 2), `WorktreeStore.moveRepository(id:toIndex:)` (from Task 1), and the existing `refreshSidebar(select:)` (`Sources/Coda/AppDelegate.swift:508-510`), `selectedWorktree` property, and `presentError(_:)`.
- Produces: nothing consumed by later tasks (final task).

- [ ] **Step 1: Add the wiring line**

In `Sources/Coda/AppDelegate.swift`, immediately after the `sidebar.onRemoveRepo = ...` line (line 452):

```swift
        sidebar.onReorderRepos = { [weak self] id, idx in self?.reorderRepo(id, toIndex: idx) }
```

- [ ] **Step 2: Add the `reorderRepo` method**

In `Sources/Coda/AppDelegate.swift`, right after the `setRepoColor(...)` method (which ends around line 488, just before `displaySections()`):

```swift
    /// Reorder a repository in the sidebar list and persist, keeping the current
    /// selection highlighted so the focused row doesn't jump. Display order only —
    /// nothing on disk changes.
    private func reorderRepo(_ repoID: String, toIndex: Int) {
        do {
            _ = try store.moveRepository(id: repoID, toIndex: toIndex)
            refreshSidebar(select: selectedWorktree?.id)
        } catch { presentError(error) }
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `DEVELOPER_DIR=$(xcode-select -p) swift build`
Expected: build succeeds with no errors.

- [ ] **Step 4: Confirm the full test suite still passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest`
Expected: PASS — the pre-existing suite plus the 7 new `testMoveRepository*` cases (total previously 482 → now ~489).

- [ ] **Step 5: Live-verify the drag in the running app**

Use the `run` skill (or the project's launch path) to build and launch Coda with at least two repos in the sidebar. Then:
1. Drag a repo header row above/below another → the drop indicator appears between repo rows (never inside a repo's worktrees), and on release the repos swap.
2. Confirm a **worktree** row cannot be dragged (no drag image / no drop).
3. Confirm the **selection stays put** (the highlighted worktree remains selected, terminal focus not stolen).
4. Quit and relaunch → the new repo order persisted.

Record what you observed. If any check fails, treat it as a bug and fix before committing.

- [ ] **Step 6: Commit**

```bash
git add Sources/Coda/AppDelegate.swift
git commit -m "feat(sidebar): wire repo reorder drag into the store

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Notes for the implementer

- **Why the drop-index adjustment lives in the store, not the UI:** `NSOutlineView`'s `childIndex` is computed against the array *before* the dragged item is removed. Keeping that `+/- 1` adjustment in `moveRepository` (Task 1) means it's covered by fast unit tests; the AppKit layer just forwards the raw index.
- **No migration:** the order is the array order in `LocalState.repositories`, already encoded in sequence by `Config`. Reordering + `config.save` is the whole persistence story.
- **Selection preservation:** `refreshSidebar(select:)` re-selects by worktree id after `reloadData()`; passing `selectedWorktree?.id` is what keeps the highlight from resetting. If no worktree is selected (a repo header is), the highlight may not restore — acceptable; it's an existing limitation of `refreshSidebar`, not introduced here.
