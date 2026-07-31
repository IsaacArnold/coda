# Package script completions (`npm run <script>` from package.json)

**Date:** 2026-07-31
**Status:** Approved

## Problem

Coda's completion popup knows a command's static shape (subcommands, flags) and
two dynamic sources (filesystem paths, git branches/remotes). It knows nothing
about the *project* it's sitting in.

The most common thing a JS developer types in a project terminal is a script
that only that project defines: `npm run dev`, `npm run test:watch`. Those names
live in `package.json` and can't be known statically. Kiro CLI surfaces them,
and it's the feature most missed after switching to Coda's popup — you have to
remember the script names, or break flow to go read `package.json`.

This adds `package.json` scripts as a completion source for the four common JS
runners. See also glossary terms **Completion popup**, **Completion spec** in
`CONTEXT.md`, and ADR `docs/adr/0002-native-completion-engine.md` for why
dynamic values come from a closed set of Swift-native generators rather than
Fig's JS `generators`.

## The experience

Scripts appear in **two** positions, because both are natural to type:

```
$ npm ▍
┌──────────────────────────────────────────────┐
│ run build        tsc && vite build           │
│ run dev          vite --host                 │
│ run test         vitest run                  │
│ install          Install a package           │
│ ci               Clean install from lockfile │
└──────────────────────────────────────────────┘
  ↑ scripts first, then npm's own subcommands

$ npm run ▍
┌──────────────────────────────────────────────┐
│ build            tsc && vite build           │
│ dev              vite --host                 │
│ test             vitest run                  │
└──────────────────────────────────────────────┘
```

At `npm ` a script is offered as `run dev`, so you never have to type `run`
first; accepting inserts `run dev `. At `npm run ` the same scripts are offered
as bare names. `yarn` runs scripts without `run`, so it offers bare names at top
level as well as under `run`.

Each row's description is the script's own command line, which doubles as a
reminder of what it actually does.

## Design

### 1. Two generator IDs, shaping chosen by spec data

`GeneratorID` gains two cases:

- `packageScripts` — yields bare names (`dev`)
- `packageScriptsWithRun` — yields `run`-prefixed names (`run dev`)

Each spec position references whichever shape it wants. This needs **no engine
change**: `resolveCompletion` already emits, for a fresh positional, the
resolved spec's subcommands + options *plus* the dynamic source of the
positional arg at that depth. So `npm `'s own `args[0]` generator and the `run`
subcommand's `args[0]` generator are both already reachable.

**Rejected:** a single generator ID with the engine threading positional context
into `DynamicSource` (e.g. `.generator(id, prefix:)`). It would change the pure
engine's types and every call site to serve one cosmetic difference in the
rendered name. Two data-selected IDs keep the engine untouched and make each
spec position explicit about what it wants.

`CandidateKind` gains `.script`, so scripts are distinguishable from
`.subcommand`/`.argument` for ordering (below) and any future icon work.

### 2. Pure shaping in CodaCore

New `Sources/CodaCore/PackageScripts.swift`:

```swift
public func packageScriptCandidates(
    packageJSON: Data,
    runPrefixed: Bool,
    cap: Int = 100
) -> [Candidate]
```

- Decodes the top-level `scripts` object. Non-string values are skipped
  (a nested object is invalid npm but must not crash us).
- `name` — `dev`, or `run dev` when `runPrefixed`.
- `insertion` — shell-escaped name + trailing space, matching the
  `gitNameCandidates` convention. For `runPrefixed`, `run ` is a literal prefix
  and only the script name is escaped.
- `description` — the script's command, truncated to 60 characters with a
  trailing `…`. The popup already tail-ellipsises past its 480pt `maxWidth`;
  truncating here keeps the width calculation from being dominated by one
  pathological script.
- `kind` — `.script`.
- **Sorted alphabetically (case-insensitive)**, then capped, mirroring
  `filesystemCandidates`' "stable pre-rank sort" contract. Decoding a JSON
  object loses declaration order, and recovering it would need a raw-byte
  rescan; determinism is worth more than matching file order. This is the one
  choice in this spec that is purely a preference — reversible in isolation.
- Malformed JSON, absent `scripts`, or empty `scripts` → `[]`. Never throws.

This mirrors the existing split: the impure half does I/O, the pure half filters
and shapes, and the pure half carries the tests.

### 3. The impure generator

`CompletionGenerators.packageScripts(cwd:runPrefixed:) -> [Candidate]`:

- **Resolution:** walk up from `cwd` looking for `package.json`, taking the
  first one found, stopping at the filesystem root. This matches npm's own
  resolution, so completions work from a subdirectory of the project — the
  common case when you're deep in `src/`.
- **Caching:** keyed by the resolved `package.json` path, invalidated when its
  modification date or size changes. Editing `package.json` is reflected on the
  next keystroke, with no stale window.
