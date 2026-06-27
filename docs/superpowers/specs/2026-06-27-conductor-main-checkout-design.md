# Conductor — Repo main-checkout sessions design

**Date:** 2026-06-27
**Status:** Approved (brainstorm complete; ready for implementation plan)
**Related:** `DECISIONS.md` → "Phase 1.5 — Multi-surface" (this becomes the final Phase 1.5 PR, reframing the originally-planned PR C); multi-surface tabs (PR #28) + splits (PR #30); `SurfaceRegistry`/`WorktreeSurfaces` (Core); repo color+rename (PR #27).

## Goal

Bring Conductor to Supacode parity on the most basic interaction: **you should never have to create a `git worktree` just to start working in a repo.** Adding a repo should immediately give you a usable session on its currently-checked-out branch (the repo's own working directory), and switching that branch with `git checkout` should be reflected live.

This **replaces** the originally-planned Phase 1.5 "PR C — scratch (worktree-less) tabs." After grilling (2026-06-27), the real need behind scratch — "always have a place to type without ceremony" — is better served by making the repo's main checkout a first-class session. Scratch terminals (a shell bound to *no* repo at all) remain deferred; the `Surface.kind = .scratch` seam stays reserved and is revisited after living with this.

## Background: how Supacode models this (researched 2026-06-27)

Supacode's `Worktree` is a **single unifying abstraction**. The repo's main checkout is just a worktree whose working directory equals the repo root — detected structurally (`isMainWorktree = workingDirectory == repositoryRootURL`). Adding a repo lists **all** worktrees including the main checkout (via `wt ls --json`), so a session exists immediately. A `git checkout` in the main dir is caught by a kqueue watch on `.git/HEAD`; the existing row's `name` updates **in place** (no new row). The main checkout can be hidden but never deleted. There is **no scratch concept** — every terminal belongs to a worktree. Conductor adopts the same shape, adapted to its existing `Worktree`/store/surface stack.

## The gap in Conductor today

Conductor's `Worktree` always points at a **separate** `git worktree add` directory (`worktreePath`). The repo's own checkout is not representable, so a repo with no created worktrees is a dead-end empty group. The git plumbing already exists: `GitWorktree.currentBranch(repo:)` and `GitWorktree.list(repo:)`.

## Locked decisions (from the grill, 2026-06-27)

| Decision | Choice |
|---|---|
| Scope | **Main-checkout sessions only.** Defer scratch terminals; keep the `.scratch` seam reserved. |
| Representation | The main checkout is a **synthesized** `Worktree` (`isMain` flag), **never persisted** to config. One per registered repo, derived on load. |
| Branch switch | **Live in-place update** via a `.git/HEAD` file watcher → updates the main row's branch subtitle. No new sidebar row. |
| Lifecycle | **Permanent** while the repo is registered. Main row has **no Archive / no branch-delete**. Removed only by removing the repo. |
| Sidebar label | Title = fixed **"Default"**; subtitle = `repo · branch` (branch part live). Main row sits **first** under its repo, above real worktrees. |
| Remove repo | New `removeRepository` store method + repo-header "Remove Repository…" menu item (with confirmation). Drops repo + its worktrees from config and evicts their surfaces; **never touches git/disk**. |
| Surfaces | Main checkout is a normal worktree to the registry → tabs/splits/badges/persist-across-switch all reused. Shell spawns in `repo.path`. No setup-script / copy-allowlist. Shell-first (never auto-launches Claude). |
| Color | Main checkout's effective color = `repo.color` if set, else a deterministic `IdentityPalette` pick seeded by repo id. Not individually overridable in MVP. |

## Architecture

The codebase pattern holds: decision logic lives in pure `ConductorCore` (XCTest-covered); AppKit stays thin. The only new **impure** piece is the `.git/HEAD` watcher (shell-side); Core never spawns processes or watches files.

### Core (`ConductorCore`, pure + tested)

**`Worktree.isMain`** — a new `Bool` stored property, **excluded from `CodingKeys`** so it never persists and always decodes `false`. Synthesized main checkouts set `isMain = true`. (Equatable includes it; that's fine — synthesized mains and real worktrees never collide.)

**Main-checkout factory** — a function/initializer producing a synthesized main `Worktree` for a repo:
- `id` = stable, derived from the repo id (e.g. `"\(repo.id)#main"`), so surfaces persist within a session and the derived color is stable.
- `repoID` = repo.id, `worktreePath` = repo.path, `title` = `"Default"`, `isMain` = true.
- `branch` = supplied current branch (see branch map below), or a fallback (`""` / repo's last-known) when unknown.
- `color` = nil (effective color is derived at display time from `repo.color` ?? deterministic palette).

**Section builder** — a pure function that produces the sidebar sections with main checkouts injected:
```
func sectionsWithMainCheckouts(
    repositories: [Repository],
    worktrees: [Worktree],          // persisted (real) worktrees only
    branchForRepo: [String: String] // repoID → current branch
) -> [RepositorySection]
```
For each repo (preserving order): prepend the synthesized main checkout (branch from `branchForRepo`, fallback if absent), then the repo's real worktrees in their existing order. This supersedes direct use of `groupWorktreesByRepository` at the sidebar seam (that function may stay for other callers/tests).

**`WorktreeStore.removeRepository(id:)`** — removes the repo and all its persisted worktrees from `state`, saves config, and **returns the removed worktrees** (or their ids) so the shell can evict surfaces. **Never** calls `git.remove` / `deleteBranch` / deletes directories. Throws `repoNotFound` if absent.

**Branch map ownership** — the store holds a `[repoID: String]` current-branch cache and exposes:
- a setter the watcher calls when HEAD changes (`setCurrentBranch(repoID:branch:)`),
- the `sectionsWithMainCheckouts(...)` result (or a convenience accessor) the sidebar consumes.
Seeding the map (reading `currentBranch` per repo at launch / on add) is the shell's job; Core just consumes the map so it stays pure and testable.

### Shell (AppKit)

**`HeadWatcher`** (new) — watches `<repo.path>/.git/HEAD` per registered repo via `DispatchSource.makeFileSystemObjectSource`. On a write/rename/delete event it re-reads `currentBranch`, calls `store.setCurrentBranch(...)`, and triggers a sidebar reload of just that repo's section (label updates in place; no row replacement). **Re-arm gotcha:** git rewrites HEAD via atomic rename, so the original fd's vnode is replaced — the watcher must re-open/re-arm on `.delete`/`.rename` (or watch the parent `.git` dir). Supacode proves the kqueue approach; mirror it. Stop/teardown watchers on `removeRepository`.

**Add-repo flow** — after `addRepository`, seed the branch map (`currentBranch`), start a `HeadWatcher` for it, reload the sidebar, and **auto-select the repo's main checkout** so a session spawns immediately (existing select→ensure-surface path).

**Sidebar** — consume `sectionsWithMainCheckouts(...)`. The main row renders title "Default" + `repo · branch` subtitle (reuse the two-line `WorktreeCellView`; branch from the section). Context menu for an `isMain` row: **omit Archive and any branch-delete**; keep Reveal in Finder; Set Color is omitted on the main row in MVP (color is derived). Repo-header menu gains **"Remove Repository…"** → confirmation → `removeRepository` → evict surfaces for the returned worktrees **and** the repo's main checkout (`"\(repo.id)#main"`) → stop its watcher → reload.

**Surface lifecycle** — selecting the main checkout uses the existing per-worktree surface path: spawn a `TerminalSurface`/`SplitSurface` whose shell cwd is `repo.path`. Skip setup-script/copy-allowlist (those run only in `createWorktree`). Never auto-launch Claude regardless of `repo.autoLaunchClaude` (that setting governs freshly-*created* worktrees). ⌘R / Launch-Claude works in the active surface as today. Badge polling already walks `surfaces.worktreeIDs`, so the main checkout participates automatically once it has a surface.

### Edge cases

- **Detached HEAD / branch read fails** — `currentBranch` may return a non-branch state. Label the branch as the short HEAD SHA (or `"detached"`); never crash. Watcher still updates on further HEAD changes.
- **Non-git folder** — Conductor already assumes git repos (`createWorktree` uses git). Out of scope to support plain folders here; if `currentBranch` throws, fall back to an empty/`"–"` branch label and skip the watcher.
- **`.git` as a file** — only relevant inside linked worktrees; the *main* checkout's `.git` is a directory, so `<path>/.git/HEAD` is the right target.
- **Color index stability** — synthesized mains stay out of `state.worktrees`, so `IdentityPalette.color(at: state.worktrees.count)` at `createWorktree` time is unaffected.

## Testing

**Core (XCTest):**
- `Worktree.isMain` round-trips: decoding a persisted worktree yields `isMain == false`; `isMain` is not emitted on encode.
- Main-checkout factory: correct derived id, `worktreePath == repo.path`, title "Default", `isMain == true`, branch from supplied value + fallback.
- `sectionsWithMainCheckouts`: one main per repo, **prepended** above real worktrees; repos with zero real worktrees still get exactly the main row; repo/worktree ordering preserved; branch pulled from `branchForRepo` with fallback when missing.
- `removeRepository`: removes repo + its worktrees from state, persists, returns the removed worktrees; throws on unknown id; leaves other repos/worktrees intact; (asserts it performs no git/disk side-effects — verified via a stub `GitWorktree` whose remove/deleteBranch fail the test if called).
- Back-compat: a repo with existing real worktrees still groups correctly with the main prepended.

**In-app (manual, per the verify skill):**
- Add a repo → a "Default" session row appears under it and is auto-selected with a live shell in the repo dir.
- `git checkout -b other` (or switch) inside the repo's main dir → the main row's branch subtitle updates live, in place, no new row.
- Open multiple tabs / a split inside the main checkout; switch to another worktree and back → surfaces persist; badges roll up.
- Detached HEAD → short SHA shown, no crash.
- Remove Repository… → confirmation → repo + its rows disappear, all its surfaces are torn down, and **the repo directory + branches on disk are untouched** (verify with `git worktree list` / the dir still present).

## Out of scope

- Scratch (worktree-less) terminals — deferred; `.scratch` seam stays reserved.
- Cross-restart restore of tabs/layout (#14 stays deferred).
- Per-surface `runScript` / fuller per-surface config (Phase 3).
- Individually overriding the main checkout's color, renaming the "Default" title, hide-instead-of-remove.
