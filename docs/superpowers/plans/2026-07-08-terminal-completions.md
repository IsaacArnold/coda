# Terminal Completions (Kiro-style CLI autocomplete) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** As the user types at a Coda terminal prompt, a native dropdown appears at the cursor listing candidate subcommands / options / arguments (each with a description), navigable by keyboard and accepted with Tab. Spec-driven, native Swift, zsh-only for v1.

**Design:** `docs/superpowers/specs/2026-07-08-terminal-completions-design.md`. **Decision:** `docs/adr/0002-native-completion-engine.md`. **Glossary:** *Completion popup*, *Completion spec*, *Shell integration* in `CONTEXT.md`.

**Architecture:** The "brain" (OSC 133 phase machine, tokenizer, spec model, matcher/ranker) is pure and lives in `CodaCore`, exhaustively unit-tested. The impure edges (OSC-handler registration, cursor reads, keystroke interception, the `NSVisualEffectView` overlay, filesystem/git generators, `ZDOTDIR` injection) live in `Coda`. One completion controller per `TerminalSurface`, inert unless focused.

**Tech Stack:** Swift, SwiftTerm (`registerOscHandler`, buffer/cursor reads), AppKit (`NSVisualEffectView` overlay, `NSEvent` monitor), Swift Package Manager, zsh.

## Global Constraints

- **Build/test with full Xcode:** set `DEVELOPER_DIR` to `Xcode.app` (CommandLineTools lacks XCTest and clashes on toolchain versions), and use a separate `--build-path` when running `swift test`. Trust `swift build`, not SourceKit's cross-module diagnostics.
- **TDD for all `CodaCore` work:** red → green → refactor. The pure engine is the highest-value test surface; write the tests first.
- **SwiftTerm's key/mouse methods are sealed** (`public` not `open`): all keystroke handling goes through the app-level `NSEvent` monitor in `AppDelegate`, never a `keyDown` override.
- **Do not regress existing intercepted keys:** ⌘K (clear), ⌘⌫ (kill-to-line-start), ⌘/⇧/⌥ + Enter (soft-newline), ⌘+click (open file/URL), ⌘-hover (pointing cursor).
- **Accuracy over coverage:** the popup appears *only* when we are certain we're at the editable prompt of our integrated shell. Silent-off everywhere else.
- Atomic tasks, one commit each. Follow existing file/naming patterns.

---

## Phase A — Pure core in `CodaCore` (TDD, no AppKit/SwiftTerm)

### Task 1: OSC 133 phase state machine

The pure model of shell phase, driven by OSC 133 marker letters.

**Files:**
- Create: `Sources/CodaCore/PromptPhase.swift`
- Create: `Tests/CodaCoreTests/PromptPhaseTests.swift`

**Interfaces:**
- Produces: `enum PromptPhase { case unknown, atPrompt, executing }`
- Produces: `struct PromptPhaseMachine { mutating func consume(marker: Character); var phase: PromptPhase; var lastCommandExitCode: Int? }`
- Semantics: `A` → prompt-start, `B` → command-start (⇒ `.atPrompt`), `C` → pre-exec (⇒ `.executing`), `D[;code]` → command-finished (⇒ `.unknown` until next `A`/`B`). Captures exit code from `D;<code>` when present.

- [ ] **Step 1 (RED):** Write `PromptPhaseTests` covering: fresh machine is `.unknown`; `B`→`.atPrompt`; `C`→`.executing`; `D`→`.unknown`; a full `A,B,C,D` cycle; `D;0` / `D;1` capture exit code; out-of-order/duplicate markers don't crash and resolve sensibly.
- [ ] **Step 2 (GREEN):** Implement `PromptPhase` + `PromptPhaseMachine`.
- [ ] **Step 3:** `swift build` + `swift test` (Xcode `DEVELOPER_DIR`). Commit.

### Task 2: Command-line tokenizer

Split the line-to-cursor into tokens and identify the token under the cursor.

**Files:**
- Create: `Sources/CodaCore/CommandLineTokenizer.swift`
- Create: `Tests/CodaCoreTests/CommandLineTokenizerTests.swift`

**Interfaces:**
- Produces: `struct CommandToken { let text: String; let range: Range<Int> }`
- Produces: `struct TokenizedLine { let tokens: [CommandToken]; let cursorTokenIndex: Int?; let cursorPrefix: String; let endsWithSeparator: Bool }`
- Produces: `func tokenizeCommandLine(_ line: String, cursorOffset: Int) -> TokenizedLine`
- Semantics: respects `'…'`, `"…"`, and backslash-escapes; `cursorPrefix` is the part of the cursor's token before the cursor; `endsWithSeparator` is true when the char before the cursor is unquoted whitespace (⇒ "starting a new token", e.g. `git ` should offer subcommands).

