# Branch Picker & Stash Management

A toolbar-triggered branch switcher with search, local+remote branches, and integrated stash management. GitHub Desktop-style checkout switching adapted for Coda's worktree-centric model.

## Scope

- Checkout-based branch switching on the repo's own working directory (the synthesized "main checkout" row)
- Stash handling: auto-stash on dirty switch + visible stash list with apply/pop/drop
- No worktree creation from the picker — that stays in the existing "New Worktree" flow

## Data Models (CodaCore — Models.swift)

Two new value types, not persisted — rebuilt from git output on every picker open.

```swift
public struct Branch: Equatable {
    public var name: String
    public var isRemote: Bool
    public var isHead: Bool
    public var remoteName: String?   // e.g. "origin" — only set for remote branches
    public var shortName: String     // strips "origin/" prefix for remotes, same as name for local
}

public struct Stash: Equatable, Identifiable {
    public var id: Int               // stash index (0, 1, 2...)
    public var message: String       // stash description from git
    public var branch: String?       // branch the stash was created on
}
```

No changes to `Worktree`, `Repository`, `LocalState`, or any persisted state.

## Git Operations (CodaCore — GitWorktree.swift)

~60 lines of new methods on the existing `GitWorktree` struct, through the existing `ProcessRunner` pattern.

### Branch listing

- `branches(repo:) -> [Branch]` — runs `git branch -a --format='%(refname:short) %(HEAD)'`. Parses into `[Branch]` array. Splits local vs remote, marks `isHead`. Strips `origin/HEAD` and deduplicates where a local branch tracks a remote.

### Checkout

- `checkout(repo:branch:)` — `git checkout <branch>` for local branches. For remote branches: `git checkout -b <localName> --track <remote/branch>` to create a local tracking branch.

### Stash

- `stashList(repo:) -> [Stash]` — `git stash list --format=%gd||%gs`. Parses index, message, and originating branch from the default stash message format.
- `stashSave(repo:message:)` — `git stash push -u -m <message>`. Includes untracked files.
- `stashPop(repo:index:)` — `git stash pop stash@{<index>}`.
- `stashApply(repo:index:)` — `git stash apply stash@{<index>}`.
- `stashDrop(repo:index:)` — `git stash drop stash@{<index>}`.

### Dirty check

- `hasUncommittedChanges(repo:) -> Bool` — `git status --porcelain`. Non-empty output = dirty.

Existing `localBranches(repo:)` stays unchanged — still used by the new-worktree dialog.

## Branch Picker UI (Coda — BranchPickerPanel.swift)

New file. `NSPanel` subclass, floating, non-activating. Follows the `CompletionPopupView` pattern: `NSVisualEffectView` with `.menu` material, rounded corners, shadow.

### Layout (top to bottom)

1. **Search field** — `NSTextField` with placeholder "Filter branches...". Incremental case-insensitive substring match across both sections. Focused on open.

2. **Branch list** — `NSScrollView` + `NSTableView`. Two sections with small grey section headers:
   - **Local** — local branches, checkmark on current HEAD
   - **Remote** — remote-tracking branches with `origin/` prefix stripped in display
   - Clicking a branch triggers checkout

3. **Stash bar** — bottom strip, only visible when stashes exist. Shows "N stashes" label + disclosure chevron. Clicking expands an inline stash list showing index and message per entry. Each stash row has Apply / Pop / Drop actions (small buttons or right-click context menu).

### Behavior

- Opens anchored below toolbar button, left-aligned
- Dismisses on: click outside, Escape, successful branch switch
- Selecting a remote branch auto-creates a local tracking branch
- If working tree is dirty on branch select: shows inline confirmation — "Uncommitted changes. Stash and switch?" with **Stash & Switch** / **Cancel** buttons. On confirm: `stashSave` then `checkout`. No auto-pop on target branch — user manages stashes explicitly from the stash list.

### Sizing

~300pt wide, height dynamic based on branch count, max ~400pt then scrolls.

