# Conductor — Theming Milestone Design

_Spec for the milestone after PRD #4. Brainstormed & locked 2026-06-25. Source of truth for decisions: `DECISIONS.md` (#11, #12) + `CONTEXT.md` glossary._

## Goal

Make Conductor behave like iTerm2 when a color theme is applied: importing/selecting a `.itermcolors` theme repaints the terminal grid **and** blends the app chrome into the terminal's background color, for a seamless "the whole window is the theme" look. Independently, each worktree carries an identity color that drives a full-width bar + sidebar accent — Conductor's equivalent of iTerm's per-tab color.

Non-goals (deferred): a hand-editable custom chrome palette + editor (the granular follow-up); per-worktree or per-repo terminal themes; light/dark theme *variants* of a single theme; OSC-based dynamic theme changes from the shell.

## Two color systems (kept strictly separate)

### 1. Terminal theme — global, `.itermcolors`

- **One** active theme app-wide (no per-worktree/per-repo override this milestone). Switching worktrees never re-themes the terminal or chrome.
- A theme = 16 ANSI colors + foreground + background + cursor, parsed from a `.itermcolors` plist.
- **Reuse the spike's parser** (`spike/swiftterm-spike/Sources/Spike/ITermColors.swift`): plist keys `Ansi 0 Color`…`Ansi 15 Color`, `Foreground Color`, `Background Color`, `Cursor Color`; each a dict of `Red/Green/Blue Component` floats 0–1. ANSI → `SwiftTerm.Color(red:green:blue:)` via `component * 65535` (clamped). fg/bg/cursor → `NSColor(srgbRed:…)`. Lift this into `ConductorCore` as `TerminalTheme` with `TerminalTheme.load(from: URL)`.
- **Applied to terminals** via `installColors(theme.ansi)` + `nativeForegroundColor` / `nativeBackgroundColor` / `caretColor` (per the spike's `applyTheme`).

### 2. Worktree identity color — chrome only

- Each worktree carries a `color`. **Auto-assigned** from a curated palette at creation, cycling so siblings differ; **manually overridable** via the sidebar right-click menu → "Set Color…".
- Drives **only** chrome: the full-width bar fill + the sidebar row accent. **Never** touches the terminal grid (preserves the imported theme's contrast).

## The iTerm2 "seamless" chrome — derived, behind one seam

Chrome is **computed from the active terminal theme**, not hand-edited:

- Toolbar, sidebar, and window background **adopt the terminal background color**.
- `NSApp.appearance` is set to `.aqua` or `.darkAqua` by the background color's **luminance**, so native controls, text, and glyphs stay legible.
- One **accent** is derived from the theme (e.g. a mid ANSI or the foreground) for themeable chrome bits (selection, glyph tints).

**The seam (critical for the future granular path):** every chrome color read routes through a single resolver type — `ChromeTheme` — built from the active `TerminalTheme`. No view reads a raw `NSColor` literal anymore. `ChromeTheme` exposes named roles (e.g. `windowBackground`, `primaryText`, `secondaryText`, `accent`, `glyphTint`) and an **override-aware fallback**: each role returns its stored override if present, else the derived value. Today no overrides exist (all derived); the future granular milestone fills in override fields + an editor — additive, no re-plumb of call sites.

Current hardcoded color call sites to migrate behind `ChromeTheme` (from code map):
- `SidebarController` repo-header text + glyph tints (`.secondaryLabelColor`, lines ~178/218/261)
- `AppDelegate` notch label + icon tint (~453/457)
- badge dots stay state-driven (see below)

**Badge dots** (`agentBadgeColor`: working/needsYou/done) remain **state colors**, intentionally separate from identity color and chrome accent (per #12 — identity color kept visually distinct from state badge). They may be lightly adapted for legibility against the themed chrome but are not part of the derived palette.

## Layout changes

- **Full-width bar** spanning the detail pane, directly under the toolbar: identity-color fill + worktree name + branch + agent badge. Bar text/foreground auto-selects black or white by the identity color's luminance for contrast.
- **Centre notch demoted**: keeps only the ambient time-of-day glyph (`notchTimeStyle`). Its former worktree-name + agent-badge role moves to the bar — no duplication.

## Storage & persistence (portable vs machine-local, per #9)

**Portable** (`~/.conductor/`, dotfiles-committable):
- `~/.conductor/themes/*.itermcolors` — imported themes copied **as-is** (fastest; reuses the parser; re-exportable). Plus bundled starter themes seeded here on first run if absent.
- `preferences.json` — gains `activeTheme: String` (theme name). Backward-compat decode: missing → the default bundled dark theme.

**Machine-local** (`local.json`):
- `Worktree` gains `color` (palette index or hex). Backward-compat custom decode (mirrors `Repository`): missing → auto-assign on next load/create. Lives here because it's tied to a specific on-disk worktree.

**Bundled starter themes:** ship ~3 (a dark default + a light + one popular e.g. Solarized) so first run looks intentional pre-import. Default active = the dark one.

## UI surfaces

- **Settings → new "Themes" tab** (`paintpalette` SF Symbol), added to `SettingsTabController` alongside General + Keyboard Shortcuts: a list of available themes with preview swatches, an "Import `.itermcolors`…" button (file picker → copy into themes dir), click-to-apply.
- **Sidebar right-click → "Set Color…"** extends the existing context menu (`SidebarController` `NSMenu` delegate) with palette swatches to override a worktree's identity color.

## Live application (the `applyKeybindings` precedent)

- `applyTheme(_ theme: TerminalTheme)` (in AppDelegate, parallel to `applyKeybindings`): persist `activeTheme`, re-apply colors to **all live terminals**, rebuild `ChromeTheme`, repaint chrome (window appearance + accent + bar + sidebar). Immediate, no relaunch.
- `setWorktreeColor(_:for:)`: persist + repaint that worktree's bar + sidebar row immediately.

## Architecture / new + changed units

**ConductorCore (pure logic, TDD-first):**
- `TerminalTheme.swift` — struct + `load(from: URL)` (lifted/adapted from spike `ITermColors.swift`). Tests: parse a fixture `.itermcolors`, ANSI count = 16, component→UInt16 scaling, fg/bg/cursor, malformed-plist error.
- `ChromeTheme.swift` — derive named roles from a `TerminalTheme`; luminance → appearance decision; override-aware fallback (override map empty for now). Tests: luminance threshold (dark bg → dark appearance, light bg → light), derived role values, override takes precedence when present.
- `IdentityPalette.swift` — curated palette + cycling auto-assignment; luminance-based contrasting text color. Tests: cycling/distinct-sibling assignment, contrast text pick.
- `Worktree.color` — model field + backward-compat decode + auto-assign on create in `WorktreeStore`. Tests: decode old JSON (no color), new worktree gets next palette color.
- `Preferences.activeTheme` — field + backward-compat decode. Test: old prefs JSON decodes with default.
- A `ThemeStore` (or fold into existing stores) for listing/copying `~/.conductor/themes/` + seeding bundled themes. Tests: list, import-copy, seed-if-empty.

**Conductor (AppKit shell):**
- `WorktreeBar.swift` — the full-width bar view (identity fill + name + branch + badge).
- `ThemeSettingsViewController.swift` — the Themes tab (list + swatches + import).
- Migrate chrome color call sites in `SidebarController` / `AppDelegate` behind `ChromeTheme`.
- `TerminalSurface` — apply `TerminalTheme` colors on creation + on `applyTheme`.
- `SettingsTabController` — add the Themes tab.
- `AppDelegate` — `applyTheme`, `setWorktreeColor`, notch demotion, bar wiring; seed bundled themes on launch.

## Build sequencing (Core-first, TDD, subagent-driven; pause for in-app check before merge)

1. **Core models & parsing**: `TerminalTheme` (lift from spike), `Preferences.activeTheme`, `Worktree.color` + auto-assign, `IdentityPalette`, `ThemeStore` — all with XCTest.
2. **`ChromeTheme` resolver** (derive + luminance + override-aware fallback) with tests.
3. **Terminal application**: wire `TerminalTheme` into `TerminalSurface` + `applyTheme` across live terminals.
4. **Chrome derivation**: migrate chrome call sites behind `ChromeTheme`; repaint window appearance/accent/sidebar on `applyTheme`.
5. **Full-width bar + notch demotion**: `WorktreeBar`, move status off the notch.
6. **Settings Themes tab + import**; **sidebar "Set Color…"**.
7. Final whole-branch review → in-app verification by user → PR.

## Toolchain

Every `swift build`/`run`/`test` must be prefixed `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Tests are XCTest, not Swift Testing. Package stays at `.macOS(.v13)`.

## Open implementation details (decide during planning, not blocking)

- Exact luminance threshold + accent-selection rule for `ChromeTheme` (tune visually in the in-app check).
- Whether `Worktree.color` stores a palette index vs hex (index = stable to palette edits; hex = explicit). Lean hex for manual overrides, with auto-assign writing the palette hex.
- How aggressively chrome adopts the *exact* terminal bg vs a slightly adjusted tone for toolbar/sidebar separation (iTerm uses subtle deltas).
