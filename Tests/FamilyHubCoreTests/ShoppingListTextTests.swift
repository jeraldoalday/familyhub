import Foundation
import Testing

@testable import FamilyHubCore

/// Covers turning a list back into text: what a message says, and what
/// survives being pasted into another household's app.
@Suite("Shopping list as text")
struct ShoppingListTextTests {

    // MARK: Fixture

    private let calendar = Calendar.testDefault
    private let householdID = Identifier<Household>()
    private let listID = Identifier<ShoppingList>()
    private let alex = Identifier<Member>()

    private func date(_ hour: Int = 9) -> Date {
        FixedDateProvider(year: 2026, month: 3, day: 2, hour: hour, calendar: calendar).now
    }

    private func item(
        _ name: String,
        quantity: Int = 1,
        unit: String? = nil,
        category: ShoppingItem.Category = .other,
        note: String? = nil,
        purchased: Bool = false,
        addedAt: Int = 9
    ) throws -> ShoppingItem {
        try ShoppingItem(
            listID: listID,
            householdID: householdID,
            name: name,
            quantity: quantity,
            unit: unit,
            category: category,
            note: note,
            addedBy: alex,
            addedAt: date(addedAt),
            purchase: purchased ? .init(by: alex, at: date(17)) : nil
        )
    }

    private func list(emoji: String? = nil) throws -> ShoppingList {
        try ShoppingList(
            id: listID,
            householdID: householdID,
            name: "Groceries",
            emoji: emoji,
            createdBy: alex,
            createdAt: date()
        )
    }

    // MARK: What a message says

    @Test("Items are grouped under their aisle, in shop order")
    func groupsUnderAisleHeadings() throws {
        let items = [
            try item("Milk", category: .dairy),
            try item("Bread", category: .bakery),
            try item("Cheddar", category: .dairy),
        ]

        let text = ShoppingListText.render(items)

        #expect(
            text == """
                Bakery
                Bread

                Dairy
                Cheddar
                Milk
                """
        )
    }

    @Test("The list's name and emoji head the message")
    func headingNamesTheList() throws {
        let text = ShoppingListText.render(
            [try item("Milk", category: .dairy)],
            from: try list(emoji: "🛒")
        )

        #expect(text.hasPrefix("🛒 Groceries\n\n"))
    }

    @Test("A quantity of one is left off unless a unit needs it")
    func quantityIsOmittedWhenItSaysNothing() throws {
        // "1 Milk" is not how anybody writes a list, and "kg Potatoes" is not a
        // sentence.
        let items = [
            try item("Milk"),
            try item("Potatoes", quantity: 1, unit: "kg"),
            try item("Lemons", quantity: 3),
            try item("Wine", quantity: 2, unit: "bottles"),
        ]

        let text = ShoppingListText.render(items, options: .interchange)

        #expect(
            text == """
                3 Lemons
                Milk
                1 kg Potatoes
                2 bottles Wine
                """
        )
    }

    @Test("A note travels in a message and is left out of an interchange")
    func notesAreOptional() throws {
        let items = [try item("Milk", note: "the oat one")]

        #expect(ShoppingListText.render(items).contains("Milk (the oat one)"))
        #expect(ShoppingListText.render(items, options: .interchange) == "Milk")
    }

    @Test("Bought items are left out unless they are asked for")
    func purchasedItemsAreLeftOut() throws {
        // The person reading this is standing in a shop; a list of things they
        // do not need is a list they have to read anyway.
        let items = [
            try item("Milk", category: .dairy),
            try item("Bread", category: .bakery, purchased: true),
        ]

        #expect(!ShoppingListText.render(items).contains("Bread"))

        let everything = ShoppingListText.render(
            items,
            options: ShoppingListText.Options(includesPurchased: true)
        )
        #expect(everything.contains("✓ Bread"))
    }

    @Test("Nothing to buy renders as nothing at all")
    func emptyListRendersEmpty() throws {
        // Only the caller knows whether this is a message that needs a sentence
        // or a pasteboard that should stay untouched.
        #expect(ShoppingListText.render([try item("Milk", purchased: true)]).isEmpty)
        #expect(ShoppingListText.render([ShoppingItem]()).isEmpty)
    }

    @Test("There is no stray blank line after the last aisle")
    func noTrailingBlankLine() throws {
        let text = ShoppingListText.render([try item("Milk", category: .dairy)])

        #expect(!text.hasSuffix("\n"))
    }

    // MARK: Round trip

    @Test("An interchange list pastes back in as the same shopping")
    func interchangeSurvivesAReimport() throws {
        // The point of the flat style: a list sent to somebody who does have
        // the app is a list they can paste rather than retype.
        let items = [
            try item("Potatoes", quantity: 2, unit: "kg", category: .produce),
            try item("Milk", quantity: 3, category: .dairy),
            try item("Bánh mì rolls", category: .bakery),
        ]

        let text = ShoppingListText.render(items, options: .interchange)
        let drafts = ShoppingListParser.drafts(from: text)

        #expect(drafts.count == 3)
        let byName = Dictionary(uniqueKeysWithValues: drafts.map { ($0.name, $0) })
        #expect(byName["Potatoes"]?.quantity == 2)
        #expect(byName["Potatoes"]?.unit == "kg")
        #expect(byName["Potatoes"]?.category == .produce)
        #expect(byName["Milk"]?.quantity == 3)
        #expect(byName["Milk"]?.category == .dairy)
        #expect(byName["Bánh mì rolls"]?.category == .bakery)
    }

    @Test("A single item with no quantity round-trips unchanged")
    func plainItemRoundTrips() throws {
        let text = ShoppingListText.render([try item("Kitchen roll")], options: .interchange)
        let draft = try #require(ShoppingListParser.drafts(from: text).first)

        #expect(draft.name == "Kitchen roll")
        #expect(draft.quantity == 1)
        #expect(draft.unit == nil)
    }

    // MARK: From a snapshot

    @Test("A household renders one of its lists by identifier")
    func snapshotRendersAList() throws {
        let household = try Household(name: "The Aldays", timeZone: .gmt, createdAt: date())
        let otherListID = Identifier<ShoppingList>()
        let groceries = try ShoppingList(
            id: listID, householdID: household.id, name: "Groceries",
            createdBy: alex, createdAt: date()
        )
        let hardware = try ShoppingList(
            id: otherListID, householdID: household.id, name: "Hardware",
            createdBy: alex, createdAt: date()
        )
        let snapshot = HouseholdSnapshot(
            household: household,
            shoppingLists: [groceries, hardware],
            shoppingItems: [
                try item("Milk", category: .dairy),
                try ShoppingItem(
                    listID: otherListID, householdID: household.id, name: "Screws",
                    addedBy: alex, addedAt: date()
                ),
            ]
        )

        let text = snapshot.shoppingListText(for: listID)

        #expect(text.contains("Groceries"))
        #expect(text.contains("Milk"))
        // The other list's shopping is not this list's shopping.
        #expect(!text.contains("Screws"))
    }

    @Test("A list another device deleted renders as nothing, not as an error")
    func missingListRendersEmpty() throws {
        let household = try Household(name: "The Aldays", timeZone: .gmt, createdAt: date())
        let snapshot = HouseholdSnapshot(household: household)

        #expect(snapshot.shoppingListText(for: listID).isEmpty)
    }
}
