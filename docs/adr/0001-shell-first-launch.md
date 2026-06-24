---
status: accepted
---

# Shell-first worktree launch (Claude on demand)

Opening a worktree drops the user into a plain shell in the worktree's directory; Claude is started on demand via an explicit **Launch Claude** action (toolbar button + keybind), not automatically. This **reverses the earlier "Claude-first auto-launch" decision** (DECISIONS.md #6), which always spawned `claude` as the only thing a worktree's terminal ever ran.

## Why

A worktree is a workspace, not a Claude conversation — the user wants to run builds, git, and one-off commands there, and decide *when* an agent runs. Auto-launching Claude conflated "the worktree I'm working in" with "an agent is running in it," made the app feel like a single-purpose Claude launcher rather than a native worktree orchestrator, and gave no clean path to a plain shell. Making Claude an on-demand, prominently-surfaced action (the orchestrator's analogue of an IDE's "Run") keeps the agent one keystroke away without forcing it.

## Considered options

- **Claude-first auto-launch** (the superseded #6) — rejected: forces an agent the user may not want and hides the shell.
- **Claude-first but killable/relaunchable** — rejected: still makes the agent the default face of every worktree.
- **Shell-first, Claude on demand** (chosen) — smallest change that decouples worktree from agent; Claude-first survives only as an opt-in per-repo default, off by default.

## Consequences

- Requires keeping each worktree's terminal **alive across sidebar switches** (a deliberately-started Claude run must survive navigating away) — see DECISIONS.md R2.
- The "Claude-first" behavior is retained as a per-repo opt-in (off by default), so users who want the old flow can still get it.
