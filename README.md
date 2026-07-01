# Coda

A native macOS app that orchestrates [Claude Code](https://claude.com/claude-code)
work across git worktrees. You manage many parallel branches of work — each in
its own git worktree — with an embedded terminal as the primary surface. Opening
a worktree drops you into a shell there; Claude is launched on demand, not
automatically.

<!-- SCREENSHOT: drop an app screenshot here, e.g.
     ![Coda](docs/design/screenshot.png)
     Until then this placeholder is intentionally left in. -->
> _Screenshot coming soon._

## Install

Coda is distributed through a public [Homebrew tap](https://github.com/IsaacArnold/homebrew-coda).
The app is signed and notarized by Apple, so it opens with no Gatekeeper
warning, including on managed/locked-down Macs.

```sh
brew tap isaacarnold/coda
brew trust isaacarnold/coda    # one-time; Homebrew 6+ gates non-official taps
brew install --cask coda
```

Update later with (no re-trust needed):

```sh
brew upgrade --cask coda
```

Requires macOS 13 (Ventura) or later. See the
[tap README](https://github.com/IsaacArnold/homebrew-coda) for details on the
one-time `trust` step.

## Concepts

- **Repository** — a registered local git repo that worktrees are created from.
  Carries per-repo settings (setup script, copy-allowlist).
- **Worktree** — the primary unit of work: a branch + its on-disk git worktree +
  the persisted surface(s) opened inside it.
- **Surface** — a single pane inside a worktree (today a terminal; later a
  read-only diff view, etc.). A worktree's surfaces stay live when you switch
  away and back.
- **Scratch terminal** — a throwaway terminal not backed by any worktree, for
  quick one-off shell work.
- **Claude run** — an actual invocation of `claude` inside a worktree's terminal,
  started on demand.

See [`CONTEXT.md`](CONTEXT.md) for the full domain vocabulary.

## Build from source

Coda is a Swift Package Manager project (Swift 6 toolchain, macOS 13+). The one
runtime dependency is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

```sh
git clone https://github.com/IsaacArnold/coda.git
cd coda
swift build          # debug build
swift run Coda       # build and launch
```

### Packaging a distributable `.app`

```sh
scripts/make-app.sh          # builds an unsigned .app + .dmg under dist/
VERSION=1.2.0 scripts/make-app.sh
```

The unsigned build is ad-hoc sealed only — Gatekeeper blocks it on first launch
on other machines. Set `DEVELOPER_ID_APP` (plus notary credentials) to produce a
signed, notarized build. `scripts/release.sh` runs the test suite, builds,
notarizes, and publishes a release to the tap in one command. See the header
comments in each script for the full set of environment variables.

### Tests

```sh
swift test
```

## Contributing

Issues and feature requests are tracked as [GitHub issues](https://github.com/IsaacArnold/coda/issues).
Bug reports and PRs are welcome.

## License

[MIT](LICENSE) © 2026 Isaac Arnold.
