# Terminal drag-and-drop — Design

**Date:** 2026-07-02
**Status:** Approved (pending spec review)

## Problem

Coda's terminal accepts no drag-and-drop. iTerm2 users (including this one) routinely
drag files and images from Finder onto the terminal to get their path inserted at the
cursor — most commonly to hand a path to a running tool. When running Claude Code inside
Coda, dropping an image is the natural way to give Claude a file path it can read. Coda
should support this.

## Scope

**In scope**
- **File drop** (one or more files, including images): insert each file's *escaped
  absolute path*, space-joined, at the cursor. No trailing newline — never auto-executes.
  An image is treated as an ordinary file; its path is inserted (no inline rendering).
- **Plain text / URL drop** (dragged from Safari, Notes, Finder, etc.): insert the text
  or URL string literally at the cursor (not shell-escaped — this is a paste, not a path).
- **Drag feedback**: while a valid drag hovers over the terminal, show `.copy` and draw a
  subtle highlight; clear it on exit or drop.
- **Per-pane targeting**: the drop lands in whichever split/pane sits under the cursor
  (falls out of per-view dragging-destination registration for free).

**Out of scope**
- ⌥-drag scp upload — iTerm2's Option-drop uploads to a *remote* host and requires its
  shell integration; Coda has neither, and it's meaningless for a local shell.
- Path-format modifier keys (⌥ filename-only, ⌃ `file://` URL, ⇧ …). These do **not**
  exist in iTerm2 — they were an early misconception during design and are dropped.
- Inline image *rendering*. The user wants the path, not a displayed image.

## Behavior detail

### Content priority
A single drop is classified once, in this order:
1. If the drag carries file URLs → **file drop** (escaped absolute paths).
2. Else if it carries a URL → insert the URL string literally.
3. Else if it carries a string → insert the string literally.
4. Else → nothing draggable; reject the drop.

### Escaping (file paths only)
Backslash-escape every character **not** in the safe set `[A-Za-z0-9._/+-]`. Dropped
files always resolve to absolute paths (leading `/`), so there is no `~`-expansion
concern. This matches iTerm2's backslash style and is robust for spaces, parentheses,
quotes, `&`, `$`, glob characters, and non-ASCII bytes.

- Multiple files: escape each, join with a single space. **No trailing space.**
- Text / URL drops are inserted verbatim (no escaping).

### Insertion into the PTY
Mirror SwiftTerm's own `paste`:
- If `getTerminal().bracketedPasteMode` is on, wrap the sent text in
  `EscapeSequences.bracketedPasteStart` / `...End` and `send(data:)`. This keeps a
  multi-line **text** drop from auto-running lines at the shell.
- Otherwise `send(txt:)`.

(The internal `insertText(_:replacementRange:isPaste:)` path that SwiftTerm uses for its
own paste is `internal` and unreachable from Coda's module, so we replicate the
bracketed-paste wrapping ourselves. `EscapeSequences` visibility to be confirmed at
implementation; if it is not `public`, fall back to the literal byte sequences
`ESC [ 200 ~` and `ESC [ 201 ~`.)

Paths are single-line, so the wrapping only ever matters for text drops.

## Architecture

Follows the existing pure-core + AppKit-glue split (logic in `CodaCore` with tests;
platform glue in `Coda`).

### `Sources/CodaCore/TerminalDrop.swift` (pure, no AppKit)
- `func shellEscape(_ path: String) -> String`
- `func dropText(fileURLs: [URL], text: String?, url: URL?) -> String?`
  - Applies the content-priority rules above and returns the exact string to insert, or
    `nil` when nothing is insertable.
  - `URL` here is `Foundation.URL` (available without AppKit); file paths are read via
    `url.path`. The function itself performs no I/O and no pasteboard access.

### `Sources/Coda/ClickableTerminalView.swift` (NSDraggingDestination glue)
- In `init`/setup: `registerForDraggedTypes([.fileURL, .URL, .string])`.
- `draggingEntered` / `draggingUpdated`: if the pasteboard yields insertable content,
  set the highlight and return `.copy`; else `[]`.
- `draggingExited` / `concludeDragOperation`: clear the highlight.
- `performDragOperation`: read file URLs / URL / string from the pasteboard, call
  `TerminalDrop.dropText(...)`, and if non-nil send it via the insertion path above.
  Return whether anything was inserted.
- Highlight: a subtle focus-ring/border drawn while `isDragHighlighted` is true (exact
  styling chosen to match Coda's existing focus affordance).

### `Tests/CodaCoreTests/TerminalDropTests.swift`
- `shellEscape`: spaces, parentheses, single/double quotes, `&`/`$`/`;`, glob chars
  (`*?[]`), a non-ASCII path, and a plain safe path (unchanged).
- `dropText`: single file, multiple files (space-joined, no trailing space), priority
  (files beat url beat string), URL-only, string-only, and the empty/no-op case → `nil`.

## Non-goals / risks
- No change to copy/paste, ⌘+click open, or existing keybindings.
- Only real risk is `EscapeSequences` visibility (mitigation noted above) — a small
  implementation-time check, not a design fork.
