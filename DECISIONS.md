# Conductor — Design Decisions & Phasing

A terminal-first native macOS app for managing Claude Code workflows.
Inspiration: Supacode (worktree/agent orchestration) + iTerm2 (tabs, colors, snippets, cmd+click) + Ghostty (aesthetic).

_Living document — updated during the `/grill-me` design session. Last updated: 2026-06-24._

---

## Decisions locked

| # | Decision | Choice |
|---|----------|--------|
| 1 | App category | **Orchestrator** around an embedded terminal — not a from-scratch emulator. |
| 2 | Terminal engine | **SwiftTerm** embedded in a native SwiftUI/AppKit shell. |
| 3 | Primary unit | **Hybrid, worktree-centric**: worktree-backed sessions are the star; plain throwaway tabs are an escape hatch. |
| 4 | Spatial hierarchy | **3-level**: sidebar (repos → worktrees) → per-worktree surface tabs → splits. iTerm's colored tab bar = the surface tab bar. |
| 5 | Agent awareness | **Heuristic output-watching for MVP → localhost HTTP-hook server** as the robust upgrade. Same badge UI either way. |
| 6 | New-session default | **Auto-launch Claude in a fresh, set-up worktree** (Claude-first) + per-repo `setupScript`. |
| 7 | Integration (work out of worktree) | **Local-only** (archive/delete + branch cleanup → one-button local merge). GitHub PRs deferred. |
| 8 | Surfaces & editing | **Terminal surfaces + cmd+click → external editor (VS Code)** for v1. Read-only diff surface as fast-follow. **Never build a built-in editor.** |
| 9 | Config storage/sync | **File-based with portable-vs-local split.** Portable (snippets, themes, keybinds, prefs) → dotfiles-committable, no absolute paths. Machine-local (repo roots, worktree paths) → git-ignored. No cloud backend. |
| 10 | Snippets | **Static, iTerm2-style** (zsh snippets): saved text + optional keybind → sent to focused terminal, per-snippet paste vs paste+run. No templating. Global, optional repo scoping. In portable config. |
| 11 | Theming | **Full theming (terminal grid + app chrome)** with **`.itermcolors` import** for the grid colors. Native theme format for chrome, in portable config. |
| 12 | Names + colors | **Both levels (C):** worktree carries name+color (drives full-width bar + sidebar entry); surface tabs can override. Manual, with optional auto-by-repo. Identity-color kept visually separate from state badge. |
| 13 | "Terminal-first" / CLI | **GUI is the hero for MVP; companion CLI deferred to Phase 2.** Phase-2 killer use: Claude calls `conductor new "try approach B"` to fork a sibling agent. CLI = local socket + command protocol, designed when added. |
| 14 | Restart restore | **Layout-only restore for v1** (sidebar, surface layout, names/colors, focus re-attach to on-disk worktrees; terminals start fresh). **Claude `--resume <session_id>` restore in Phase 2.** Quit never destroys worktrees/branches. |
| 15 | New-worktree file copy | **Per-repo copy-allowlist, default empty** (e.g. `.env`). `node_modules`/deps handled by `setupScript`, not copying. Allowlist lives in machine-local config. |
| 16 | Notifications | **In-app cues only for MVP** (badge + move-needy-worktree-to-top). **macOS system notifications in Phase 2**, gated on reliable hook signal; separate notify-on-needs-you / notify-on-done toggles; click banner → focus worktree. (User currently covered by an Apple Shortcut Claude triggers.) |
| 17 | Build sequencing | **Spike SwiftTerm first** (prove: render shell, inject text, cmd+click→VS Code, `.itermcolors`, 2 instances in splits), **then a vertical slice** (create worktree → SwiftTerm surface running `claude` → archive). Breadth after. |
| 18 | Distribution | **Build from source on each Mac** for now; escalate to Developer ID + notarization only if the work laptop blocks unsigned local builds. ⚠️ Brew-installing notarized Supacode ≠ permission to run an unsigned local build — verify Xcode + unsigned-run on the work Mac. |

## Remaining small defaults (assumed unless changed)

