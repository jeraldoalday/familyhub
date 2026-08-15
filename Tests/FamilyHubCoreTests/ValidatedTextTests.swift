import Foundation
import Testing

@testable import FamilyHubCore

@Suite("Validated text")
struct ValidatedTextTests {

    @Test("Trims surrounding whitespace")
    func trimsWhitespace() throws {
        let text = try ValidatedText("  Take out the bins \n", field: .choreTitle)
        #expect(text.value == "Take out the bins")
    }

    @Test("Rejects blank input", arguments: ["", " ", "\n", "\t  \n "])
    func rejectsBlank(_ raw: String) {
        #expect(throws: DomainError.blank(field: .memberName)) {
            _ = try ValidatedText(raw, field: .memberName)
        }
    }

    @Test("Rejects input over the limit")
    func rejectsTooLong() {
        let raw = String(repeating: "a", count: 41)
        #expect(throws: DomainError.tooLong(field: .memberName, limit: 40)) {
            _ = try ValidatedText(raw, field: .memberName, limit: 40)
        }
    }

    @Test("Accepts input exactly at the limit")
    func acceptsBoundary() throws {
        let raw = String(repeating: "a", count: 40)
        let text = try ValidatedText(raw, field: .memberName, limit: 40)
        #expect(text.value.count == 40)
    }

    @Test("Measures length in characters, not bytes")
    func measuresGraphemeClusters() throws {
        // Ten emoji are ten characters to a person and forty bytes to UTF-8.
        // Validating on bytes would reject a title a user considers short.
        let raw = String(repeating: "🧺", count: 10)
        let text = try ValidatedText(raw, field: .choreTitle, limit: 10)
        #expect(text.value == raw)
    }

    @Test("Search key folds case and diacritics")
    func foldsForSearch() throws {
        let text = try ValidatedText("Bánh Mì", field: .itemName)
        #expect(text.searchKey == "banh mi")
    }

    @Test("Optional text maps blank input to nil")
    func optionalBlankIsNil() throws {
        #expect(try ValidatedText.optional(nil, field: .choreNotes) == nil)
        #expect(try ValidatedText.optional("   ", field: .choreNotes) == nil)
    }

    @Test("Optional text still enforces the limit")
    func optionalEnforcesLimit() {
        #expect(throws: DomainError.tooLong(field: .choreNotes, limit: 5)) {
            _ = try ValidatedText.optional("far too long", field: .choreNotes, limit: 5)
        }
    }

    @Test("Numeric validation reports the allowed range")
    func numericRange() throws {
        #expect(throws: DomainError.outOfRange(field: .points, allowed: 0...500)) {
            _ = try 501.validated(in: Limits.pointsPerChore, field: .points)
        }
        let atLimit = try 500.validated(in: Limits.pointsPerChore, field: .points)
        #expect(atLimit == 500)
    }
}
