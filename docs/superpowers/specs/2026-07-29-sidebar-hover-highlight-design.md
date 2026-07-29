# Sidebar hover highlight

**Date:** 2026-07-29
**Status:** Approved — ready for implementation plan

## Summary

Give the left sidebar a hover highlight: a faint neutral wash behind whichever
row the pointer is over. It uses the same rounded-rect geometry as the existing
selection fill, and is skipped on the selected row so the accent "glass" fill
stays unmuddied.

## Motivation

Sidebar rows are all clickable — worktree rows and repo headers select, section
headers toggle collapse — but nothing responds to the pointer. There is no
affordance telling the user a row is live before they click it, and no feedback
about which row a click will land on.

## Background: how sidebar rows are drawn today

`SidebarController` (`Sources/Coda/SidebarController.swift`) owns a plain
`NSOutlineView` in `.sourceList` style. Three node types are rendered:

| Node | Row height | Click behaviour |
|---|---|---|
| `SectionNode` | 28pt | toggles collapse; not selectable (`shouldSelectItem` returns `false`) |
| `RepoNode` | 24pt | selectable; clears the detail surface |
| `WorktreeNode` | 38pt (two-line) | selectable; focuses its terminal |

Every row uses one row-view class, `FocusHighlightRowView`
(`SidebarController.swift:108`), vended from
`outlineView(_:rowViewForItem:)` via `makeView(withIdentifier:)` — so **row views
are recycled**. It forces `isEmphasized` to `true` and overrides
`drawSelection(in:)` to paint the selected row itself: `bounds.insetBy(dx: 4, dy: 1)`,
`NSBezierPath(roundedRect:xRadius: 5, yRadius: 5)`, filled with the app accent at
22% alpha and stroked with the same accent at 50%.

Two existing behaviours the hover work must not disturb:

- **Background reloads.** The 1s agent-state poll calls
  `reloadRowsPreservingSelection()` → `reloadData(forRowIndexes:columnIndexes:)`.
  Tested directly: this **re-vends row views** — `outlineView(_:rowViewForItem:)`
  fires again for every reloaded row, and `makeView(withIdentifier:)` can hand a row
  a *different* recycled `FocusHighlightRowView` instance than it had before. So
  row-view state does NOT survive a reload on its own; any state that must persist
  (like `isHovered`) has to be explicitly reseeded from a source of truth inside
  `rowViewForItem` every time. A full `reloadData()` additionally drops the
  outline's *selection*, which is why the poll path avoids it.
- **Focus.** Focus normally lives in the terminal, not the sidebar. Hover must be
  purely visual — it must never select, scroll, or steal first-responder status.

`SplitSurface.swift:243` has the house `NSTrackingArea` pattern
(`[.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect]`, refreshed in
`updateTrackingAreas()`), used to reveal a pane's close button on hover.

## Scope

**In scope**

- A hover wash on all three row types: worktree rows, repo headers, section headers.
- Hover suppressed on the currently-selected row.
- Correct hover after scrolling with a stationary pointer.
- Hover cleared when the pointer leaves the sidebar, and when the app deactivates.

**Out of scope (YAGNI)**

- Any hover-revealed controls (buttons, disclosure affordances, badges).
- A cursor change — the arrow cursor stays.
- A Settings toggle or user-configurable hover colour.
- Hover on the worktree bar, tab bar, or diff pane. Sidebar only.
- Animating the wash in or out. It appears and disappears immediately.

## Design

### Appearance

`NSColor.labelColor` at ~6% alpha, filled into
`bounds.insetBy(dx: 4, dy: 1)` at corner radius 5 — identical geometry to the
selection fill — with **no rim stroke**.

Rationale for the two deliberate differences from the selection:

- **Neutral hue, not the accent.** The lavender accent means "this is the active
  worktree". Reusing it for hover would put two accent-tinted rows on screen at
  once and dilute that meaning.
- **No rim.** The selection's stroked edge is what makes it read as a defined
  panel. Omitting it keeps hover subordinate.

The wash is a dynamic colour (`NSColor(name:dynamicProvider:)`) so it holds up in
both appearances: **6% in light, 10% in dark**, since the same alpha over a dark
sidebar reads weaker. Those are the starting values — nudging them during
live-verify is expected and needs no further approval.

### Drawing

`FocusHighlightRowView` gains:

- `var isHovered: Bool = false`, with a `didSet` that sets `needsDisplay = true`
  only on an actual change.
- An override of `drawBackground(in:)`: call `super`, then if `isHovered && !isSelected`,
  fill the rounded rect with the wash.

`drawSelection(in:)` is not modified. Because the hover check includes
`!isSelected`, selection always wins with no ordering subtlety between the two
overrides.

