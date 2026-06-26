# Conductor — Repository color + rename (design)

_Date: 2026-06-26. Status: approved, ready for implementation plan._

## Goal

Mirror Supacode's repository customization in Conductor's sidebar: each registered
repository can carry an optional **display name** (a rename that overrides the
folder-derived name) and an optional **color**. The color tints the repo's
section header and cascades to the `repo · branch` subtitle of every worktree row
under it. Both are display-only and machine-local.

Reference: Supacode's `RepoSectionHeaderView` (`Text(displayName).foregroundStyle(color?.color ?? .secondary)`),
`Repository.sidebarDisplayName(custom:fallback:)`, and the per-repo `color` /
`customTitle` customization.

## Non-goals

- **No on-disk rename.** The display name is a UI override only; it never renames
  the worktree folder, the git repo, or any branch. (Matches Supacode's `customTitle`.)
- **No auto-assigned repo colors.** Unlike worktrees (which cycle through
  `IdentityPalette`), a repo has no color until the user sets one — it stays
  secondary-gray. (Matches Supacode.)
- No change to the terminal grid or chrome theming. Repo color is sidebar-text-only.

## Data model (`ConductorCore`)

Add two optional fields to `Repository` (in `Models.swift`):

```swift
public var displayName: String?   // rename override; nil/blank → use `name`
public var color: String?         // hex like "#D97757"; nil → secondary gray
```

- Extend the memberwise `init` with `displayName: String? = nil, color: String? = nil`.
- Add both to `CodingKeys` and decode with `decodeIfPresent` (older configs load as
  `nil`) — same backward-compat pattern as `setupScript` / `autoLaunchClaude`.
- Add a computed helper:

```swift
/// The name to show in the sidebar: a non-blank displayName override, else the folder name.
public var sidebarDisplayName: String {
    let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (trimmed?.isEmpty == false) ? trimmed! : name
}
```

`Repository` is machine-local config (it holds an absolute `path`), so these fields
persist alongside the existing repo entries — no portable/local split change.

## Store (`ConductorCore`)

Extend `WorktreeStore.updateRepository(...)` with two optional params
(`displayName: String??` and `color: String??`, or a small dedicated method —
implementer's choice, but it must support *clearing* a value back to `nil`).
Mirrors the existing `autoLaunchClaude` parameter addition. Persists to config.

> Clearing matters: "Remove Color" sets `color = nil`; a blank rename sets
> `displayName = nil`. The signature must distinguish "leave unchanged" from
> "set to nil". Using `String??` (or separate explicit setters) is acceptable.

## Sidebar rendering (`Conductor/SidebarController.swift`)

1. **Repo header** (`viewFor` RepoNode): set the text to `repo.repository.sidebarDisplayName`
   and tint it with `NSColor(hex: repo.repository.color)` when present, else the
   current `chrome.secondaryText` gray. Keep the existing small-semibold font.

2. **Worktree subtitle cascade** (`viewFor` WorktreeNode): the `repo · branch`
   subtitle becomes an `NSAttributedString` — the repo-name portion painted with the
   parent repo's color (when set), the ` · <branch>` remainder in secondary gray.
   The parent repo is reached via `outline.parent(forItem:)` (already used for the
   repo name today). When the repo has no color, render exactly as today.

## Right-click repo menu (`SidebarController` `menuNeedsUpdate`)

Add to the repo section of the context menu (mirroring the worktree Set Color UX):

- **`Rename…`** → invokes `onRenameRepo(repoID)`. AppDelegate shows a text prompt
  (existing `promptForText`) prefilled with the current `sidebarDisplayName`.
  Submitting a blank value clears the override (`displayName = nil`).
- **`Set Color ▸`** → submenu of `IdentityPalette.colors` swatches (reuse
  `swatchImage`), each invoking `onSetRepoColor(repoID, hex)`; plus
  **`Remove Color`** → `onRemoveRepoColor(repoID)` (sets `color = nil`).

These sit alongside the existing `Repository Settings…` and `New Worktree` items.

## Wiring (`Conductor/AppDelegate.swift`)

`SidebarController` gains three closures: `onRenameRepo`, `onSetRepoColor`,
`onRemoveRepoColor`. AppDelegate implements them by calling
`store.updateRepository(...)` then rebuilding + reloading the sidebar sections
(same flow as `setWorktreeColor`).

## Testing (`ConductorCore` XCTest)

- `Repository` decodes an old config (no `displayName`/`color` keys) → both `nil`.
- `Repository` round-trips `displayName` + `color` through encode/decode.
- `sidebarDisplayName`: nil → folder name; blank/whitespace → folder name;
  non-blank → trimmed override.
- `WorktreeStore.updateRepository` persists a set name + color, and clears each
  back to `nil`, reloading from disk to confirm.

UI tinting/attributed-string rendering is verified in-app (no view-layer tests,
consistent with the existing sidebar work).

## Out of scope / deferred

- Editing name/color from the Repository Settings sheet (right-click only for now).
- Color picker beyond the `IdentityPalette` swatches (no free-form NSColorPanel for
  repos in this pass; worktrees don't have it either).
