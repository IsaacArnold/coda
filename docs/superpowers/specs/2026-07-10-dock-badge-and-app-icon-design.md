# Dock badge + user-selectable app icon — design

Date: 2026-07-10

Two independent features for Coda:

1. A **Dock badge** — a red badge on the Dock icon showing how many worktrees
   currently need the user's input.
2. A **user-selectable app icon** — a curated gallery of bundled icons the user
   can pick from, changing both the running Dock icon and the Finder icon.

They share nothing except living in the same `AppDelegate`/settings surfaces, so
they can be built and reviewed independently.

> **Correction (verification finding, 2026-07-10):** The Finder-icon half of
> Feature 2 below was **dropped during implementation**. This spec claimed
> `NSWorkspace.setIcon(_:forFile:)` sets the Finder icon via an xattr without
> touching the sealed `Contents/`, leaving the code signature valid. That is
> false: it writes `com.apple.FinderInfo` on the bundle root, which
> `codesign`/Gatekeeper disallow — verified on the built `.app`, where after the
> write `codesign --verify --strict` fails and `spctl` **rejects** the app (a
> notarized build would risk "damaged app" errors on relaunch/update). There is
> no signature-safe way to give a signed `.app` a custom Finder icon. The
> shipped picker therefore changes **only the running Dock/app-switcher icon**
> (`NSApp.applicationIconImage`, persisted across launches); Finder keeps the
> shipped icon. Everything else below is as-built.

---

## Feature 1 — Dock badge (count of worktrees needing input)

### Behaviour

- When one or more worktrees are in the `.needsYou` agent state, the Dock icon
  shows the standard red badge with the **count** of such worktrees (e.g. `2`).
- When the count is zero, the badge is cleared (no badge shown).
- Gated by a new preference `showDockBadge`, default **on**. When off, the badge
  is always cleared regardless of state.

### Where it hooks in

`AppDelegate.recomputeRollupsAndRefreshUI()` is the single chokepoint through
which every agent-state change flows — both the hook-driven path
(`handleHookEvent`) and the 1.2s polling fallback (`pollAgentStates`) call it.
Add one line there:

```swift
updateDockBadge(rollups)
```

`updateDockBadge(_ rollups: [String: AgentState])`:

```swift
private func updateDockBadge(_ rollups: [String: AgentState]) {
    let count = preferences.showDockBadge ? needsYouCount(rollups) : 0
    NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
}
```

Setting `NSApp.dockTile.badgeLabel` is safe with or without an `.app` bundle, so
no bundle guard is needed.

### Testable core

The counting logic is a pure function in **CodaCore**, unit-tested without AppKit:

```swift
/// Number of worktrees whose rolled-up state is `.needsYou`.
public func needsYouCount(_ rollups: [String: AgentState]) -> Int {
    rollups.values.filter { $0 == .needsYou }.count
}
```

Tests: empty dict → 0; mixed states → counts only `.needsYou`; all-idle → 0.

### Settings UI

In `GeneralSettingsViewController`, add a checkbox to the existing
"Notifications" group:

> ☑ Show a Dock badge when agents need you

Follows the exact pattern of `notifyNeedsYouCheckbox` / `notifyDoneCheckbox`:
a stored `showDockBadge: Bool`, an `onChangeShowDockBadge: ((Bool) -> Void)?`
callback, wired in `AppDelegate` to persist the pref and immediately call
`recomputeRollupsAndRefreshUI()` so the badge updates live.

### Preference

Add `showDockBadge: Bool` to `Preferences`, defaulting to `true`, with the same
optional-decode-with-default treatment as `notifyOnNeedsYou` so older prefs files
still decode.

---

## Feature 2 — User-selectable app icon (bundled, curated gallery)

### Behaviour

- A new "App Icon" section in General settings shows a gallery of thumbnail
  swatches, one per bundled icon, with the current selection ringed (reuses the
  accent-swatch selection visuals).
- Picking an icon changes **both** the running Dock/app-switcher icon **and** the
  Finder icon of the installed `.app`.
- The gallery is **curated by adding/removing `.icns` files** in the bundle — the
  list auto-populates from the shipped folder.

### Shipping the icons

- Icons live in `Sources/Coda/Resources/Icons/*.icns`.
- No build-script change is required: `Package.swift` already declares
  `.copy("Resources")`, and `make-app.sh` copies the resource bundle's contents
  flat into `Contents/Resources`, so a new `Resources/Icons/` subfolder ships in
  both the `swift run`/test layout and the distributed `.app`.
