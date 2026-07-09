import AppKit
import CodaCore

/// Native-chrome completion dropdown, anchored at the terminal cursor. Hosted as a plain
/// subview of `ClickableTerminalView` (mirrors `DropHighlightOverlay` in that file): it never
/// intercepts mouse events (`hitTest` → nil everywhere) so the terminal keeps normal input,
/// focus, ⌘+click, drag, and ⌘K behavior untouched.
///
/// **Display-only in this task (Task 9):** `selectedIndex` is driven programmatically (always
/// `0` on a fresh `show`). Keyboard navigation/accept lands in Task 10, which will mutate
/// `selectedIndex` directly as the user presses arrow keys — the `didSet` here already restyles
/// + scrolls the newly-selected row into view, so Task 10 needs no further plumbing on this view.
final class CompletionPopupView: NSView {
    /// Rows visible before the list scrolls.
    static let maxVisibleRows = 8
    static let rowHeight: CGFloat = 20
    static let minWidth: CGFloat = 160
    static let maxWidth: CGFloat = 480
    /// Horizontal padding inside each row (mirrored on both sides of the widest-row measurement
    /// in `preferredSize(for:)` and the live row layout in `CompletionRowView`).
    static let horizontalInset: CGFloat = 8
    static let cornerRadius: CGFloat = 6

    private let effectView = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let documentView = CompletionPopupDocumentView()
    private var rowViews: [CompletionRowView] = []

    /// The currently-highlighted row. Setting this (Task 10, on arrow-key nav) restyles the
    /// affected rows and scrolls the new selection into view; setting it to its current value
    /// is a no-op. `show(...)` also clamps/applies this for a freshly-built row set.
    var selectedIndex: Int = 0 {
        didSet {
            guard selectedIndex != oldValue else { return }
            applySelection()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        effectView.material = .menu
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = Self.cornerRadius
        effectView.layer?.masksToBounds = true
        effectView.autoresizingMask = [.width, .height]
        effectView.frame = bounds
        addSubview(effectView)

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.autoresizingMask = [.width, .height]
        scrollView.frame = bounds
        scrollView.documentView = documentView
        addSubview(scrollView)

        // Rounded corners on the whole popup (the effect view clips its own material, but the
        // scroll view sits on top of it and would otherwise draw square corners over it).
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true

        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Never intercepts mouse events — the terminal underneath keeps normal click/drag/focus
    /// behavior even while the popup is visible. A single override here is enough (AppKit's
    /// default hit-testing on the *parent* calls this directly rather than recursing into our
    /// subviews), same pattern as `DropHighlightOverlay`.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Pure size computation the host (`ClickableTerminalView`) uses to size *and position* the
    /// popup's frame BEFORE calling `show` — positioning (incl. the bottom-of-screen flip) needs
    /// to know the height up front. `show` reuses this same function so the two can never
    /// disagree about how big the popup is for a given candidate set.
    ///
    /// Width is the widest row (name + description, measured with the same fonts the rows
    /// render with) clamped to `minWidth...maxWidth`; over-width content truncates with a tail
    /// ellipsis at render time (`CompletionRowView`), it never grows the popup past `maxWidth`.
    /// Height is `rowHeight * min(count, maxVisibleRows)` — beyond 8 rows the list scrolls
    /// instead of growing taller.
    static func preferredSize(for candidates: [Candidate]) -> CGSize {
        guard !candidates.isEmpty else { return .zero }
        let nameFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let descriptionFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        var contentWidth: CGFloat = 0
        for candidate in candidates {
            var width = (candidate.name as NSString)
                .size(withAttributes: [.font: nameFont]).width
            if let description = candidate.description, !description.isEmpty {
                width += CompletionRowView.nameDescriptionSpacing
                width += (description as NSString)
                    .size(withAttributes: [.font: descriptionFont]).width
            }
            contentWidth = max(contentWidth, width)
        }

        let width = min(maxWidth, max(minWidth, contentWidth + horizontalInset * 2))
        let visibleRows = min(candidates.count, maxVisibleRows)
        return CGSize(width: width, height: CGFloat(visibleRows) * rowHeight)
    }

    /// Populates the popup with `candidates` and shows it. Idempotent and safe to call on every
    /// cursor move / candidate refresh: it always rebuilds the row views from scratch (candidate
    /// identity/order can change between calls even at the same count) and re-applies
    /// `selectedIndex` (clamped into range) to the new rows.
    ///
    /// `anchorCell` isn't used for layout here — the host already positioned this view's `frame`
    /// (via `preferredSize(for:)` + its own cursor→point math) before calling this. It's threaded
    /// through the interface for symmetry with the host's anchor bookkeeping and so a future pass
    /// (e.g. re-deriving position without a full reposition call) has it available.
    ///
    /// Silent-off: an empty candidate list or a degenerate (zero) frame hides instead of showing.
    func show(candidates: [Candidate], anchorCell: (col: Int, row: Int), selectedIndex: Int) {
        guard !candidates.isEmpty, bounds.width > 0, bounds.height > 0 else {
            hide()
            return
        }

        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = candidates.map { CompletionRowView(candidate: $0) }
        for (index, row) in rowViews.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(index) * Self.rowHeight,
                               width: bounds.width, height: Self.rowHeight)
            documentView.addSubview(row)
        }
        documentView.frame = NSRect(x: 0, y: 0, width: bounds.width,
                                    height: CGFloat(candidates.count) * Self.rowHeight)
        scrollView.hasVerticalScroller = candidates.count > Self.maxVisibleRows

        let clamped = max(0, min(selectedIndex, candidates.count - 1))
        if clamped == self.selectedIndex {
            // `didSet` only fires on a change; the rows are new objects either way, so restyle
            // explicitly to cover the "still selecting index 0 on a fresh candidate set" case.
            applySelection()
        } else {
            self.selectedIndex = clamped
        }
        isHidden = false
    }

