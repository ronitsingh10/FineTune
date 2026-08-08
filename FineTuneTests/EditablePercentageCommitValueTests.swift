// FineTuneTests/EditablePercentageCommitValueTests.swift
// Tests the pure commit-validation shared by Return-key and click-outside dismissal.
import Testing
@testable import FineTune

@Suite("EditablePercentage.committedValue — pure commit validation")
struct EditablePercentageCommitValueTests {
    @Test("plain integer in range commits")
    func plainInteger() {
        #expect(EditablePercentage.committedValue(from: "50", in: 0...400) == 50)
    }
    @Test("trailing percent sign is stripped")
    func trailingPercent() {
        #expect(EditablePercentage.committedValue(from: "50%", in: 0...400) == 50)
    }
    @Test("whitespace is trimmed before parsing")
    func whitespaceTrimmed() {
        #expect(EditablePercentage.committedValue(from: "  73 ", in: 0...400) == 73)
    }
    @Test("out-of-range value is discarded (nil)")
    func outOfRange() {
        #expect(EditablePercentage.committedValue(from: "500", in: 0...400) == nil)
    }
    @Test("non-numeric input is discarded (nil)")
    func nonNumeric() {
        #expect(EditablePercentage.committedValue(from: "abc", in: 0...400) == nil)
    }
    @Test("empty string is discarded (nil)")
    func empty() {
        #expect(EditablePercentage.committedValue(from: "", in: 0...400) == nil)
    }
}