## Toolbar Integration (Coda — AppDelegate.swift)

### Toolbar button

- New cluster button in `rightCluster`, positioned left of "Launch Claude"
- SF Symbol: `arrow.triangle.branch`
- Tooltip: "Switch Branch"
- Shows current branch name as text label beside icon when space allows; icon-only when narrow
- Disabled when no repo is selected in sidebar

### Toolbar layout

```
[leftCluster] [flexibleSpace] [notch] [flexibleSpace] [branchPicker] [rightCluster] [openIn]
```

New `.branchPicker` toolbar item identifier.

### Wiring

- `@objc func toggleBranchPicker(_:)` — creates or toggles `BranchPickerPanel`. Passes current repo path.
- On picker open: calls `GitWorktree.branches(repo:)` and `GitWorktree.stashList(repo:)` synchronously. These are fast local git ops.
- On branch select: calls `hasUncommittedChanges(repo:)`. If clean, `checkout(repo:branch:)`. If dirty, shows inline confirmation.
- After successful checkout: `HeadWatcher` fires automatically, updates `currentBranches`, refreshes sidebar and `WorktreeBar`. Picker dismisses. Diff pane refreshes via existing `displayDiff` path.
- On stash actions: re-fetches stash list, updates panel in place.

No changes to `SidebarController`, `WorktreeBar`, `WorktreeStore`, or `LocalState`.

## Error Handling

All errors are non-destructive — picker stays open, state unchanged, git message shown inline.

| Scenario | Behavior |
|----------|----------|
| Checkout failure (merge conflict) | Inline error in picker: "Checkout failed: \<git stderr first line\>". Picker stays open. |
| Branch deleted between list and select | Same inline error. Branch list re-fetches automatically. |
| Stash pop/apply conflict | Inline error with git message. Stash stays in list (git doesn't drop on conflict). User resolves in terminal. |
| Branch locked by another worktree | "Branch '\<name\>' is checked out in another worktree." Picker stays open. |
| No repo selected | Toolbar button disabled. |
| Detached HEAD | Toolbar label shows "(detached)". Picker opens, lists all branches, no checkmark. |
| Empty repo (no commits) | Picker shows "No branches" placeholder. Stash section still functional. |

## Testing

### Unit tests (CodaCoreTests)

New test file. All tests against real temporary git repos (existing test pattern — no mocks).

- `Branch` parsing: local/remote split, `isHead` marking, `origin/` stripping, deduplication of tracked branches
- `Stash` parsing: index extraction, message parsing, originating branch extraction from various `git stash list` formats
- `hasUncommittedChanges`: staged, unstaged, untracked, and clean states
- `checkout`: local branch, remote branch (creates tracking), branch locked by worktree (error)
- `stashSave` / `stashPop` / `stashApply` / `stashDrop`: round-trip correctness

### Manual verification (Coda)

- Toolbar button enables/disables based on repo selection
- Picker opens, lists branches correctly, search filters both sections
- Checkout switches branch; sidebar + WorktreeBar update via HeadWatcher
- Dirty-tree confirmation: stash-and-switch works, cancel aborts
- Remote branch checkout creates local tracking branch
- Stash list: shows entries, apply/pop/drop work, list refreshes after each action
- Error states: branch locked by worktree, checkout conflict, detached HEAD, empty repo
- Picker dismisses on Escape, click-outside, successful switch

## Files Touched

| File | Change |
|------|--------|
| `Sources/CodaCore/Models.swift` | Add `Branch` and `Stash` types |
| `Sources/CodaCore/GitWorktree.swift` | Add ~60 lines: `branches`, `checkout`, stash ops, `hasUncommittedChanges` |
| `Sources/Coda/BranchPickerPanel.swift` | New file (~300-400 lines) |
| `Sources/Coda/AppDelegate.swift` | Toolbar button, `.branchPicker` identifier, `toggleBranchPicker` wiring |
| `Tests/CodaCoreTests/` | New test file for branch/stash parsing and operations |
