import Foundation
import Testing

@testable import FamilyHubCore

/// Covers reading a pasted shopping list. The cases that matter are the ones
/// that come out of a real notes app: bullets, numbering, checkboxes, and
/// quantities written four different ways by four different people.
@Suite("Pasted shopping lists")
struct ShoppingListParserTests {

    // MARK: One line at a time

    @Test("A bare name is one of that thing")
    func plainName() throws {
        let draft = try #require(ShoppingListParser.draft(from: "  Milk  "))
        #expect(draft.name == "Milk")
        #expect(draft.quantity == 1)
        #expect(draft.unit == nil)
        #expect(draft.category == .dairy)
        #expect(draft.source == "Milk")
    }

    @Test("A leading number is a quantity, however it is written")
    func leadingQuantities() throws {
        for line in ["2 milk", "2x milk", "2 x milk", "2 × milk"] {
            let draft = try #require(ShoppingListParser.draft(from: line), "\(line)")
            #expect(draft.quantity == 2, "\(line)")
            #expect(draft.name == "milk", "\(line)")
        }
    }

    @Test("A trailing count is a quantity too")
    func trailingQuantities() throws {
        let draft = try #require(ShoppingListParser.draft(from: "Milk x2"))
        #expect(draft.quantity == 2)
        #expect(draft.name == "Milk")
    }

    @Test("A unit after the number is a unit, not part of the name")
    func unitsAreLifted() throws {
        let draft = try #require(ShoppingListParser.draft(from: "2 bottles of milk"))
        #expect(draft.quantity == 2)
        #expect(draft.unit == "bottles")
        #expect(draft.name == "milk")
        #expect(draft.category == .dairy)
    }

    @Test("A unit with nothing after it is the thing being bought")
    func unitAloneIsAName() throws {
        // "2 bottles" means two bottles. Lifting the unit here would leave a
        // row with a quantity, a unit, and no item.
        let draft = try #require(ShoppingListParser.draft(from: "2 bottles"))
        #expect(draft.quantity == 2)
        #expect(draft.unit == nil)
        #expect(draft.name == "bottles")
    }

    @Test("An unusual unit stays part of the name rather than being invented")
    func unknownUnitsStayInTheName() throws {
        let draft = try #require(ShoppingListParser.draft(from: "2 sprigs rosemary"))
        #expect(draft.unit == nil)
        #expect(draft.name == "sprigs rosemary")
    }

    // MARK: What a notes app leaves behind

    @Test("Bullets and dashes are stripped")
    func bulletsAreStripped() throws {
        for line in ["- Milk", "* Milk", "• Milk", "  –   Milk", "+ Milk"] {
            let draft = try #require(ShoppingListParser.draft(from: line), "\(line)")
            #expect(draft.name == "Milk", "\(line)")
        }
    }

    @Test("Numbering is stripped but a quantity is not")
    func numberingIsStripped() throws {
        // The difference is the punctuation. "1." is a list; "2 milk" is two
        // of something.
        let numbered = try #require(ShoppingListParser.draft(from: "1. Milk"))
        #expect(numbered.name == "Milk")
        #expect(numbered.quantity == 1)

        let bracketed = try #require(ShoppingListParser.draft(from: "3) Bread"))
        #expect(bracketed.name == "Bread")
        #expect(bracketed.quantity == 1)

        let counted = try #require(ShoppingListParser.draft(from: "3 Bread"))
        #expect(counted.quantity == 3)
    }

    @Test("Checkboxes are stripped")
    func checkboxesAreStripped() throws {
        for line in ["[ ] Milk", "[x] Milk", "☐ Milk"] {
            let draft = try #require(ShoppingListParser.draft(from: line), "\(line)")
            #expect(draft.name == "Milk", "\(line)")
        }
    }

    @Test("A line with nothing to buy in it is skipped")
    func emptyLinesAreSkipped() {
        #expect(ShoppingListParser.draft(from: "") == nil)
        #expect(ShoppingListParser.draft(from: "   ") == nil)
        #expect(ShoppingListParser.draft(from: "- ") == nil)
        #expect(ShoppingListParser.draft(from: "4") == nil)
    }

    // MARK: A whole paste

    @Test("A pasted list becomes one draft per line, in order")
    func wholeList() {
        let drafts = ShoppingListParser.drafts(
            from: """
                - 2 pints milk
                Bread

                • 6 eggs
                1. Washing up liquid
                """
        )

        #expect(drafts.map(\.name) == ["milk", "Bread", "eggs", "Washing up liquid"])
        #expect(drafts.first?.unit == "pints")
        #expect(drafts.map(\.quantity) == [2, 1, 6, 1])
        #expect(drafts.map(\.category) == [.dairy, .bakery, .dairy, .household])
    }

    @Test("Semicolons separate items; commas do not")
    func separators() {
        // "Onion, red" and "Milk, the oat one" are how people write single
        // items, and splitting them produces two rows that are each wrong.
        let split = ShoppingListParser.drafts(from: "Milk; Bread")
        #expect(split.map(\.name) == ["Milk", "Bread"])

        let kept = ShoppingListParser.drafts(from: "Onion, red")
        #expect(kept.map(\.name) == ["Onion, red"])
    }

    @Test("The same thing twice in one paste is one row with the counts added")
    func repeatsAreMerged() {
        // A recipe pasted twice should not produce two rows of onions — and
        // here the count genuinely is a measurement rather than a guess.
        let drafts = ShoppingListParser.drafts(from: "2 onions\nBread\nONIONS")
        #expect(drafts.count == 2)
        #expect(drafts.first?.name == "onions")
        #expect(drafts.first?.quantity == 3)
    }

    @Test("A quantity nobody meant is clamped rather than losing the line")
    func absurdQuantitiesAreClamped() throws {
        // Somebody who wrote a thousand apples has made a typo, and refusing
        // the line loses the apples as well as the number.
        let draft = try #require(ShoppingListParser.draft(from: "1000 apples"))
        #expect(draft.quantity == Limits.itemQuantity.upperBound)
        #expect(draft.name == "apples")
    }

    @Test("A paste of a whole document is bounded")
    func pasteIsBounded() {
        let novel = (0..<500).map { "Item \($0)" }.joined(separator: "\n")
        #expect(ShoppingListParser.drafts(from: novel).count == ShoppingListParser.maximumLines)
    }

    @Test("Every draft is something a shopping item can actually be built from")
    func draftsAreConstructible() throws {
        // The parser is upstream of `ShoppingItem`, so anything it produces
        // that the initialiser would refuse is a row the person cannot add and
        // cannot see why.
        let drafts = ShoppingListParser.drafts(
            from: """
                2 pints milk
                1000 apples
                Bánh mì
                [x] 3) 12 x eggs
                """
        )
        #expect(!drafts.isEmpty)

        for draft in drafts {
            #expect(throws: Never.self) {
                try ShoppingItem(
                    listID: Identifier(),
                    householdID: Identifier(),
                    name: draft.name,
                    quantity: draft.quantity,
                    unit: draft.unit,
                    category: draft.category,
                    addedBy: Identifier(),
                    addedAt: Date(timeIntervalSince1970: 0)
                )
            }
        }
    }
}
