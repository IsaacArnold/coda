# Customizable Keybindings — Design

Date: 2026-06-25
Status: Approved (brainstorm), pending implementation plan
Related: PRD #4 milestone is complete; this is a new, standalone feature. Reference blueprint: Supacode's `AppShortcuts` system (`/Users/isaac/web-projects/supacode/SupacodeSettingsShared/App/`).

## Problem

Conductor's menu-bar keyboard shortcuts are hardcoded in `AppDelegate.buildMenu()`. Users can't change them — e.g. rebinding Toggle Sidebar, or disabling a shortcut they keep hitting by accident. We want a **Keyboard Shortcuts** pane in the Settings window where the user can rebind and enable/disable the app's commands, with conflict warnings.

## Scope

**In scope (this spec):**
- Rebind the 8 existing menu commands; persist overrides; per-command enable/disable; Restore Defaults (global + per-row).
- Conflict detection against (a) other app commands and (b) a known set of **reserved** chords — the terminal's ⌘K (Clear) plus a small hardcoded set of standard menu chords (Copy/Paste/Cut/Select-All, Quit/Hide/Close). Note: ⌘⌫ is *deliberately not* reserved — it's `archiveWorktree`'s default and intentionally coexists with the terminal's delete-to-line-start via focus-gating (PR #22), so flagging it would be a permanent false alarm.

**Out of scope (explicit):**
- macOS symbolic-hotkey (`com.apple.symbolichotkeys`) scanning.
- Layout-aware key display via `UCKeyTranslate` (we store/display the `keyEquivalent` character directly).
- Search/filter in the pane.
- Rebinding the terminal's own ⌘K / ⌘⌫ (they stay fixed — see `[[terminal-key-bindings]]`). Only ⌘K is *reserved* for conflict warnings; ⌘⌫ is excluded as noted in Scope.
- Per-repo shortcuts.

## Architecture

Follows the project's two-target split: all decision logic in `ConductorCore` (pure, the test seam); only AppKit wiring in `Conductor`. Mirrors existing patterns — `Preferences`/`PreferencesStore`, `terminalKeyAction`.

### Core model (`Sources/ConductorCore/Keybindings.swift`)

```
struct KeyModifiers: OptionSet, Codable, Hashable
    .command (1<<0), .shift (1<<1), .option (1<<2), .control (1<<3)

struct KeyChord: Codable, Equatable, Hashable
    key: String                 // the NSMenuItem keyEquivalent char, lowercased
                                 // (special keys normalized: ⌫ = "\u{8}", ⏎ = "\r", arrows, space)
    modifiers: KeyModifiers
    var display: String         // "⌘⌥R" — symbol map over modifiers + key

enum ShortcutCategory: String, CaseIterable   // worktree, repository, view, app
    var displayName: String
    var order: Int

enum ShortcutCommand: String, Codable, CaseIterable
    case newWorktree, launchClaude, openInEditor, revealInFinder, archiveWorktree,
         addRepository, toggleSidebar, openSettings
    var displayName: String
    var category: ShortcutCategory
    var defaultChord: KeyChord

struct ShortcutOverride: Codable, Equatable
    chord: KeyChord
    isEnabled: Bool

struct Keybindings: Codable, Equatable
    overrides: [String: ShortcutOverride]          // keyed by command.rawValue → clean JSON object
    func effectiveChord(for: ShortcutCommand) -> KeyChord?   // default → override.chord → nil if disabled
    func isEnabled(_ command: ShortcutCommand) -> Bool
    // mutation helpers: setting an override, disabling (override{defaultChord, isEnabled:false}),
    // resetting one command (remove its override), resetting all (overrides = [:])
```

**Default chords** (match today's menu): newWorktree ⌘N, launchClaude ⌘R, openInEditor ⌘O, revealInFinder ⌘⌥R, archiveWorktree ⌘⌫, addRepository ⌘⇧N, toggleSidebar ⌃⌘S, openSettings ⌘,.

### Conflict detection (pure, same file or sibling)

```
struct ReservedChord: Equatable { chord: KeyChord; label: String }   // e.g. (⌘K, "Clear")
enum ConflictReason: Equatable { case command(ShortcutCommand); case reserved(String) }
struct ShortcutConflict: Equatable { command: ShortcutCommand; reason: ConflictReason }

func keybindingConflicts(_ bindings: Keybindings,
                         reserved: [ReservedChord]) -> [ShortcutCommand: ShortcutConflict]
```

Rules: only **enabled** commands participate. Two enabled commands with the same effective chord → mutual `.command` conflict. An enabled command whose chord equals a reserved chord → `.reserved(label)`. Disabled commands never conflict.

`ConductorCore` exposes the reserved set the shell passes in:
`Keybindings.reservedChords` (static) = ⌘K "Clear" (the terminal's only always-shadowing, no-menu-fallback key) + standard menu chords (⌘C Copy, ⌘V Paste, ⌘X Cut, ⌘A Select All, ⌘Q Quit, ⌘H Hide, ⌘W Close). ⌘⌫ is intentionally omitted (see Scope).

### Special-key normalization (pure helper)

```
func normalizedKeyEquivalent(charactersIgnoringModifiers: String) -> String?
```
Maps a recorded event's characters to the `keyEquivalent` form NSMenuItem expects (Delete `\u{7f}`→`\u{8}`, Return, arrows, space, escape); returns the lowercased character for ordinary keys; `nil` for keys we don't support binding.

### Persistence (`Sources/ConductorCore/Keybindings.swift` or sibling)

```
final class KeybindingsStore
    init(url: URL)
    func load() -> Keybindings          // missing/corrupt file → Keybindings(overrides: [:])
    func save(_ bindings: Keybindings) throws   // pretty-printed, sorted keys, atomic
```
File: `~/.conductor/keybindings.json`. Mirrors `PreferencesStore` exactly.

## Shell (`Sources/Conductor`, verified in the running app)

### Tabbed Settings window
- Refactor the current single-pane `SettingsController` into an `NSTabViewController` (`tabStyle = .toolbar`) hosting:
  - `GeneralSettingsViewController` — today's default-editor picker, moved verbatim.
  - `KeybindingsViewController` — new.
- `AppDelegate.openSettings()` builds the tab controller (reused instance); ⌘, opens it on the General tab.

### Keybindings pane (`KeybindingsViewController`)
- `NSTableView` grouped by `ShortcutCategory`. Each command row: display name · a **chord button** (`⌘N`; bold when overridden) opening a recorder popover · an **enable checkbox** · a ⚠️ image with a tooltip when `keybindingConflicts` flags the command.
- **Restore Defaults** button (clears all overrides); per-row "Reset to Default" via context menu (removes that command's override).
- Any change → mutate the in-memory `Keybindings` → `store.save(...)` → invoke a callback that has `AppDelegate` rebuild the menu and re-run the conflict check to refresh warnings.

### Recorder (`HotkeyRecorderView: NSView`)
- Overrides `performKeyEquivalent(with:)` to capture the next keyDown (so the chord doesn't trigger a menu item). Requires ≥1 modifier; Esc cancels. Translates `NSEvent` → `KeyChord` using `normalizedKeyEquivalent` + the event's modifier flags. The pane runs `keybindingConflicts` on the proposed binding and shows the warning inline before committing (commit still allowed; warning is advisory, matching Supacode).

### Menu wiring (`AppDelegate`)
- New stored `keybindingsStore` + `keybindings`, loaded in `applicationDidFinishLaunching`.
- `buildMenu()` reads each of the 8 commands' `effectiveChord` to set `keyEquivalent` + `keyEquivalentModifierMask`. A disabled command (`effectiveChord == nil`) gets an empty key equivalent — the menu item stays clickable. Standard items (Quit/Hide/Copy/Paste/About/Close) remain hardcoded.
- A `rebuildMenu()` path re-runs `buildMenu()` after a binding change so shortcuts update live.

## Testing

**Core (TDD — the bulk of the work):**
- `KeyChord.display` for representative chords; Codable round-trip.
- Every `ShortcutCommand` case has a `defaultChord` and a `category`.
- `effectiveChord`: returns default with no override; returns override chord; returns `nil` when disabled.
- `KeybindingsStore`: missing file → empty overrides; save→load round-trip; a fresh store on the same URL reads from disk; JSON is keyed by command rawValue (object, not array).
- `keybindingConflicts`: two commands same chord → mutual conflict; command equals a terminal reserved chord → `.reserved`; disabled command excluded; **defaults are conflict-free** (sanity).
- `normalizedKeyEquivalent`: delete/return/arrow/space mappings; ordinary char lowercased; unsupported → nil.

**Shell (verified in the running app, per the project's testing philosophy):**
- ⌘, opens the tabbed Settings window; General shows the editor picker.
- Keyboard Shortcuts pane lists the 8 commands grouped by category with current chords.
- Recording a new chord updates the menu's key equivalent live; the menu item triggers on the new chord.
- Conflict warning appears when a chord matches another command or a reserved/terminal chord.
- Disabling a command removes its menu shortcut but leaves the item clickable.
- Restore Defaults (and per-row reset) revert chords; persist across relaunch.

## Build order (for the plan)
1. Core model + defaults + `effectiveChord` (+ tests).
2. Conflict detection + reserved set + normalization helper (+ tests).
3. `KeybindingsStore` (+ tests).
4. Menu wiring: `buildMenu()` reads effective chords; load at launch; `rebuildMenu()`.
5. Tabbed Settings window: split `SettingsController` into a tab controller + General pane.
6. Keybindings pane + recorder; wire save → rebuild.

## Toolchain
Prefix every `swift build`/`run`/`test` with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Tests are XCTest.
