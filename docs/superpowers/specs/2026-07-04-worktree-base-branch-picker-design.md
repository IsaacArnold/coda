# Worktree Base-Branch Picker — Design

**Goal:** When creating a new worktree, show the user which branch it will be based off, and let them choose a different local branch to fork from. Today the base is silently the repo's current `HEAD`, computed inside `WorktreeStore.createWorktree` with no UI surface.

## Background

The "New Worktree" flow (`AppDelegate.newWorktree`, `AppDelegate.swift:564`) prompts for a title via the generic `promptForText` helper (`AppDelegate.swift:1453`) — a bare `NSAlert` with one `NSTextField`. The base branch is only determined later, inside `WorktreeStore.createWorktree` (`WorktreeStore.swift:82`):

```swift
let base = try git.currentBranch(repo: repo.path)   // rev-parse --abbrev-ref HEAD
```

The user has no visibility into or control over the fork point.

## Scope (decided)

- **Selectable base**, not info-only: the dialog gets a branch picker.
- **Local branches only** — no remote-tracking branches in this milestone.
- Default selection = the repo's current `HEAD`.

## Design

Follows the existing pure-core / AppKit-glue split. All git and path logic stays in `CodaCore`; the dialog is the only new AppKit surface.

### 1. CodaCore — pure logic (unit-tested)

**`GitWorktree.localBranches(repo:) -> [String]`** *(new)*

```
git -C <repo> branch --format=%(refname:short)
```

Returns trimmed, non-empty local branch names in git's default (alphabetical) order.

**`WorktreeStore.createWorktree(repoID:title:base:)`** — add a `base: String? = nil` parameter.

- `base == nil` → fall back to `git.currentBranch(repo:)`, preserving today's behavior and all existing tests/callers unchanged.
- `base != nil` → fork the new branch from that base: `git worktree add -b <branch> <path> <base>` (the existing `git.add` call already takes `base`).

**`WorktreeStore.localBranches(repoID:) -> [String]`** *(thin pass-through)* — resolves the repo and calls `GitWorktree.localBranches`. The UI uses this plus the existing current-branch resolution to populate the picker and preselect the default.

### 2. Coda — AppKit glue (manual GUI verification)

**`promptForNewWorktree(repo:) -> (title: String, base: String)?`** *(new)* — an `NSAlert` whose accessory view stacks two labeled rows:

- **Title** label + `NSTextField` (default `"New Worktree"`)
- **Base branch** label + `NSPopUpButton` listing the local branches, with the repo's current `HEAD` preselected.

Returns `nil` on Cancel. `newWorktree` calls it and threads the chosen base into `createWorktree(repoID:title:base:)`.

### 3. Error handling / edge cases

- If branch enumeration fails or returns empty (e.g. an **unborn repo** — freshly `git init`'d with no commits, so no branches and `rev-parse --abbrev-ref HEAD` is unhelpful), **fall back to the existing title-only `promptForText` prompt** with `base: nil`. Worktree creation still works, just without the picker.
- Atomic rollback on failed create, allowlist file copy, identity color assignment, and all downstream surface/badge wiring are **unchanged**.

### 4. Testing

- **CodaCore:**
  - `GitWorktree.localBranches` parses branch names from a temp git repo with multiple branches.
  - `WorktreeStore.createWorktree` with an explicit `base` forks the new branch from that base.
  - `createWorktree` with `base: nil` preserves current-`HEAD` behavior (existing tests remain green).
- **Coda:** the modal dialog is not unit-testable (AppKit `runModal`); verified manually, consistent with the untested `promptForText`.

## Non-goals

- Remote-tracking branches as a base (deferred).
- Choosing an arbitrary commit-ish / tag / SHA as a base.
- Changing the new-branch naming scheme (still `slugify(title)` + uniqueness suffix).
