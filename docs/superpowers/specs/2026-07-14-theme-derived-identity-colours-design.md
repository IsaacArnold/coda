# Theme-derived identity colours + Xcode/Rider themes

**Date:** 2026-07-14
**Status:** Approved
**ADR:** [docs/adr/0001-theme-derived-identity-colors.md](../../adr/0001-theme-derived-identity-colors.md)

## Problem

Two gaps in Coda's theming:

1. **Identity colours don't follow the theme.** App *chrome* already derives from
   the active theme (`ChromeTheme`), but repo / worktree / surface-tab identity
   colours — and the focused-row accent — are frozen hex strings auto-assigned
   from a **hardcoded Dracula palette** (`IdentityPalette.colors`). Switch to
   Nord or Solarized and every repo tag stays Dracula purple/green. They should
   be *based off the theme the user sets*.
2. **Too few themes.** Only Dracula, Nord, Solarized Light, IsaacTheme ship. Users
   want the familiar JetBrains Rider (Darcula) and Xcode looks.

## Scope (decided during grilling — see ADR 0001)

- Identity colours become **theme-derived hue roles** that restyle **live** on
  theme switch, with a **pinned-hex** escape hatch. Applies to all four identity
  surfaces: repo, worktree, surface tab, and the app accent.
- **8 hues**: `red, orange, yellow, green, cyan, blue, purple, pink`.
- **Curated palette per theme** (hand-authored hue→hex), **ANSI fallback** for
  imported themes with no curation. Curate **all six** bundled themes.
- Bundle **Xcode Default Dark** + **Rider Darcula**.
- **Hard requirement:** Dracula stays **pixel-identical** — same default theme,
  and its curated palette reproduces today's exact hexes. A current daily user
  sees zero change. Guarded by a regression test.

Out of scope (YAGNI): free per-hue editing in the UI, importing curated palettes,
a light/dark auto-pair per theme, recolouring the agent-state badge.

## Domain model (new terms in `CONTEXT.md`)

- **Identity colour** — the colour tagging a repo/worktree/tab (+ the app accent),
  resolved `surface → worktree → repo → default`.
- **Identity hue** — the theme-independent role an identity colour is stored as.
- **Pinned colour** — an exact hex fixed against the theme (escape hatch).
- **Curated palette** — a bundled hue→hex map per theme; else ANSI fallback.

## Design

### 1. CodaCore — data model + pure logic

**`IdentityHue` (new, `Sources/CodaCore/IdentityHue.swift`)**

```swift
public enum IdentityHue: String, CaseIterable, Codable {
    case red, orange, yellow, green, cyan, blue, purple, pink
    // Assignment order for auto-by-creation-index: matches today's spread so
    // neighbours differ. (purple, green, pink, cyan, orange, blue, yellow, red)
    public static let assignmentOrder: [IdentityHue] =
        [.purple, .green, .pink, .cyan, .orange, .blue, .yellow, .red]
    public static func autoAssigned(index: Int) -> IdentityHue {
        let o = assignmentOrder
        return o[((index % o.count) + o.count) % o.count]
    }
}
```

**`IdentityColorValue` (new)** — the stored identity value, a sum type:

```swift
public enum IdentityColorValue: Equatable {
    case hue(IdentityHue)   // follows the theme
    case pinned(RGB)        // exact colour, ignores the theme

    /// Serialized form stored in JSON: a hue is its raw name ("red"); a pin is
    /// TAGGED as "pin:#RRGGBB". The tag is load-bearing — see note below.
    public var serialized: String { ... }
    public init?(serialized: String) { ... }  // "pin:#.." → .pinned, name → .hue
}
```

> **Serialization refined during TDD.** The first cut serialized a pin as a bare
> `#RRGGBB` and disambiguated from a hue by the leading `#`. That collides with
> the *legacy* format: a legacy Dracula-red `#FF5555` and a deliberately-pinned
> `#FF5555` are byte-identical, so reloading would silently reinterpret the pin as
> the red *hue* and it would start following the theme — breaking the pin
> guarantee. The `pin:` tag makes new pins unambiguous forever; a bare `#hex` is
> therefore *always* legacy, handled exactly once by `migrating(from:)`.

