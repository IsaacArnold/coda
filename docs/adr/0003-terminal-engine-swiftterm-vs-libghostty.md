# Terminal engine: stay on SwiftTerm, revisit libghostty when its embedding API is stable

**Status:** accepted (2026-11-26)

Coda keeps **SwiftTerm** as its terminal engine. Switching to **libghostty** was considered after a run of terminal-reliability problems (#82). Every one of those problems was fixed inside Coda, and the one that remains (Claude Code's redraw on resize) also shows up in iTerm2, so an engine swap wouldn't fix it. libghostty's rendering/embedding API, which is the part Coda would actually need, isn't yet offered as a stable, versioned API for apps other than Ghostty. We'll revisit when one of the triggers at the end of this ADR happens.

This extends the original choice in `DECISIONS.md` (#1, #2, #17, 2026-06-24). That spike evaluated SwiftTerm on its own; Ghostty was only an aesthetic influence and was never evaluated as an engine.

## What prompted this, and what the fixes showed

Moving to a harness-centric workflow (mostly markdown output, fewer worktrees) made two things feel unreliable: ⌘ + click on paths, and repaint when the window is resized. The question was whether the engine was to blame.

| Problem | Root cause | Fix | Engine's fault? |
|---|---|---|---|
| ⌘ + click opened the wrong file or nothing (#79) | Coda's own path matcher: first token on the row, no wrap joining, markdown punctuation | Pure resolver in CodaCore (PR #85) | No |
| Relative paths after `cd` (#84) | A Coda launched from a Coda tab chained the parent's wrapper instead of `~/.zshrc`, so the shell sent no OSC 7. Coda's own zsh setup never sent OSC 7 either | `userZdotdir` fix plus an OSC 7 hook (PR #86) | No |
| ⌘-hover showed the hand but no underline (#87) | SwiftTerm only underlines its own URL matches, and its highlight state is internal | Coda draws its own underline overlay (PR #88) | Partly: an API gap, worked around |
| Garbled Claude output on window resize (#80) | One SIGWINCH per drag frame, plus Claude Code's in-place redraw over reflowed text | Hold PTY size back until the drag ends, so there's 1 SIGWINCH instead of dozens (PR #89) | No: the remaining artefacts match iTerm2 |

The resize comparison (written up on #80) is the deciding evidence. Text Claude printed at the old width gets soft-wrapped the same way in Coda and in iTerm2, and the leftover rows at full width come from Claude Code's own redraw. Any terminal engine reflows like this; a new one wouldn't remove it.

## What SwiftTerm costs us

SwiftTerm's sealed or internal APIs force workarounds. Each is contained and tested, but together they're the real argument for an engine with a richer embedding surface:

- `mouseDown` / `keyDown` are `public`, not `open` → app-level `NSEvent` monitors for ⌘ + click, ⌘-hover and soft newline.
- `BufferLine.isWrapped` is internal → wraps are detected through `getText`, which only puts a newline between unwrapped rows.
- The link highlight range is internal → Coda draws its own underline overlay and skips drawing where SwiftTerm already underlines.
- `sizeChanged` (which sends TIOCSWINSZ) is sealed → we gate the size through the `open` `getWindowSize()` instead.
- Cell size is internal → we recompute it from the font the same way SwiftTerm does.
- The scroll-follow flag is internal → we restore the scroll position after each `dataReceived`.
- Glyphs taller than the base font's ascent are clipped (see the debugging-terminal-rendering notes).

## libghostty today (as researched on 2026-11-26)

- **Two layers.** `libghostty-vt` is a C/Zig library for parsing terminal sequences and holding terminal state, with **no rendering**. The full embedding API (`ghostty.h`, packaged as GhosttyKit.xcframework) adds the Metal renderer, surfaces and input. It's what Ghostty's own macOS app uses.
- **Stability.** Ghostty's README says libghostty-vt's "functionality is extremely stable … but the API signatures are still in flux." Third-party coverage reports a libghostty-vt 1.0 with a stable C ABI on 2026-11-06 (and a `vt-1.0.1` tag); we couldn't confirm that from a primary source. Either way, 1.0 covers only the VT layer. The full embedding API is described by people using it as having Ghostty's own app as its only intended consumer, with no stability promise.
- **Licence:** MIT, so not an obstacle.
- **Prior art:** many macOS apps now embed it, including Supacode (agent orchestration, the closest to Coda), Aster ("built on GhosttyKit"), Muxy, Forge and Mori. Community SwiftPM wrappers ship a prebuilt `GhosttyKit.xcframework`. One notes that the full static library is only assembled as a side effect of Ghostty's own macOS app build.

## Options considered

- **Stay on SwiftTerm (chosen).** Every reported problem is fixed; the workarounds are contained in `ClickableTerminalView` and CodaCore and tested; the build stays pure SwiftPM, which keeps `release.sh` and notarization unchanged.
- **Switch to the full libghostty embedding API.** Would get a GPU renderer, Ghostty-grade reflow, no glyph clipping, and native link and OSC handling. But it depends on an unstable API not meant for third parties, adds a Zig build (or a third-party prebuilt binary) to a notarized release pipeline, and means rewriting the terminal view and surface layer: 3 files, about 1,100 lines, around 20 SwiftTerm APIs plus 4 subclass overrides (input injection, colours, OSC 7/133/8 hooks, buffer reads for ⌘ + click and completions, scroll control, delegate callbacks, drag and drop, cursor-cell anchoring for the completion popup, live-resize gating). It wouldn't fix the resize artefacts that prompted the question. Rejected for now.
- **libghostty-vt plus Coda's own renderer.** It gets a stable(ish) core, but writing and maintaining a Metal text renderer is far outside what an orchestrator should own (DECISIONS #1: "not a from-scratch emulator"). Rejected.

## What would change this decision

Revisit (a short spike, as in June) when any of these happens:

1. **libghostty's rendering/embedding API becomes a stable, versioned API intended for other apps,** like libghostty-vt's `vt-X.Y.Z` tags. That removes the main risk.
2. **A reliability bug is traced to SwiftTerm itself** and can't be worked around through public API or a small upstream patch.
3. **Rendering performance or fidelity becomes a real complaint:** heavy agent output dropping frames, or glyph clipping hurting common fonts or icons.
4. **The workaround list keeps growing,** e.g. a fourth sealed-API workaround in one feature, or one that breaks on a SwiftTerm update.

If we spike, check: building GhosttyKit reproducibly inside `release.sh` (universal binary, Hardened Runtime, zero entitlements), and parity for every API listed under the switch option.

## Sources

- Ghostty README (libghostty section): https://github.com/ghostty-org/ghostty
- awesome-libghostty (apps and wrappers): https://github.com/Uzaaft/awesome-libghostty
- libghostty-spm (prebuilt GhosttyKit.xcframework): https://github.com/sethdeckard/libghostty-spm
- Reports of libghostty-vt 1.0 and the embedding-API status (secondary): https://runtimewire.com/article/libghostty-1-0-mitchell-hashimoto-stable-c-abi, https://github.com/XueshiQiao/Attache/issues/38, https://github.com/Lockyc/libghostty-build/issues/1
- Coda evidence: #79, #80 (resize comparison), #84, #87; PRs #85, #86, #88, #89.
