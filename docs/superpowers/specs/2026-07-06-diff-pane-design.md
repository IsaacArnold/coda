# 2c — Read-only diff pane — Design

**Date:** 2026-07-06
**Status:** Draft (pending spec review)
**Supersedes:** the "2c — Read-only diff surface (scope only)" section of
`2026-07-03-phase-2-rescope-and-hook-foundation-design.md`.

## Why this exists

Phase 2's 2a (authoritative badges) and 2b (notifications) shipped in v0.1.8. 2c — letting
you review the agent's changes **in-app** instead of leaving for VS Code / git — was left as
*scope only* in the Phase 2 spec, with one blocking question flagged: *what does the diff
compare against?* This spec answers that and settles the rest of the design, grilled
2026-07-06.

Two Supacode references shaped the UI:
- A small **+N −M line figure near each worktree name** (at-a-glance churn per worktree).
- A **GitHub-Desktop-style panel** for reviewing the changes.

## Key decision up front — a pane, not a `Surface`

The Phase 2 spec (and `CONTEXT.md`) reserved the diff view as a `Surface.kind = .diff` — i.e.
a **tab** that would replace the terminal when active. **We are retiring that seam.** A tab
hides the terminal behind the diff, which defeats the whole point for an agent-orchestration
tool: you want to review *while* the agent keeps working.

