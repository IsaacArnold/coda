import Foundation

/// A PTY window size: character grid plus pixel size (the `winsize` a TIOCSWINSZ carries).
public struct PtySize: Equatable, Sendable {
    public var cols: Int
    public var rows: Int
    public var width: Int
    public var height: Int
    public init(cols: Int, rows: Int, width: Int, height: Int) {
        self.cols = cols
        self.rows = rows
        self.width = width
        self.height = height
    }
}

/// Holds PTY size updates back while the window is being live-resized (#80).
///
/// SwiftTerm re-wraps its buffer on every frame of a window drag and tells the PTY each new
/// size (TIOCSWINSZ → SIGWINCH). A TUI like Claude Code then redraws dozens of times while the
/// reflow is still moving under it, which leaves garbled frames behind. The gate keeps
/// reporting the last size the program was given for the duration of the drag — the kernel
/// only signals SIGWINCH when the size actually changes, so the program sees nothing — and
/// hands back the final size once when the drag ends, for a single clean redraw.
public struct LiveResizePtyGate: Equatable, Sendable {
    /// The size the program running in the PTY was last given.
    public private(set) var committed: PtySize?

    public init() {}

    /// The size to report to the PTY now. Outside a live resize that's `actual` (and it
    /// becomes the committed size); during one it's the committed size, unless nothing has
    /// been committed yet — a pane created mid-drag still needs a real size.
    public mutating func sizeToReport(actual: PtySize, inLiveResize: Bool) -> PtySize {
        if inLiveResize, let committed { return committed }
        committed = actual
        return actual
    }

    /// The live resize ended at `actual`: returns the size to push to the PTY, or nil when the
    /// program already has it (e.g. the drag ended where it started).
    public mutating func endLiveResize(actual: PtySize) -> PtySize? {
        guard actual != committed else { return nil }
        committed = actual
        return actual
    }
}
