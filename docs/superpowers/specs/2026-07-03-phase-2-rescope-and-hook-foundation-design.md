# Phase 2 re-scope + hook foundation — Design

**Date:** 2026-07-03
**Status:** Draft (pending spec review)

## Why this exists

A step-back re-grill of Phase 2, done after living with Phase 1 + 1.5 shipped (v0.1.7).
The old "fast-follows" list in `DECISIONS.md:155` was written before the app was in daily
use; this re-scopes it around the pain that actually bites, and settles the design of the
first item (the hook foundation) in detail — including its security requirements.

Two references shaped the design, both confirmed against Supacode's shipping,
open-source implementation:
- Correlation by **env-var injection at PTY spawn**, not `cwd`/`session_id` scraping
  (Supacode injects `SUPACODE_SOCKET_PATH`/`SUPACODE_WORKTREE_ID`/… into every terminal;
  the hook process inherits them and self-identifies).
- Transport over a **Unix domain socket**, self-noop when the env is absent
  ("if any are missing it returns immediately").

## Re-scoped Phase 2

Reordered around the daily pain: **trust the badges, get pinged, review in-app.** Merge
drops out to a later Git-operations milestone.

| # | Item | State |
|---|------|-------|
| **2a** | **Hook foundation → authoritative badges** | Designed in this doc. Keystone. Kills the stuck-badge bug (`DECISIONS.md:135`). |
| **2b** | **macOS system notifications** | Designed in this doc. Rides on 2a — same foundation, second payoff. Fulfils decision #16. |
| **2c** | **Read-only diff surface** | Scope only (below). Independent; needs its own grill (base-branch question) → own spec. |

