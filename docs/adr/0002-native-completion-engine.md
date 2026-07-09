---
status: accepted
---

# Native Swift completion engine over a Fig-subset JSON spec format

Coda's terminal completions are computed by a **native Swift engine** reading a **JSON completion-spec format that is a subset of Fig's**, not by bundling a Node runtime and an existing engine (inshellisense / Fig's own spec runner). v1 ships a small set of hand-authored specs for the CLIs the user lives in (git, claude, cd/ls paths, and a handful more) plus a Swift generator abstraction for the highest-value dynamic cases (filesystem paths, git branches). The spec format is deliberately Fig-subset-compatible so the community spec repo can be vendored in later without an architecture change.

## Why

The obvious path is to bundle Microsoft's `inshellisense` (MIT), which already ships the thousands of `withfig/autocomplete` specs plus a working engine — instant breadth. It was rejected: it would embed a Node runtime and a subprocess IPC protocol inside a lean, signed, notarized native macOS bundle, adding a large moving dependency to keep updated and sandbox-safe. A native engine keeps the app a single Swift binary, keeps latency low (no process hop per keystroke), and keeps full control over rendering and cancellation.

The cost is coverage: v1 knows only the CLIs we author specs for, and Fig's JS `generators` (dynamic value producers) don't run — so dynamic completions exist only where we hand-write a Swift generator. We accept a sharp, fast, native core over broad-but-heavy on day one, with a growth path via later spec vendoring.

## Considered options

- **Node sidecar (inshellisense / Fig runner)** — rejected: broadest coverage, but ships Node + IPC in a native bundle; heavy, sandbox-fragile, per-keystroke process hop.
- **Native engine, static-only, vendor all Fig specs' static parts** — deferred, not rejected: the format is built to allow it; not needed for v1's tool set.
- **Native engine, hand-authored specs, Fig-subset format** (chosen) — smallest thing that feels like Kiro for the tools the user actually uses, with no runtime lock-in and a clean import path later.

## Consequences

- A JSON completion-spec format must be defined up front and kept Fig-subset-compatible, so future vendoring is a data import, not a rewrite.
- Dynamic completions (git branches, file paths) require bespoke Swift generators; unknown CLIs degrade to path/no-arg completion rather than failing.
