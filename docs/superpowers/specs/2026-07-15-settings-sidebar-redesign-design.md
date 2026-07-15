# Settings Sidebar Redesign

**Date:** 2026-07-15
**Status:** Approved design, ready for planning

## Problem

Coda's Settings window has grown messy. Today it is a macOS *toolbar-tab*
window (`NSTabViewController`, `.toolbar` style) with three tabs:

- **General** — a single long, cramped vertical stack of eight unrelated
  sections (Default Editor, Terminal Font & Size, Interface Size,
  Notifications, Shell, Command Completions, Accent Colour, App Icon).
- **Themes**
- **Keyboard Shortcuts**

Related settings are not grouped, the General tab is a wall of controls, and
there is no visual structure. We want a settings screen like Supacode or macOS
System Settings: a source-list **sidebar** of categories on the left and a
**detail pane** of grouped "cards" on the right, so users can find what they
need quickly.

## Scope

**Visual reorganization only.** No settings are added or removed. Persistence
behaviour is unchanged. The per-repository settings *sheet*
(`RepoSettingsController`) is out of scope and stays a separate sheet.

## Goals

- Replace the toolbar-tab layout with a sidebar + grouped-cards layout.
- Re-sort the ten existing settings into five sensible categories.
- Match the visual language of macOS System Settings / Supacode (grouped
  rounded cards, title + grey subtitle rows, trailing `NSSwitch` toggles).
- Do it without changing what gets persisted or when.

## Non-goals

- No new settings, features, or categories (no Updates / GitHub / Global
  Scripts panes).
- No change to the persistence model (`Preferences`, `~/.coda/preferences.json`,
  keybindings store, theme store).
- No change to the per-repository settings sheet.

## Category taxonomy (five categories)

| Category | SF Symbol | Settings |
|---|---|---|
| **General** | `gearshape` | Default Editor, Interface Size, App Icon |
| **Appearance** | `paintpalette` | Theme (list + Import/Apply), Accent Colour (hue swatches + Custom…) |
| **Terminal** | `terminal` | Font & Size, Shell, Command Completions (toggle) |
| **Notifications** | `bell` | Agent needs you, Agent finishes, Dock badge (toggles + subtitles) |
| **Shortcuts** | `keyboard` | Keyboard shortcuts (existing list, restyled header) |

## Architecture

All AppKit (the codebase has zero SwiftUI). Programmatic Auto Layout with
`NSStackView`, consistent with the existing settings code. Follows the existing
callback-injection pattern (controllers are pure UI; `AppDelegate` owns
persistence and live application).

### New / changed controllers

- **`SettingsWindowController` + `SettingsSplitViewController`** — replaces
  `SettingsTabController`. An `NSSplitViewController` with two split items:
  1. `SettingsSidebarViewController` — a source-list `NSTableView` (icon +
     label per row), styled as a sidebar.
  2. A detail container that swaps the selected pane VC as its only child.
- **Five pane view controllers**, each isolated and independently testable /
  understandable:
  - `GeneralPaneViewController`
  - `AppearancePaneViewController` (absorbs the current
    `ThemeSettingsViewController` content + the accent-colour controls that
    currently live in `GeneralSettingsViewController`)
  - `TerminalPaneViewController`
  - `NotificationsPaneViewController`
  - `KeybindingsViewController` — reused as-is for the Shortcuts pane, with its
    header restyled to match the new panes.

### Source of truth for the sidebar

- **`SettingsCategory`** enum — the single source of truth for the sidebar
  rows. It is a **pure-data** enum (case, display title, SF Symbol name; sidebar
  order = enum order) with no AppKit dependency, so it can live in `CodaCore`
  and be unit-tested directly. The mapping from a `SettingsCategory` to the
  AppKit pane VC it builds (from the `SettingsContext`) lives in the Coda UI
  layer, keeping the enum framework-free.

### Reusable card kit

Built once, used by every pane so they read as one system:

- **`SettingsCard`** — a rounded grouped container view that vertically stacks
  rows with hairline separators between them (System Settings "grouped box").
- **`SettingsRow`** — leading title label + optional grey subtitle
  (`.secondaryLabelColor`, small system font), trailing control (an
  `NSSwitch`, `NSPopUpButton`, stepper, button, etc.).
- **`SettingsPane`** scaffold — gives each pane a scroll view, a large title
  header, and a vertical stack of cards. Panes are assembled by adding cards to
  this scaffold.

### Control changes

- The Command Completions checkbox and the three Notifications checkboxes
  become trailing **`NSSwitch`** toggles.
- Each Notifications row gains a one-line grey subtitle (copy drafted during
  implementation for review).
- All other controls (pop-ups, font picker, stepper, hue swatches, app-icon
  gallery, theme table) keep their control types; only their container styling
  changes to cards/rows.

## Wiring & persistence (behaviour unchanged)

No settings added/removed. Persistence stays exactly as-is: `Preferences` →
`~/.coda/preferences.json` (write-through on change via `AppDelegate`), the
keybindings store, and the theme store/directory.

To avoid the constructor bloat already flagged (`SettingsTabController` takes
20+ parameters; adding structure would make it worse), introduce a
**`SettingsContext`** struct that bundles every current initial value plus
every `onChange` closure. `AppDelegate` builds one `SettingsContext` and hands
it to the split controller; each pane VC reads only the values and closures it
needs. This is a *plumbing* refactor only — it changes how values and callbacks
are passed, not what is saved or when.

## Window

- Resizable `NSSplitViewController` window (replaces the fixed 620×520 toolbar
  window).
- Sidebar ≈ 200 pt wide; detail pane with a minimum content size (~720×560) so
  cards always lay out cleanly.
- Preserves the existing entry points and chrome: `⌘ ,`
  (`ShortcutCommand.openSettings`), the App-menu "Settings…" item, controller
  reuse (`isReleasedWhenClosed = false`), and theme chrome re-application on
  open (`applyWindowChrome`).

## Verification

- **Unit tests** for the pieces with real logic: `SettingsCategory` (ordering,
  symbols, titles, count) and `SettingsContext` wiring/defaulting.
- **Visual verification** for the AppKit layout the way this repo already does
  GUI work: snapshot each pane to a PNG in-app and inspect it. AppKit layout is
  not meaningfully unit-testable, so the visual result is verified by
  inspection rather than asserted in tests.
- Confirm no persisted behaviour changed: every setting still reads its initial
  value and still writes through to the same file on change.

## Files affected (anticipated)

**Replaced / heavily changed** (`Sources/Coda/`):
- `SettingsTabController.swift` → removed, replaced by
  `SettingsWindowController` / `SettingsSplitViewController` /
  `SettingsSidebarViewController`.
- `GeneralSettingsViewController.swift` → split into `GeneralPaneViewController`
  + contributions to `AppearancePaneViewController` / `TerminalPaneViewController`
  / `NotificationsPaneViewController`.
- `ThemeSettingsViewController.swift` → folded into
  `AppearancePaneViewController`.
- `KeybindingsViewController.swift` → reused, header restyled.

**New** (`Sources/Coda/`):
- `SettingsCategory.swift` (pure-data enum, in `CodaCore`)
- `SettingsContext.swift`
- Card kit: `SettingsCard.swift`, `SettingsRow.swift`, `SettingsPane.swift`
- The five pane VCs.

**Touched:** `AppDelegate.swift` (`openSettings()` builds the new split
controller + `SettingsContext`; the per-setting write-through setters are
unchanged).

**Unchanged:** `Preferences.swift`, `PreferencesStore`, `KeybindingsStore`,
`ThemeStore`, `RepoSettingsController.swift`, all persistence.