**Deferred out of Phase 2** (were Phase-2-tagged; pushed to stay focused):
- One-button local merge + PR integration → a later **Git-operations** milestone (decision #7).
- Claude `--resume <session_id>` restore (#14) — cheap once 2a records session ids; revisit after.
- Companion CLI `coda new "try approach B"` (#13) — the socket transport here is forward-compatible with it.

**Sequencing:** 2a → 2b are one foundation shipped in two steps; 2c is independent and can
land in parallel or after. This spec covers **2a + 2b**. 2c gets its own spec.

---

## 2a + 2b — Hook foundation and notifications

### The mechanism, end to end

1. **Spawn-time env injection.** When Coda starts a surface's PTY it injects three vars into
   the shell environment:
   - `CODA_SOCKET_PATH` — absolute path to Coda's Unix domain socket.
   - `CODA_WORKTREE_ID` — the worktree id already used as the badge key.
   - `CODA_SURFACE_ID` — the surface id (`surface.id`), already half of `surfaceKey`.

   Today `TerminalSurface` spawns `/bin/zsh` with `environment: nil` (inherits the app's
   env). We replace `nil` with the inherited environment **plus** these three keys.
   Because they live in the PTY's environment, any `claude` launched in that terminal —
   via the Launch Claude ▶ action **or** hand-typed — inherits them.

2. **One global self-noop hook forwarder.** Coda registers a single hook in
   `~/.claude/settings.json` (the only always-read global registration point Claude Code
   offers — it has no per-extension dir like Pi). The hook command:
   - Exits `0` immediately if `CODA_SOCKET_PATH` is unset or the socket is absent (so every
     `claude` run **outside** a Coda terminal is a fast no-op — Supacode's "returns
     immediately" pattern). No network, no file writes on the no-op path.
   - Otherwise reads the event JSON from stdin and writes one framed message to the socket
     with a short timeout, then exits. Never blocks Claude's turn.
   - Is registered for the lifecycle events below. This is the **only** modification to a
     user config file, done transparently and reversibly (see Security §6).

3. **Coda's socket server** receives framed messages, validates them (Security §3–4), maps
   `CODA_SURFACE_ID` → `surfaceKey(worktreeID, surfaceID)`, and updates the same
   `agentStates` dictionary the heuristic poll writes today — so the sidebar, notch, and
   worktree bar light up with **no rendering changes**, just a better source of truth.

### Event → state mapping (authoritative, replaces the heuristic)

| Claude Code hook event | Effect |
|---|---|
| `UserPromptSubmit`, `PreToolUse`, `PostToolUse` | surface → `.working` |
| `Notification` (waiting for input/permission) | surface → `.needsYou`; the payload's own `message` field is the notification body |
| `Stop` | surface → `.done`; body comes from `transcript_path` (see below) |
| `SessionStart` / `SessionEnd` | lifecycle: mark a Claude run present/absent (absent → `.idle`) |

Worktree roll-up (`needsYou > working > done > idle`, `rollup(_:)`) is unchanged.

**Payload reality (verified against the installed hooks reference, `DECISIONS.md:124`):**
every hook payload carries `session_id`, `transcript_path`, `cwd`, `hook_event_name`.
There is **no** `last_assistant_message` field on any event — the docs direct you to read
`transcript_path` for conversation content. `Notification` carries a human-readable
`message` (used directly as the needs-you body). So:
- **needs-you body** = the `Notification` payload's `message` (no file read).
- **done body** = the last assistant text extracted from `transcript_path` (a JSONL; scan
  from the end for the last `type:"assistant"` record and concatenate its `content[]`
  `text` blocks). Bounded read (Security §4 extends to it): read only the tail, cap bytes.

### Wire protocol (single physical line)

`<worktreeID> <surfaceID> <json>\n` — the JSON is the rest of the line, so a `message`
containing spaces/newlines is safe (JSON-escaped). The forwarder emits:
`{"hook_event_name":"…","message":"…"?, "transcript_path":"…"?}` — it copies `message`
and `transcript_path` straight from the stdin payload; it does **not** read the transcript
itself (that stays in Coda — Security §5). Line-framed, bounded (Security §4); IDs are the
injected env values.

### Worked example — three channels (env ⊕ stdin → socket)

The `CODA_*` values are **not** in Claude Code's JSON payload. Claude knows nothing about
Coda; it writes its normal payload to the hook's **stdin**. Our identity rides the inherited
**process environment**. The forwarder fuses the two. This split is the whole point:
identity is set by Coda at spawn and can't be spoofed by, or drift from, the payload.

**(1) Environment** in the surface's PTY (same for every event in that pane — identifies
*which pane*, not *what happened*):
```
CODA_SOCKET_PATH=/Users/isaac/Library/Application Support/Coda/hooks.sock
CODA_WORKTREE_ID=coda#feat-hooks
CODA_SURFACE_ID=s7
PATH=…  TERM=xterm-256color  SHELL=/bin/zsh      # inherited; plus Claude Code's own env
```

**(2) stdin payload** Claude Code sends (no `CODA_*` in it):
```json
// PreToolUse (→ working)
{ "session_id":"3f2b…", "transcript_path":"/Users/…/3f2b….jsonl", "cwd":"/Users/…/feat-hooks",
  "hook_event_name":"PreToolUse", "permission_mode":"default",
  "tool_name":"Bash", "tool_input":{ "command":"swift test" } }
// Notification (→ needsYou)
{ "session_id":"3f2b…", "transcript_path":"/Users/…/3f2b….jsonl", "cwd":"/Users/…/feat-hooks",
  "hook_event_name":"Notification", "message":"Claude needs your permission to run swift test" }
// Stop (→ done)
{ "session_id":"3f2b…", "transcript_path":"/Users/…/3f2b….jsonl", "cwd":"/Users/…/feat-hooks",
  "hook_event_name":"Stop" }
```

**(3) Socket line** the forwarder emits (env IDs + selected stdin fields):
```
coda#feat-hooks s7 {"hook_event_name":"PreToolUse","transcript_path":"/Users/…/3f2b….jsonl"}
coda#feat-hooks s7 {"hook_event_name":"Notification","message":"Claude needs your permission to run swift test","transcript_path":"/Users/…/3f2b….jsonl"}
coda#feat-hooks s7 {"hook_event_name":"Stop","transcript_path":"/Users/…/3f2b….jsonl"}
```

Coda decodes each line, checks `s7` is a live surface in `coda#feat-hooks` (allowlist §3),
maps the event to a state (`agentStates["coda#feat-hooks|s7"]`), and for `Stop` opens that
`transcript_path` (bounded tail read) for the done-notification body. (`session_id` and
`transcript_path` being on every payload is also what makes the deferred `--resume` cheap.)

### Fate of the heuristic

The scrollback poll (`AppDelegate.swift:66` → `pollAgentStates()`, 1.2s) and
`agentState(fromOutput:)` are **retired for Claude-run classification** once events flow.
Keep `agentState`'s idle-vs-Claude-open detection only as a fallback for a surface that has
never emitted an event (e.g. a shell with no Claude). The 1.2s timer can drop to a slow
sweep or go away; decided at implementation once the socket path is proven live.

### 2b — Notifications (on top of 2a)

Once transitions are event-driven and trustworthy:
- Fire a macOS notification on `→ .needsYou` and on `→ .done`, gated by **two independent
  toggles** (notify-on-needs-you / notify-on-done) per decision #16.
- Body: needs-you → the `Notification` `message`; done → last assistant text from
  `transcript_path`. Both are plain text set as a data field (Security §1). Title = worktree name.
- Click the banner → focus that worktree (reuse existing focus path).

**No sidebar reorganization (decided 2026-07-03).** Authoritative badges recolor sidebar
rows in place; the sidebar keeps its repo→worktree grouping and order untouched. A dedicated
"Active" section / state-based sorting (Supacode-style) is **out of scope** — YAGNI until
we've lived with reliable badges. Note `DECISIONS.md:16`'s "move-needy-worktree-to-top" cue
was decided but never built; it stays unbuilt here rather than being resurrected.

---

## Security requirements (hard requirements, not guidance)

The socket choice already removes the whole network class the TCP alternative carried: no
port, so nothing remotely reachable, no browser CSRF/DNS-rebind, nothing to port-scan; the
receiver never executes the payload; data stays local. The following are the residual items
and are **mandatory** in the implementation:

1. **🔴 No shell/osascript string built from the payload.** `last_assistant_message` is
   untrusted (it reflects repo files and web content the agent read). Notifications MUST be
   fired via the native `UNUserNotificationCenter` API with the message as a plain data
   field. Never interpolate any payload field into an `osascript`/shell/AppleScript string.
   (Claude Code's own docs suggest `osascript -e '…'` notification hooks — that pattern is
   an RCE here and must not be used.)
2. **Socket location & perms.** Prefer `~/Library/Application Support/Coda/` (home is `0700`)
   over `/tmp`. Socket dir `0700`, socket file `0600`. On open, **verify ownership and
   perms** rather than trusting an existing path (guards against a pre-created directory
   with loose perms).
3. **Inbound allowlist.** Accept an event only when its `CODA_SURFACE_ID` matches a surface
   Coda actually spawned; drop unknown ids. A spoofer would need a live surface's UUID,
   which exists only in that PTY's environment.
4. **Parser hardening.** Bounded line and JSON length; `hook_event_name` treated as a closed
   enum (unknown → drop); tolerate partial writes and non-UTF-8; rate-limit so a socket
   flood cannot spin CPU; never crash on malformed input. The transcript read (for the done
   body) is bounded too: read only the file's tail (cap bytes) and treat its content as
   untrusted (rendered only as a plain-text notification data field, per §1).
5. **Forwarder is tamper-evident and non-blocking.** Hooks run synchronously inside Claude's
   turn: the forwarder writes with a short timeout and fails silently+fast — it must never
   wedge the agent. It runs on *every* `claude`, so the no-op path (env absent) must be
   provably harmless: exit 0, no network, no file writes. Point the hook at the **signed
   binary inside the notarized app bundle**, not a loose script in a writable directory, so
   it cannot be swapped to run arbitrary code on every agent launch.
6. **Consent & reversibility.** The `~/.claude/settings.json` edit happens transparently:
   show exactly what will be added, on explicit consent, idempotently, clearly labelled,
   with one-click removal.

---

## Architecture (2a + 2b)

Follows the existing pure-core + AppKit-glue split (logic + tests in `CodaCore`; platform
glue in `Coda`).

### `Sources/CodaCore/` (pure, tested)
- **`AgentHookEvent.swift`** — encode/decode one socket line → a typed value
  (`worktreeID`, `surfaceID`, `hookEventName` enum, optional `message`, optional
  `transcriptPath`). Enforces the bounds/enum rules of Security §4. No I/O.
- **`AgentHookEvent → AgentState`** — pure mapping per the event table (extends the existing
  `AgentState.swift`; the heuristic classifier stays only as the idle/Claude-open fallback).
- **`lastAssistantText(fromTranscript:)`** — pure parse of transcript JSONL text → the last
  `type:"assistant"` record's concatenated `text` blocks. The bounded *reading* of the file
  is Coda's job; the parsing is pure and tested here.
- **Env-injection helper** — build the `[String:String]` (inherited env + the three
  `CODA_*` keys) for a given worktree/surface. Pure, testable.

### `Sources/Coda/` (AppKit / platform glue)
- **`AgentHookSocketServer`** — creates/permission-checks the Unix socket (Security §2),
  accepts connections, feeds bytes to the `CodaCore` parser, applies the allowlist
  (Security §3), and dispatches state updates onto the main thread into `agentStates`.
- **`TerminalSurface.swift:122`** — pass the injected environment instead of `nil`.
- **Hook installer** — writes/removes the single self-noop hook in `~/.claude/settings.json`
  with consent (Security §5–6); the hook command targets the signed in-bundle forwarder.
- **`AppDelegate`** — own the socket server's lifecycle; retire/downgrade the 1.2s poll;
  notification firing + toggles (2b) via `UNUserNotificationCenter`.

### Tests (`Tests/CodaCoreTests/`)
- Parser: valid busy flag, valid event+JSON, oversized line (rejected), unknown
  `hook_event_name` (rejected), non-UTF-8 / partial line, missing fields.
- Event→state mapping: each event yields the expected `AgentState`.
- Env-injection helper: the three keys present with correct values; inherited env preserved.

---

## 2c — Read-only diff surface (scope only; own spec to follow)

**Intent:** a new `Surface.kind = .diff` (the seam is already reserved) showing the agent's
changes in-app, so review doesn't require leaving Coda for VS Code/git (decisions #8, R8).

**The open question to grill before its spec:** *what does it diff against?* R8 deferred
diff **stats** precisely because this "needs a base-branch / recompute design" — the diff
surface inherits that question: working tree vs. `HEAD`, vs. the worktree's branch-point
base, vs. `main`? Recompute cadence? This is deliberately **not** designed here; 2c gets its
own brainstorm → spec once 2a/2b land.

## Non-goals / risks
- No merge, PR, resume, or CLI work in this milestone (explicitly deferred above).
- No change to sidebar/notch/worktree-bar **rendering** — only the badge's data source.
- Main risk is Claude Code hook-payload field names/versions (`message`, `transcript_path`,
  event names, `Notification` subtypes) drifting; verified against the installed reference
  now (`DECISIONS.md:124`), re-check at implementation. The parser's closed-enum +
  drop-unknown behaviour and optional `message`/`transcript_path` fail safe if a field is
  missing (a done notification just falls back to a generic body).

### Known limitation — needs-you (🔴) latency (measured 2026-07-03)

The 🔴 needs-you badge is driven by the `Notification` event, and **Claude Code fires that
hook ~6s *after* the permission/input prompt actually appears** (it's really an
"idle/waiting" notification, not a prompt-time one). Consequences, confirmed by timestamped
instrumentation of the live pipeline:
- 🟡→🟢 (`Stop`) is immediate; 🟡→🔴 (`Notification`) lags ~6s.
- Coda's own pipeline is **instant** — socket receive → decode → allowlist → main-thread
  repaint all land in the same millisecond. The delay is entirely upstream in Claude Code.
- `PermissionRequest` (a plausible prompt-time signal) **does not fire** in this flow, so
  there is no faster event to switch to.

The only prompt-time signal is the on-screen prompt itself. We **deliberately do not**
reintroduce a scrollback heuristic to beat the delay (decided 2026-07-03) — it would walk
back the "authoritative, no heuristic" design for a latency issue we don't own. Accepted as
a known Claude-Code limitation; revisit if Claude adds a prompt-time hook event (or a
configurable Notification delay).
