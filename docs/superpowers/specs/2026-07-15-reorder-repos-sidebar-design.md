# Reorder repos in the sidebar (drag-and-drop)

**Date:** 2026-07-15
**Status:** Approved — ready for implementation plan

## Summary

Let the user reorder the repositories in the sidebar by dragging a repo header
row above or below the others. The new order persists across launches.

## Motivation

Repos appear in the sidebar in the order they were added, with no way to change
it. Users who work across several repos want to arrange them meaningfully
(most-active first, grouped by project, etc.).

## Background: how repo order works today

Repo order is already fully determined by the order of the `state.repositories`
array (`CodaCore/Config.swift` → `LocalState.repositories`). That order flows
unchanged through `sectionsWithMainCheckouts(...)` → `[RepositorySection]` →
`SidebarController.reload(sections:)`, which builds one `RepoNode` per section in
array order. The `NSOutlineView` renders top-level items in that same order.

Consequences:

- Reordering is entirely: **mutate the array's order → persist → reload.**
- No new model field, no `Codable` schema change, no migration. Order is already
  persisted for free by the existing `config.save(state)` (the array is encoded
  in order).

## Scope

**In scope:** dragging **repo header rows** to reorder the top-level repo list.

**Out of scope (YAGNI):**

- Reordering worktrees within a repo.
- Moving worktrees across repos.
- Any menu-based "Move Up / Move Down" fallback. Drag-and-drop is the only
  affordance.

## Design

### 1. Core / store layer — `WorktreeStore` (CodaCore)

New method, built test-first:

```swift
@discardableResult
public func moveRepository(id: String, toIndex: Int) throws -> [Repository]
```

Behavior:

- Find the repo's current index in `state.repositories`. If not found, throw
  `WorktreeStoreError.repoNotFound(id)`.
- Remove it, then re-insert at the destination.
- `toIndex` uses the standard `NSOutlineView` drop convention — the insertion
  slot computed **before** the dragged item is removed. So it adjusts: if
  `currentIndex < toIndex`, insert at `toIndex - 1`; otherwise insert at
  `toIndex`. The final insertion index is clamped to `0...count` (post-removal)
  so an out-of-range `toIndex` can't crash.
- A no-op move (item ends up where it started) is allowed and still calls
  `config.save(state)` harmlessly.
- Persist via `config.save(state)` and return the reordered `state.repositories`.

This keeps the only fiddly logic (index adjustment) in one pure, directly
unit-testable place.

### 2. Sidebar — `SidebarController` (Coda)

Implement `NSOutlineView` drag-reorder, scoped to repo headers only.

- `loadView`: register a private drag type
  (e.g. `NSPasteboard.PasteboardType("com.coda.repo-row")`) via
  `outline.registerForDraggedTypes([...])`, and
  `outline.setDraggingSourceOperationMask(.move, forLocal: true)`.
- `outlineView(_:pasteboardWriterForItem:)`: return an `NSPasteboardItem`
  carrying the repo id under the private type **only for `RepoNode`**; return
  `nil` for `WorktreeNode` (worktrees are not draggable).
- `outlineView(_:validateDrop:proposedItem:proposedChildIndex:)`: accept **only
  top-level drops** — `proposedItem == nil`. If the drop targets a repo row or
  lands inside a repo's children, **retarget it to the top level** via
  `setDropItem(nil, dropChildIndex: ...)` so the user always gets valid
  between-rows feedback rather than a rejected drop. Reject (return `[]`) only
  when the dragged payload isn't a repo id; otherwise return `.move`.
- `outlineView(_:acceptDrop:item:childIndex:)`: decode the repo id from the
  pasteboard and invoke a new callback:

  ```swift
  var onReorderRepos: ((_ id: String, _ toIndex: Int) -> Void)?
  ```

  passing the drop's `childIndex` straight through as `toIndex`.

### 3. Wiring — `AppDelegate` (Coda)

Mirror the existing `onRemoveRepo` / `onSetRepoColor` wiring:

```swift
sidebar.onReorderRepos = { [weak self] id, idx in self?.reorderRepo(id, toIndex: idx) }
```

`reorderRepo(_:toIndex:)`:

- Calls `store.moveRepository(id:toIndex:)`.
- Calls `refreshSidebar(select:)` **preserving the current selection** (pass the
  selected worktree's id) so the highlighted row doesn't jump after the reorder.
- Routes any thrown error through `presentError(_:)`.

## Testing

**TDD unit tests** on `WorktreeStore.moveRepository` (added to the existing
suite):

1. Move a repo down one slot.
2. Move a repo up one slot.
3. Move a repo to the first position.
4. Move a repo to the last position.
5. No-op move (same position) leaves order unchanged and still saves.
6. Unknown id throws `.repoNotFound`.
7. Order persists — reload state from disk and confirm the new order.

**Live verification** of the AppKit drag/drop glue in the running app: drag a
repo header to a new position, confirm the order sticks, relaunch and confirm it
persisted. (Matches the project's live-verify norm for AppKit-bound behavior.)

## Risks / notes

- `NSOutlineView` drop-index semantics are the classic error-prone part; keeping
  the adjustment math in `moveRepository` (unit-tested) rather than in the
  AppKit layer contains that risk.
- Must ensure worktrees remain non-draggable (return `nil` from
  `pasteboardWriterForItem`) so the gesture can't produce a nonsensical drop.
