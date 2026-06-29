# Coda

A native macOS app that orchestrates Claude Code work across git worktrees. The user manages many parallel branches of work, each in its own worktree, with an embedded terminal as the primary surface.

## Language

**Repository**:
A registered local git repo that worktrees are created from. Carries per-repo settings (setup script, copy-allowlist).
_Avoid_: Project, repo (in user-facing text)

**Worktree**:
The primary unit of work: a branch + its on-disk git worktree + the persisted surface(s) opened inside it. Opening one drops you into a shell in that worktree; Claude is launched on demand, not automatically.
_Avoid_: Session (the old name — it wrongly implied a Claude run is the thing)

**Surface**:
A single pane inside a worktree — for now a terminal; later a read-only diff view, etc. A worktree's surfaces persist (stay live) when you switch away and back.
_Avoid_: Pane (use for split geometry only), view

**Scratch terminal**:
A throwaway terminal not backed by any worktree — the escape hatch for quick one-off shell work.
_Avoid_: Throwaway tab, plain tab

**Claude run**:
An actual invocation of `claude` inside a worktree's terminal surface, started on demand. A worktree may have zero or one running.
_Avoid_: Session, agent (when referring to the process)
