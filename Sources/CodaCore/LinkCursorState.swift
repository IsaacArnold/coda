import Foundation

/// What the ⌘-hover cursor logic should do for one mouse-move / modifier-change event.
public enum LinkCursorAction: Equatable, Sendable {
    /// Leave the cursor alone (AppKit's cursor rects own it).
    case none
    /// Show the pointing hand: ⌘ is held over a clickable link/path.
    case pointingHand
    /// We showed the hand and no longer should — restore the terminal's I-beam.
    case iBeam
    /// We showed the hand and the pointer is now outside any terminal — restore the arrow.
    case arrow
}

/// Bookkeeping for the ⌘-hover pointing hand. Pure, so it's testable without AppKit.
///
/// Showing the hand is easy; taking it away is the catch. Releasing ⌘ arrives as a
/// `flagsChanged` event, and AppKit re-applies no cursor rects for keyboard events — so
/// unless whoever set the hand restores the cursor, it stays until the mouse next moves.
public struct LinkCursorState: Equatable, Sendable {
    public private(set) var showingHand = false

    public init() {}

    public mutating func update(overLink: Bool, overTerminal: Bool) -> LinkCursorAction {
        if overLink {
            showingHand = true
            return .pointingHand
        }
        guard showingHand else { return .none }
        showingHand = false
        return overTerminal ? .iBeam : .arrow
    }
}