**Migration** — old stored values were bare hexes auto-assigned from the retired
Dracula-8 palette. Map each **1:1** to a hue; an unrecognized hex becomes a pin:

```swift
extension IdentityColorValue {
    /// Interpret a legacy/stored string. New values already serialize to
    /// hue-name-or-#hex; legacy values are bare hexes matched to the Dracula-8
    /// table, falling through to `.pinned`.
    public static func migrating(from stored: String?) -> IdentityColorValue? {
        guard let s = stored else { return nil }
        if let v = IdentityColorValue(serialized: s) { /* new format */ }
        // legacy Dracula-8 → hue:
        //   #BD93F9→purple #50FA7B→green #FF79C6→pink  #8BE9FD→cyan
        //   #FFB86C→orange #6272A4→blue  #F1FA8C→yellow #FF5555→red
        // else → .pinned(RGB(hex: s))
    }
}
```

The map is deliberately **the retired `IdentityPalette` in reverse** — same eight
hexes, so migration is lossless and Dracula's curated palette (below) closes the
loop by reproducing them.

**Hue resolution — extend `TerminalTheme`** (it owns the ANSI data):

```swift
extension TerminalTheme {
    /// Concrete colour for a hue under this theme: curated map first, ANSI
    /// fallback otherwise. `themeName` keys the curated lookup.
    public func color(for hue: IdentityHue) -> RGB {
        if let curated = CuratedIdentityPalettes.map[name]?[hue] { return curated }
        return ansiFallback(for: hue)
    }
}
```

`ansiFallback(for:)` maps hues to ANSI indices — `red→9, yellow→11, green→10,
cyan→14, blue→12, purple→13` (bright hues). **orange** and **pink** have no ANSI
slot: derive `orange = blend(ANSI9 red, ANSI11 yellow, 0.5)` and
`pink = blend(ANSI13 magenta, foreground, 0.25)` (lightened magenta). Reuse the
existing `blend` helper (lift it out of `ChromeTheme` into an `RGB` extension so
both share it).

**`CuratedIdentityPalettes` (new)** — a Swift map keyed by theme name:

```swift
public enum CuratedIdentityPalettes {
    public static let map: [String: [IdentityHue: RGB]] = [
        "Dracula":        [ .red: rgb("#FF5555"), .orange: rgb("#FFB86C"), .yellow: rgb("#F1FA8C"),
                            .green: rgb("#50FA7B"), .cyan: rgb("#8BE9FD"), .blue: rgb("#6272A4"),
                            .purple: rgb("#BD93F9"), .pink: rgb("#FF79C6") ],   // EXACT retired hexes
        "Nord":           [ ... ],   // Aurora + Frost
        "Solarized Light":[ ... ],
        "IsaacTheme":     [ ... ],
        "Xcode Dark":     [ ... ],   // from the shipped .itermcolors syntax hues
        "Rider Darcula":  [ ... ],
    ]
}
```

**Resolve the whole chain to a concrete colour** — replace the hex-only
`identityBaseColor` with a theme-aware resolver in `IdentityColor.swift`:

```swift
/// surface → worktree → repo → nil, each an IdentityColorValue, resolved through
/// the active theme. A .hue resolves via theme.color(for:); a .pinned uses its hex.
public func resolvedIdentityColor(
    surface: IdentityColorValue?, worktree: IdentityColorValue?,
    repo: IdentityColorValue?, theme: TerminalTheme) -> RGB? {
    let value = surface ?? worktree ?? repo
    switch value {
    case .hue(let h):    return theme.color(for: h)
    case .pinned(let c): return c
    case nil:            return nil
    }
}
```