- [ ] **Step 1 (RED):** Tests: `git ch|` → one-ish token, prefix `ch`; `git |` → `endsWithSeparator`, empty prefix; quoted `cd "my dir|"`; escaped `cd my\ di|`; cursor mid-line; empty line.
- [ ] **Step 2 (GREEN):** Implement.
- [ ] **Step 3:** Build + test. Commit.

### Task 3: Completion-spec model + JSON loader (Fig-subset)

Define the Fig-subset spec format and load it from bundled JSON.

**Files:**
- Create: `Sources/CodaCore/CompletionSpec.swift`
- Create: `Tests/CodaCoreTests/CompletionSpecTests.swift`

**Interfaces (Fig-subset — keep field names Fig-compatible so future vendoring is a data import, per ADR 0002):**
- `struct CompletionSpec: Codable { let name: [String]; let description: String?; let subcommands: [CompletionSpec]?; let options: [SpecOption]?; let args: [SpecArg]? }`
- `struct SpecOption: Codable { let name: [String]; let description: String?; let args: [SpecArg]? }`
- `struct SpecArg: Codable { let name: String?; let template: ArgTemplate?; let generator: GeneratorID?; let isOptional: Bool?; let isVariadic: Bool? }`
- `enum ArgTemplate: String, Codable { case filepaths, folders }` (Fig's `"filepaths"`/`"folders"`)
- `enum GeneratorID: String, Codable { case gitBranches, gitRemotes }` (Coda-native generator ids; extend as needed)
- `func loadCompletionSpecs(from directory: URL) throws -> [String: CompletionSpec]` keyed by primary command name.

- [ ] **Step 1 (RED):** Tests decode a sample `git.json` and `cd.json` fixture into the model (subcommands, options with aliases via `name: [...]`, an arg with `template: "folders"`, an arg with `generator: "gitBranches"`); loader indexes by name and handles missing/malformed files gracefully.
- [ ] **Step 2 (GREEN):** Implement model + loader. Add fixtures under `Tests/CodaCoreTests/Fixtures/specs/`.
- [ ] **Step 3:** Build + test. Commit.

### Task 4: Completion engine — pure context resolution + ranking

The heart. Split into two pure functions with the impure I/O sitting *between* them, so both are testable.

**Files:**
- Create: `Sources/CodaCore/CompletionEngine.swift`
- Create: `Tests/CodaCoreTests/CompletionEngineTests.swift`

**Interfaces:**
- `enum CandidateKind { case subcommand, option, argument, file, directory, command }`
- `struct Candidate { let name: String; let description: String?; let kind: CandidateKind; let insertion: String }`
- `enum DynamicSource { case filepaths, folders, generator(GeneratorID) }`
- `struct CompletionContext { let staticCandidates: [Candidate]; let dynamicSources: [DynamicSource]; let query: String; let replacementRange: Range<Int> }`
- **Pure step 1:** `func resolveCompletion(line: String, cursorOffset: Int, specs: [String: CompletionSpec]) -> CompletionContext` — tokenizes, walks the spec tree, classifies the cursor token, returns static candidates (subcommands/options) + which dynamic sources to resolve + the query (`cursorPrefix`) + the range to replace on accept.
- **Pure step 2:** `func rankCandidates(_ all: [Candidate], query: String) -> [Candidate]` — case-insensitive **prefix** match ranked above **substring** match; stable within a tier by spec order; drop non-matches.

The GUI resolves `dynamicSources` (filesystem/git) between the two calls and merges the results into `all`.

- [ ] **Step 1 (RED):** Tests for `resolveCompletion`: `git |`→subcommands; `git ch`→query `ch` + subcommands; `git checkout |`→`dynamicSources` contains `.generator(.gitBranches)`; `git --|`→options; `cd |`→`.folders`; `cd ./s`→`.folders` + query; **unknown command `frobnicate ./s`→`.filepaths`** (path completion for unknown commands); empty line→empty context. Tests for `rankCandidates`: prefix beats substring; case-insensitive; order stability; no-match dropped.
- [ ] **Step 2 (GREEN):** Implement both functions.
- [ ] **Step 3:** Build + test. Commit. **This is the milestone that proves the feature's brain works headlessly.**

---

## Phase B — Shell integration & enablement

### Task 5: Bundled zsh `ZDOTDIR` integration + spawn wiring

Inject OSC 133 (+ confirm OSC 7) into Coda-spawned zsh without touching the user's dotfiles.

**Files:**
- Create: `Resources/shell-integration/zsh/.zshrc` (bundled; emits OSC 133 via `precmd`/`preexec`, then `source`s the user's real rc)
- Create: `Sources/CodaCore/ShellIntegration.swift` (pure: compute the `ZDOTDIR` value + the env additions given a bundle path + enable flag)
- Create: `Tests/CodaCoreTests/ShellIntegrationTests.swift`
- Modify: `Sources/CodaCore/HookEnvironment.swift` (fold integration env in alongside the existing `CODA_*`/`TERM` vars)
- Modify: `Sources/Coda/TerminalSurface.swift` (`viewDidLayout` spawn ~lines 129–154) and `Package.swift` (bundle the resource)

**Bundled `.zshrc` behavior:** save incoming `ZDOTDIR`/`HOME`; define `precmd`/`preexec` that print `\e]133;A\a`/`\e]133;B\a` (prompt) and `\e]133;C\a` (pre-exec) and a `precmd` that emits `\e]133;D;$?\a` for the prior command; then restore `ZDOTDIR` to the user's and `source "${__coda_user_zdotdir}/.zshrc"` (respecting `.zshenv`/`.zprofile` already sourced by zsh before `.zshrc`). Guard against double-install.

**Interfaces:**
- `func shellIntegrationEnv(enabled: Bool, shell: ResolvedShell, bundleZdotdir: URL, userZdotdir: URL) -> [String: String]` — returns `["ZDOTDIR": <bundle>, "CODA_USER_ZDOTDIR": <user>]` when enabled *and* shell is zsh; empty otherwise (bash/fish/etc ⇒ silent-off).

- [x] **Step 1 (RED):** `ShellIntegrationTests`: zsh + enabled → sets `ZDOTDIR` to bundle + preserves user dir; bash + enabled → empty (unsupported); disabled → empty.
- [x] **Step 2 (GREEN):** Implement pure helper; add the bundled `.zshrc`; bundle it via `Package.swift` resources; merge its env in `HookEnvironment`/`TerminalSurface` spawn. Set via **env, not argv**, so it composes with both the bare `-i` and the `-i -c '…'` paths.
- [x] **Step 3:** Build + test. **Manual verify:** launch Coda, open a terminal, confirm the user's aliases/prompt still load AND `printf '\e]133;B\a'` markers arrive (log them in a temp OSC-133 handler). Commit. _(Done headlessly: `expect`-driven zsh against the real built bundle showed the full A/B/C/D lifecycle + oh-my-zsh aliases loading. GUI-launch confirmation deferred to Task 12's end-to-end pass.)_