    /// Hides the popup. Safe to call redundantly (e.g. from `CompletionController.onHide` firing
    /// more than once, or before the popup was ever shown).
    func hide() {
        isHidden = true
    }

    private func applySelection() {
        for (index, row) in rowViews.enumerated() {
            row.isSelected = index == selectedIndex
        }
        guard rowViews.indices.contains(selectedIndex) else { return }
        rowViews[selectedIndex].scrollToVisible(rowViews[selectedIndex].bounds)
    }
}

/// The completion popup's scroll-view document view. Flipped so row 0 sits at the top and rows
/// stack downward in index order (0 = best-ranked match) — the natural reading order, and what
/// keeps `CompletionPopupView.show`'s per-row `y = index * rowHeight` math simple. `hitTest`
/// returns nil for the same reason as the popup itself: never steals events from the terminal.
private final class CompletionPopupDocumentView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One candidate row: `name` in the system font (primary label color), plus `description` (if
/// any) dimmed and smaller, tail-truncated if the popup's capped width can't fit it. The selected
/// row gets a full-width tinted highlight and switches both labels to the "on accent" text colors
/// a native menu uses for its selected item.
private final class CompletionRowView: NSView {
    /// Gap between the name and description segments of the row's attributed string; also used
    /// by `CompletionPopupView.preferredSize(for:)` so width measurement matches what's rendered.
    static let nameDescriptionSpacing: CGFloat = 8

    private let candidate: Candidate
    private let highlight = NSView()
    private let label = NSTextField(labelWithString: "")

    var isSelected: Bool = false {
        didSet {
            guard isSelected != oldValue else { return }
            applyStyle()
        }
    }

    init(candidate: Candidate) {
        self.candidate = candidate
        super.init(frame: .zero)

        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 4
        highlight.isHidden = true
        addSubview(highlight)

        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        addSubview(label)

        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        highlight.frame = bounds.insetBy(dx: 4, dy: 1)
        let inset = CompletionPopupView.horizontalInset
        let labelHeight = min(bounds.height, label.intrinsicContentSize.height)
        let y = (bounds.height - labelHeight) / 2
        label.frame = NSRect(x: inset, y: y,
                             width: max(0, bounds.width - inset * 2), height: labelHeight)
    }

    private func applyStyle() {
        highlight.isHidden = !isSelected
        highlight.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.cgColor

        let nameColor: NSColor = isSelected ? .selectedMenuItemTextColor : .labelColor
        let descriptionColor: NSColor = isSelected
            ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.8)
            : .secondaryLabelColor

        let text = NSMutableAttributedString(
            string: candidate.name,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: nameColor,
            ]
        )
        if let description = candidate.description, !description.isEmpty {
            text.append(NSAttributedString(
                string: String(repeating: " ", count: 2) + description,
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: descriptionColor,
                ]
            ))
        }
        label.attributedStringValue = text
    }
}