### Hover detection: one tracking area on the outline

A single `NSTrackingArea` is added to `outline` with options
`[.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect]` and
`SidebarController` as owner. `.inVisibleRect` means AppKit maintains the rect as
the outline resizes and scrolls, so the area is installed once in `loadView()` and
never rebuilt. `.mouseMoved` in a tracking area delivers `mouseMoved(with:)` to the
owner without requiring `window.acceptsMouseMovedEvents`.

The controller implements:

- `mouseMoved(with:)` — convert `event.locationInWindow` into the outline's
  coordinates, ask `outline.row(at:)`, and update the hover state.
- `mouseExited(with:)` — clear the hover state.

**Why not one tracking area per row view?** Row views are recycled by
`makeView(withIdentifier:)` and their frames shift as rows are inserted, removed,
and re-measured (`noteHeightOfRows`), so each recycled view would have to tear down
and re-add its area at exactly the right moments. `SplitSurface` gets away with the
per-view pattern because it has one long-lived view per pane. A single area on the
container is immune to both recycling and reflow.

### Scrolling with a stationary pointer

Scrolling generates no `mouseMoved`, so the highlight would stay on a row that has
moved out from under the pointer. `SidebarController` observes the enclosing clip
view's `NSView.boundsDidChangeNotification` (requires
`clipView.postsBoundsChangedNotifications = true`, which is the default) and
recomputes the hovered row from `NSEvent.mouseLocation`, converted through the
window. The same recompute runs after `reload(rootItems:...)`, since a reorder can
put a different row under a stationary pointer.

### Hover bookkeeping

The row→redraw bookkeeping is extracted into a small value type in `CodaCore`
so it can be unit-tested away from AppKit:

```swift
/// Tracks which sidebar row the pointer is over. Pure bookkeeping: no AppKit.
public struct SidebarHoverState: Equatable {
    public private(set) var hoveredRow: Int?

    /// Move hover to `row` (nil = no row) given the outline's current row count.
    /// Returns the row indices whose highlight changed and therefore need
    /// redrawing — empty if nothing moved. A row outside `0..<rowCount` counts as
    /// "no row", and the returned indices are always valid rows.
    public mutating func update(to row: Int?, rowCount: Int) -> [Int]
}
```

`update(to:rowCount:)` returns the old and new rows when hover moves, just the
vacated row when hover leaves, just the entered row when hover arrives, and nothing
when the row is unchanged. The controller feeds it from `mouseMoved` /
`mouseEntered` / `mouseExited` / the scroll recompute, passing
`outline.numberOfRows`, then walks the returned indices and sets `isHovered` on each
corresponding row view via `outline.rowView(atRow:makeIfNecessary: false)`.

**`rowCount` is a crash guard, not a convenience.** The vacated index comes from a
previous event, and the sidebar's row count shrinks whenever a repo, section, or
worktree goes away. `outline.rowView(atRow:)` range-checks and throws an uncaught
`NSTableViewException` on a stale index — `makeIfNecessary: false` does not spare
you. Bounds validation lives in this type, where tests cover it, rather than as a
guard at the call site that reads as optional.

Repainting only the changed rows — rather than reloading — keeps hover off the
reload path entirely, so it cannot perturb selection or focus.

## Testing

**Unit tests (`Tests/CodaCoreTests`)** cover `SidebarHoverState`:

- entering a row from nothing returns that row
- moving between rows returns both the vacated and the entered row
- re-reporting the same row returns nothing (no redraw churn)
- leaving to `nil` returns only the vacated row
- `nil` → `nil` returns nothing

**Live verification** in the running app, which is where this sidebar's real bugs
have surfaced before:

1. Hover each row type — worktree, repo header, section header — and confirm the
   wash appears with the same footprint as the selection.
2. Hover the selected worktree; its accent fill must be unchanged.
3. Scroll with the pointer held still over the sidebar; the highlight must follow
   the row now under the pointer.
4. Let the 1s agent-state poll run while hovering; the highlight must not flicker.
5. Click a worktree while hovering; selection and terminal focus must behave as
   before.
6. Move the pointer out of the sidebar and switch apps; the highlight must clear.
7. Check both light and dark appearance, and a non-default accent colour.

## Files touched

- `Sources/CodaCore/SidebarHoverState.swift` — new value type.
- `Sources/Coda/SidebarController.swift` — `isHovered` + `drawBackground(in:)` on
  `FocusHighlightRowView`; tracking area, mouse handlers, bounds observer, and
  hover-state wiring on the controller.
- `Tests/CodaCoreTests/SidebarHoverStateTests.swift` — new tests.
