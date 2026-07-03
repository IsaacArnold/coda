# Phase 2 Hook Foundation (2a + 2b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the scrollback-scraping agent-state heuristic with authoritative badges driven by Claude Code lifecycle hooks over a Unix domain socket, and add opt-in macOS notifications on those transitions.

**Architecture:** Coda injects `CODA_SOCKET_PATH`/`CODA_WORKTREE_ID`/`CODA_SURFACE_ID` into every terminal's environment at PTY spawn. A single self-noop hook registered once in `~/.claude/settings.json` runs a signed, in-bundle forwarder that pipes each hook event to the socket, tagged with those ids. Coda's socket server validates and maps events to the existing `agentStates` dictionary, so the sidebar/notch/tab-bar light up from real events instead of a poll. Notifications fire from the same transitions via `UNUserNotificationCenter`.

**Tech Stack:** Swift 6 toolchain (language mode v5), SwiftPM, AppKit, SwiftTerm, Darwin POSIX sockets, `UNUserNotificationCenter`. Pure logic in `CodaCore` (unit-tested with XCTest); AppKit/socket glue in `Coda`; a new `CodaHook` executable target for the forwarder.

## Global Constraints

- **Pure-core split:** all decidable logic lives in `Sources/CodaCore/` with XCTest coverage in `Tests/CodaCoreTests/`; AppKit/socket/process glue lives in `Sources/Coda/`. Copy the existing pattern (e.g. `TerminalDrop`, `LaunchCommand`, `AgentState`).
- **macOS 13+ / Swift tools 6.0, language mode v5** (`Package.swift`).
- **Security requirements are mandatory** (from the spec's §1–§6). In particular:
  - **§1 🔴 Never interpolate any hook payload field (esp. `last_assistant_message`) into an `osascript`/shell/AppleScript string.** Notifications use `UNUserNotificationCenter` with the message as a plain data field only.
  - **§2** Socket lives under `~/Library/Application Support/Coda/` (home is `0700`). Socket dir `0700`, socket file `0600`; verify ownership+perms on open.
  - **§3** Accept an event only if its `CODA_SURFACE_ID` matches a live surface Coda spawned; drop unknown ids.
  - **§4** Bounded line/JSON length; `hook_event_name` is a closed enum (unknown → drop); tolerate partial writes/non-UTF-8; never crash on malformed input.
  - **§5** Forwarder is the signed in-bundle binary, writes with a short timeout, fails silently+fast, and is a provable no-op when `CODA_SOCKET_PATH` is unset (exit 0, no network, no file writes).
  - **§6** The `~/.claude/settings.json` edit is transparent, consented, idempotent, clearly labelled, one-click removable.
- **No sidebar reorganization** (spec, decided 2026-07-03): badges recolor rows in place; no Active section, no state-sort.
- **Naming:** user-facing terms follow `CONTEXT.md` (Worktree, Surface, Claude run). Env vars are `CODA_`-prefixed.
- Spec: `docs/superpowers/specs/2026-07-03-phase-2-rescope-and-hook-foundation-design.md`.

---

### Task 1: Hook environment builder (`CodaCore`, pure)

Builds the environment dictionary injected at PTY spawn, and centralises the env-var names so the forwarder and the injector agree.

**Files:**
- Create: `Sources/CodaCore/HookEnvironment.swift`
- Test: `Tests/CodaCoreTests/HookEnvironmentTests.swift`

**Interfaces:**
- Produces:
  - `enum HookEnv { static let socketPath = "CODA_SOCKET_PATH"; static let worktreeID = "CODA_WORKTREE_ID"; static let surfaceID = "CODA_SURFACE_ID" }`
  - `func hookEnvironment(base: [String: String], socketPath: String, worktreeID: String, surfaceID: String) -> [String: String]`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import CodaCore

final class HookEnvironmentTests: XCTestCase {
    func testInjectsTheThreeKeys() {
        let env = hookEnvironment(base: ["PATH": "/usr/bin"],
                                  socketPath: "/tmp/x.sock",
                                  worktreeID: "wt1", surfaceID: "s1")
        XCTAssertEqual(env[HookEnv.socketPath], "/tmp/x.sock")
        XCTAssertEqual(env[HookEnv.worktreeID], "wt1")
        XCTAssertEqual(env[HookEnv.surfaceID], "s1")
    }

    func testPreservesInheritedEnv() {
        let env = hookEnvironment(base: ["PATH": "/usr/bin", "TERM": "xterm"],
                                  socketPath: "/s", worktreeID: "w", surfaceID: "s")
        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertEqual(env["TERM"], "xterm")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HookEnvironmentTests`
Expected: FAIL — `cannot find 'hookEnvironment' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Environment-variable names Coda injects into every terminal's PTY so a Claude Code
/// hook (a child of that shell) can identify itself and reach Coda's socket. Shared by the
/// injector (Coda) and the forwarder (CodaHook) so the two never drift.
public enum HookEnv {
    public static let socketPath = "CODA_SOCKET_PATH"
    public static let worktreeID = "CODA_WORKTREE_ID"
    public static let surfaceID  = "CODA_SURFACE_ID"
}

/// The full environment for a surface's PTY: the inherited environment plus the three
/// CODA_* keys. Pure; performs no I/O.
public func hookEnvironment(base: [String: String],
                            socketPath: String,
                            worktreeID: String,
                            surfaceID: String) -> [String: String] {
    var env = base
    env[HookEnv.socketPath] = socketPath
    env[HookEnv.worktreeID] = worktreeID
    env[HookEnv.surfaceID]  = surfaceID
    return env
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HookEnvironmentTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CodaCore/HookEnvironment.swift Tests/CodaCoreTests/HookEnvironmentTests.swift
git commit -m "feat(core): hook environment builder + CODA_* var names"
```

---

### Task 2: Hook event codec + state mapping (`CodaCore`, pure)

The wire protocol lives here so both the forwarder (encode) and the socket server (decode) share one tested implementation, and the event→`AgentState` mapping is decidable and covered.

**Files:**
- Create: `Sources/CodaCore/AgentHookEvent.swift`
- Test: `Tests/CodaCoreTests/AgentHookEventTests.swift`

**Interfaces:**
- Consumes: `AgentState` (existing, `AgentState.swift`).
- Produces:
  - `enum HookEventName: String { case sessionStart = "SessionStart", userPromptSubmit = "UserPromptSubmit", preToolUse = "PreToolUse", postToolUse = "PostToolUse", notification = "Notification", stop = "Stop", sessionEnd = "SessionEnd" }`
  - `struct AgentHookEvent: Equatable { let worktreeID: String; let surfaceID: String; let event: HookEventName; let message: String?; let transcriptPath: String? }`
  - `func encodeHookMessage(worktreeID: String, surfaceID: String, event: HookEventName, message: String?, transcriptPath: String?) -> String`
  - `func decodeHookMessage(_ line: String, maxLength: Int = 64_000) -> AgentHookEvent?`
  - `func agentState(for event: HookEventName) -> AgentState?`  (nil = no state change, e.g. SessionStart)
  - `func lastAssistantText(fromTranscript jsonl: String) -> String?`  (last `type:"assistant"` record's text blocks)

**Payload reality (verified):** hook stdin has `session_id`, `transcript_path`, `cwd`,
`hook_event_name`. There is **no** `last_assistant_message`. `Notification` carries a
`message` string (used as the needs-you body); the done body is read from `transcript_path`.
The forwarder copies `message` + `transcript_path` onto the wire; Coda does the transcript
read (Task 6). Hence the codec carries `message` + `transcriptPath`, not an assistant message.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import CodaCore

final class AgentHookEventTests: XCTestCase {
    func testRoundTrip() {
        let line = encodeHookMessage(worktreeID: "w", surfaceID: "s", event: .notification,
                                     message: "needs your input", transcriptPath: nil)
        XCTAssertEqual(decodeHookMessage(line),
            AgentHookEvent(worktreeID: "w", surfaceID: "s", event: .notification,
                           message: "needs your input", transcriptPath: nil))
    }

    func testCarriesTranscriptPath() {
        let line = encodeHookMessage(worktreeID: "w", surfaceID: "s", event: .stop,
                                     message: nil, transcriptPath: "/t/x.jsonl")
        XCTAssertEqual(decodeHookMessage(line)?.transcriptPath, "/t/x.jsonl")
        XCTAssertNil(decodeHookMessage(line)?.message)
    }

    func testDecodeBareEvent() {
        let line = encodeHookMessage(worktreeID: "w", surfaceID: "s", event: .preToolUse,
                                     message: nil, transcriptPath: nil)
        XCTAssertEqual(decodeHookMessage(line)?.event, .preToolUse)
    }

    func testRejectsUnknownEventName() {
        XCTAssertNil(decodeHookMessage(#"w s {"hook_event_name":"Bogus"}"#))
    }

    func testRejectsOversizedLine() {
        let huge = String(repeating: "a", count: 100_000)
        let line = #"w s {"hook_event_name":"Notification","message":"\#(huge)"}"#
        XCTAssertNil(decodeHookMessage(line, maxLength: 64_000))
    }

    func testRejectsMalformed() {
        XCTAssertNil(decodeHookMessage(""))
        XCTAssertNil(decodeHookMessage("only-two fields"))
        XCTAssertNil(decodeHookMessage("w s not-json"))
    }

    func testMessageWithSpacesAndNewlinesSurvives() {
        let msg = "line one\nline two with spaces"
        let line = encodeHookMessage(worktreeID: "w", surfaceID: "s", event: .notification,
                                     message: msg, transcriptPath: nil)
        XCTAssertEqual(decodeHookMessage(line)?.message, msg)
    }

    func testStateMapping() {
        XCTAssertEqual(agentState(for: .userPromptSubmit), .working)
        XCTAssertEqual(agentState(for: .preToolUse), .working)
        XCTAssertEqual(agentState(for: .postToolUse), .working)
        XCTAssertEqual(agentState(for: .notification), .needsYou)
        XCTAssertEqual(agentState(for: .stop), .done)
        XCTAssertEqual(agentState(for: .sessionEnd), .idle)
        XCTAssertNil(agentState(for: .sessionStart))   // presence handled separately
    }

    // MARK: - transcript parsing (for the done-notification body)

    func testLastAssistantTextFromTranscript() {
        // One assistant line per record; content is an array of typed blocks.
        let jsonl = """
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"first"}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"final answer"}]}}
        """
        XCTAssertEqual(lastAssistantText(fromTranscript: jsonl), "final answer")
    }

    func testLastAssistantTextSkipsToolUseBlocks() {
        // The last assistant record may contain a tool_use block plus text; take the text.
        let jsonl = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}},{"type":"text","text":"ran it"}]}}
        """
        XCTAssertEqual(lastAssistantText(fromTranscript: jsonl), "ran it")
    }

    func testLastAssistantTextNilWhenNoAssistant() {
        let jsonl = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}"#
        XCTAssertNil(lastAssistantText(fromTranscript: jsonl))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AgentHookEventTests`
Expected: FAIL — `cannot find 'encodeHookMessage' in scope`.

- [ ] **Step 3: Write minimal implementation**

The message is a single physical line: `worktreeID surfaceID <json>`. IDs never contain spaces (worktree ids are slugs/`repo#main`; surface ids are `s<int>`), and the JSON is the rest of the line — so any `message` (spaces/newlines JSON-escaped) is safe to carry. Newlines inside a message are escaped by JSON, so the physical line has no raw `\n`.

```swift
import Foundation

/// Claude Code lifecycle hook events Coda cares about. Closed enum: an unrecognised
/// hook_event_name is dropped (Security §4).
public enum HookEventName: String {
    case sessionStart     = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse       = "PreToolUse"
    case postToolUse      = "PostToolUse"
    case notification     = "Notification"
    case stop             = "Stop"
    case sessionEnd       = "SessionEnd"
}

/// `message` is present on Notification events (the needs-you body). `transcriptPath` is
/// forwarded so Coda can read the last assistant turn for the done body. There is no
/// assistant-message field on the wire — the payload doesn't have one (verified).
public struct AgentHookEvent: Equatable {
    public let worktreeID: String
    public let surfaceID: String
    public let event: HookEventName
    public let message: String?
    public let transcriptPath: String?
    public init(worktreeID: String, surfaceID: String, event: HookEventName,
                message: String?, transcriptPath: String?) {
        self.worktreeID = worktreeID; self.surfaceID = surfaceID; self.event = event
        self.message = message; self.transcriptPath = transcriptPath
    }
}

/// One physical line: "<worktreeID> <surfaceID> <json>". JSON escapes any spaces/newlines,
/// so the line is always single-physical-line and space-splittable into 3.
public func encodeHookMessage(worktreeID: String, surfaceID: String, event: HookEventName,
                              message: String?, transcriptPath: String?) -> String {
    var obj: [String: String] = ["hook_event_name": event.rawValue]
    if let message { obj["message"] = message }
    if let transcriptPath { obj["transcript_path"] = transcriptPath }
    let json = (try? JSONSerialization.data(withJSONObject: obj))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    return "\(worktreeID) \(surfaceID) \(json)"
}

public func decodeHookMessage(_ line: String, maxLength: Int = 64_000) -> AgentHookEvent? {
    guard line.utf8.count <= maxLength else { return nil }
    let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    let worktreeID = String(parts[0]), surfaceID = String(parts[1])
    guard !worktreeID.isEmpty, !surfaceID.isEmpty else { return nil }
    guard let data = String(parts[2]).data(using: .utf8),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let name = obj["hook_event_name"] as? String,
          let event = HookEventName(rawValue: name) else { return nil }
    return AgentHookEvent(worktreeID: worktreeID, surfaceID: surfaceID, event: event,
                          message: obj["message"] as? String,
                          transcriptPath: obj["transcript_path"] as? String)
}

/// Event → state. nil means "no state change from this event alone" (SessionStart just
/// marks a Claude run present; the socket server handles presence).
public func agentState(for event: HookEventName) -> AgentState? {
    switch event {
    case .userPromptSubmit, .preToolUse, .postToolUse: return .working
    case .notification: return .needsYou
    case .stop:         return .done
    case .sessionEnd:   return .idle
    case .sessionStart: return nil
    }
}

/// Last assistant record's text from transcript JSONL (its `content[]` `text` blocks
/// joined). Pure; Coda does the bounded file read and passes the tail here (Security §4).
public func lastAssistantText(fromTranscript jsonl: String) -> String? {
    for raw in jsonl.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
        guard let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let msg = obj["message"] as? [String: Any],
              let content = msg["content"] as? [[String: Any]] else { continue }
        let text = content.compactMap { block -> String? in
            (block["type"] as? String) == "text" ? block["text"] as? String : nil
        }.joined(separator: "\n")
        if !text.isEmpty { return text }
    }
    return nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AgentHookEventTests`
Expected: PASS (11 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CodaCore/AgentHookEvent.swift Tests/CodaCoreTests/AgentHookEventTests.swift
git commit -m "feat(core): hook event codec + event->state mapping"
```

---

### Task 3: Claude settings hook transform (`CodaCore`, pure)

Idempotent add/remove of Coda's self-noop hook inside a decoded `~/.claude/settings.json` object, without disturbing the user's other hooks (Security §6). Pure dictionary transform — the file I/O is Task 7.

**Files:**
- Create: `Sources/CodaCore/ClaudeHookSettings.swift`
- Test: `Tests/CodaCoreTests/ClaudeHookSettingsTests.swift`

**Interfaces:**
- Produces:
  - `let codaHookMarker = "coda-agent-hook"`  (identifying substring in the command)
  - `func codaHookCommand(forwarderPath: String) -> String`
  - `func addCodaHook(to settings: [String: Any], forwarderPath: String) -> [String: Any]`
  - `func removeCodaHook(from settings: [String: Any]) -> [String: Any]`
  - `func containsCodaHook(_ settings: [String: Any]) -> Bool`

Coda registers on the union of events the mapping needs: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop`, `SessionEnd`. Each event entry gets one `{matcher:"", hooks:[{type:"command", command:<coda cmd>}]}` block, appended (not replacing) any existing blocks for that event.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import CodaCore

final class ClaudeHookSettingsTests: XCTestCase {
    func testAddThenContains() {
        let out = addCodaHook(to: [:], forwarderPath: "/App/coda-hook")
        XCTAssertTrue(containsCodaHook(out))
        let hooks = out["hooks"] as? [String: Any]
        XCTAssertNotNil(hooks?["Stop"])
        XCTAssertNotNil(hooks?["Notification"])
    }

    func testAddIsIdempotent() {
        let once = addCodaHook(to: [:], forwarderPath: "/App/coda-hook")
        let twice = addCodaHook(to: once, forwarderPath: "/App/coda-hook")
        let stop = ((twice["hooks"] as? [String: Any])?["Stop"]) as? [[String: Any]]
        XCTAssertEqual(stop?.count, 1)   // not duplicated
    }

    func testPreservesForeignHooks() {
        let existing: [String: Any] = ["hooks": ["Stop": [["matcher": "",
            "hooks": [["type": "command", "command": "echo mine"]]]]]]
        let out = addCodaHook(to: existing, forwarderPath: "/App/coda-hook")
        let stop = ((out["hooks"] as? [String: Any])?["Stop"]) as? [[String: Any]]
        XCTAssertEqual(stop?.count, 2)   // user's block + coda's block
    }

    func testRemoveLeavesForeignHooks() {
        let withCoda = addCodaHook(to: ["hooks": ["Stop": [["matcher": "",
            "hooks": [["type": "command", "command": "echo mine"]]]]]],
            forwarderPath: "/App/coda-hook")
        let out = removeCodaHook(from: withCoda)
        XCTAssertFalse(containsCodaHook(out))
        let stop = ((out["hooks"] as? [String: Any])?["Stop"]) as? [[String: Any]]
        XCTAssertEqual(stop?.count, 1)
        let cmd = ((stop?.first?["hooks"] as? [[String: Any]])?.first?["command"]) as? String
        XCTAssertEqual(cmd, "echo mine")
    }

    func testCommandIsMarkedAndNotAShellString() {
        let cmd = codaHookCommand(forwarderPath: "/App/coda-hook")
        XCTAssertTrue(cmd.contains(codaHookMarker))
        XCTAssertTrue(cmd.contains("/App/coda-hook"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClaudeHookSettingsTests`
Expected: FAIL — `cannot find 'addCodaHook' in scope`.

- [ ] **Step 3: Write minimal implementation**

The command is the bare forwarder path plus a trailing comment marker so we can find/remove our own entry idempotently. Claude Code passes the event JSON on the hook's stdin, so no arguments or shell interpolation are needed — the forwarder path stands alone (Security §5). The marker is a `#`-comment the shell ignores.

```swift
import Foundation

public let codaHookMarker = "coda-agent-hook"

private let codaHookEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse",
                              "PostToolUse", "Notification", "Stop", "SessionEnd"]

/// The hook command string. Just the signed forwarder's absolute path plus an identifying
/// comment — no arguments, no interpolation of any payload (Security §1, §5).
public func codaHookCommand(forwarderPath: String) -> String {
    "\(forwarderPath) # \(codaHookMarker)"
}

private func isCodaBlock(_ block: [String: Any]) -> Bool {
    guard let hooks = block["hooks"] as? [[String: Any]] else { return false }
    return hooks.contains { ($0["command"] as? String)?.contains(codaHookMarker) == true }
}

public func containsCodaHook(_ settings: [String: Any]) -> Bool {
    guard let hooks = settings["hooks"] as? [String: Any] else { return false }
    return hooks.values.contains { ($0 as? [[String: Any]])?.contains(where: isCodaBlock) == true }
}

public func addCodaHook(to settings: [String: Any], forwarderPath: String) -> [String: Any] {
    var out = removeCodaHook(from: settings)   // idempotent: strip any prior coda block first
    var hooks = (out["hooks"] as? [String: Any]) ?? [:]
    let codaBlock: [String: Any] = ["matcher": "",
        "hooks": [["type": "command", "command": codaHookCommand(forwarderPath: forwarderPath)]]]
    for event in codaHookEvents {
        var blocks = (hooks[event] as? [[String: Any]]) ?? []
        blocks.append(codaBlock)
        hooks[event] = blocks
    }
    out["hooks"] = hooks
    return out
}

public func removeCodaHook(from settings: [String: Any]) -> [String: Any] {
    var out = settings
    guard var hooks = out["hooks"] as? [String: Any] else { return out }
    for (event, value) in hooks {
        guard let blocks = value as? [[String: Any]] else { continue }
        let kept = blocks.filter { !isCodaBlock($0) }
        if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
    }
    if hooks.isEmpty { out.removeValue(forKey: "hooks") } else { out["hooks"] = hooks }
    return out
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ClaudeHookSettingsTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CodaCore/ClaudeHookSettings.swift Tests/CodaCoreTests/ClaudeHookSettingsTests.swift
git commit -m "feat(core): idempotent add/remove of coda hook in claude settings"
```

---

### Task 4: The forwarder executable (`CodaHook` target)

A tiny signed binary the hook command points at. Reads the event JSON on stdin, and if `CODA_SOCKET_PATH`/IDs are present, connects to the Unix socket and writes one framed line (Task 2's `encodeHookMessage`) with a short timeout, then exits. If the env is absent it exits 0 immediately — a provable no-op (Security §5).

**Files:**
- Create: `Sources/CodaHook/main.swift`
- Modify: `Package.swift` (add the executable target)

**Interfaces:**
- Consumes: `CodaCore.HookEnv`, `CodaCore.encodeHookMessage`, `CodaCore.HookEventName`.
- Produces: an executable `coda-hook` bundled at `Coda.app/Contents/MacOS/coda-hook` (Task 8).

- [ ] **Step 1: Add the target to `Package.swift`**

Add to `targets:` (after the `Coda` executable target):

```swift
        .executableTarget(
            name: "CodaHook",
            dependencies: ["CodaCore"]
        ),
```

- [ ] **Step 2: Write the forwarder**

Reads all of stdin (the hook payload), extracts `hook_event_name` + optional `message` + optional `transcript_path`, and forwards them. No arguments; everything comes from stdin + env. Uses a connect timeout and never blocks longer than that. It never reads the transcript itself (Security §5).

```swift
import Foundation
import CodaCore
#if canImport(Darwin)
import Darwin
#endif

// Security §5: no-op fast if not launched inside a Coda terminal.
let env = ProcessInfo.processInfo.environment
guard let socketPath = env[HookEnv.socketPath],
      let worktreeID = env[HookEnv.worktreeID],
      let surfaceID  = env[HookEnv.surfaceID],
      !socketPath.isEmpty else { exit(0) }

// Read the event JSON Claude Code delivers on stdin (bounded).
let stdinData = FileHandle.standardInput.readDataToEndOfFile()
guard stdinData.count <= 256_000,
      let obj = (try? JSONSerialization.jsonObject(with: stdinData)) as? [String: Any],
      let name = obj["hook_event_name"] as? String,
      let event = HookEventName(rawValue: name) else { exit(0) }
// Copy only what Coda needs onto the wire; do NOT read the transcript here (Security §5).
let message = obj["message"] as? String                 // present on Notification events
let transcriptPath = obj["transcript_path"] as? String  // present on every event

let line = encodeHookMessage(worktreeID: worktreeID, surfaceID: surfaceID,
                             event: event, message: message, transcriptPath: transcriptPath) + "\n"

// Connect to the Unix stream socket with a short send timeout; fail silently+fast.
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }
defer { close(fd) }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
_ = socketPath.withCString { src in
    withUnsafeMutablePointer(to: &addr.sun_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: addr.sun_path)) {
            strncpy($0, src, MemoryLayout.size(ofValue: addr.sun_path) - 1)
        }
    }
}
var tv = timeval(tv_sec: 1, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

let len = socklen_t(MemoryLayout<sockaddr_un>.size)
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
}
guard connected == 0 else { exit(0) }
_ = line.withCString { send(fd, $0, strlen($0), 0) }
exit(0)
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build --product CodaHook`
Expected: `Compiling CodaHook main.swift` then `Build complete!`.

- [ ] **Step 4: Manual smoke test (no socket → clean no-op)**

Run: `echo '{"hook_event_name":"Stop"}' | .build/debug/coda-hook; echo "exit=$?"`
Expected: `exit=0` with no output and no error (env not set → immediate no-op).

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/CodaHook/main.swift
git commit -m "feat(hook): signed in-bundle forwarder (stdin -> unix socket)"
```

---

### Task 5: Socket server (`Coda` glue)

Creates and permission-checks the Unix socket, accepts connections, decodes each line via `CodaCore`, and hands validated events to a callback on the main thread. Validation against live surface ids (Security §3) is injected as a closure so the server stays testable-by-inspection and AppDelegate owns the source of truth.

**Files:**
- Create: `Sources/Coda/AgentHookSocketServer.swift`

**Interfaces:**
- Consumes: `CodaCore.decodeHookMessage`, `CodaCore.AgentHookEvent`.
- Produces:
  - `final class AgentHookSocketServer` with:
    - `init(socketURL: URL, isKnownSurface: @escaping (_ worktreeID: String, _ surfaceID: String) -> Bool, onEvent: @escaping (AgentHookEvent) -> Void)`
    - `func start() throws` / `func stop()`
    - `var socketPath: String { socketURL.path }`

- [ ] **Step 1: Implement the server**

Key points: bind under an app-support dir created `0700`; `chmod` the socket `0600`; on start, if a stale socket file exists, verify it is owned by us before unlinking; read line-framed with a bounded buffer; dispatch decoded+allowlisted events to `onEvent` on `DispatchQueue.main`. Accept/read loops run on a background queue.

```swift
import Foundation
import CodaCore
import Darwin

/// Receives Claude Code hook events over a Unix domain socket and forwards validated ones
/// on the main thread. See spec Security §2–§4.
final class AgentHookSocketServer {
    private let socketURL: URL
    private let isKnownSurface: (String, String) -> Bool
    private let onEvent: (AgentHookEvent) -> Void
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "coda.hook.socket")
    private var running = false

    var socketPath: String { socketURL.path }

    init(socketURL: URL,
         isKnownSurface: @escaping (String, String) -> Bool,
         onEvent: @escaping (AgentHookEvent) -> Void) {
        self.socketURL = socketURL
        self.isKnownSurface = isKnownSurface
        self.onEvent = onEvent
    }

    func start() throws {
        let dir = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // Remove a stale socket only if we own it (Security §2).
        if FileManager.default.fileExists(atPath: socketURL.path) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: socketURL.path)
            if (attrs?[.ownerAccountID] as? NSNumber)?.uintValue == UInt(getuid()) {
                try? FileManager.default.removeItem(at: socketURL)
            } else {
                throw NSError(domain: "coda.hook", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "socket path not owned by us"])
            }
        }
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw NSError(domain: "coda.hook", code: 2) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = socketURL.path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: addr.sun_path)) {
                    strncpy($0, src, MemoryLayout.size(ofValue: addr.sun_path) - 1)
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, len) }
        }
        guard bound == 0 else { close(listenFD); throw NSError(domain: "coda.hook", code: 3) }
        chmod(socketURL.path, 0o600)               // Security §2
        guard listen(listenFD, 16) == 0 else { close(listenFD); throw NSError(domain: "coda.hook", code: 4) }
        running = true
        queue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        running = false
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 { if running { continue } else { break } }
            queue.async { [weak self] in self?.readClient(clientFD) }
        }
    }

    private func readClient(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count <= 128_000 {              // Security §4: bounded
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            if chunk[0..<n].contains(0x0A) { break }  // got a newline; one message per connection
        }
        guard let text = String(data: buffer, encoding: .utf8) else { return }  // §4 non-UTF-8 → drop
        for raw in text.split(separator: "\n") {
            guard let event = decodeHookMessage(String(raw)),
                  isKnownSurface(event.worktreeID, event.surfaceID) else { continue }  // §3 allowlist
            DispatchQueue.main.async { [weak self] in self?.onEvent(event) }
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build --product Coda`
Expected: `Build complete!` (warnings OK; no errors).

- [ ] **Step 3: Commit**

```bash
git add Sources/Coda/AgentHookSocketServer.swift
git commit -m "feat(app): unix-socket hook server with perms check + allowlist"
```

---

### Task 6: Wire injection, server lifecycle, and retire the poll (`Coda` glue)

Thread the socket path + ids into PTY spawn, start the server, route events into the existing `agentStates` update path, and downgrade the heuristic poll to a fallback.

**Files:**
- Modify: `Sources/Coda/TerminalSurface.swift:25-31,114-129` (accept ids, inject env)
- Modify: `Sources/Coda/AppDelegate.swift` (server lifecycle, event handler, `makePane`, poll interval)

**Interfaces:**
- Consumes: `AgentHookSocketServer`, `CodaCore.hookEnvironment`, `CodaCore.agentState(for:)`, `CodaCore.HookEventName`.

- [ ] **Step 1: TerminalSurface accepts ids and injects env**

In `TerminalSurface`, add stored properties + init params:

```swift
    private let workingDirectory: String
    private let command: String
    private let setupScript: String
    private let hookWorktreeID: String
    private let hookSurfaceID: String
    private let hookSocketPath: String
```

```swift
    init(workingDirectory: String, command: String, setupScript: String = "",
         hookWorktreeID: String = "", hookSurfaceID: String = "", hookSocketPath: String = "") {
        self.workingDirectory = workingDirectory
        self.command = command
        self.setupScript = setupScript
        self.hookWorktreeID = hookWorktreeID
        self.hookSurfaceID = hookSurfaceID
        self.hookSocketPath = hookSocketPath
        super.init(nibName: nil, bundle: nil)
    }
```

Replace the `environment: nil` spawn at `viewDidLayout` (line ~122) with the injected env (only when we have a socket path + ids; otherwise keep inheriting `nil`). `LocalProcessTerminalView.startProcess(environment:)` takes `[String]?` of `KEY=VALUE` strings, so build that array from the `CodaCore` helper:

```swift
        var envArray: [String]? = nil
        if !hookSocketPath.isEmpty, !hookWorktreeID.isEmpty, !hookSurfaceID.isEmpty {
            let dict = hookEnvironment(base: ProcessInfo.processInfo.environment,
                                       socketPath: hookSocketPath,
                                       worktreeID: hookWorktreeID, surfaceID: hookSurfaceID)
            envArray = dict.map { "\($0.key)=\($0.value)" }
        }
        terminal.startProcess(executable: "/bin/zsh",
                              args: args,
                              environment: envArray,
                              execName: "-zsh",
                              currentDirectory: workingDirectory)
```

(Confirm the `environment:` parameter type against the installed SwiftTerm at implementation; if it is `[String:String]?`, pass `dict` directly.)

- [ ] **Step 2: Thread ids through `makePane` in AppDelegate**

At `AppDelegate.swift:540` (and the fallback at :510), `makePane` builds a `TerminalSurface`. Pass the owning worktree id, the surface id, and `hookServer.socketPath`:

```swift
        let pane = TerminalSurface(workingDirectory: wt.worktreePath, command: command, setupScript: setup,
                                   hookWorktreeID: wt.id, hookSurfaceID: surfaceID,
                                   hookSocketPath: hookServer?.socketPath ?? "")
```

(`surfaceID` is the `Surface.id` this pane belongs to — the same value used in `surfaceKey(wt.id, surface.id)`. Thread it into `makePane`'s signature from its caller, which already has the `Surface`.)

- [ ] **Step 3: Add server property + lifecycle in AppDelegate**

Add a property near `stateTimer`:

```swift
    private var hookServer: AgentHookSocketServer?
    private var claudePresent: Set<String> = []   // surfaceKeys with a live Claude run
```

In `applicationDidFinishLaunching`, before creating surfaces, start the server:

```swift
        let socketURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Coda/hooks.sock")
        let server = AgentHookSocketServer(
            socketURL: socketURL,
            isKnownSurface: { [weak self] wt, s in
                self?.surfaces.existingSurfaces(for: wt)?.entries.contains { $0.surface.id == s } ?? false
            },
            onEvent: { [weak self] event in self?.handleHookEvent(event) })
        try? server.start()
        hookServer = server
```

- [ ] **Step 4: Handle events into the existing update path**

Add the handler. It updates `agentStates` for the surface, tracks presence (SessionStart/End), recomputes worktree roll-ups, and reuses the same UI refreshes `pollAgentStates` calls:

```swift
    private func handleHookEvent(_ event: AgentHookEvent) {
        let key = surfaceKey(event.worktreeID, event.surfaceID)
        switch event.event {
        case .sessionStart: claudePresent.insert(key)
        case .sessionEnd:   claudePresent.remove(key)
        default: break
        }
        guard let newState = agentState(for: event.event) else {
            recomputeRollupsAndRefreshUI(); return    // e.g. SessionStart: presence only
        }
        agentStates[key] = newState
        // 2b: needs-you body = the Notification's own message; done body = last assistant
        // text from the transcript (bounded read). No payload carries the assistant message.
        let body: String?
        switch newState {
        case .needsYou: body = event.message
        case .done:     body = event.transcriptPath.flatMap(Self.lastAssistantMessage(fromTranscriptAt:))
        default:        body = nil
        }
        maybeNotify(worktreeID: event.worktreeID, state: newState, body: body)
        recomputeRollupsAndRefreshUI()
    }

    /// Bounded read of a transcript JSONL's tail → last assistant text (Security §4). Reads
    /// only the last ~64 KB, drops a partial leading line, and delegates parsing to CodaCore.
    private static func lastAssistantMessage(fromTranscriptAt path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tailBytes: UInt64 = 64_000
        let start = size > tailBytes ? size - tailBytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let body = start > 0 ? String(text.drop { $0 != "\n" }.dropFirst()) : text
        return lastAssistantText(fromTranscript: body)
    }
```

Extract the tail of `pollAgentStates` (the roll-up build + `sidebar.updateAgentStates` + `updateNotch` + `refreshChromeForActiveSurface` + `refreshTabBar`) into `recomputeRollupsAndRefreshUI()` and call it from both places (DRY).

- [ ] **Step 5: Downgrade the heuristic poll to a fallback**

Change the `stateTimer` interval from `1.2` to a slow sweep (e.g. `5.0`) and, inside `pollAgentStates`, only classify surfaces whose `surfaceKey` is **not** in `claudePresent` (event-driven surfaces own their state; the poll only covers shells that never emitted an event). Keep `agentState(fromOutput:)` for that fallback.

```swift
        stateTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.pollAgentStates()
        }
```

Inside `pollAgentStates`, guard the per-surface classification:

```swift
                let key = surfaceKey(wtID, entry.surface.id)
                let surfaceState = claudePresent.contains(key)
                    ? (agentStates[key] ?? .idle)           // event-owned; don't overwrite
                    : rollup(entry.handle.allPanes.map { $0.currentAgentState() })
```

- [ ] **Step 6: Stop the server on terminate**

In `applicationWillTerminate` (add if absent): `hookServer?.stop()`.

- [ ] **Step 7: Build and run**

Run: `swift build --product Coda`
Expected: `Build complete!`.

- [ ] **Step 8: Manual verify — env injection reaches the shell**

Before wiring the forwarder, confirm the vars actually land in the PTY. Launch Coda
(`swift run Coda`), open a worktree, and in its terminal run:

Run: `env | grep CODA`
Expected: three lines —
```
CODA_SOCKET_PATH=/Users/<you>/Library/Application Support/Coda/hooks.sock
CODA_WORKTREE_ID=<the worktree id>
CODA_SURFACE_ID=<this surface's id, e.g. s7>
```
If they're missing, the injection in Step 1/2 didn't take (check the `environment:`
parameter type against SwiftTerm) — fix before proceeding. This is the cheap insurance that
correlation will work; the socket line's first two fields come straight from these.

- [ ] **Step 9: Manual end-to-end (with a running socket, before the installer exists)**

Temporarily add the hook by hand to `~/.claude/settings.json` pointing at `.build/debug/coda-hook`, launch Coda (`swift run Coda`), open a worktree, run `claude`, submit a prompt. Expected: the sidebar badge turns 🟡 working on submit, 🔴/🟢 on stop — without the old 1.2s lag or stale-line stickiness.

- [ ] **Step 10: Commit**

```bash
git add Sources/Coda/TerminalSurface.swift Sources/Coda/AppDelegate.swift
git commit -m "feat(app): drive badges from hook events; poll becomes fallback"
```

---

### Task 7: Hook installer + consent (`Coda` glue)

Read/modify/write `~/.claude/settings.json` via Task 3's transform, gated by an explicit consent prompt on first launch, with a menu action to remove (Security §6).

**Files:**
- Create: `Sources/Coda/HookInstaller.swift`
- Modify: `Sources/Coda/AppDelegate.swift` (call on launch; menu item)

**Interfaces:**
- Consumes: `CodaCore.addCodaHook`, `CodaCore.removeCodaHook`, `CodaCore.containsCodaHook`.

- [ ] **Step 1: Implement the installer**

```swift
import Foundation
import CodaCore

enum HookInstaller {
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// The forwarder shipped inside the app bundle (Contents/MacOS/coda-hook).
    static var forwarderPath: String {
        (Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("coda-hook").path) ?? "coda-hook"
    }

    static func isInstalled() -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return containsCodaHook(obj)
    }

    static func install() throws {
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { obj = existing }
        let updated = addCodaHook(to: obj, forwarderPath: forwarderPath)
        try write(updated)
    }

    static func uninstall() throws {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        try write(removeCodaHook(from: obj))
    }

    private static func write(_ obj: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
    }
}
```

- [ ] **Step 2: Consent prompt on launch**

In `applicationDidFinishLaunching`, after the server starts and only if `!HookInstaller.isInstalled()` and the user hasn't previously declined (persist a `Preferences` bool), show an `NSAlert` that states exactly what will change:

```swift
        if !HookInstaller.isInstalled() && !preferences.declinedHookInstall {
            let alert = NSAlert()
            alert.messageText = "Enable live agent status?"
            alert.informativeText = """
            Coda can show accurate 🟡/🔴/🟢 badges and notifications by adding one hook to \
            ~/.claude/settings.json. It only reports to Coda while a terminal is open here, and \
            is ignored by any claude you run elsewhere. You can remove it anytime from the menu.
            """
            alert.addButton(withTitle: "Enable")
            alert.addButton(withTitle: "Not now")
            if alert.runModal() == .alertFirstButtonReturn {
                try? HookInstaller.install()
            } else {
                preferences.declinedHookInstall = true
                try? prefsStore.save(preferences)
            }
        }
```

(Add `declinedHookInstall` to `Preferences` in `CodaCore` with a default of `false`; follow the existing `Preferences` Codable pattern.)

- [ ] **Step 3: Menu items to enable/remove**

Add to the app menu (in `buildMenu`) two items under a suitable submenu: "Enable Agent Status Hook" → `HookInstaller.install()`, "Remove Agent Status Hook" → `HookInstaller.uninstall()`, each followed by an `NSAlert` confirmation of the result.

- [ ] **Step 4: Build**

Run: `swift build --product Coda`
Expected: `Build complete!`.

- [ ] **Step 5: Manual verify install/remove round-trip**

Back up `~/.claude/settings.json`. Launch, click Enable, inspect the file (coda block present under each event, foreign hooks intact). Remove via menu, inspect again (coda blocks gone, foreign hooks intact). Restore backup.

- [ ] **Step 6: Commit**

```bash
git add Sources/Coda/HookInstaller.swift Sources/Coda/AppDelegate.swift Sources/CodaCore/Preferences.swift
git commit -m "feat(app): consented install/remove of the claude agent-status hook"
```

---

### Task 8: Bundle + sign the forwarder (packaging)

The forwarder must ship inside the notarized app bundle so the hook path is signed and tamper-evident (Security §5).

**Files:**
- Modify: `scripts/make-app.sh`

- [ ] **Step 1: Build and copy the forwarder into the bundle**

In `make-app.sh`, after the main `Coda` binary is built and copied into `Contents/MacOS/`, also build `CodaHook` and copy `coda-hook` beside it:

```sh
swift build -c release --product CodaHook
cp "$(swift build -c release --product CodaHook --show-bin-path)/CodaHook" \
   "$APP/Contents/MacOS/coda-hook"
```

(Match the variable names already used in the script for the release bin path and `$APP`.)

- [ ] **Step 2: Ensure signing covers it**

Confirm the `codesign` step signs `Contents/MacOS/coda-hook` (either via a recursive `--deep`-equivalent already in the script, or add an explicit sign of the helper before the outer bundle sign). The notarization step needs no change once the helper is inside the signed bundle.

- [ ] **Step 3: Build a local unsigned app and verify layout**

Run: `scripts/make-app.sh`
Expected: `dist/Coda.app/Contents/MacOS/coda-hook` exists and runs (`.../coda-hook </dev/null; echo $?` → `0`).

- [ ] **Step 4: Commit**

```bash
git add scripts/make-app.sh
git commit -m "chore(packaging): bundle + sign the coda-hook forwarder"
```

---

### Task 9: Notifications (2b) — `UNUserNotificationCenter`

Fire a macOS notification on `→ needsYou` / `→ done`, gated by two independent toggles; body is the caller-supplied `body` (Notification message for needs-you, transcript-derived text for done) set as plain data (Security §1); click → focus the worktree.

**Files:**
- Modify: `Sources/Coda/AppDelegate.swift` (the `maybeNotify` referenced in Task 6)
- Create: `Sources/Coda/AgentNotifier.swift`
- Modify: `Sources/CodaCore/Preferences.swift` (two toggles)

**Interfaces:**
- Consumes: `CodaCore.AgentState`, `UserNotifications`.

- [ ] **Step 1: Add toggles to Preferences**

Add `notifyOnNeedsYou: Bool = true` and `notifyOnDone: Bool = true` to `Preferences` (follow the existing Codable/default pattern; add a decode test in `PreferencesTests` asserting the defaults).

- [ ] **Step 2: Implement the notifier**

Message goes in `content.body` — a data field, never a shell/osascript string (Security §1).

```swift
import AppKit
import UserNotifications
import CodaCore

enum AgentNotifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// title = worktree name, body = the agent's last message (plain text data field).
    static func notify(worktreeID: String, title: String, state: AgentState, body: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body ?? (state == .needsYou ? "Needs your input" : "Finished")
        content.sound = .default
        content.userInfo = ["worktreeID": worktreeID]   // for click-to-focus
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
```

- [ ] **Step 3: Wire `maybeNotify` in AppDelegate**

```swift
    private func maybeNotify(worktreeID: String, state: AgentState, body: String?) {
        let allowed = (state == .needsYou && preferences.notifyOnNeedsYou)
                   || (state == .done && preferences.notifyOnDone)
        guard allowed else { return }
        let title = displayName(forWorktreeID: worktreeID) ?? "Coda"
        AgentNotifier.notify(worktreeID: worktreeID, title: title, state: state, body: body)
    }
```

(`displayName(forWorktreeID:)`: reuse the existing worktree-name lookup used for sidebar rows.)

- [ ] **Step 4: Authorize on launch + click-to-focus**

Call `AgentNotifier.requestAuthorization()` in `applicationDidFinishLaunching`. Set `UNUserNotificationCenter.current().delegate = self`, implement `userNotificationCenter(_:didReceive:withCompletionHandler:)` to read `worktreeID` from `userInfo` and reuse the existing "focus this worktree" path (the same one the sidebar selection uses).

- [ ] **Step 5: Add the toggles to the Settings window**

Add two checkboxes ("Notify when an agent needs you", "Notify when an agent finishes") to the existing Settings UI, bound to the two `Preferences` fields, saved via `prefsStore`.

- [ ] **Step 6: Build**

Run: `swift build --product Coda`
Expected: `Build complete!`.

- [ ] **Step 7: Manual verify**

With notifications authorized and both toggles on: run `claude` in a Coda worktree, ask it something requiring permission → a "needs you" banner appears; let a turn finish → a "finished" banner with the last message. Click a banner → that worktree focuses. Toggle each off → the corresponding banner stops.

- [ ] **Step 8: Commit**

```bash
git add Sources/Coda/AgentNotifier.swift Sources/Coda/AppDelegate.swift Sources/CodaCore/Preferences.swift Tests/CodaCoreTests/PreferencesTests.swift
git commit -m "feat(app): opt-in macOS notifications on agent needs-you/done"
```

---

## Self-review

**Spec coverage:**
- 2a env injection → Tasks 1, 6. ✅
- Global self-noop forwarder → Tasks 4 (no-op path), 7 (install). ✅
- Unix socket transport + perms/ownership → Task 5 (§2). ✅
- Event→state mapping table → Task 2. ✅
- Wire protocol (single line `wt surface <json>`, carrying `message` + `transcript_path`) → Task 2 codec. ✅
- Notification-message vs transcript-read body split → Task 2 (`lastAssistantText`), Task 4 (forward fields), Task 6 (bounded read + handler), Task 9 (use `body`). ✅
- Retire/downgrade heuristic → Task 6 Step 5. ✅
- Notifications + two toggles + click-to-focus (2b) → Task 9. ✅
- Security §1 (no osascript interpolation) → Task 9 Step 2, Task 3 command form. §2 → Task 5. §3 allowlist → Tasks 5, 6 Step 3. §4 parser bounds + bounded transcript tail read → Tasks 2, 6. §5 forwarder (copies fields, never reads transcript) → Tasks 4, 8. §6 consent/reversible → Task 7. ✅
- No sidebar reorg → honoured (no task adds sorting/sections). ✅

**Placeholder scan:** the one soft edge is the SwiftTerm `startProcess(environment:)` parameter *type* (Task 6 Step 1) — flagged as a build-time confirmation with both branches spelled out, not a TBD. `make-app.sh` variable names (Task 8) are "match existing" because the script's exact vars aren't quoted here — the implementer has the file open. No true placeholders.

**Type consistency:** `encodeHookMessage`/`decodeHookMessage` signatures match between Tasks 2, 4, 5. `HookEnv` keys match between Tasks 1, 4, 6. `addCodaHook`/`removeCodaHook`/`containsCodaHook` match between Tasks 3 and 7. `surfaceKey`, `agentStates`, `surfaces` reference the real AppDelegate members. `hookServer.socketPath` matches Task 5's `var socketPath`.

**Note for the implementer:** Tasks 1–4 are pure/TDD and land green independently. Tasks 5–9 are AppKit/socket/packaging glue verified by build + the manual smoke tests written into each; they depend on 1–4 and should land in order.
