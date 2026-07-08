import XCTest
@testable import CodaCore

/// Tests the pure visibility gate. Each failing-condition test starts from a fully-passing
/// baseline and flips exactly one input, so a green means "this one condition, on its own,
/// suppresses the popup". The two passing tests cover the two independent ways to satisfy the
/// query condition (a non-empty query, or an empty query after a command + separator).
final class CompletionGateTests: XCTestCase {
    /// A set of inputs that, together, make the gate return true — the reference "show" state
    /// every failing-condition test perturbs by exactly one field.
    private func passing(
        phase: PromptPhase = .atPrompt,
        isFocused: Bool = true,
        isScrolledToBottom: Bool = true,
        isSuppressed: Bool = false,
        query: String = "ch",
        endsWithSeparator: Bool = false,
        hasCommandToken: Bool = true,
        rankedCount: Int = 3
    ) -> Bool {
        shouldShowCompletions(
            phase: phase, isFocused: isFocused, isScrolledToBottom: isScrolledToBottom,
            isSuppressed: isSuppressed, query: query, endsWithSeparator: endsWithSeparator,
            hasCommandToken: hasCommandToken, rankedCount: rankedCount
        )
    }

    // MARK: - Passing cases

    func testShowsWithNonEmptyQuery() {
        XCTAssertTrue(passing())
    }

    func testShowsWithEmptyQueryAfterCommandAndSeparator() {
        // e.g. `git ` — empty query, but a committed command token + trailing separator.
        XCTAssertTrue(passing(query: "", endsWithSeparator: true, hasCommandToken: true))
    }

    // MARK: - Failing conditions (one flipped field each)

    func testHiddenWhenNotAtPrompt() {
        XCTAssertFalse(passing(phase: .executing))
        XCTAssertFalse(passing(phase: .unknown))
    }

    func testHiddenWhenUnfocused() {
        XCTAssertFalse(passing(isFocused: false))
    }

    func testHiddenWhenScrolledUp() {
        XCTAssertFalse(passing(isScrolledToBottom: false))
    }

    func testHiddenWhenSuppressed() {
        XCTAssertFalse(passing(isSuppressed: true))
    }

    func testHiddenWhenNoCandidates() {
        XCTAssertFalse(passing(rankedCount: 0))
    }

    func testHiddenWhenEmptyQueryAndNoSeparator() {
        XCTAssertFalse(passing(query: "", endsWithSeparator: false, hasCommandToken: true))
    }

    func testHiddenWhenEmptyQueryAndSeparatorButNoCommand() {
        // A bare prompt with only a trailing space must not spuriously trigger.
        XCTAssertFalse(passing(query: "", endsWithSeparator: true, hasCommandToken: false))
    }
}
