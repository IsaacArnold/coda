import XCTest
@testable import CodaCore

final class IdentityHueTests: XCTestCase {
    func testEightHues() {
        XCTAssertEqual(IdentityHue.allCases.count, 8)
    }

    func testAssignmentOrderIsHueSpreadMatchingRetiredPalette() {
        // Matches the retired IdentityPalette order so neighbours differ and
        // upgrading users' auto-assigned colours land on the same hues.
        XCTAssertEqual(IdentityHue.assignmentOrder,
                       [.purple, .green, .pink, .cyan, .orange, .blue, .yellow, .red])
    }

    func testAutoAssignedCyclesByIndex() {
        XCTAssertEqual(IdentityHue.autoAssigned(index: 0), .purple)
        XCTAssertEqual(IdentityHue.autoAssigned(index: 1), .green)
        XCTAssertEqual(IdentityHue.autoAssigned(index: 7), .red)
        XCTAssertEqual(IdentityHue.autoAssigned(index: 8), .purple) // wraps
    }

    func testAutoAssignedHandlesNegativeIndex() {
        XCTAssertEqual(IdentityHue.autoAssigned(index: -1), .red)
    }
}
