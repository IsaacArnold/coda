# Global accent colour for the sidebar highlight

**Date:** 2026-07-10
**Status:** Approved

## Problem

The sidebar now keeps a persistent highlight fill on the focused worktree/branch
row (added by the recent "keep the focused worktree highlighted" change —
`FocusHighlightRowView`, forcing `isEmphasized`). That fill currently borrows the
macOS **system accent colour** — Coda has no say in it, and it changes per user
depending on their System Settings ▸ Appearance ▸ Accent choice.

Users want to choose Coda's accent themselves, independent of the OS, so the
highlighted worktree reads the way they want and matches the app's look.

## Scope (decided during brainstorming)

Deliberately narrow — one global choice, one surface:

- **Recolours:** only the sidebar's focused-worktree/branch highlight fill.
  Nothing else (no focus-pane border, no toolbar/controls, no per-worktree
  accent).
- **Picker:** the 8 curated Coda swatches only (`IdentityPalette.colors`). No
  free colour picker, no "follow system accent" option.
- **Default:** Dracula purple `#BD93F9` (the first palette swatch), overridable.
  This *does* change the out-of-the-box look for everyone (system-accent blue →
  purple), which is intended.

Explicitly out of scope (YAGNI): free NSColorPanel picking, a "follow macOS
accent" mode, broad app-wide tinting, per-repo/per-worktree accent overrides.

## Design

### 1. CodaCore — data model + pure logic

**`Preferences` (`Sources/CodaCore/Preferences.swift`)**

Add one field:

```swift
/// The app accent colour (hex) for the sidebar's focused-worktree highlight.
/// nil → the app default (AccentColor.defaultHex). Older prefs files without
/// the key decode to nil via the custom decoder below.
public var accentColor: String?
```

Wire it through `init` (defaulting to `nil`), `CodingKeys`, and the custom
`init(from:)` decoder with `decodeIfPresent(String.self, forKey: .accentColor)`
— matching the established backward-compatible pattern used by every other
optional/defaulted key, so existing `~/.coda/preferences.json` files keep
loading.

**New `AccentColor` helper (`Sources/CodaCore/AccentColor.swift`)** — pure, so it
is unit-testable without AppKit:

```swift
public enum AccentColor {
    /// Default accent — Dracula purple, the first identity-palette swatch.
    public static let defaultHex = "#BD93F9"
    /// The swatches offered in Settings (the curated identity palette).
    public static var swatches: [String] { IdentityPalette.colors }
    /// Resolve a stored preference (nil → default) to a concrete hex.
    public static func resolve(_ stored: String?) -> String { stored ?? defaultHex }
}
```

### 2. Settings UI — `GeneralSettingsViewController`

Add an **"Accent Colour"** section below the existing sections, following the
same title/hint/stack layout the pane already uses:

- A horizontal `NSStackView` of 8 small circular swatch buttons, one per
  `AccentColor.swatches` entry. Filled with `NSColor(hex:)`; the currently
  selected swatch is ringed (a focus ring / border) so the active choice is
  obvious.
- Clicking a swatch selects it (updates the ring) and fires a new
  `onChangeAccentColor: ((String) -> Void)?` with that swatch's hex.
- Hint: *"Colour of the selected worktree/branch in the sidebar."*

Init gains `accentColor: String` (the resolved hex) so the pane can pre-select
the active swatch. Swatch rendering can reuse `ColorMenu.swatchImage(_:)`'s
rounded-fill approach, drawn as circles for the inline row.

### 3. Wiring — `AppDelegate`

- On launch, compute `AccentColor.resolve(preferences.accentColor)` and:
  - pass it into `GeneralSettingsViewController`'s init, and
  - call `sidebar.setAccentColor(NSColor(hex: resolved) ?? .controlAccentColor)`.
- Set `general.onChangeAccentColor = { [weak self] hex in ... }` to:
  - persist (`self.preferences.accentColor = hex; try? self.prefsStore.save(...)`),
    mirroring the other `onChange…` handlers, and
  - update the sidebar live: `self.sidebar.setAccentColor(NSColor(hex: hex) ?? ...)`.

### 4. Rendering — `SidebarController` + `FocusHighlightRowView`

**`SidebarController`**

- Store `private var accentColor: NSColor` (seeded to the resolved default).
- `func setAccentColor(_ color: NSColor)`: store it, and refresh the visible rows
  so the highlight repaints (reload, or re-push the colour to existing row views
  and `needsDisplay`). Hand the colour to each row in
  `outlineView(_:rowViewForItem:)`.

**`FocusHighlightRowView`**

- Keep `isEmphasized` forcing so selection stays vivid regardless of first
  responder.
- Add `var accentColor: NSColor`.
- Override `drawSelection(in:)`: when `isSelected`, fill a rounded rect (matching
  the current source-list selection inset/radius) with `accentColor`, instead of
  the system emphasized fill.

**Legibility (the one real subtlety)**

Several swatches are light (`#F1FA8C` yellow, `#8BE9FD` cyan, `#50FA7B` green),
so a fixed white title on the fill would be unreadable. Drive text colour from
the accent's contrast:

- Compute `let onAccent = RGB(hex: accentHex)?.contrastingText.nsColor` (the same
  luminance-based black/white helper `WorktreeBar` already uses).
- On selection, set the worktree cell's **title** and **branch subtitle** to
  `onAccent` (subtitle at reduced alpha), via a small method on `WorktreeCellView`
  invoked from the row view's `isSelected` change. On deselect, restore defaults
  (`labelColor` / `secondaryLabelColor`).
- The `+N −M` stats and the branch glyph keep their existing colours — they stay
  readable on a saturated fill and preserve their diff/identity semantics.

This replaces the interim `WorktreeCellView.backgroundStyle` didSet that assumed
white-on-selection (correct only for dark fills).

## Testing

- **Unit (CodaCore, no AppKit):**
  - `AccentColor.resolve(nil) == AccentColor.defaultHex`.
  - `AccentColor.resolve("#FF5555") == "#FF5555"`.
  - `AccentColor.defaultHex` is a member of `AccentColor.swatches`.
  - `Preferences` round-trips `accentColor` through encode/decode, and a JSON
    blob **without** the key decodes to `accentColor == nil` (backward compat).
- **Manual / interactive (AppKit chrome, can't be unit-driven):**
  - New install / prefs without the key → highlight is purple.
  - Pick each swatch → sidebar highlight updates live and persists across relaunch.
  - Title/subtitle stay legible on light swatches (yellow/cyan/green) — contrast
    inverts to dark text.
  - Selecting then clicking into the terminal keeps the accent fill (regression
    check on the always-emphasized behaviour).

## Files touched

- `Sources/CodaCore/Preferences.swift` — add `accentColor` field + decoder.
- `Sources/CodaCore/AccentColor.swift` — new pure helper.
- `Tests/CodaCoreTests/…` — `AccentColor` + `Preferences` decode tests.
- `Sources/Coda/GeneralSettingsViewController.swift` — swatch section + callback.
- `Sources/Coda/AppDelegate.swift` — resolve, wire init + `onChangeAccentColor`,
  seed sidebar.
- `Sources/Coda/SidebarController.swift` — `accentColor` state, `setAccentColor`,
  `FocusHighlightRowView` accent fill + contrast-aware text, replacing the interim
  `backgroundStyle` didSet in `WorktreeCellView`.