Instead: a **toggleable right-hand pane** (like the left sidebar / GitHub Desktop's panel),
sitting beside the terminal, scoped to the active worktree. The terminal stays visible.

**`CONTEXT.md` change (do at implementation):** the Surface definition currently says
"a single pane inside a worktree — for now a terminal; later a read-only diff view, etc."
Drop "read-only diff view" from Surface; note the diff pane as separate window chrome.
Remove `.diff` from any reserved-seam language; `SurfaceKind` stays `{ worktree, scratch }`.

---

## What it diffs (the blocking question, answered)

**Scope: branch-since-fork, flattened.** Everything this worktree's branch has changed
relative to its fork point — committed **and** uncommitted — as one unified review. Not
just uncommitted working-tree changes: Claude commits as it goes, so a working-tree-only
diff would go empty the moment the agent commits, hiding what it did.

- **No commit-history breakdown in v1.** One flattened diff, not a per-commit list. "What
  changed" matters more than "in which commit" when reviewing an agent; history can come later.

**Base resolution (fallback chain).** The comparison is `git merge-base <base> HEAD` → diff
that fork point against the working tree. `<base>` is resolved in order:

1. **The worktree's stored base branch name.** Add an optional `base: String?` to `Worktree`
   (same decode-if-present pattern as `color`), populated from the New Worktree dialog's
   base-branch picker (v0.1.10 already captures it — we just persist it now). Storing the
   **branch name** (not a frozen SHA) is self-correcting: as the base advances, `merge-base`
   stays at the true fork point, so you always see exactly what this worktree added.
2. **The repo's main-checkout branch** — resolved the same way `Worktree.mainCheckout` already
   does (`symbolic-ref`), so no guessing "main" vs "master". Used for worktrees created before
   this shipped (no stored base) and any with a missing base.
3. **Working-tree-only** (`git diff HEAD` + untracked) — the terminal fallback when no
   merge-base is computable (base deleted, unborn repo) and for the **main-checkout worktree
   itself** (it has no fork point).

The +/− figure and the pane always use the **same** resolved scope, so they never disagree.

**No backfill/migration** for existing worktrees — the main-checkout fallback is the right
answer for them and self-improves as new worktrees are created.

---

## The +/− figure

- **Metric:** lines — **+insertions / −deletions**, green / red. Not a files-changed count.
- **Where:** in the **sidebar rows** (triage across all worktrees at once) **and** mirrored
  in the **WorktreeBar** for the active worktree (the spacer at `WorktreeBar.swift:33` is the
  slot). Because updates are per-worktree events, inactive worktrees keep their figure live.
- **Scope:** identical to the pane (branch-since-fork, degrading to working-tree).
- **Untracked files:** counted as additions (every line is a "+"), matching the pane.
- **Rename detection:** on (`--find-renames`) — a moved file is one rename, not delete+add.
- **Zero state:** show nothing (no "+0 −0").

---

## The pane

**Layout: collapsible file sections in one vertical scroll.** Each changed file is a header
row (change-kind glyph + path + its own +N −M), expandable inline to that file's unified
hunks. The headers double as the file list and the navigation — fits a narrow right-hand
strip, where GitHub Desktop's horizontal master-detail would not.

- **Diff style:** unified (one column, +/− prefixed lines). Side-by-side needs width we
  don't have in the pane.
- **Coloring:** red/green line backgrounds, monospace. **No per-token syntax highlighting**
  in v1 (large effort for a read-only pane; line coloring carries the review).
- **Read-only:** no stage / discard / commit / line-level actions. Those belong to the
  deferred Git-operations milestone.
- **Header click = expand/collapse only.** No click-to-open-in-editor in v1 (the existing
  "Open in Editor" toolbar covers jumping out); could be a later right-click nicety.
- **Manual refresh** control in the pane (covers the human-hand-edit-no-hook gap, below).

**Guard rails:**
- **Binary files:** render "Binary file changed", not bytes.
- **Very large files/hunks:** cap rendered lines per file (e.g. collapse a >2,000-line diff
  behind a "Show large diff" click) so generated-file churn can't freeze the pane.

**Empty states:** "No worktree selected" (scratch terminal / no active worktree),
"No changes" (clean worktree). The toggle stays enabled in the empty case.

---

## Recompute cadence — event-driven, two-tier, no polling

Two costs, two tiers, driven by signals we already have — no blind timer:

- **+/− figure (cheap):** recompute on `PostToolUse`/`Stop` hook events for that worktree
  (already flowing into `handleHookEvent`, `AppDelegate.swift:1364`), on `HeadWatcher` change
  (commit / external checkout, `HeadWatcher.swift`), and when a worktree becomes active.
  Debounced ~300–500 ms (Claude fires `PostToolUse` in bursts). Runs `--numstat` only.
- **Full pane (expensive):** recompute on the same triggers **only while the pane is open**
  for the active worktree, plus the manual refresh. Computes nothing when closed.
- **No filesystem watcher in v1.** The agent is the primary mutator and hooks cover it. The
  one gap — a human hand-editing in an external editor with no hook and no commit — is
  covered by manual refresh (and the next HEAD change). A full FS watcher is YAGNI.

**Sidebar-wide population:** a serialized, low-priority **background sweep on launch** fills
every worktree's figure without stalling launch; events keep them live thereafter.

**Inherited boundary:** a Claude run that predates the hook install emits no events, so its
in-flight edits won't auto-tick the figure/pane — the same fallback the badges already have.
Commits (HeadWatcher), manual refresh, and re-activation catch it up; the next normally-started
run restores live updates.

---

## Toggle control

- **Toolbar item** `.toggleDiff`, placed **between `.launchClaude` and `.openIn`** in
  `toolbarDefaultItemIdentifiers` (`AppDelegate.swift:1530`). Shows a selected state when open.
- **Icon** `sidebar.right`, label **"Diff"**, tooltip **"Toggle Diff (⌃⌘D)"**.
- **Keybinding** new `.toggleDiff` action, **View** category, default **`Ctrl + ⌘ + D`**
  (parallels `Ctrl + ⌘ + S` = Toggle Sidebar; `⌘ + D` / `⌘ + Shift + D` are the split
  actions). Rebindable via the existing keybindings UI.
- **Menu** "Toggle Diff" item alongside Toggle Sidebar in the View menu, same action.

**Pane state:** one window-level toggle, **in-memory, default closed** (like the sidebar;
surfaces are already no-restore). When open it always reflects the active worktree; switching
worktrees repopulates it.

---

## Architecture (core / glue split)

Follows the existing pure-core + AppKit-glue pattern.

### `Sources/CodaCore/` (pure, unit-tested)
- **Unified-diff parser** — `git diff` patch text → typed model: `[DiffFile]` (path, change
  kind add/mod/del/rename, binary flag, `[DiffHunk]` → `[DiffLine]` of add/del/context). The
  correctness-critical piece; fixture patch text in, model out. Mirrors `AgentHookEvent` /
  `TerminalDrop`.
- **+/− aggregation** — numstat text (or the parsed model) → `(insertions, deletions)`,
  including the untracked-as-additions rule.
- **Base-resolution decision** — given (stored base?, main-checkout branch?, merge-base
  succeeded?) → mode `sinceFork(base)` vs `workingTreeOnly`. Pure branching; the git calls
  stay outside.
- **Large-file / binary thresholds** — cap constants + the "collapse this file?" predicate.

### `GitWorktree` (in `CodaCore`, runs git — as it already does)
- New methods: `mergeBase`, the diff patch (`git diff <base>` with `--find-renames`),
  `--numstat`, and untracked enumeration. For **untracked** files use
  `git diff --no-index /dev/null <file>` so one parser path handles them (no special-case
  render, binary/large guards apply). **Never `git add -N`** — it mutates the index; this is
  read-only. Integration-tested against temp repos like the existing `GitWorktreeTests`.

### `Sources/Coda/` (AppKit glue)
- The right-hand pane view (collapsible file sections), the `.toggleDiff` toolbar item +
  menu + keybinding wiring, the sidebar-row and WorktreeBar +/− labels, and wiring the
  recompute triggers (hook events / HeadWatcher / activate + background sweep) to
  `GitWorktree` → parser → render.

### Tests (`Tests/CodaCoreTests/`)
- Parser: add/modify/delete/rename, multi-hunk, binary, context lines, empty diff,
  malformed patch (tolerated), oversized/large-file classification.
- Aggregation: insertions/deletions summed; untracked-as-additions; zero state.
- Base-resolution decision: stored base → main branch → working-tree-only branches.
- `GitWorktree` diff methods against temp repos: since-fork vs working-tree, untracked via
  `--no-index`, rename detection.

---

## Non-goals / risks
- **Read-only only.** No stage / discard / commit / merge / PR — deferred Git-operations
  milestone. No commit-history breakdown, no syntax highlighting, no FS watcher, no
  click-to-open in v1.
- **`.diff` SurfaceKind retired** — not a tab. `CONTEXT.md` updated to match.
- **Risk — hook-run coverage:** figure/pane auto-update relies on hook events; pre-hook runs
  fall back to manual refresh + HEAD changes (same boundary as the badges).
- **Risk — large/binary churn:** guarded by the render caps and binary detection above.
- **Risk — base drift:** storing the base *branch name* + computing `merge-base` at review
  time is immune to the base advancing; a *deleted* base degrades to working-tree-only.