- **Working name:** Conductor (matches repo dir; rename anytime).
- **UI stack:** SwiftUI for chrome + AppKit (`NSViewRepresentable`) to host SwiftTerm, which is AppKit-based.
- **Target OS:** a recent macOS (both Macs are current); pin exact min-version at project setup.
- **Window model:** single main window with the 3-level layout (multi-window deferred).
- **Keybinds:** global keybinds for snippets + core actions, rebindable, stored in portable config.

## SwiftTerm 1.13.0 API notes (from the spike)

- **Engine:** `LocalProcessTerminalView` (AppKit) — `startProcess(executable:args:environment:execName:currentDirectory:)`, `terminate()`. Delegate: `LocalProcessTerminalViewDelegate` (sizeChanged, setTerminalTitle, hostCurrentDirectoryUpdate via OSC 7, processTerminated).
- **Inject text (snippets):** `view.send(txt: String)`. ✅ trivial.
- **Theming:** `view.installColors([Color])` (16 ANSI), `Color(red:green:blue:)` UInt16 0–65535; `nativeForegroundColor` / `nativeBackgroundColor` / `caretColor` / `selectedTextBackgroundColor` (NSColor). `.itermcolors` is a plist → parse with PropertyListSerialization.
- **cmd+click:** built-in command-modifier tracking + `requestOpenLink(source:link:params:)` delegate. Implicit detection uses **Ghostty's URL regex → URLs only**, not bare file paths. Internal hit-test helpers (`calculateMouseHit`) are not public, but `getTerminal()`, `getText(start:end:)`, `getCharData`, `getLine` ARE public — so file-path cmd+click is done with a custom `mouseDown` reading the clicked line. (Refinement: screen→buffer row mapping under scrollback; or upstream file-path link detection / OSC 8.)

## Spike verdict (2026-06-24) — ✅ COMPLETE — SwiftTerm 1.13.0, `swift run` AppKit app

Throwaway spike at `spike/swiftterm-spike/`. **All five capability checks + bonus keybinds verified working by the user → SwiftTerm confirmed as the engine. Engine risk retired.**

| Check | Result |
|-------|--------|
| ① Real shell rendering | ✅ `LocalProcessTerminalView` + `startProcess` |
| ② Programmatic input (snippets) | ✅ `send(txt:)` |
| ③ cmd+click → file:line → VS Code | ✅ read token from buffer → exec `code --goto <path>:<line>:<col>` |
| ④ `.itermcolors` import + theming | ✅ plist parse → `installColors` + native fg/bg/caret colors; live toggle |
| ⑤ Two+ PTYs in a split | ✅ `NSSplitView` + `setPosition(_:ofDividerAt:)`; dynamic add-pane works |
| (bonus) iTerm-style keybinds | ✅ ⌘K→Ctrl-L, ⌘⌫→Ctrl-U by sending control bytes to PTY |

**Key learning: every bug hit was the bare `swift run` harness or generic AppKit, NOT SwiftTerm.** All of these are gone/trivial in a real bundled `.app`.

