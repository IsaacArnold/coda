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

    /// Move hover to `row` (nil for "no row"), given the outline's current `rowCount`.
    /// Returns the row indices whose highlight changed and therefore need redrawing —
    /// empty when hover didn't actually move. On a move between rows the vacated row is
    /// returned first, then the entered one.
    ///
    /// `row` is normalized against `rowCount` before anything else: negative, or
    /// `>= rowCount`, is treated as "no row hovered" (same as `nil`), and a `rowCount`
    /// of 0 means nothing can be hovered. The returned list is further filtered to rows
    /// that are valid right now (`0..<rowCount`) — a row that was hovered before the
    /// outline shrank out from under it no longer exists, so there's nothing to redraw
    /// there; handing back a stale index would crash a caller that feeds it straight to
    /// `NSOutlineView.rowView(atRow:)`.
    public mutating func update(to row: Int?, rowCount: Int) -> [Int] {
        let normalized: Int? = row.flatMap { $0 >= 0 && $0 < rowCount ? $0 : nil }
        guard normalized != hoveredRow else { return [] }
        let vacated = hoveredRow
        hoveredRow = normalized
        return [vacated, normalized].compactMap { $0 }.filter { $0 >= 0 && $0 < rowCount }
    }
}
