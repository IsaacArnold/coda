# Terminal completions (Kiro-style CLI autocomplete)

**Date:** 2026-07-08
**Status:** Approved

## Problem

Coda's embedded terminal is a bare shell. Users who live in `git`, `claude`,
and friends get no in-app help composing commands — they rely entirely on the
shell's own Tab-completion, which is invisible until pressed, plain, and gives
no descriptions. Kiro CLI (descended from Fig) sets the bar: as you type, a
dropdown appears at the cursor listing subcommands / options / arguments, each
with a short description, navigable by keyboard.

We want that experience, native to Coda. Crucially, Coda **owns the SwiftTerm
emulator** (`ClickableTerminalView : LocalProcessTerminalView`) and already
intercepts keystrokes before the terminal via an app-level `NSEvent` monitor.
That means we get, for free, the two things Fig had to bolt on with a headless
terminal (`figterm`) plus the accessibility API: the parsed screen buffer and a
pre-terminal keystroke hook.

See also: glossary terms **Completion popup**, **Completion spec**, **Shell
integration** in `CONTEXT.md`; and ADR
`docs/adr/0002-native-completion-engine.md`.

## The experience

A **spec-driven dropdown popup** (Kiro clone), not ghost-text and not a
prettified dump of the shell's own completions. Architected so ghost-text and
history/AI suggestions can layer on later, but v1 is the popup.

## Design

### 1. Capturing the current command line — OSC 133 shell integration

The completer needs, every keystroke: the **current command line** (from the
start of the editable command to the cursor) and the **cursor's screen cell**
(to anchor the popup). We get both by having the shell emit OSC 133 semantic
prompt markers (`A` prompt-start, `B` command-start, `C` pre-exec, `D`
command-finished), plus OSC 7 for cwd.

- **Why OSC 133 over heuristics or a keystroke shadow-model:** heuristics break
  on custom/multi-line prompts, wrapping, and syntax highlighting; a shadow
  model desyncs the moment the user uses history, reverse-search, word-motion,
  kill-line, paste, or accepts a zsh autosuggestion. OSC 133 is what made Fig
  reliable; it survives all of the above. Accuracy over coverage.
- **SwiftTerm support (verified):** SwiftTerm does *not* parse OSC 133 natively,
  but exposes `terminal.registerOscHandler(code:handler:)`
  (`Terminal.swift:1054`). We register a handler for code 133 and parse the
  phase letters ourselves — no fork, no raw-byte scraping. OSC 7 is already
  handled (`oscSetCurrentDirectory` → `hostCurrentDirectory`) and already wired
  into `TerminalSurface` (`hostCurrentDirectoryUpdate`).
- **Cursor → pixel:** read the cursor cell from SwiftTerm's buffer and multiply
  by cell size — the inverse of the existing ⌘+click cell math in
  `ClickableTerminalView.clickTarget(at:)`.

### 2. Injecting the integration — `ZDOTDIR` / `--rcfile` wrapper

Consent-gated (mirroring the existing Claude-hook installer,
`promptForHookInstallIfNeeded`). We point the Coda-spawned shell at a bundled,
Coda-managed rc dir: our `.zshrc` emits the OSC 133 + OSC 7 snippet, then
`source`s the user's real `.zshrc` (respecting `.zshenv`/`.zprofile` ordering).
Bash uses `--rcfile` equivalently (fast-follow, see scope).

- **Why not append to the user's `~/.zshrc`:** mutates the user's dotfiles,
  needs uninstall cleanup, drifts. The wrapper touches none of the user's files
  and is trivially reversible (stop setting the env var).
- **Set via env, not argv,** so it composes with both spawn paths — the bare
  shell-first `-i` path *and* the setup/command `-i -c '…'` path
  (`LaunchCommand.swift`). Coda already controls the spawn env
  (`HookEnvironment.swift`).
- **Consequence:** completions work only in shells **launched by Coda** — which
  is exactly the intended scope (an in-app feature), so this is a feature, not a
  limitation.

### 3. Keymap — steal keys only while the popup is visible