### Task 6: Consent prompt + global settings toggle

Gate injection behind consent; expose an independent global toggle.

**Files:**
- Modify: `Sources/Coda/AppDelegate.swift` (mirror `promptForHookInstallIfNeeded` ~lines 203–220; add a completions-consent path + persisted flag)
- Modify: the Settings/preferences surface (same section as the hook toggle, but an independent control)

**Interfaces:**
- Produces: a persisted `completionsEnabled` flag (UserDefaults), default decided by first-run consent; independent of the Claude-hook flag.
- Consumes: Task 5's `shellIntegrationEnv(enabled:…)` — the flag feeds `enabled`.
- **Applies to newly-opened terminals only** (the `ZDOTDIR` wrapper is fixed at spawn); add a note in the toggle's help text.

- [x] **Step 1:** Add first-run consent prompt (reuse the hook-installer pattern), persist the flag, default on after consent.
- [x] **Step 2:** Add the global Settings toggle; when off, `shellIntegrationEnv` returns empty ⇒ zero OSC 133 overhead on new terminals.
- [x] **Step 3:** Build. **Manual verify:** decline consent → no `ZDOTDIR` set; accept → set; toggle off → new terminal has no markers. Commit. _(Build + full suite green; gate logic verified via code trace. GUI decline/accept/toggle-off confirmation deferred to Task 12's end-to-end pass.)_

---

## Phase C — GUI wiring in `Coda`

### Task 7: OSC 133 handler + phase/cwd/cursor exposure on the surface

Feed the pure phase machine from the live terminal, and expose what the controller needs.

**Files:**
- Modify: `Sources/Coda/ClickableTerminalView.swift` (register handler; expose cursor cell + phase; `currentDirectory` already tracked via OSC 7)
- Modify: `Sources/Coda/TerminalSurface.swift`

**Interfaces:**
- On terminal creation: `terminal.registerOscHandler(code: 133) { data in … }` → parse leading letter → `PromptPhaseMachine.consume(marker:)`.
- Produces: `ClickableTerminalView.promptPhase: PromptPhase`, `.cursorCell: (col: Int, row: Int)` (from SwiftTerm's buffer cursor), `.isScrolledToBottom: Bool`, and a `cursorCellToViewPoint(_:)` helper (inverse of the `clickTarget(at:)` cell math ~lines 225–263).
- Consumes: `currentDirectory`/`fallbackDirectory` (`baseDirs`, ~lines 265–276) for cwd.

- [x] **Step 1:** Register the OSC 133 handler; drive the phase machine; log phase transitions behind a debug flag to confirm.
- [x] **Step 2:** Add the cursor-cell + scrolled-to-bottom accessors and the cell→point helper. **Resolve implementation risk:** confirm the public SwiftTerm accessor for the live cursor cell (`buffer.x`/`buffer.y` or equivalent). _(Confirmed public: `terminal.buffer.x`/`.y`; scroll via `canScroll`/`scrollPosition`; OSC payload arrives pre-split after `133;`.)_
- [x] **Step 3:** Build. **Manual verify:** debug-log shows `atPrompt`↔`executing` tracking real typing vs a running `sleep 3`. Commit. _(Build + full suite green; phase-trace correctness proven on paper. Live GUI debug-log confirmation (`CODA_DEBUG_OSC133`) deferred to Task 12's end-to-end pass.)_

### Task 8: `CompletionController` per surface (orchestration + gating + async I/O)

The conductor: debounce, call the pure engine, resolve dynamic sources, apply the visibility gate.

**Files:**
- Create: `Sources/Coda/CompletionController.swift`
- Modify: `Sources/Coda/TerminalSurface.swift` (own one controller; inert unless focused)

**Interfaces:**
- `func refresh()` — read line-to-cursor from the buffer (from command-start), call `resolveCompletion`, resolve `dynamicSources` async (Task 11), call `rankCandidates`, hand results to the overlay (Task 9).
- **Gate (all must hold to show):** `promptPhase == .atPrompt`; surface focused; `isScrolledToBottom`; non-empty query or `endsWithSeparator` after a command; ≥1 ranked candidate; not in post-Esc suppression window.
- **Debounce ~30–50 ms, cancellable;** the keystroke reaches the shell immediately regardless.
- State: `isSuppressedUntilNextEdit` (set by Esc, cleared by the next character/backspace).

- [x] **Step 1:** Implement the controller with the gate + debounce; wire it to fire on terminal output/keystroke. Read the current command line from the buffer between command-start and cursor. _(Gate extracted to `CodaCore/CompletionGate.swift`, TDD-tested. Keystroke-driven refresh is Task 10; output/phase/focus wired here.)_
- [x] **Step 2:** Build. **Manual verify:** debug-log the ranked candidates as you type `git ch` (no UI yet). Commit. _(Build + 405 tests green; `git ch`→query `ch`→ranked `[checkout, cherry-pick]` proven via static trace + a minimal seed `git.json`. `CODA_DEBUG_COMPLETIONS` live-log verification deferred to Task 12's end-to-end pass.)_

### Task 9: The completion popup overlay (`NSVisualEffectView`)

Native-chrome dropdown, anchored at the cursor.

**Files:**
- Create: `Sources/Coda/CompletionPopupView.swift`
- Modify: `Sources/Coda/ClickableTerminalView.swift` (host the overlay, following the `DropHighlightOverlay` pattern ~lines 315–324; `hitTest` → nil)

**Interfaces:**
- `func show(candidates: [Candidate], anchorCell: (col: Int, row: Int), selectedIndex: Int)`, `func hide()`, `var selectedIndex`.
- Native `NSVisualEffectView`-backed panel, system font; rows = name + dimmed description; ~8 visible, scrolls; selection highlighted.
- **Placement:** below the current line, left-aligned to the completed token's start; **flips above** near the window's bottom edge; repositions on cursor move.

- [x] **Step 1:** Build the view + positioning/flip logic; drive it from the controller.
- [x] **Step 2:** Build. **Manual verify:** popup appears at the cursor for `git ch`, flips above near the bottom, shows descriptions. Commit. _(Build + 405 tests green; positioning/flip/clamp proven via traces. Live on-screen verification deferred to the combined GUI pass after Task 10, when the popup is keyboard-drivable.)_

### Task 10: Keystroke interception for popup navigation

Extend the existing `NSEvent` monitor so the popup steals keys *only while visible*.

**Files:**
- Modify: `Sources/Coda/AppDelegate.swift` (the local key monitor ~lines 131–140; route to the focused surface's `CompletionController`)
- Possibly: `Sources/CodaCore/TerminalKeyBindings.swift` (if a pure decision helper fits the existing pattern)

**Interfaces / keymap (only when popup visible):** ↑/↓ move selection; **Tab accepts** (send `insertion` for the `replacementRange` via `terminal.send`); Esc dismisses + suppresses; Enter closes the popup and **passes through to run**; printable filters. When hidden: everything passes through unchanged (↑/↓→history, Tab→zsh completion).

- [ ] **Step 1:** In the monitor, if the focused surface's popup is visible, consult the controller; consume handled keys (return `nil`), else fall through. **Verify existing shortcuts still work** (⌘K, ⌘⌫, soft-newline, ⌘+click, ⌘-hover) — add a regression check to the manual pass.
- [ ] **Step 2:** Implement accept (compute insertion + send), Esc suppression, Enter passthrough.
- [ ] **Step 3:** Build. **Manual verify:** full loop — type `git ch`, ↓ to `cherry-pick`, Tab inserts it, Enter runs; Esc hides and stays hidden until next edit; Tab with no popup still triggers zsh completion. Commit.

### Task 11: Dynamic generators (filesystem + git branches)

The impure candidate sources, throttled and cached.

**Files:**
- Create: `Sources/Coda/CompletionGenerators.swift`

**Interfaces:**
- `func filesystemCandidates(prefix: String, cwd: URL, foldersOnly: Bool) -> [Candidate]` (enumerate a directory, filter by prefix).
- `func gitBranchCandidates(cwd: URL) async -> [Candidate]` (spawn `git branch`/`git remote`, parse) — **throttled + cached per cwd** to avoid a process per keystroke.
- Consumes: `DynamicSource` from Task 4; produces `[Candidate]` merged before `rankCandidates`.

- [ ] **Step 1:** Implement filesystem enumeration (sync, cheap) and git generators (async, cached with a short TTL + in-flight de-dup).
- [ ] **Step 2:** Wire into `CompletionController.refresh()` between `resolveCompletion` and `rankCandidates`.
- [ ] **Step 3:** Build. **Manual verify:** `cd ./` lists dirs; `git checkout ` lists branches; rapid typing doesn't spawn a `git` storm (log spawn count). Commit.

---

## Phase D — Integration, ship-readiness

### Task 12: End-to-end verification, edge cases, seed specs

**Files:**
- Add: hand-authored specs under `Resources/completion-specs/` — `git.json`, `claude.json`, `cd.json`, `ls.json`, and a handful more the user lives in.
- Modify: docs/changelog as the repo convention requires.

- [ ] **Step 1:** Author the seed specs (Fig-subset JSON). Include git subcommands + the `gitBranches` generator on `checkout`/`switch`/`merge`/`rebase`/`push`.
- [ ] **Step 2 — Silent-off verification (the accuracy-over-coverage guarantees):** confirm no popup during a `claude` run; inside `python3` REPL; inside `ssh localhost`; after `exec bash`; while a command runs; while scrolled up.
- [ ] **Step 3 — Regression pass:** all existing intercepted keys and terminal features still work; user prompt/aliases still load; disabling the toggle removes injection on new terminals.
- [ ] **Step 4:** Use the `verify` skill to drive the full flow end-to-end in the real app. Follow the release pipeline convention when cutting the version.

---

## Sequencing notes

- **Phase A is fully headless** — land all of it (Tasks 1–4) behind no UI; it's the safest, most testable foundation and proves the brain before any AppKit work.
- **Phase B before C:** you need markers arriving (Task 5/7) before the controller has anything to gate on.
- **Task 9 (popup) and Task 10 (keys) are separable:** you can see the popup render (9) before wiring acceptance (10), which makes debugging positioning independent of key handling.
- **Implementation risks to close during build** (from the design doc): exact SwiftTerm cursor-cell accessor (Task 7); `ZDOTDIR` chaining faithfulness incl. a user rc that touches `ZDOTDIR` (Task 5); NSEvent-monitor ordering vs existing shortcuts (Task 10); generator throttling (Task 11).
