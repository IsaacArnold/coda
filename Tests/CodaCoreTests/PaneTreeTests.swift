// Tests/CodaCoreTests/PaneTreeTests.swift
import XCTest
@testable import CodaCore

final class PaneTreeTests: XCTestCase {
    private func ids(_ t: PaneTree<String>) -> [String] { t.leaves.map { $0.id } }

    func testStartsAsSingleFocusedLeaf() {
        let t = PaneTree(rootID: "A", "hA")
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t.focusedLeafID, "A")
        XCTAssertEqual(t.focusedLeaf, "hA")
        XCTAssertEqual(ids(t), ["A"])
    }

    func testSplitFocusedAddsLeafAfterAndFocusesIt() {
        let t = PaneTree(rootID: "A", "hA")
        t.splitFocused(axis: .horizontal, newID: "B", newLeaf: "hB")
        XCTAssertEqual(ids(t), ["A", "B"])     // in-order: a then b
        XCTAssertEqual(t.focusedLeafID, "B")   // new pane focused
        XCTAssertEqual(t.count, 2)
    }

    func testNestedSplitBuildsTree() {
        // A | B, then split B downward → A | (B / C)
        let t = PaneTree(rootID: "A", "hA")
        t.splitFocused(axis: .horizontal, newID: "B", newLeaf: "hB")  // focus B
        t.splitFocused(axis: .vertical, newID: "C", newLeaf: "hC")    // splits B
        XCTAssertEqual(ids(t), ["A", "B", "C"])
        XCTAssertEqual(t.focusedLeafID, "C")
        // Root is a horizontal split: a = leaf A, b = vertical split (B, C)
        guard case let .split(axis, a, b, _) = t.root else { return XCTFail("root not split") }
        XCTAssertEqual(axis, .horizontal)
        guard case .leaf(let aid, _) = a else { return XCTFail("a not leaf") }
        XCTAssertEqual(aid, "A")
        guard case .split(let inner, _, _, _) = b else { return XCTFail("b not split") }
        XCTAssertEqual(inner, .vertical)
    }

    func testCloseCollapsesParentIntoSibling() {
        let t = PaneTree(rootID: "A", "hA")
        t.splitFocused(axis: .horizontal, newID: "B", newLeaf: "hB")
        let remaining = t.close(id: "B")
        XCTAssertTrue(remaining)
        XCTAssertEqual(ids(t), ["A"])
        // Root collapsed back to a bare leaf.
        guard case .leaf(let id, _) = t.root else { return XCTFail("root not leaf") }
        XCTAssertEqual(id, "A")
    }

    func testClosingFocusedRefocusesSurvivor() {
        let t = PaneTree(rootID: "A", "hA")
        t.splitFocused(axis: .horizontal, newID: "B", newLeaf: "hB")  // focus B
        _ = t.close(id: "B")
        XCTAssertEqual(t.focusedLeafID, "A")
    }

    func testClosingNonFocusedKeepsFocus() {
        let t = PaneTree(rootID: "A", "hA")
        t.splitFocused(axis: .horizontal, newID: "B", newLeaf: "hB")  // focus B
        t.setFocus(id: "A")
        _ = t.close(id: "B")
        XCTAssertEqual(t.focusedLeafID, "A")
    }

    func testClosingOnlyLeafReportsEmpty() {
        let t = PaneTree(rootID: "A", "hA")
        XCTAssertFalse(t.close(id: "A"))   // nothing left
    }

    func testNestedCloseRefocusesIntoSiblingSubtree() {
        // A | (B / C), focus on C; close C → A | B, focus B
        let t = PaneTree(rootID: "A", "hA")
        t.splitFocused(axis: .horizontal, newID: "B", newLeaf: "hB")
        t.splitFocused(axis: .vertical, newID: "C", newLeaf: "hC")    // focus C
        _ = t.close(id: "C")
        XCTAssertEqual(ids(t), ["A", "B"])
        XCTAssertEqual(t.focusedLeafID, "B")
        guard case .split(.horizontal, _, let b, _) = t.root else { return XCTFail("root not h-split") }
        guard case .leaf(let bid, _) = b else { return XCTFail("b not leaf") }
        XCTAssertEqual(bid, "B")
    }

    func testSetFocusUnknownIsNoOp() {
        let t = PaneTree(rootID: "A", "hA")
        t.setFocus(id: "ghost")
        XCTAssertEqual(t.focusedLeafID, "A")
    }

    func testLeafLookup() {
        let t = PaneTree(rootID: "A", "hA")
        t.splitFocused(axis: .horizontal, newID: "B", newLeaf: "hB")
        XCTAssertEqual(t.leaf(id: "A"), "hA")
        XCTAssertEqual(t.leaf(id: "B"), "hB")
        XCTAssertNil(t.leaf(id: "Z"))
    }
}