**`AccentColor`** — becomes a hue with a pin fallback; default `.hue(.purple)`
(resolves to `#BD93F9` under Dracula → identical default look):

```swift
public enum AccentColor {
    public static let defaultValue: IdentityColorValue = .hue(.purple)
    public static func resolve(_ stored: String?, theme: TerminalTheme) -> RGB {
        (IdentityColorValue.migrating(from: stored) ?? defaultValue).resolved(theme)
    }
}
```

**Model fields (`Models.swift`, `Surface.swift`)** — keep the persisted field
types (`Repository.color: String?`, `Worktree.color: String?`, and the surface
override) as **strings for backward-compatible decode**, but treat them as
`IdentityColorValue.serialized`. `Surface.colorOverride` moves from raw `RGB?` to
the same serialized-string representation for consistency. All read paths go
through `IdentityColorValue.migrating(from:)`. `WorktreeStore.createWorktree`
assigns `.hue(IdentityHue.autoAssigned(index: worktrees.count)).serialized`
instead of `IdentityPalette.color(at:)`.

**Retire `IdentityPalette`** — its 8 hexes now live inside the Dracula curated
palette and the migration table; delete the type (and its test) once callers move.

### 2. AppKit — `ColorMenu` (Set Color submenu)

The swatch menu must reflect the **active theme's** hues plus a `Custom…` pin:

- `makeSetColorItem` gains a `theme: TerminalTheme` parameter. It builds one
  swatch per `IdentityHue.allCases`, each swatch's fill = `theme.color(for: hue)`,
  `representedObject = ["id": id, "hue": hue.rawValue]`.
- A `Custom…` item opens `NSColorPanel`; on pick, stores
  `.pinned(RGB).serialized` for that target.
- `Remove Color` unchanged (clears to nil → inherit).
- Selectors persist an `IdentityColorValue` (hue or pin), not a bare hex.

### 3. AppKit — Settings

- **Accent (`GeneralSettingsViewController`)** — the 8 swatch buttons now render
  `activeTheme.color(for: hue)`; selecting one stores `.hue(hue)`. Add the same
  `Custom…` affordance as the menu for a pinned accent. The controller needs the
  active `TerminalTheme` passed in (and refreshed on theme change) to paint
  swatches.
- **Themes pane (`ThemeSettingsViewController`)** — unchanged in structure; it
  already lists installed `.itermcolors` and applies on click. Xcode/Rider appear
  automatically once seeded.

### 4. AppKit — live restyle on theme switch (`AppDelegate`)

`setActiveTheme(named:)` (≈ line 1073) already reloads panes + chrome. Extend it
to **re-resolve every identity colour** against the new `activeTheme`:

- Refresh the sidebar (repo + worktree rows) — push the new resolved colours so
  `reloadData(forRowIndexes:)` repaints. Reuse the resolver via the existing
  `identityColor(for:)` helper (≈ line 993), which must now take the active theme.
- Refresh the focused **worktree bar** (`WorktreeBar.update(colorHex:)` →
  resolved hue colour) and the **surface tab bar** colours.
- Refresh the **accent**: `sidebar.setAccentColor(AccentColor.resolve(
  preferences.accentColor, theme: activeTheme))`.
- Rebuild any open `Set Color` menus / Settings swatches with the new theme.

All identity reads (`identityColor(for:)`, worktree bar, tab bar) thread
`activeTheme` through — that is the single seam that makes restyle live.

### 5. New theme files

Add `Sources/Coda/Themes/Xcode Dark.itermcolors` and
`Sources/Coda/Themes/Rider Darcula.itermcolors` (plists in the existing format),
included in `bundledThemeURLs()` so `seedIfEmpty` installs them. **Source the
colour values from the published, well-known schemes** (iTerm2-Color-Schemes'
"Darcula" and "Xcode Dark") and **live-verify** the terminal + curated identity
palette visually in a running build before finalising (per the project's
live-verify discipline — see the notification/badge work).

