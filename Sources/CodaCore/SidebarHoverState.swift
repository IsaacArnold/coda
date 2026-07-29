import Foundation

/// Tracks which sidebar row the pointer is over. Pure bookkeeping — no AppKit — so the
/// hover logic is unit-testable away from the mouse-tracking plumbing that drives it.
///
/// Callers report the row under the pointer (`nil` = none) and get back the rows whose
/// highlight changed, so only those rows are repainted. Deliberately NOT a reload: the
/// sidebar's selection and the terminal's focus must be untouched by mere hovering.
public struct SidebarHoverState: Equatable {
    /// The row currently under the pointer, or nil when the pointer is elsewhere.
    public private(set) var hoveredRow: Int?

    public init() {}

    /// Move hover to `row` (nil for "no row"). Returns the row indices whose highlight
    /// changed and therefore need redrawing — empty when hover didn't actually move.
    /// On a move between rows the vacated row is returned first, then the entered one.
    public mutating func update(to row: Int?) -> [Int] {
        guard row != hoveredRow else { return [] }
        let vacated = hoveredRow
        hoveredRow = row
        return [vacated, row].compactMap { $0 }
    }
}
