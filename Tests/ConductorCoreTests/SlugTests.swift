import Testing
@testable import ConductorCore

@Test func slugifyLowercasesAndHyphenates() {
    #expect(slugify("Add Login Flow") == "add-login-flow")
}

@Test func slugifyStripsPunctuationAndCollapsesDashes() {
    #expect(slugify("Fix: the @bug!! (urgent)") == "fix-the-bug-urgent")
}

@Test func slugifyFallsBackWhenEmpty() {
    #expect(slugify("!!!") == "session")
}