**Gotchas to carry into the real app:**
- SwiftTerm's `mouseDown`/`keyDown` are `public` but **not `open`** → can't subclass-override from outside the module. Use **`NSEvent.addLocalMonitorForEvents`** to intercept ⌘+click / ⌘+key before the view. (Or upstream `open` annotations / file-path link detection.)
- **Editor open:** bare binary can't use LaunchServices (`open`/`NSWorkspace`/`vscode://` all flaky → `-50`); spike execs `code --goto` directly. In the bundled `.app`, prefer the **`vscode://file/<path>:<line>` URL scheme** (no helper-process flicker, focuses the running instance) with `code --goto` as fallback.
- cmd+click currently assumes **no scrollback offset** (screen row == buffer row) and scans clicked row ± neighbors. Production needs proper screen→buffer row mapping (SwiftTerm's hit-test helpers are `internal`).
- iTerm conveniences (⌘K clear, ⌘⌫ kill-line, etc.) are **ours to add** — SwiftTerm gives the raw grid. Trivial: send control bytes to the PTY. This is the "keybinds" feature, confirmed cheap.
- **NSSplitView** leaves the first arranged subview full-width unless you `setPosition(_:ofDividerAt:)` after layout. Generic AppKit, not SwiftTerm.
- Swift 6 strict concurrency vs. AppKit main-actor: spike used `swiftLanguageModes: [.v5]`; real app should adopt `@MainActor` / default-MainActor isolation properly.

## Vertical slice (Phase 1 spine) — ✅ COMPLETE (verified 2026-06-24)

End-to-end, verified in the running app: register repo → create worktree-session (branch + worktree + auto-launched `claude` in an embedded SwiftTerm) → switch between sessions → archive (worktree dir removed, branch deleted, session dropped from config) → state persists across relaunch.

- **Architecture:** Swift package, two targets. `ConductorCore` (pure logic: `ProcessRunner`, `slugify`, `GitWorktree`, `Repository`/`Session`/`Config`, `SessionStore`) — 17 XCTest tests, all green. `Conductor` (AppKit shell: `AppDelegate` + `NSSplitViewController`, `SidebarController`, `TerminalSurface`).
- **Toolchain gotcha (important for the work laptop too):** Command Line Tools ship neither XCTest nor the Testing framework — running tests requires Xcode's toolchain. Prefix every `swift build`/`run`/`test` with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Plan/code use XCTest, not Swift Testing. Package stays at `.macOS(.v13)`, no linker hacks.
- **AppKit gotchas learned:** start the embedded terminal in `viewDidLayout` (not `viewDidAppear`) so zero-bounds-at-appear doesn't permanently skip it; embed surfaces as constrained subviews of a stable detail view (reassigning an `NSViewController.view` inside `NSSplitViewController` strips the pane's sizing constraints → blank).
- **Plan:** `docs/superpowers/plans/2026-06-24-conductor-vertical-slice.md`. Built via subagent-driven development on branch `conductor-vertical-slice`.

Next Phase-1 plans layer on: setupScript + copy-allowlist, theming/.itermcolors, snippets, agent-state badges, tab/surface colors, cmd+click, multi-surface, restore-running-agents.

**Slice follow-ups (from final review, deferred — fold into next plan):**
- `SessionStoreError` should get a `CustomStringConvertible` so `presentError` shows readable text (today it interpolates the raw enum case).
- Sidebar lists only sessions, so "Add Repo…" gives no visible feedback — surface repos or confirm.
- `TerminalSurface.command` is unquoted (safe today: only literal `"claude"`); quote/guard when a user-supplied command is wired in.
- Atomicity gap: if `git.add` succeeds but `config.save` throws, an orphan worktree can remain (and vice versa on archive). Unlikely with atomic-write JSON; revisit when state grows.

## To verify during the spike / setup

- SwiftTerm capabilities (the 5 spike checks above) — biggest technical risk.
- Exact Claude Code hook payload fields against the installed version (before Phase-2 hook server).
- Work-laptop permission to build/run an unsigned local app (Xcode + Gatekeeper/MDM).

## Agent-state → badge mapping (from Claude Code hooks)

- 🟡 Working — `UserPromptSubmit`, `PreToolUse`, `PostToolUse`
- 🔴 Needs you — `Notification` (permission/idle prompt)
- 🟢 Done/idle — `Stop`, `StopFailure`
- ⚪️ Lifecycle — `SessionStart` / `SessionEnd`
- Correlate firings to worktree via `cwd` + `session_id` + `transcript_path`. Transport: `http` hook type → localhost server.

---

## Phased backlog (the "additions" we keep deferring)

### Phase 1 — MVP
- SwiftTerm embedded in 3-level shell (sidebar / surface tabs / splits)
- Worktree create (fetch → branch → `setupScript` → auto-launch Claude)
- Worktree archive/delete with branch cleanup
- Heuristic agent-state badges in sidebar
- Tab colors + naming, theming, snippets+keybinds, cmd+click → VS Code _(all still to be grilled)_

### Phase 2 — Fast-follows
- Localhost HTTP-hook server → authoritative agent badges (replaces heuristic)
- One-button local merge to main
- Read-only **diff surface** (review the agent's changes in-app)

### Phase 3 — Later
- GitHub PR integration (create PR, status, merge → archive)
- Fuller per-surface configurability (per-surface `runScript`, etc.)

### Explicitly out of scope
- Writing our own terminal emulator
- A built-in code editor / mini-IDE
