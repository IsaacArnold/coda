# Custom terminal font size + chrome (UI) scale

Date: 2026-07-02
Status: Approved (pre-implementation)

## Problem

The Settings → General → **Terminal font** picker uses the macOS `NSFontPanel`,
whose size column jumps 14 → 18 with no in-between. The user wants a finer
terminal size (e.g. 15). Separately, the app chrome (sidebar, tabs, worktree
bar, labels) uses fixed system/point sizes and does not scale — the user wants
an app-wide interface size control too.

Scope decisions (confirmed with the user):

- The terminal size must accept **arbitrary** integer point sizes, decoupled
  from the font panel's preset list.
- A **separate** control scales the **chrome** (sidebar, tabs, labels), not the
  terminal.
- Chrome scale is expressed as **presets: Small / Medium / Large / Extra Large**,
  not a continuous slider or absolute point size.
- Chrome scale applies **live** (no relaunch), consistent with the terminal font.

## Non-goals (YAGNI)

- No continuous percentage slider.
- No per-view size overrides.
- No separate chrome font *family* picker (chrome stays on the system font).
- No change to how the terminal typeface is chosen (font panel stays).

## Approach

Approach A (chosen over a NotificationCenter broadcast or full view-tree
rebuild): a central `UIMetrics` provider vends scaled fonts and lengths; each
chrome view gains an `apply(metrics:)` that stores the metrics and rebuilds;
`AppDelegate` (which already holds every chrome view) coordinates the live
broadcast. This fits the existing "chrome views rebuild wholesale
(`reloadData()` / `update(items:)`)" pattern and keeps the scale math in one
testable place.

## Design

### 1. Data model — `Sources/CodaCore/Preferences.swift`

- Terminal size: no schema change. `TerminalFontPref.size` already stores a
  `Double`; the UI simply becomes able to set arbitrary integers.
- Add:

  ```swift
  public enum UIScale: String, Codable, CaseIterable {
      case small, medium, large, xlarge
      public var multiplier: CGFloat {
          switch self {
          case .small:  return 0.9
          case .medium: return 1.0
          case .large:  return 1.15
          case .xlarge: return 1.3
          }
      }
      public var displayName: String { ... }  // "Small" / "Medium" / "Large" / "Extra Large"
  }
  ```

- Add `public var uiScale: UIScale` to `Preferences`, defaulting to `.medium`.
  Decode must be tolerant of older prefs files that lack the key (default
  applied), matching how `terminalFont` is optional today.

`UIScale` lives in `CodaCore` (alongside `TerminalFontPref`) so its math is unit-testable there.

### 2. `UIMetrics` — new file `Sources/Coda/UIMetrics.swift`

A small value type constructed from a `UIScale`:

- `func length(_ base: CGFloat) -> CGFloat` → `round(base * scale.multiplier)`.
  Used for geometry: sidebar row heights, bar heights, insets, icon/badge sizes.
- Semantic font accessors, each = today's base size × multiplier:
  - `sectionHeader` — `smallSystemFontSize`, `.semibold` (sidebar repo header)
  - `body` — `systemFontSize` (sidebar worktree title, settings labels)
  - `footnote` — `preferredFont(forTextStyle: .footnote).pointSize` (sidebar subtitle)
  - `tabLabel` — 11 (surface tab label; weight decided by caller)
  - `worktreeTitle` — 12, `.semibold`
  - `worktreeBranch` — 11, monospaced

The terminal font is **not** routed through `UIMetrics` — it keeps its own explicit point size from `TerminalFontPref`.

### 3. Chrome consumers

Each gets an injected `UIMetrics` (default `.medium`) and an
`apply(metrics:)` that stores it and rebuilds:

- **`SidebarController`** — fonts in `viewFor(...)` and `makeWorktreeCell()`
  read from metrics; `heightOfRowByItem` returns `metrics.length(24)` /
  `metrics.length(38)`; `apply(metrics:)` calls `outline.reloadData()`.
- **`SurfaceTabBar`** — `makeTab` label font from metrics; the `22` tab height
  and `Self.height` (28) become metric-driven. The view's own height constraint
  is stored as a property so `apply(metrics:)` updates its `.constant`, then
  re-runs `update(items:)`.
- **`WorktreeBar`** — `titleLabel`/`branchLabel` fonts from metrics; `height`
  (26) and edge insets metric-driven; height constraint stored so
  `apply(metrics:)` updates `.constant` and refreshes.

Fixed `static let height` constants become instance-computed from the current
metrics. The height constraints that were previously created inline at `init`
become stored properties so they can be mutated on scale change. Spacing
constraints owned by `AppDelegate` (e.g. `worktreeBar.top`, `surfaceTabBar.top`)
stay fixed — only the bar heights scale.

### 4. Settings UI — `GeneralSettingsViewController.swift` (+ `SettingsTabController`)

Extend the existing General pane:

- **Terminal size**: add an `NSStepper` + editable `NSTextField` next to the
  existing font "Change…" button, bound to the size (range 8–48, step 1).
  Editing calls `onChangeFont(TerminalFontPref(name: currentName, size: newSize))`.
  The font panel still picks the typeface; size is decoupled from its preset
  list. `fontValueLabel` keeps showing "`<name> <size>`".
- **Interface size**: a new labeled row with an `NSPopUpButton` offering the
  four `UIScale` cases (via `displayName`), bound to the current `uiScale`.
  Emits a new `onChangeUIScale: ((UIScale) -> Void)?`.

`SettingsTabController` gains `uiScale` pass-through and the new callback,
mirroring the existing `terminalFont` / `onChangeFont` wiring.

### 5. Live-apply flow — `AppDelegate.swift`

- On launch: build `UIMetrics(scale: preferences.uiScale)` and inject it when the
  chrome views are constructed.
- `setUIScale(_:)` — persist to prefs (`prefsStore.save`), build fresh
  `UIMetrics`, call `sidebar.apply(metrics:)`, `worktreeBar.apply(metrics:)`,
  `surfaceTabBar.apply(metrics:)`, and re-run `refreshSurfaceTabs()` so the bars
  relayout. No relaunch.
- Terminal size reuses the existing `setTerminalFont` path unchanged — already
  live across every pane.

## Testing

- **Unit** (`CodaCore` tests): `UIScale.multiplier` mapping for all four cases;
  `UIMetrics.length` rounding.
- **Manual** (`run` skill): cycle interface size across all four presets and
  confirm sidebar rows, tabs, and worktree bar scale without clipping; set
  terminal size to 15 and confirm panes update live; relaunch and confirm both
  the terminal size and the interface scale persist.

## Risks / notes

- Larger scale must not clip text inside bars/rows — this is why geometry scales
  alongside fonts (the core reason chrome scaling touches both).
- Older prefs files without `uiScale` must decode to `.medium`.
- `xlarge` (1.3×) is the practical upper bound; verify the tab bar and worktree
  bar still lay out at that size.