- **`Resources/Coda.icns` stays exactly where it is.** The `.app`-layout probe in
  `ResourceBundle.codaAssets` keys off `Bundle.main.url(forResource: "Coda",
  withExtension: "icns", subdirectory: "Resources")`, so it must not move or be
  renamed. It is presented in the gallery as the **"Default"** entry.
- Seed `Icons/` with the user's `~/Downloads/Coda.icns`, copied in as
  `Icons/Alternate.icns` (neutral name; the user renames during curation).

### AppIconCatalog

A new helper type in the **Coda** target (AppKit), responsible for enumerating
and resolving icons:

```swift
struct AppIcon {
    let id: String          // filename stem, e.g. "Default", "Alternate"
    let displayName: String // derived from id
    let image: NSImage
}

enum AppIconCatalog {
    /// "Default" (Resources/Coda.icns) first, then each *.icns in Resources/Icons
    /// sorted by name. Entries whose image fails to load are skipped.
    static func all() -> [AppIcon]

    /// Image for the chosen id (nil → Default). Falls back to Default if the id
    /// is unknown (e.g. a curated icon was removed after being selected).
    static func image(forID id: String?) -> NSImage?
}
```

- "Default" is synthesised from `Resources/Coda.icns` (via `Bundle.codaAssets`)
  so it always appears even though it lives outside `Icons/`.
- Additional entries come from scanning `Bundle.codaBundledResource("Icons")`.
- Display name = the filename stem as-is (curators pick sensible filenames).

### Applying the choice

Replace today's `applyDockIcon()` with `applyAppIcon()`, called at launch and
after every change:

```swift
private func applyAppIcon() {
    guard let image = AppIconCatalog.image(forID: preferences.appIconName) else { return }
    NSApp.applicationIconImage = image                       // running Dock / app-switcher
    if isRunningFromAppBundle {
        NSWorkspace.shared.setIcon(image, forFile: Bundle.main.bundlePath, options: [])
    }
}
```

- **Running Dock icon:** `NSApp.applicationIconImage` — immediate, works in every
  layout.
- **Finder icon:** `NSWorkspace.setIcon(_:forFile:)` writes a custom icon as an
  extended attribute on the `.app` directory. It does **not** modify the sealed
  `Contents/`, so the Developer-ID code signature stays valid. Guarded by
  `isRunningFromAppBundle` (`Bundle.main.bundlePath.hasSuffix(".app")`) so a
  `swift run` dev session never tries to write it.
- **Survives Homebrew updates:** an update replaces the whole `.app`, wiping the
  xattr. Because `applyAppIcon()` runs on every launch, the first post-update
  launch re-applies the Finder icon automatically. No manual repair.

### Settings UI

In `GeneralSettingsViewController`, add an "App Icon" section: a horizontal
`NSStackView` of image buttons, one per `AppIconCatalog.all()` entry, each showing
a downscaled thumbnail of the icon. The currently-selected icon's button gets the
selection ring (same `updateAccentSelection`-style border logic). Clicking a
swatch stores `appIconName = icon.id`, updates the ring, and fires
`onChangeAppIcon?(icon.id)`, wired in `AppDelegate` to persist the pref and call
`applyAppIcon()`.

### Preference

Add `appIconName: String?` to `Preferences` (the chosen icon's `id`; `nil` →
Default), following the `accentColor` optional-decode pattern.

---

## Out of scope (YAGNI)

- Importing arbitrary user icon files via a file picker (explicitly chosen against
  in favour of a curated bundled gallery).
- Per-worktree or per-window icons.
- Animating / temporarily bouncing the Dock icon (the badge is the signal).
- A separate toggle for the Finder-icon behaviour — it always tracks the choice.

## Testing

- **CodaCore unit test:** `needsYouCount(_:)` — empty, mixed, none, all.
- **Manual verification (per the `verify` skill, in the built `.app`):**
  - Drive an agent to `needsYou` in one then two worktrees → badge shows `1` then
    `2`; respond → badge clears.
  - Toggle the Dock-badge checkbox off → badge clears; on → re-appears.
  - Pick each gallery icon → Dock and Finder icons change; relaunch → choice
    persists; confirm `codesign --verify` still passes after a Finder-icon change.
