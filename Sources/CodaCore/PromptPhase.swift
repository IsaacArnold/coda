import Foundation

/// The current phase of the shell, driven by OSC 133 semantic-prompt markers.
public enum PromptPhase: Equatable {
    case unknown
    case atPrompt
    case executing
}

/// A pure reduction from OSC 133 semantic-prompt marker payloads to `PromptPhase`.
///
/// OSC 133 marks four points in the prompt/command lifecycle: `A` (prompt start), `B`
/// (command start — the shell is ready for input), `C` (pre-exec — the typed command begins
/// running), and `D[;code]` (command finished, optionally carrying its exit code). Downstream,
/// a live SwiftTerm OSC handler (a later task) will parse each escape sequence off the wire and
/// feed this machine its data segment (e.g. `"A"`, `"D;0"`); this type has no notion of AppKit
/// or SwiftTerm and does no parsing of the surrounding escape sequence itself.
///
/// The task brief describes `consume(marker: Character)`, but `D;<code>` needs to carry the
/// exit-code payload alongside the marker letter, so this takes the full marker string (the
/// OSC 133 data segment, minus the `\x1b]133;` prefix and `\x07`/`ST` terminator) instead.
///
/// Out-of-order and duplicate markers (a `C` with no preceding `A`/`B`, repeated `A`s, a stray
/// `D` on a fresh machine, a malformed `D;<code>`) are all valid input from a real terminal and
/// must never crash; each resolves to the phase the marker itself implies.
public struct PromptPhaseMachine: Equatable {
    public private(set) var phase: PromptPhase = .unknown
    public private(set) var lastCommandExitCode: Int?

    public init() {}

    /// Feed one OSC 133 marker payload, e.g. `"A"`, `"B"`, `"C"`, `"D"`, or `"D;0"`.
    /// Unrecognized markers (or an empty payload) are ignored, leaving phase unchanged.
    public mutating func consume(_ payload: String) {
        switch payload.first {
        case "A", "B":
            phase = .atPrompt
        case "C":
            phase = .executing
        case "D":
            phase = .unknown
            lastCommandExitCode = Self.exitCode(fromDPayload: payload)
        default:
            break
        }
    }

    /// Parses the optional `;<code>` suffix of a `D` marker's payload. Returns `nil` when no
    /// code is present, or when it isn't a valid integer — a malformed marker must not crash.
    private static func exitCode(fromDPayload payload: String) -> Int? {
        let parts = payload.split(separator: ";", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return Int(parts[1])
    }
}