Because the `NSEvent` monitor sees keys before SwiftTerm, the popup steals keys
*only while showing*; hidden, everything passes through as today.

| Key | Popup visible | Popup hidden |
|-----|---------------|--------------|
| Printable | filter/refine list | types; may open popup |
| ↑ / ↓ | move selection | pass through → shell history |
| Tab | **accept** highlighted item | pass through → zsh's own completion |
| Esc | dismiss (+ suppress, see below) | pass through |
| Enter | **run the command** (popup closes) | run the command |
| → / End | v1: pass through (reserved for future ghost-text) | pass through |

- **Tab replaces zsh completion only while our popup is up.** Where we have
  nothing to offer, no popup shows, so Tab falls through to zsh untouched. Net:
  we complete the contexts we cover (git, paths, …); zsh completes everywhere
  else.
- **Enter is never hijacked — it always runs.** Fig/Kiro's "Enter accepts the
  selection" is their most-complained-about behavior (accidental completes,
  double-Enter). Tab is the *only* accept key. One extra keystroke, zero
  surprise.
- **Post-Esc suppression:** after Esc, the popup stays suppressed until the next
  line-editing keystroke (a character or backspace that changes the command
  line). Pure navigation (↑/↓) does not re-summon it.

### 4. Trigger / dismiss timing

OSC 133 tells us the shell phase, so we gate hard.

**Appears when** all hold: shell is at the prompt (post-`B`, pre-`C`); terminal
focused **and scrolled to bottom**; the keystroke produced a non-empty current
token *or* the cursor sits just after `command␣`; ≥1 candidate matches; not in
the post-Esc suppression window.

**Disappears when** any: Enter, Esc, line goes empty, a command starts
executing, no candidates match, focus leaves the terminal, or the user scrolls
back.

- **Never on a totally empty prompt** — no "every command on PATH" wall of noise
  on focus.
- **Short debounce (~30–50 ms), async, cancellable.** The keystroke always
  reaches the shell immediately; the popup catches up a beat later. Native
  engine (no process hop) keeps this imperceptible.
- **The scrolled-to-bottom gate** is what keeps the popup from ever intruding
  while reading output or during a running command.

### 5. Engine behavior

**Parse:** tokenize the line to the cursor (quotes/escapes) → resolve first
token to a spec → walk subcommands → classify the cursor token (subcommand /
option / option-arg / positional).

**Offer, by context:** first token → command names (specs + PATH, after ≥1
char); after `git ` → subcommands + descriptions; `-`/`--` token → that
context's options + descriptions; positional/option arg → its declared type
(**filesystem paths** by default, dirs-only for `cd`; or a **generator**).

- **Unknown commands still get filesystem-path completion** for their arguments
  (using OSC 7 cwd). Highest-value behavior, costs nothing; occasional
  wrong-context path is easily ignored.
- **Matching: case-insensitive prefix, falling back to substring.** Not full
  fuzzy in v1 (deferred as a later toggle) — avoids ranking complexity and false
  positives.
- **v1 dynamic generators (Swift-native), deliberately two:** filesystem paths,
  and git branches/remotes (for `git checkout`/`switch`/`merge`/`rebase`/
  `push`). Generators spawn processes, so they are throttled and cached.

### 6. Rendering — native macOS chrome

