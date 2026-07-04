# Terminal Fixes: Soft Newline, URL Click, Shell Support, Invisible Text Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix four terminal issues in Coda — (#2) Cmd/Shift/Option+Enter should insert a soft newline in Claude Code, (#1) Cmd+click on a URL should open the browser (not VS Code), (#4) support the user's login shell incl. bash, and (#3) fix intermittent invisible typed text in Claude's TUI.

**Architecture:** Coda is a macOS AppKit app embedding SwiftTerm terminals. Pure, testable logic lives in the `CodaCore` SwiftPM target (unit-tested with XCTest); AppKit view/wiring lives in the `Coda` target (verified by build + manual run). Each fix pushes as much logic as possible into `CodaCore` pure functions, keeping the AppKit layer a thin adapter.

**Tech Stack:** Swift, AppKit, SwiftTerm 1.13.0, SwiftPM, XCTest.

## Global Constraints

- **SwiftTerm** is pinned `from: "1.2.0"`, currently resolved to **1.13.0**. Do not bump it as part of this work.
- **`Preferences` is portable-only — never persist machine-local absolute paths.** Editors are stored by bundle id, fonts by PostScript name. The shell preference MUST be a portable enum, not a path. (Absolute paths are allowed only in `Config`.)
- **Soft-newline byte is exactly `0x0a` (LF)** — Claude Code's canonical `chat:newline`. Not ESC+CR, not `\n\r`.
- **URL scope for cmd+click:** `http://`, `https://`, plus bare `localhost` / `127.0.0.1` (optionally `:port` and/or `/path`). Schemeless localhost/127.0.0.1 get an `http://` prefix. Opens the **system default browser** via `NSWorkspace.shared.open`. **URL classification always wins over the file→editor route.**
- **Shell:** default **Automatic** = the user's login shell (`$SHELL`, fallback to password DB). Portable enum `Automatic / zsh / bash`, global, in General Settings. bash + zsh are first-class; any other login shell (fish, etc.) is launched best-effort. Changing the setting affects **new** terminals only (running shells are not restarted).
- **Every git commit message must end with the trailer:**
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  ```
- Build with `swift build`. Run unit tests with `swift test --filter <TestClassName>`. The AppKit `Coda` target has no unit tests — verify it with `swift build` and a manual run.

---

## File Structure

**Task 1 — Soft newline (#2)**
- Modify: `Sources/CodaCore/TerminalKeyBindings.swift` — add `.insertNewline` action + Enter handling with ⌘/⇧/⌥.
- Modify: `Tests/CodaCoreTests/TerminalKeyBindingsTests.swift` — cover the new cases.
- Modify: `Sources/Coda/ClickableTerminalView.swift` — handle `.insertNewline` in `performKeyEquivalent`; add a `keyDown` override for Shift/Option+Enter.

**Task 2 — URL cmd+click (#1)**
- Create: `Sources/CodaCore/TerminalClick.swift` — pure `firstWebURL(in:)` detector.
- Create: `Tests/CodaCoreTests/TerminalClickTests.swift` — detector tests.
- Modify: `Sources/Coda/ClickableTerminalView.swift` — reorder `handleCommandClick` so URL wins; delete the private `firstURL`.

**Task 3 — Shell resolution core (#4a)**
- Create: `Sources/CodaCore/Shell.swift` — `ShellChoice` enum, `ResolvedShell` struct, `resolveShell(choice:loginShell:)`.
- Create: `Tests/CodaCoreTests/ShellTests.swift` — resolution tests.
- Modify: `Sources/CodaCore/Preferences.swift` — add portable `shell: ShellChoice` field + decoder default.
- Modify: `Sources/CodaCore/LaunchCommand.swift` — parametrize launch line by shell name.
- Modify: `Tests/CodaCoreTests/PreferencesTests.swift` — shell field round-trip + old-prefs default.
- Modify: `Tests/CodaCoreTests/LaunchCommandTests.swift` — bash launch-line cases.

**Task 4 — Shell wiring + settings UI (#4b)**
- Modify: `Sources/Coda/TerminalSurface.swift` — take a `ResolvedShell`, spawn it.
- Modify: `Sources/Coda/AppDelegate.swift` — resolve shell from prefs, pass to panes, add setter + settings wiring.
- Modify: `Sources/Coda/GeneralSettingsViewController.swift` — add the Shell dropdown.
- Modify: `Sources/Coda/SettingsTabController.swift` — thread the shell params through.

**Task 5 — Invisible typed text (#3)**
- Diagnose first (reproduce + snapshot), then apply the matching fix in `Sources/Coda/ClickableTerminalView.swift` (or `TerminalSurface.swift`).

---

### Task 1: Soft newline on ⌘/⇧/⌥ + Enter (#2)

**Files:**
- Modify: `Sources/CodaCore/TerminalKeyBindings.swift`
- Test: `Tests/CodaCoreTests/TerminalKeyBindingsTests.swift`
- Modify: `Sources/Coda/ClickableTerminalView.swift:136-164` (`performKeyEquivalent`) and add a `keyDown` override

**Interfaces:**
- Produces: `TerminalKeyAction.insertNewline` case; `terminalKeyAction(charactersIgnoringModifiers:command:shift:option:)` — the `option` parameter is new and defaults to `false`.

- [ ] **Step 1: Write the failing tests**

Add these methods to `Tests/CodaCoreTests/TerminalKeyBindingsTests.swift` (inside the existing `TerminalKeyBindingsTests` class). Note the local `action` helper already defaults `command: true, shift: false`; add explicit args per case:

```swift
    func testCommandEnterInsertsNewline() {
        XCTAssertEqual(action("\r", command: true, shift: false), .insertNewline)
    }

    func testShiftEnterInsertsNewline() {
        XCTAssertEqual(terminalKeyAction(charactersIgnoringModifiers: "\r",
                                         command: false, shift: true, option: false), .insertNewline)
    }

    func testOptionEnterInsertsNewline() {
        XCTAssertEqual(terminalKeyAction(charactersIgnoringModifiers: "\r",
                                         command: false, shift: false, option: true), .insertNewline)
    }

    func testPlainEnterPassesThrough() {
        // A bare Return is normal terminal input (submit), not a soft newline.
        XCTAssertEqual(terminalKeyAction(charactersIgnoringModifiers: "\r",
                                         command: false, shift: false, option: false), .passThrough)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TerminalKeyBindingsTests`
Expected: compile error / FAIL — `insertNewline` is not a member of `TerminalKeyAction`, and `terminalKeyAction` has no `option:` parameter.

- [ ] **Step 3: Implement the action + Enter handling**

Replace the entire contents of `Sources/CodaCore/TerminalKeyBindings.swift` with:

```swift
/// What a ⌘-modified keystroke means to a focused terminal.
public enum TerminalKeyAction: Equatable {
    /// ⌘K — clear the terminal screen.
    case clear
    /// ⌘⌫ — kill the current input line back to the prompt (readline Ctrl-U).
    case deleteToLineStart
    /// ⌘↵ / ⇧↵ / ⌥↵ — insert a soft newline (LF, 0x0a) instead of submitting. This is
    /// Claude Code's `chat:newline`; in a plain shell readline treats LF like Enter.
    case insertNewline
    /// Not a terminal key — let the menu bar / app handle it (⌘Q, ⌘N, ⌘R, ⌘C, …).
    case passThrough
}

/// Maps a modified keystroke to the action a real terminal owns, so a focused terminal
/// can claim those keys *before* the menu bar's key-equivalents see them — and explicitly
/// pass everything else through. `chars` is the event's `charactersIgnoringModifiers`
/// (Return is "\r" / U+000D regardless of Shift/Option).
public func terminalKeyAction(charactersIgnoringModifiers chars: String,
                              command: Bool, shift: Bool, option: Bool = false) -> TerminalKeyAction {
    // Return + any of ⌘/⇧/⌥ → soft newline (LF), never submit. Checked before the
    // bare-⌘ rules below so ⇧↵ and ⌥↵ (which have no Command) are still handled.
    if chars == "\r", command || shift || option {
        return .insertNewline
    }
    // Only bare ⌘ combos are ours; anything with Shift stays with the app (e.g. ⌘⇧⌫).
    guard command, !shift else { return .passThrough }
    switch chars {
    case "k": return .clear
    case "\u{7f}", "\u{8}": return .deleteToLineStart   // Delete / Backspace
    default: return .passThrough
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TerminalKeyBindingsTests`
Expected: PASS — all tests, including the pre-existing `testCommandKClears`, `testShiftCombosPassThrough`, `testAppLevelCommandKeysPassThrough` (unaffected — none use `"\r"`).

- [ ] **Step 5: Wire ⌘↵ in `performKeyEquivalent`**

In `Sources/Coda/ClickableTerminalView.swift`, the `performKeyEquivalent(with:)` method (around line 136). Update the `terminalKeyAction` call to pass `option`, and add an `.insertNewline` case. Replace this block:

```swift
        let mods = event.modifierFlags
        switch terminalKeyAction(charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                                 command: mods.contains(.command), shift: mods.contains(.shift)) {
        case .clear:
```

with:

```swift
        let mods = event.modifierFlags
        switch terminalKeyAction(charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                                 command: mods.contains(.command), shift: mods.contains(.shift),
                                 option: mods.contains(.option)) {
        case .insertNewline:
            // ⌘↵ — send LF (Claude Code's soft newline). Command keystrokes arrive via
            // performKeyEquivalent, not keyDown, so ⌘↵ is handled here.
            send(data: [UInt8(0x0a)][0...])
            return true
        case .clear:
```

- [ ] **Step 6: Add a `keyDown` override for ⇧↵ and ⌥↵**

⇧↵ and ⌥↵ are not Command key-equivalents, so they reach the view through `keyDown`, not `performKeyEquivalent`. Add this method to `ClickableTerminalView` (place it right after the `performKeyEquivalent(with:)` method, before the `isFocusedSurface` computed property near line 168):

```swift
    /// ⇧↵ and ⌥↵ never reach `performKeyEquivalent` (they carry no Command modifier), so
    /// intercept them here and emit LF — Claude Code's soft newline. Everything else is
    /// normal terminal input and goes to SwiftTerm untouched. ⌘↵ is handled in
    /// `performKeyEquivalent` (Command keystrokes don't arrive via keyDown).
    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags
        if terminalKeyAction(charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                             command: mods.contains(.command), shift: mods.contains(.shift),
                             option: mods.contains(.option)) == .insertNewline {
            send(data: [UInt8(0x0a)][0...])
            return
        }
        super.keyDown(with: event)
    }
```

- [ ] **Step 7: Build the app**

Run: `swift build`
Expected: builds cleanly, no errors.

- [ ] **Step 8: Manual verification**

Run the app (`swift run Coda` or the built binary). In a Claude Code session, place the cursor in the prompt, type a word, press **Cmd+Enter** — the caret drops to a new line without submitting. Repeat with **Shift+Enter** and **Option+Enter**. In a plain shell, Cmd+Enter behaves like Enter (accepted per spec). Confirm a *plain* Enter still submits normally.

- [ ] **Step 9: Commit**

```bash
git add Sources/CodaCore/TerminalKeyBindings.swift Tests/CodaCoreTests/TerminalKeyBindingsTests.swift Sources/Coda/ClickableTerminalView.swift
git commit -m "feat(terminal): insert soft newline on Cmd/Shift/Option+Enter

Cmd/Shift/Option+Enter now send LF (0x0a), Claude Code's chat:newline, so
users can write multi-line prompts. Fixed built-in; not user-rebindable.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: URL cmd+click opens the browser, not the editor (#1)

**Files:**
- Create: `Sources/CodaCore/TerminalClick.swift`
- Test: `Tests/CodaCoreTests/TerminalClickTests.swift`
- Modify: `Sources/Coda/ClickableTerminalView.swift` — `handleCommandClick` row loop (around lines 199-212) and remove the private `firstURL` (lines 253-261)

**Interfaces:**
- Produces: `firstWebURL(in line: String) -> URL?` (public, in `CodaCore`). Recognizes `http://`, `https://`, and bare `localhost`/`127.0.0.1` (with optional `:port`/`/path`), returning a fully-schemed `URL`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CodaCoreTests/TerminalClickTests.swift`:

```swift
import XCTest
@testable import CodaCore

final class TerminalClickTests: XCTestCase {
    func testFindsHTTPSURL() {
        XCTAssertEqual(firstWebURL(in: "see https://example.com now")?.absoluteString,
                       "https://example.com")
    }

    func testFindsHTTPURL() {
        XCTAssertEqual(firstWebURL(in: "http://example.com/a/b")?.absoluteString,
                       "http://example.com/a/b")
    }

    func testTrimsSurroundingPunctuation() {
        XCTAssertEqual(firstWebURL(in: "(https://example.com)")?.absoluteString,
                       "https://example.com")
    }

    func testSchemelessLocalhostGetsHTTP() {
        XCTAssertEqual(firstWebURL(in: "open localhost:3000")?.absoluteString,
                       "http://localhost:3000")
    }

    func testSchemelessLoopbackIPGetsHTTP() {
        XCTAssertEqual(firstWebURL(in: "127.0.0.1:8080/path")?.absoluteString,
                       "http://127.0.0.1:8080/path")
    }

    func testBareLocalhostGetsHTTP() {
        XCTAssertEqual(firstWebURL(in: "curl localhost")?.absoluteString,
                       "http://localhost")
    }

    func testDoesNotMatchLocalhostSubstring() {
        // "localhostfoo" is not the localhost authority — must not be treated as a URL.
        XCTAssertNil(firstWebURL(in: "localhostfoo bar"))
    }

    func testReturnsNilForPlainText() {
        XCTAssertNil(firstWebURL(in: "just some words and a path Sources/main.swift"))
    }

    func testReturnsFirstURLWhenMultiple() {
        XCTAssertEqual(firstWebURL(in: "https://a.com https://b.com")?.absoluteString,
                       "https://a.com")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TerminalClickTests`
Expected: compile error / FAIL — `firstWebURL` is undefined.

- [ ] **Step 3: Implement the detector**

Create `Sources/CodaCore/TerminalClick.swift`:

```swift
import Foundation

/// First web URL on a terminal line, or nil. Recognizes `http://`/`https://` tokens and
/// bare `localhost`/`127.0.0.1` authorities (optionally `:port` and/or `/path`), returning
/// a fully-schemed URL (schemeless localhost forms are prefixed with `http://`). Tokens are
/// split on whitespace and stripped of surrounding quotes/brackets, mirroring how paths are
/// tokenized elsewhere in the click handler.
public func firstWebURL(in line: String) -> URL? {
    for raw in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
        let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'(),[]{}<>"))
        if token.hasPrefix("http://") || token.hasPrefix("https://") {
            if let url = URL(string: token) { return url }
        } else if isLoopbackAuthority(token) {
            if let url = URL(string: "http://" + token) { return url }
        }
    }
    return nil
}

/// True when `token` is `localhost`/`127.0.0.1`, optionally followed by `:` (port) or `/`
/// (path) — but NOT a longer host that merely starts with those letters (e.g. `localhostx`).
private func isLoopbackAuthority(_ token: String) -> Bool {
    for host in ["localhost", "127.0.0.1"] where token.hasPrefix(host) {
        let rest = token.dropFirst(host.count)
        if rest.isEmpty { return true }
        if let first = rest.first, first == ":" || first == "/" { return true }
    }
    return false
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TerminalClickTests`
Expected: PASS — all nine tests.

- [ ] **Step 5: Reorder `handleCommandClick` so URL wins, using the shared detector**

In `Sources/Coda/ClickableTerminalView.swift`, inside `handleCommandClick`, replace this block (around lines 204-211):

```swift
            if let (path, lineNo) = resolvePath(in: line) {
                onOpenFile?(path, lineNo)
                return true
            }
            if let url = firstURL(in: line) {
                NSWorkspace.shared.open(url)
                return true
            }
```

with (URL checked first — a clicked URL must never fall through to the editor):

```swift
            if let url = firstWebURL(in: line) {
                NSWorkspace.shared.open(url)
                return true
            }
            if let (path, lineNo) = resolvePath(in: line) {
                onOpenFile?(path, lineNo)
                return true
            }
```

- [ ] **Step 6: Delete the now-unused private `firstURL`**

In `Sources/Coda/ClickableTerminalView.swift`, delete the entire private method (lines ~253-261):

```swift
    private func firstURL(in line: String) -> URL? {
        for raw in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'(),[]{}<>"))
            if token.hasPrefix("http://") || token.hasPrefix("https://"), let url = URL(string: token) {
                return url
            }
        }
        return nil
    }
```

(`CodaCore` is already imported at the top of the file, so `firstWebURL` resolves.)

- [ ] **Step 7: Build**

Run: `swift build`
Expected: builds cleanly (no "unused function" is possible since we deleted it; no "undefined firstURL").

- [ ] **Step 8: Manual verification (also confirms the root cause)**

Run the app. In a terminal, print a URL (`echo https://example.com`) and Cmd+click it → the **default browser** opens it. Print a dev-server URL (`echo localhost:3000`) and Cmd+click → browser opens `http://localhost:3000`. Then Cmd+click a real file token like `Sources/Coda/AppDelegate.swift` → it still opens in VS Code. If reproduction shows the original "URL → VS Code" came from a specific line shape (URL sharing a line with a filename, or a wrapped URL), note it in the commit body — the URL-first ordering fixes it regardless.

- [ ] **Step 9: Commit**

```bash
git add Sources/CodaCore/TerminalClick.swift Tests/CodaCoreTests/TerminalClickTests.swift Sources/Coda/ClickableTerminalView.swift
git commit -m "fix(terminal): Cmd+click URLs open the browser, not VS Code

URL detection now runs before file-path resolution in the click handler, so a
clicked URL always opens in the default browser. Adds bare localhost/127.0.0.1
recognition. Detection extracted to a pure, unit-tested CodaCore function.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Shell resolution core — types, prefs, launch line (#4a)

**Files:**
- Create: `Sources/CodaCore/Shell.swift`
- Test: `Tests/CodaCoreTests/ShellTests.swift`
- Modify: `Sources/CodaCore/Preferences.swift`
- Modify: `Sources/CodaCore/LaunchCommand.swift`
- Test: `Tests/CodaCoreTests/PreferencesTests.swift`, `Tests/CodaCoreTests/LaunchCommandTests.swift`

**Interfaces:**
- Produces:
  - `enum ShellChoice: String, Codable, CaseIterable { case automatic, zsh, bash }` with `var displayName: String`.
  - `struct ResolvedShell: Equatable { let executablePath: String; var name: String; var loginArgv0: String }` (init: `ResolvedShell(executablePath: String)`).
  - `func resolveShell(choice: ShellChoice, loginShell: String?) -> ResolvedShell`.
  - `Preferences.shell: ShellChoice` (defaults to `.automatic`; old prefs decode to `.automatic`).
  - `terminalLaunchLine(workingDirectory:setupScript:command:shell:)` and `terminalShellArgs(workingDirectory:setupScript:command:shell:)` gain a `shell: String = "zsh"` parameter (the interactive shell name used for the `<shell> -i` target and the `exec <shell>` fallback).

- [ ] **Step 1: Write the failing shell-resolution tests**

Create `Tests/CodaCoreTests/ShellTests.swift`:

```swift
import XCTest
@testable import CodaCore

final class ShellTests: XCTestCase {
    func testExplicitZsh() {
        let s = resolveShell(choice: .zsh, loginShell: "/bin/bash")
        XCTAssertEqual(s.executablePath, "/bin/zsh")
        XCTAssertEqual(s.name, "zsh")
        XCTAssertEqual(s.loginArgv0, "-zsh")
    }

    func testExplicitBash() {
        let s = resolveShell(choice: .bash, loginShell: "/bin/zsh")
        XCTAssertEqual(s.executablePath, "/bin/bash")
        XCTAssertEqual(s.name, "bash")
        XCTAssertEqual(s.loginArgv0, "-bash")
    }

    func testAutomaticUsesLoginShell() {
        let s = resolveShell(choice: .automatic, loginShell: "/bin/bash")
        XCTAssertEqual(s.executablePath, "/bin/bash")
        XCTAssertEqual(s.name, "bash")
        XCTAssertEqual(s.loginArgv0, "-bash")
    }

    func testAutomaticSupportsHomebrewAndExoticShells() {
        let s = resolveShell(choice: .automatic, loginShell: "/opt/homebrew/bin/fish")
        XCTAssertEqual(s.executablePath, "/opt/homebrew/bin/fish")
        XCTAssertEqual(s.name, "fish")
        XCTAssertEqual(s.loginArgv0, "-fish")
    }

    func testAutomaticFallsBackToZshWhenLoginShellMissing() {
        XCTAssertEqual(resolveShell(choice: .automatic, loginShell: nil).executablePath, "/bin/zsh")
        XCTAssertEqual(resolveShell(choice: .automatic, loginShell: "").executablePath, "/bin/zsh")
    }

    func testAutomaticFallsBackToZshForNonAbsoluteLoginShell() {
        // A relative/garbage $SHELL is not a spawnable path — fall back to a known-good one.
        XCTAssertEqual(resolveShell(choice: .automatic, loginShell: "bash").executablePath, "/bin/zsh")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter ShellTests`
Expected: compile error / FAIL — `resolveShell`, `ShellChoice`, `ResolvedShell` undefined.

- [ ] **Step 3: Implement the shell types + resolver**

Create `Sources/CodaCore/Shell.swift`:

```swift
import Foundation

/// The user's shell preference. Portable (no absolute path) so it can live in `Preferences`.
/// `.automatic` means "use my login shell"; `.zsh`/`.bash` force a specific well-known shell.
public enum ShellChoice: String, Codable, CaseIterable {
    case automatic, zsh, bash

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic (login shell)"
        case .zsh:       return "zsh"
        case .bash:      return "bash"
        }
    }
}

/// A concrete shell to spawn: its executable path plus the derived login argv0 (a leading
/// dash tells the shell to behave as a login shell, matching Terminal.app) and basename.
public struct ResolvedShell: Equatable {
    public let executablePath: String
    public init(executablePath: String) { self.executablePath = executablePath }

    /// The shell's basename, e.g. "zsh", "bash", "fish".
    public var name: String { (executablePath as NSString).lastPathComponent }

    /// argv0 for a login shell: the basename prefixed with "-" (e.g. "-zsh"), which is the
    /// convention login shells use to decide to source login-profile files.
    public var loginArgv0: String { "-" + name }
}

/// Resolve a `ShellChoice` (plus the detected login shell) to a concrete `ResolvedShell`.
/// `.automatic` uses `loginShell` when it's an absolute path, else falls back to `/bin/zsh`.
/// Pure and FS-free for testability — the caller supplies `loginShell` (from `$SHELL` /
/// the password DB).
public func resolveShell(choice: ShellChoice, loginShell: String?) -> ResolvedShell {
    switch choice {
    case .zsh:  return ResolvedShell(executablePath: "/bin/zsh")
    case .bash: return ResolvedShell(executablePath: "/bin/bash")
    case .automatic:
        if let s = loginShell, s.hasPrefix("/") {
            return ResolvedShell(executablePath: s)
        }
        return ResolvedShell(executablePath: "/bin/zsh")
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter ShellTests`
Expected: PASS — all six tests.

- [ ] **Step 5: Write the failing Preferences tests**

Add to `Tests/CodaCoreTests/PreferencesTests.swift` (inside the `PreferencesTests` class):

```swift
    func testShellDefaultsAutomatic() {
        XCTAssertEqual(Preferences().shell, .automatic)
    }

    func testShellDefaultsAutomaticForOldPrefs() throws {
        // Prefs written before the shell picker carried no shell key.
        let json = #"{"defaultEditor":{"name":"Visual Studio Code","bundleID":"com.microsoft.VSCode","urlScheme":"vscode"}}"#
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        XCTAssertEqual(prefs.shell, .automatic)
    }

    func testShellRoundTrips() throws {
        var prefs = Preferences()
        prefs.shell = .bash
        let back = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(back.shell, .bash)
    }
```

- [ ] **Step 6: Run to verify they fail**

Run: `swift test --filter PreferencesTests`
Expected: FAIL — `Preferences` has no member `shell`.

- [ ] **Step 7: Add the `shell` field to `Preferences`**

In `Sources/CodaCore/Preferences.swift`, make four edits to the `Preferences` struct:

(a) Add the stored property after `notifyOnDone` (after line 90):

```swift
    /// The shell to spawn in new terminals. Defaults to `.automatic` (the login shell);
    /// older prefs files without the key decode to `.automatic` via the custom decoder below.
    /// Changing this affects new terminals only. Portable (an enum, never a path).
    public var shell: ShellChoice
```

(b) Add `shell` to the initializer signature and body. Replace the `init(...)` declaration line and its assignments. Change the signature's last parameter line from:

```swift
                notifyOnDone: Bool = true) {
```

to:

```swift
                notifyOnDone: Bool = true, shell: ShellChoice = .automatic) {
```

and add, after `self.notifyOnDone = notifyOnDone`:

```swift
        self.shell = shell
```

(c) Add `shell` to `CodingKeys`. Change:

```swift
        case notifyOnNeedsYou, notifyOnDone
```

to:

```swift
        case notifyOnNeedsYou, notifyOnDone, shell
```

(d) Add the defaulting decode in `init(from:)`, after the `notifyOnDone` line:

```swift
        self.shell = try c.decodeIfPresent(ShellChoice.self, forKey: .shell) ?? .automatic
```

- [ ] **Step 8: Run to verify Preferences tests pass**

Run: `swift test --filter PreferencesTests`
Expected: PASS — including the existing `testPreferencesHoldsNoAbsolutePaths` (the shell enum serializes to `"automatic"`/`"zsh"`/`"bash"` — no `/`).

- [ ] **Step 9: Write the failing bash launch-line tests**

Add to `Tests/CodaCoreTests/LaunchCommandTests.swift` (inside `LaunchCommandTests`):

```swift
    func testBashEmptyCommandExecsBashInteractive() {
        let line = terminalLaunchLine(workingDirectory: "/tmp/wt", setupScript: "", command: "", shell: "bash")
        XCTAssertEqual(line, "cd '/tmp/wt' && exec bash -i")
    }

    func testBashSetupFallsBackToBash() {
        let line = terminalLaunchLine(workingDirectory: "/tmp/wt", setupScript: "npm install",
                                      command: "", shell: "bash")
        XCTAssertEqual(line, "cd '/tmp/wt' && { npm install && exec bash -i || exec bash; }")
    }

    func testBashCommandArgs() {
        let args = terminalShellArgs(workingDirectory: "/tmp/wt", setupScript: "",
                                     command: "claude", shell: "bash")
        // A non-empty command is exec'd directly; the shell name only affects the fallback path.
        XCTAssertEqual(args, ["-i", "-c", "cd '/tmp/wt' && exec claude"])
    }

    func testShellNameDefaultsToZsh() {
        // Existing call sites that omit `shell:` keep zsh behavior.
        let line = terminalLaunchLine(workingDirectory: "/tmp/wt", setupScript: "", command: "")
        XCTAssertEqual(line, "cd '/tmp/wt' && exec zsh -i")
    }
```

- [ ] **Step 10: Run to verify they fail**

Run: `swift test --filter LaunchCommandTests`
Expected: FAIL — `terminalLaunchLine`/`terminalShellArgs` have no `shell:` parameter.

- [ ] **Step 11: Parametrize the launch line by shell name**

In `Sources/CodaCore/LaunchCommand.swift`, replace both functions (`terminalLaunchLine` and `terminalShellArgs`) with:

```swift
/// Build the `<shell> -i -c` line for a terminal surface.
/// - Empty `command` (shell-first): exec a live interactive shell (`<shell> -i`).
/// - Non-empty `command`: `exec <command>` (the command replaces the shell).
/// - With setupScript: run setup first; on success exec the target; on failure drop into
///   an interactive shell (`exec <shell>`) so the user can investigate.
/// `shell` is the interactive shell's name (e.g. "zsh", "bash"); it only appears in the
/// shell-first target and the setup-failure fallback. `command` is not quoted (a single
/// token like `claude`).
public func terminalLaunchLine(workingDirectory: String, setupScript: String,
                               command: String, shell: String = "zsh") -> String {
    let dir = shellSingleQuote(workingDirectory)
    let setup = setupScript.trimmingCharacters(in: .whitespacesAndNewlines)
    let target = command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(shell) -i" : command
    if setup.isEmpty {
        return "cd \(dir) && exec \(target)"
    }
    return "cd \(dir) && { \(setup) && exec \(target) || exec \(shell); }"
}

/// The argv (after the shell executable, whose argv0 is the login `-<shell>`) for a terminal
/// surface. `currentDirectory` is set on the spawn, so no `cd` is needed for the shell-first
/// path.
/// - Shell-first (no setup, no command): a single interactive login shell (`-i`), NO `-c`
///   wrapper — a `-c` form would nest a second interactive shell and source rc files twice.
/// - With setup and/or command: keep the `-i -c <line>` form; a directly-exec'd target
///   (e.g. `claude`) needs the outer shell's `-i` to source the interactive environment.
public func terminalShellArgs(workingDirectory: String, setupScript: String,
                              command: String, shell: String = "zsh") -> [String] {
    let setup = setupScript.trimmingCharacters(in: .whitespacesAndNewlines)
    let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
    if setup.isEmpty && cmd.isEmpty {
        return ["-i"]
    }
    return ["-i", "-c", terminalLaunchLine(workingDirectory: workingDirectory,
                                           setupScript: setupScript,
                                           command: command, shell: shell)]
}
```

(The `shellSingleQuote` and `launchCommand(for:)` functions in this file are unchanged.)

- [ ] **Step 12: Run all affected tests**

Run: `swift test --filter LaunchCommandTests`
Expected: PASS — the new bash cases AND all pre-existing zsh cases (they omit `shell:`, so the `= "zsh"` default preserves their expected output).

- [ ] **Step 13: Full test + build sanity**

Run: `swift build && swift test`
Expected: build succeeds; entire suite passes.

- [ ] **Step 14: Commit**

```bash
git add Sources/CodaCore/Shell.swift Tests/CodaCoreTests/ShellTests.swift Sources/CodaCore/Preferences.swift Tests/CodaCoreTests/PreferencesTests.swift Sources/CodaCore/LaunchCommand.swift Tests/CodaCoreTests/LaunchCommandTests.swift
git commit -m "feat(core): shell choice model + shell-parametric launch line

Adds ShellChoice (automatic/zsh/bash), ResolvedShell, and resolveShell() plus a
portable Preferences.shell field. terminalLaunchLine/terminalShellArgs now take a
shell name (defaulting to zsh) so bash and other login shells launch correctly.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Shell wiring + Settings dropdown (#4b)

**Files:**
- Modify: `Sources/Coda/TerminalSurface.swift`
- Modify: `Sources/Coda/AppDelegate.swift`
- Modify: `Sources/Coda/GeneralSettingsViewController.swift`
- Modify: `Sources/Coda/SettingsTabController.swift`

**Interfaces:**
- Consumes (from Task 3): `ShellChoice`, `ResolvedShell`, `resolveShell(choice:loginShell:)`, `Preferences.shell`, `terminalShellArgs(..., shell:)`.
- Produces: `TerminalSurface.init(..., shell: ResolvedShell = ResolvedShell(executablePath: "/bin/zsh"))`; `AppDelegate.resolvedShell() -> ResolvedShell`; `GeneralSettingsViewController(..., shell: ShellChoice)` + `onChangeShell: ((ShellChoice) -> Void)?`.

_No unit tests — this is AppKit view/wiring; verified by `swift build` + manual run._

- [ ] **Step 1: Make `TerminalSurface` spawn a chosen shell**

In `Sources/Coda/TerminalSurface.swift`:

(a) Add a stored property after `private let hookSocketPath: String` (line 14):

```swift
    private let shell: ResolvedShell
```

(b) Add the parameter to `init` — change the signature line:

```swift
    init(workingDirectory: String, command: String, setupScript: String = "",
         hookWorktreeID: String = "", hookSurfaceID: String = "", hookSocketPath: String = "") {
```

to:

```swift
    init(workingDirectory: String, command: String, setupScript: String = "",
         hookWorktreeID: String = "", hookSurfaceID: String = "", hookSocketPath: String = "",
         shell: ResolvedShell = ResolvedShell(executablePath: "/bin/zsh")) {
```

and add, among the assignments in `init` (e.g. after `self.hookSocketPath = hookSocketPath`):

```swift
        self.shell = shell
```

(c) In `viewDidLayout()`, update the args build and the `startProcess` call. Replace:

```swift
        let args = terminalShellArgs(workingDirectory: workingDirectory,
                                     setupScript: setupScript,
                                     command: command)
```

with:

```swift
        let args = terminalShellArgs(workingDirectory: workingDirectory,
                                     setupScript: setupScript,
                                     command: command, shell: shell.name)
```

and replace:

```swift
        terminal.startProcess(executable: "/bin/zsh",
                              args: args,
                              environment: envArray,
                              execName: "-zsh",
                              currentDirectory: workingDirectory)
```

with:

```swift
        terminal.startProcess(executable: shell.executablePath,
                              args: args,
                              environment: envArray,
                              execName: shell.loginArgv0,
                              currentDirectory: workingDirectory)
```

- [ ] **Step 2: Resolve the shell in AppDelegate and pass it to panes**

In `Sources/Coda/AppDelegate.swift`:

(a) Add a helper (place it near `resolvedTerminalFont()`, around line 903):

```swift
    /// The shell to spawn in new terminals, per the user's preference. `.automatic` uses the
    /// login shell from `$SHELL`, falling back to the password DB, then to /bin/zsh.
    private func resolvedShell() -> ResolvedShell {
        let login = ProcessInfo.processInfo.environment["SHELL"] ?? loginShellFromPasswordDB()
        return resolveShell(choice: preferences.shell, loginShell: login)
    }

    /// The current user's login shell from the password database (getpwuid), or nil.
    /// Fallback for the rare case `$SHELL` is absent (e.g. an unusual launch context).
    private func loginShellFromPasswordDB() -> String? {
        guard let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell else { return nil }
        let path = String(cString: shell)
        return path.isEmpty ? nil : path
    }
```

(b) In `makePane(in:command:setup:surfaceID:)` (line 653), pass the shell. Change:

```swift
        let pane = TerminalSurface(workingDirectory: wt.worktreePath, command: command, setupScript: setup,
                                   hookWorktreeID: wt.id, hookSurfaceID: surfaceID,
                                   hookSocketPath: hookServer?.socketPath ?? "")
```

to:

```swift
        let pane = TerminalSurface(workingDirectory: wt.worktreePath, command: command, setupScript: setup,
                                   hookWorktreeID: wt.id, hookSurfaceID: surfaceID,
                                   hookSocketPath: hookServer?.socketPath ?? "",
                                   shell: resolvedShell())
```

(The `?? TerminalSurface(...)` fallback in the split's `makePane` closure at line 623 runs only when `self` is nil during teardown — leave it on the default zsh.)

(c) Add a setter (place near `setUIScale`/`setNotifyOnDone`, around line 416+):

```swift
    private func setShell(_ shell: ShellChoice) {
        preferences.shell = shell
        do { try prefsStore.save(preferences) } catch { presentError(error) }
        // Applies to new terminals only; running shells keep their process.
    }
```

- [ ] **Step 3: Add the Shell dropdown to General Settings**

In `Sources/Coda/GeneralSettingsViewController.swift`:

(a) Add properties near the other popups (after the `scalePopup` declaration, ~line 29):

```swift
    private let shellPopup = NSPopUpButton()
    private var shell: ShellChoice
```

(b) Add the callback near the other `onChange…` vars (~line 36):

```swift
    var onChangeShell: ((ShellChoice) -> Void)?
```

(c) Add `shell` to `init`. Change the signature:

```swift
    init(editor: Editor, terminalFont: NSFont, uiScale: UIScale,
         notifyOnNeedsYou: Bool, notifyOnDone: Bool) {
```

to:

```swift
    init(editor: Editor, terminalFont: NSFont, uiScale: UIScale,
         notifyOnNeedsYou: Bool, notifyOnDone: Bool, shell: ShellChoice) {
```

and add, among the init assignments:

```swift
        self.shell = shell
```

(d) In `loadView()`, build the shell row. Add this just before the final `let stack = NSStackView(...)` assembly (after the notifications block that ends with `notifyStack`):

```swift
        // Shell — which shell new terminals launch. Applies to new terminals only.
        let shellTitle = NSTextField(labelWithString: "Shell")
        shellTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        for choice in ShellChoice.allCases { shellPopup.addItem(withTitle: choice.displayName) }
        shellPopup.selectItem(at: ShellChoice.allCases.firstIndex(of: shell) ?? 0)
        shellPopup.target = self
        shellPopup.action = #selector(shellChanged)
        let shellRow = NSStackView(views: [NSTextField(labelWithString: "Shell:"), shellPopup])
        shellRow.orientation = .horizontal
        shellRow.spacing = 8
        let shellHint = NSTextField(labelWithString: "Automatic uses your login shell. Applies to new terminals.")
        shellHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        shellHint.textColor = .secondaryLabelColor
```

(e) Add `shellTitle, shellRow, shellHint` to the vertical `stack`'s view list. Change:

```swift
        let stack = NSStackView(views: [
            title, row, hint,
            fontTitle, fontRow, fontHint,
            scaleTitle, scaleRow, scaleHint,
            notifyTitle, notifyStack,
        ])
```

to:

```swift
        let stack = NSStackView(views: [
            title, row, hint,
            fontTitle, fontRow, fontHint,
            scaleTitle, scaleRow, scaleHint,
            notifyTitle, notifyStack,
            shellTitle, shellRow, shellHint,
        ])
```

(f) Add the action handler near `scaleChanged` (~line 250):

```swift
    @objc private func shellChanged() {
        let idx = shellPopup.indexOfSelectedItem
        guard ShellChoice.allCases.indices.contains(idx) else { return }
        shell = ShellChoice.allCases[idx]
        onChangeShell?(shell)
    }
```

- [ ] **Step 4: Thread the shell params through `SettingsTabController`**

In `Sources/Coda/SettingsTabController.swift`:

(a) Add two parameters to `init`. After the `onChangeNotifyOnDone` parameter, add:

```swift
         shell: ShellChoice,
         onChangeShell: @escaping (ShellChoice) -> Void) {
```

(i.e. change the last parameter line `onChangeNotifyOnDone: @escaping (Bool) -> Void) {` to `onChangeNotifyOnDone: @escaping (Bool) -> Void,` and add the two lines above.)

(b) Pass `shell` when constructing the general pane. Change:

```swift
        let general = GeneralSettingsViewController(editor: editor, terminalFont: terminalFont, uiScale: uiScale,
                                                    notifyOnNeedsYou: notifyOnNeedsYou, notifyOnDone: notifyOnDone)
```

to:

```swift
        let general = GeneralSettingsViewController(editor: editor, terminalFont: terminalFont, uiScale: uiScale,
                                                    notifyOnNeedsYou: notifyOnNeedsYou, notifyOnDone: notifyOnDone,
                                                    shell: shell)
```

(c) Wire the callback, after `general.onChangeNotifyOnDone = onChangeNotifyOnDone`:

```swift
        general.onChangeShell = onChangeShell
```

- [ ] **Step 5: Pass shell prefs from `openSettings()`**

In `Sources/Coda/AppDelegate.swift`, in `openSettings()` (line 377), add the two arguments to the `SettingsTabController(...)` call. Change:

```swift
                notifyOnDone: preferences.notifyOnDone,
                onChangeNotifyOnDone: { [weak self] on in self?.setNotifyOnDone(on) })
```

to:

```swift
                notifyOnDone: preferences.notifyOnDone,
                onChangeNotifyOnDone: { [weak self] on in self?.setNotifyOnDone(on) },
                shell: preferences.shell,
                onChangeShell: { [weak self] choice in self?.setShell(choice) })
```

- [ ] **Step 6: Build**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 7: Manual verification**

Run the app. Open Settings (⌘,) → General → the **Shell** dropdown shows `Automatic (login shell)`, `zsh`, `bash`. With `Automatic`, open a **new tab** and run `echo $0` / `ps -p $$` — it should be your login shell (e.g. `-zsh`). Switch to `bash`, open a **new tab**, run `echo $0` → `-bash`, and confirm `~/.bash_profile` sourced (e.g. a known alias/PATH entry). Existing tabs keep their original shell (setting applies to new terminals only). If your login shell is bash, `Automatic` should also give bash.

- [ ] **Step 8: Commit**

```bash
git add Sources/Coda/TerminalSurface.swift Sources/Coda/AppDelegate.swift Sources/Coda/GeneralSettingsViewController.swift Sources/Coda/SettingsTabController.swift
git commit -m "feat(app): launch the user's login shell + Shell setting

New terminals spawn the resolved shell (Automatic=login shell, or forced
zsh/bash) with the correct login argv0, so bash users get bash sourcing their
profile. Adds a Shell dropdown to General Settings; applies to new terminals.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Diagnose & fix intermittent invisible typed text in Claude's TUI (#3)

> **STATUS (2026-07-04): DEFERRED.** Not reproduced/fixed in this branch. The bug is
> intermittent and GUI-only; it cannot be reproduced or observed autonomously (no Screen
> Recording permission — see [[debugging-terminal-rendering]]) and the maintainer reports it
> is now rare/uncertain on the current build. Deferred until it can be reliably reproduced.
>
> **Corrections to the fix specs below, from a static read of SwiftTerm 1.13.0 — do not
> follow Step 4a as written:**
> - In Claude's TUI the shell is in **raw mode with no local echo**: a typed key only sends
>   bytes to the PTY. The glyph appears when the app **echoes it back as output** —
>   `dataReceived` → `feed` → SwiftTerm's `Terminal.updateRange` marks the row dirty →
>   throttled `updateDisplay` (queued at ~1/60s) calls `setNeedsDisplay` on just
>   `refreshStart…refreshEnd`. So "invisible typed text" is really "echoed output not painted."
> - Therefore Step 4a's lever is wrong: it sets `needsDisplay = true` in a `keyDown` override,
>   but (a) that override no longer exists — soft-newline (Task 1) became an **app-level
>   NSEvent monitor** (`ClickableTerminalView.sendSoftNewline()`) because SwiftTerm seals
>   `keyDown` (public, not open), and (b) at keyDown time the echoed glyph isn't in the model
>   yet, so repainting then paints nothing new.
> - If this is pursued as H1, the correct app-layer lever is in the **`dataReceived` path**
>   (already overridden in `ClickableTerminalView`), forcing a fuller repaint after output —
>   not `keyDown`. The likely true cause is upstream in SwiftTerm's throttled `updateDisplay`
>   dirty-region math (`AppleTerminalView.updateDisplay` + `Terminal.getUpdateRange`).

This is a **diagnosis-first** task: the symptom (typed glyphs render in the background color; cursor advances; intermittent; recovers on redraw; mostly in Claude's TUI on SwiftTerm 1.13.0) does not yet have a confirmed root cause, so we reproduce and observe before committing a fix. Two candidate fixes are fully specified below; the diagnosis selects one. **Use the superpowers:systematic-debugging skill for this task.**

**Files:**
- Investigate: `Sources/Coda/ClickableTerminalView.swift`, `Sources/Coda/TerminalSurface.swift`, and SwiftTerm's rendering path (`.build/checkouts/SwiftTerm`).
- Modify (fix location depends on diagnosis): `Sources/Coda/ClickableTerminalView.swift` or `Sources/Coda/TerminalSurface.swift`.

- [ ] **Step 1: Reproduce reliably**

Run the app, start a Claude Code session in a terminal, and type into the prompt. Reproduce the invisible-text state (cursor advances, glyphs not visible). Note what triggers it (e.g. after Claude streams a large output block, after a resize, after a specific TUI redraw) and what makes it recover (running a command, resize, tab switch). Write these observations into a scratch note.

- [ ] **Step 2: Capture a snapshot of the terminal view in the bad state**

Per the project's established technique (Claude cannot screen-capture the GUI): add a temporary snapshot of the `ClickableTerminalView` to a PNG from within the app, then Read the PNG. Use `NSView.dataWithPDF(inside:)` or a bitmap rep of `terminal` written to `~/coda-snapshot.png`, triggered from a temporary debug menu item or a keystroke. Confirm from the image whether the glyph cells are (a) drawn in the background color (a color/SGR problem) or (b) not drawn at all / stale (a dirty-region/repaint problem). Remove the temporary snapshot code before committing.

- [ ] **Step 3: Classify the root cause**

Decide between the two hypotheses using Step 2's evidence:
- **H1 — Repaint/dirty-region:** the typed cells aren't marked needing display until a larger redraw forces it. Symptom in the PNG: the just-typed region is stale/empty though the model has the characters.
- **H2 — SGR color-state desync:** SwiftTerm mis-tracks the current foreground SGR after some sequence Claude emits, so typed glyphs are painted in (or too close to) the background color. Symptom in the PNG: glyphs are present but the same color as the background.

Cross-check the terminal's model vs. render: in a debugger or via a temporary log, dump `getTerminal().getLine(row:)` for the cursor row while the text is invisible. If the model HAS the characters but they're invisible → H1 (or H2 if the cells carry a bg-matching fg attribute). Inspect the cell attributes (fg color) for the affected cells to distinguish.

- [ ] **Step 4a: If H1 (repaint) — force a repaint on input**

In `Sources/Coda/ClickableTerminalView.swift`, after sending typed input, mark the view for redisplay. In the `keyDown(with:)` override added in Task 1, after `super.keyDown(with: event)` returns for normal input, request display:

```swift
    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags
        if terminalKeyAction(charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                             command: mods.contains(.command), shift: mods.contains(.shift),
                             option: mods.contains(.option)) == .insertNewline {
            send(data: [UInt8(0x0a)][0...])
            needsDisplay = true
            return
        }
        super.keyDown(with: event)
        // H1 fix: SwiftTerm intermittently fails to flush the just-typed cells during
        // Claude's TUI redraws; force a repaint so echoed input is always visible.
        needsDisplay = true
    }
```

If `needsDisplay = true` alone is insufficient (SwiftTerm may need an explicit invalidation of the changed region), escalate to calling SwiftTerm's public redraw entry point that covers the full viewport, or drive it via `dataReceived` — determine the exact SwiftTerm API from `.build/checkouts/SwiftTerm` and pick the narrowest one that works. Document the chosen call in a code comment.

- [ ] **Step 4b: If H2 (SGR color desync) — correct the color state**

If glyphs carry a background-matching foreground attribute, the defect is in how the terminal's default/current foreground is applied. Verify `nativeForegroundColor` is set (it is, in `applyTheme`) and reproduce whether the issue is a specific escape sequence Claude emits. If it is a SwiftTerm bug in SGR handling, prefer the minimal correct fix in our layer if possible (e.g. ensuring theme/foreground is re-asserted); otherwise apply the H1 forced-repaint mitigation as the pragmatic fallback (per the spec's Option B) and record that the true cause is upstream in SwiftTerm, with a link/issue reference.

- [ ] **Step 5: Verify the fix reproduces clean**

Rebuild (`swift build`) and repeat Step 1's reproduction steps several times in a Claude session. Confirm typed text is now always visible immediately. Confirm no visible performance regression (typing latency, CPU) from any added repaints.

- [ ] **Step 6: Remove all temporary diagnostic code**

Delete the snapshot code, debug menu items, and any temporary logging added during diagnosis. Confirm `git diff` shows only the intended fix.

- [ ] **Step 7: Full build + tests**

Run: `swift build && swift test`
Expected: build succeeds; full suite passes.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "fix(terminal): keep typed text visible during Claude TUI redraws

<Replace this body with the confirmed root cause from diagnosis (H1 repaint vs
H2 SGR desync) and the exact mechanism of the fix.>

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- #2 soft newline (⌘/⇧/⌥+Enter → `0x0a`, fixed built-in, two interception points) → Task 1. ✓
- #1 URL → browser, wins over file, http/https/localhost, default browser → Task 2. ✓
- #4 login-shell support + Automatic/zsh/bash portable enum, global setting, best-effort exotic shells, login argv0 parity → Tasks 3 & 4. ✓
- #3 invisible typed text, diagnose-first (Option A), mitigation fallback (Option B) → Task 5. ✓
- Global constraints (SwiftTerm pin untouched, Preferences portability, commit trailer, build/test commands) → header + per-task steps. ✓

**Placeholder scan:** Task 5 is intentionally a diagnosis task; both candidate fixes carry real code, and the only literal placeholder is the commit-body `<…>` that must be filled with the confirmed cause after diagnosis (unavoidable — the cause is unknown until reproduced). No other TODO/TBD/"handle edge cases" placeholders.

**Type consistency:** `ShellChoice`, `ResolvedShell(executablePath:)`, `.name`, `.loginArgv0`, `resolveShell(choice:loginShell:)`, `Preferences.shell`, `terminalShellArgs(..., shell:)`, `terminalLaunchLine(..., shell:)`, `TerminalSurface(..., shell:)`, `GeneralSettingsViewController(..., shell:)` + `onChangeShell`, `SettingsTabController(..., shell:onChangeShell:)`, `AppDelegate.resolvedShell()`/`setShell(_:)` — names and signatures are consistent across Tasks 3→4. `TerminalKeyAction.insertNewline` and the `option:` parameter are consistent across Task 1's core and wiring.
