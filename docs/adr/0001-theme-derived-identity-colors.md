# Identity colours are theme-derived hue roles, not frozen hexes

**Status:** accepted (2026-07-14)

Repo / worktree / surface-tab identity colours (and the focused-row accent) used to be stored as frozen hex strings auto-assigned from a hardcoded Dracula palette, so they never followed the user's theme. We now store each identity colour as an **Identity hue** (`red, orange, yellow, green, cyan, blue, purple, pink`) or a **Pinned** exact hex, and resolve a hue to a concrete colour through the *active* theme. Switching themes restyles every hue-valued identity live; pinned colours are the deliberate opt-out. This makes identity colour genuinely "based off the theme the user sets" while keeping the "my red repo stays red-ish everywhere" semantic.

## Considered options

- **Frozen hex, theme only seeds new assignments** — simplest, no migration, but existing repos keep stale Dracula colours forever; rejected because it doesn't actually make identity follow the theme.
- **Positional slot (index into each theme's ordered palette)** — 1:1 migration, but "the 3rd swatch" is an unrelated hue per theme, so restyling visually scrambles which repo looks like what. Rejected in favour of semantic hues, which map cleanly onto ANSI (each hue = a known ANSI index) so the imported-theme fallback is trivial.

## How a hue resolves

Curated map first (`CuratedIdentityPalettes[themeName]`, a Swift map in `CodaCore`), else an **ANSI fallback** deriving each hue from the theme's ANSI colours (red→9, yellow→11, green→10, cyan→14, blue→12, purple→13; orange/pink approximated). All six bundled themes ship curated palettes; imported `.itermcolors` use the fallback.

## Consequences

- **Persisted-format change + migration.** Worktree/repo/surface colour fields and the accent preference change from a bare hex to a hue-name-or-`#hex` string. On load, an old hex is matched against the retired Dracula-8 palette → hue; unrecognized hex → pinned. This migration is one-way and must be covered by tests.
- **Dracula stays pixel-identical.** Dracula remains the default theme and its curated palette reproduces the exact retired hexes (`#BD93F9` purple, `#50FA7B` green, `#FF79C6` pink, `#8BE9FD` cyan, `#FFB86C` orange, `#6272A4` blue, `#F1FA8C` yellow, `#FF5555` red), so a current daily user sees no change. This is a hard requirement, guarded by a regression test.
- Two new bundled themes ship alongside: **Xcode Default Dark** and **Rider Darcula**.