An overlay child `NSView` (reusing the `DropHighlightOverlay` "draw on top of
the terminal, `hitTest` → nil" pattern), backed by `NSVisualEffectView`, using
the system font/appearance — so it reads as *app UI floating over* the terminal
(Kiro's actual look), stays legible regardless of terminal color scheme, and
signals "this is Coda helping."

- **Placement:** directly below the current line, left-aligned to the start of
  the token being completed; **flips above** near the window's bottom edge;
  repositions as the cursor moves.
- **Size:** width fits the longest visible item (name + description), capped;
  ~8 rows visible, scrolls beyond; selection highlighted.
- **Row:** name + dimmed description; optional type glyph later.

### 7. Enablement

- Consent prompt on first run → **on by default** thereafter.
- **Global** Settings toggle (not per-repo — this is a terminal-input-UX
  preference, like key bindings). When off, we **stop setting the `ZDOTDIR`
  wrapper** on new terminals — zero OSC 133 overhead, not just a hidden popup.
- **Independent of the Claude-hook toggle** — different capability; a user may
  want one without the other. May share a Settings section.
- Toggling applies to **newly-opened terminals only** (the wrapper is fixed at
  spawn); older terminals keep their spawn-time state.

### 8. Behavior where we lack our own OSC 133 markers — silent-off

The popup **only ever appears when we are certain we're at the editable prompt
of the shell we integrated with.** Everywhere else it is invisible and inert —
no false positives, ever:

- **During a Claude run** — shell is in the executing phase; Claude has its own
  TUI; we stay out.
- **Inside ssh / a REPL / `docker exec` / a nested shell / vim** — no *our* OSC
  133 markers, so nothing shows. We never guess in an environment we don't
  understand.
- **After `exec`ing a different shell or unsetting the hooks** — markers stop,
  feature goes quiet.

This misses places completions could theoretically help (e.g. remote zsh over
ssh) in exchange for never intruding where we'd be wrong. Accuracy over
coverage.

## Architecture — pure core / thin impure edges / per-surface controller

Mirrors the existing grain (`AgentState`, `TerminalKeyBindings` are pure in
`CodaCore`).

**Pure, in `CodaCore` (unit-tested, no AppKit/SwiftTerm):**
- OSC 133 phase state machine (`A`/`B`/`C`/`D` → at-prompt / executing).
- Command-line tokenizer (quotes/escapes → tokens + cursor token).
- Completion-spec model + JSON loader, and the matcher/ranker — a pure
  `(line, cursorOffset, cwd, specs) → [Candidate]`. The heart of the feature and
  the most edge-case-prone part; being pure, it's exhaustively testable
  (`git ch`→`checkout`, `cd ./s`→dirs, unknown-command→paths, quote handling…).

**GUI, in `Coda`:**
- Registering the OSC 133 handler; reading cursor cell + buffer.
- Keystroke interception (extending the existing `NSEvent` monitor).
- The overlay `NSView` (render / position / flip).
- Running generators (spawning `git branch`, etc.) and filesystem enumeration —
  the impure I/O that *feeds* candidates into the pure ranker.

**Ownership:** one completion controller **per `TerminalSurface`** (surfaces are
independent and persist across sidebar switches); inert unless its surface is
focused. Phase + suppression state lives with the surface.

## Scope

**In, v1:**
- zsh only.
- Spec-driven popup; hand-authored specs for the CLIs the user lives in
  (git, claude, cd/ls, and a handful more) in a Fig-subset JSON format.
- Two generators: filesystem paths, git branches/remotes.
- Prefix + substring matching.
- Path completion for unknown commands.
- Consent + global toggle.

**Fast-follow / later (not v1):**
- bash integration (`--rcfile`; the format and pipeline are proven on zsh
  first).
- Vendoring the community Fig spec repo's static parts (the JSON format is
  deliberately Fig-subset-compatible so this is a data import, not a rewrite —
  see ADR 0002).
- Fuzzy matching toggle; ghost-text layer; history/AI suggestions.
- More dynamic generators.

**Out:**
- fish/nushell and other shells (silent-off).
- Node/inshellisense sidecar (rejected — ADR 0002).
- Completions in ssh/remote/REPL contexts.

## Open implementation risks (not design blockers)

- **Cursor-cell API surface:** confirm the exact SwiftTerm accessor for the live
  cursor cell (`buffer.x`/`buffer.y` or equivalent) and that it's public.
- **`ZDOTDIR` faithfulness:** the wrapper must correctly chain `.zshenv` →
  `.zprofile` → (our) `.zshrc` → user `.zshrc`, and cope with a user rc that
  itself reads/writes `ZDOTDIR`.
- **NSEvent monitor ordering:** the new interception must not regress existing
  handled keys (⌘K clear, ⌘⌫ kill-to-start, ⌘/⇧/⌥ + Enter soft-newline, ⌘+click,
  ⌘-hover).
- **Generator cost:** spawning `git branch` on keystrokes must be throttled and
  cached to avoid process storms.