> Seeding note: `seedIfEmpty` only populates an **empty** themes dir, so existing
> users (who already have `~/.coda/themes/`) will **not** get Xcode/Rider on
> upgrade. Add a small idempotent "install any missing bundled theme" step
> alongside seeding so upgraders receive the new files too (copy each bundled
> theme whose destination doesn't yet exist; never overwrite a user's file).

## Testing

- **Unit (CodaCore, no AppKit):**
  - `IdentityColorValue`: `.hue(.red).serialized == "red"`; `.pinned(...)`
    serializes to `#RRGGBB`; both round-trip through `init(serialized:)`.
  - **Migration table**: each retired Dracula-8 hex → its expected hue; an
    arbitrary hex (`"#123456"`) → `.pinned`; `nil` → `nil`.
  - **Dracula pixel-identity (regression):** for every hue,
    `dracula.color(for: hue)` equals the exact retired `IdentityPalette` hex.
    This is the guard that a daily Dracula user sees no change.
  - `TerminalTheme.color(for:)`: curated hit returns the map value; a theme not
    in the map returns the ANSI-fallback colour (assert the ANSI index mapping,
    and that orange/pink are the documented blends).
  - **Every bundled theme has a curated palette** — iterate the bundled names,
    assert each is a key in `CuratedIdentityPalettes.map` with all 8 hues.
  - `resolvedIdentityColor` honours the `surface → worktree → repo` precedence and
    that a `.pinned` value ignores the theme while a `.hue` follows it.
  - `AccentColor.resolve(nil, theme: dracula) == #BD93F9`.
- **Manual / interactive (AppKit, live-verify):**
  - Fresh install → looks exactly like today (Dracula, purple accent, same repo
    colours).
  - Switch Dracula → Xcode Dark → Nord: every repo/worktree/tab and the accent
    restyle live and stay legible (contrast) on each theme.
  - Set a repo to a hue, switch themes → it follows. Pin a repo via `Custom…`,
    switch themes → it stays put.
  - Upgrade path: an existing `~/.coda/themes/` gains Xcode Dark + Rider Darcula
    (missing-theme install step), and old stored repo colours migrate to hues
    (a repo that was Dracula purple stays purple under Dracula).

## Files touched

- `Sources/CodaCore/IdentityHue.swift` — **new**: `IdentityHue`, `IdentityColorValue`, migration.
- `Sources/CodaCore/CuratedIdentityPalettes.swift` — **new**: per-theme hue maps.
- `Sources/CodaCore/TerminalTheme.swift` — `color(for:)` + ANSI fallback.
- `Sources/CodaCore/IdentityColor.swift` — theme-aware `resolvedIdentityColor`.
- `Sources/CodaCore/AccentColor.swift` — hue-based default + `resolve(_:theme:)`.
- `Sources/CodaCore/ChromeTheme.swift` — lift `blend` to a shared `RGB` extension.
- `Sources/CodaCore/Models.swift`, `Surface.swift`, `WorktreeStore.swift`,
  `WorktreeSurfaces.swift` — identity fields as `IdentityColorValue.serialized`;
  auto-assign a hue.
- `Sources/CodaCore/IdentityPalette.swift` — **deleted** (folded into curated Dracula + migration).
- `Tests/CodaCoreTests/…` — new `IdentityHue`/migration/curated/fallback/Dracula-identity tests; update `IdentityColorTests`, `AccentColorTests`; remove `IdentityPaletteTests`.
- `Sources/Coda/ColorMenu.swift` — theme-hue swatches + `Custom…` pin.
- `Sources/Coda/GeneralSettingsViewController.swift` — theme-painted accent swatches + `Custom…`.
- `Sources/Coda/AppDelegate.swift` — thread `activeTheme` through identity reads; restyle-on-switch; missing-bundled-theme install.
- `Sources/Coda/Themes/Xcode Dark.itermcolors`, `Sources/Coda/Themes/Rider Darcula.itermcolors` — **new**.