- **Synchronous**, unlike `gitBranches`/`gitRemotes`. Those are async because
  each is a subprocess spawn; this is one small file read, well within the
  budget of a 40ms-debounced refresh. That means it needs none of the
  `inFlight` / `onAsyncUpdate` / TTL machinery, and — better for the user —
  candidates appear on the *first* keystroke rather than after a second refresh.

The walk-up is bounded by the filesystem root, and a failed read at any level is
skipped rather than aborting the walk.

**Implementation note:** resolution and caching (`PackageScriptStore`) actually
live in `CodaCore`, not `CompletionGenerators` as planned above — `CodaCoreTests`
is the only test target, so putting them there is what makes them testable.

### 4. Scripts rank first

With an empty query `rankCandidates` returns candidates unchanged, and the
controller assembles `staticCandidates + dynamic` — so scripts would land
*below* npm's subcommands at `npm `, which is backwards: the project's scripts
are the reason you're typing.

`rankCandidates` gains a **stable partition placing `.script` ahead of other
kinds**, applied in both the empty-query and matched paths. Because `.script` is
a brand-new kind produced only by this generator, no existing ordering changes.

**Rejected:** assembling `dynamic + static` in the controller. That would push
git branches ahead of subcommands everywhere — a broad behavioural change to fix
a local ordering problem.

### 5. Spec files

Four new files in `Sources/Coda/Resources/completion-specs/`, auto-discovered by
the existing loader:

| Spec | Top-level `args[0]` | `run` subcommand | Static subcommands |
|---|---|---|---|
| `npm.json` | `packageScriptsWithRun` | `packageScripts` (alias `run-script`) | `install`, `ci`, `test`, `start`, `uninstall`, `update`, `outdated`, `publish`, `exec`, `init`, `link` |
| `pnpm.json` | `packageScriptsWithRun` | `packageScripts` | `install`, `add`, `remove`, `update`, `dlx`, `exec`, `init` |
| `bun.json` | `packageScriptsWithRun` | `packageScripts` | `install`, `add`, `remove`, `x`, `init`, `test` |
| `yarn.json` | `packageScripts` (bare — yarn needs no `run`) | `packageScripts` | `add`, `remove`, `install`, `up`, `why`, `dlx`, `init` |

Each top-level script arg is `isOptional: true` so the spec stays valid for
invocations that take a subcommand instead.

**Overlap is intentional, not a bug to dedupe.** A project with a `test` script
shows both `run test` (the script, with its command as the description) and
`test` (npm's built-in subcommand) at `npm `. Both are real, and they can do
different things — `npm test` is only an alias for `npm run test` when a `test`
script exists. The implementation must not filter one out.

## Error handling

Every failure degrades to "no script candidates", never an error surfaced to the
user and never a thrown error:

| Situation | Behaviour |
|---|---|
| No `package.json` anywhere above cwd | `[]` — e.g. `npm ` in a Swift project offers only npm's subcommands |
| `package.json` unreadable (permissions) | `[]`, walk continues upward |
| Malformed JSON | `[]` |
| No `scripts` key, or empty | `[]` |
| Non-string script value | that entry skipped, others kept |
| More than `cap` scripts | first 100 alphabetically |

Diagnostics only behind the existing `CODA_DEBUG_COMPLETIONS` env var.

## Testing

Pure, headless tests carry the logic:

- `packageScriptCandidates`: bare vs `run`-prefixed shaping; alphabetical order;
  description truncation; cap; escaping of a script name needing it; malformed
  JSON; absent/empty `scripts`; non-string value skipped.
- `rankCandidates`: scripts precede other kinds with an empty query *and* with a
  matching query; existing non-script ordering unchanged.
- `resolveCompletion` over a spec fixture: `npm ` yields both static
  subcommands and `.generator(.packageScriptsWithRun)`; `npm run ` yields
  `.generator(.packageScripts)`; `yarn ` yields the bare generator.
- `CompletionGenerators.packageScripts` against a real temp directory tree:
  resolution from a nested subdirectory, no-`package.json` case, and cache
  invalidation after rewriting the file (proving an edit is picked up).

## Out of scope

Deliberately excluded, each addable later on the same seam:

- Non-JS runners: Makefile targets, `cargo`, `composer`, `uv`.
- Monorepo workspace merging — only the nearest `package.json` is read, not the
  workspace root's as well.
- Completing *arguments* to a script (`npm run test -- --watch`).
- Reading the package manager from the lockfile to suppress the "wrong" runner's
  completions. Scripts run under any of them, so the noise isn't worth the
  inference.

## Note on branching

Branched from `fix/completions-shell-integration-hijack` (PR #71) rather than
`main`, because live-verifying any completion behaviour requires the shell
integration that PR restores. To be rebased onto `main` once #71 merges.
