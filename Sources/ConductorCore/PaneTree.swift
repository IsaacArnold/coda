import Foundation

/// A binary tree of terminal panes inside one surface tab. Generic over `Leaf` (the shell
/// stores a `TerminalSurface`). Pure so split/close/collapse/focus logic is unit-testable.
public final class PaneTree<Leaf> {
    public indirect enum Node {
        case leaf(id: String, Leaf)
        case split(axis: SplitAxis, a: Node, b: Node, ratio: Double)
    }

    public private(set) var root: Node
    public private(set) var focusedLeafID: String

    public init(rootID: String, _ leaf: Leaf) {
        root = .leaf(id: rootID, leaf)
        focusedLeafID = rootID
    }

    public var count: Int { Self.leavesOf(root).count }
    public var leaves: [(id: String, leaf: Leaf)] { Self.leavesOf(root) }

    public func leaf(id: String) -> Leaf? { leaves.first { $0.id == id }?.leaf }
    public var focusedLeaf: Leaf? { leaf(id: focusedLeafID) }

    public func setFocus(id: String) {
        if leaves.contains(where: { $0.id == id }) { focusedLeafID = id }
    }

    /// Replace the focused leaf with a split of {focused, new}; the new leaf takes the `b`
    /// slot and becomes focused.
    public func splitFocused(axis: SplitAxis, newID: String, newLeaf: Leaf, ratio: Double = 0.5) {
        let target = focusedLeafID
        root = Self.replacingLeaf(root, id: target) { existing in
            .split(axis: axis, a: existing, b: .leaf(id: newID, newLeaf), ratio: ratio)
        }
        focusedLeafID = newID
    }

    /// Remove a leaf; collapse the now-only-child split into its parent. Returns false if the
    /// tree is now empty (the closed leaf was the only one). When the focused leaf is closed,
    /// focus moves to its SIBLING subtree's first leaf (not just the first leaf overall).
    @discardableResult
    public func close(id: String) -> Bool {
        if case let .leaf(rootID, _) = root {
            return rootID == id ? false : true   // closing the lone leaf empties the tab
        }
        guard leaves.contains(where: { $0.id == id }) else { return true }
        let refocusTo = (focusedLeafID == id) ? Self.siblingFirstLeaf(root, id: id) : focusedLeafID
        root = Self.removingLeaf(root, id: id)
        focusedLeafID = refocusTo ?? Self.leavesOf(root).first?.id ?? focusedLeafID
        return true
    }

    // MARK: - recursion helpers

    private static func leavesOf(_ node: Node) -> [(id: String, leaf: Leaf)] {
        switch node {
        case let .leaf(id, leaf): return [(id, leaf)]
        case let .split(_, a, b, _): return leavesOf(a) + leavesOf(b)
        }
    }

    /// The first leaf of the sibling of the leaf `id` — where focus goes when `id` is closed.
    private static func siblingFirstLeaf(_ node: Node, id: String) -> String? {
        switch node {
        case .leaf:
            return nil
        case let .split(_, a, b, _):
            if case let .leaf(lid, _) = a, lid == id { return leavesOf(b).first?.id }
            if case let .leaf(lid, _) = b, lid == id { return leavesOf(a).first?.id }
            return siblingFirstLeaf(a, id: id) ?? siblingFirstLeaf(b, id: id)
        }
    }

    private static func replacingLeaf(_ node: Node, id: String,
                                      _ transform: (Node) -> Node) -> Node {
        switch node {
        case .leaf(let lid, _):
            return lid == id ? transform(node) : node
        case let .split(axis, a, b, ratio):
            return .split(axis: axis,
                          a: replacingLeaf(a, id: id, transform),
                          b: replacingLeaf(b, id: id, transform),
                          ratio: ratio)
        }
    }

    /// Remove the leaf with `id`; a split that loses one child collapses to its survivor.
    /// NOTE the `case let .leaf(lid, _) = …, lid == id` form: `case .leaf(id, _)` would BIND
    /// a new `id` (shadowing the parameter) instead of comparing against it — a Swift gotcha.
    private static func removingLeaf(_ node: Node, id: String) -> Node {
        switch node {
        case .leaf:
            return node   // not the target (caller guarantees target exists below a split)
        case let .split(axis, a, b, ratio):
            if case let .leaf(lid, _) = a, lid == id { return b }   // a was the target → sibling survives
            if case let .leaf(lid, _) = b, lid == id { return a }   // b was the target → sibling survives
            return .split(axis: axis, a: removingLeaf(a, id: id), b: removingLeaf(b, id: id), ratio: ratio)
        }
    }
}
