import Foundation
import Testing

@testable import FamilyHubCore

@Suite("Shopping lists")
struct ShoppingListTests {

    private let calendar = Calendar.testDefault
    private let householdID = Identifier<Household>()
    private let listID = Identifier<ShoppingList>()
    private let alex = Identifier<Member>()

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        FixedDateProvider(year: y, month: m, day: d, hour: hour, calendar: calendar).now
    }

    private func item(
        _ name: String,
        quantity: Int = 1,
        unit: String? = nil,
        category: ShoppingItem.Category = .other,
        purchased: Bool = false
    ) throws -> ShoppingItem {
        try ShoppingItem(
            listID: listID,
            householdID: householdID,
            name: name,
            quantity: quantity,
            unit: unit,
            category: category,
            addedBy: alex,
            addedAt: date(2026, 3, 2),
            purchase: purchased ? .init(by: alex, at: date(2026, 3, 2, hour: 17)) : nil
        )
    }

    // MARK: Validation

    @Test("Rejects a blank item name")
    func rejectsBlankName() {
        #expect(throws: DomainError.blank(field: .itemName)) {
            _ = try item("  ")
        }
    }

    @Test("Rejects a quantity outside the permitted range")
    func rejectsBadQuantity() {
        #expect(throws: DomainError.outOfRange(field: .quantity, allowed: Limits.itemQuantity)) {
            _ = try item("Milk", quantity: 0)
        }
    }

    @Test("A blank unit is stored as nil")
    func blankUnitIsDropped() throws {
        #expect(try item("Milk", unit: "   ").unit == nil)
        #expect(try item("Flour", unit: " kg ").unit == "kg")
    }

    @Test("Quantity description includes the unit when there is one")
    func quantityDescription() throws {
        #expect(try item("Milk", quantity: 2, unit: "bottles").quantityDescription == "2 bottles")
        #expect(try item("Apples", quantity: 6).quantityDescription == "6")
    }

    // MARK: Duplicates

    @Test("Duplicate detection ignores case, accents, and padding")
    func duplicateDetectionFolds() throws {
        // Adding 'milk' to a list that already has 'Milk' should bump the
        // quantity, not produce two rows for the person in the shop to
        // reconcile at the till.
        let items = [try item("Milk"), try item("Bánh mì")]
        #expect(items.pendingMatch(for: "  MILK ")?.name.value == "Milk")
        #expect(items.pendingMatch(for: "banh mi")?.name.value == "Bánh mì")
        #expect(items.pendingMatch(for: "Bread") == nil)
    }

    @Test("A purchased item is not a duplicate match")
    func purchasedItemsAreNotMatched() throws {
        // Milk bought last week must not silently absorb this week's milk.
        let items = [try item("Milk", purchased: true)]
        #expect(items.pendingMatch(for: "Milk") == nil)
    }

    @Test("Incrementing raises the quantity and clamps at the maximum")
    func incrementClamps() throws {
        let bumped = try item("Milk", quantity: 2).incremented(by: 3)
        #expect(bumped.quantity == 5)

        let atCeiling = try item("Milk", quantity: Limits.itemQuantity.upperBound).incremented()
        #expect(atCeiling.quantity == Limits.itemQuantity.upperBound)
    }

    @Test("Incrementing by a negative amount does not reduce the quantity")
    func incrementIgnoresNegatives() throws {
        #expect(try item("Milk", quantity: 2).incremented(by: -5).quantity == 2)
    }

    // MARK: Purchase state

    @Test("Purchasing records who and when, and is reversible")
    func purchaseIsReversible() throws {
        let pending = try item("Milk")
        #expect(pending.isPending)

        let bought = pending.purchased(by: alex, at: date(2026, 3, 2, hour: 17))
        #expect(!bought.isPending)
        #expect(bought.purchase?.by == alex)

        #expect(bought.unpurchased().isPending)
    }

    @Test("Pending and purchased partition the list")
    func pendingAndPurchasedPartition() throws {
        let items = [
            try item("Milk"),
            try item("Bread", purchased: true),
            try item("Eggs"),
        ]
        #expect(items.pending.count == 2)
        #expect(items.purchased.count == 1)
        #expect(items.pending.count + items.purchased.count == items.count)
    }

    // MARK: Aisle grouping

    @Test("Items group into shop order, not the order they were added")
    func groupsIntoShopOrder() throws {
        // Grouping by aisle rather than by insertion is the difference between
        // one pass through a shop and three.
        let items = [
            try item("Bleach", category: .household),
            try item("Apples", category: .produce),
            try item("Milk", category: .dairy),
            try item("Bananas", category: .produce),
        ]
        let grouped = items.groupedByAisle()
        #expect(grouped.map(\.category) == [.produce, .dairy, .household])
        #expect(grouped[0].items.map(\.name.value) == ["Apples", "Bananas"])
    }

    @Test("Aisle categories sort in supermarket layout order")
    func aisleOrderIsStable() {
        #expect(ShoppingItem.Category.produce < ShoppingItem.Category.dairy)
        #expect(ShoppingItem.Category.dairy < ShoppingItem.Category.frozen)
        #expect(ShoppingItem.Category.household < ShoppingItem.Category.other)
    }

    // MARK: Lists

    @Test("Rejects a blank list name")
    func rejectsBlankListName() {
        #expect(throws: DomainError.blank(field: .listName)) {
            _ = try ShoppingList(
                householdID: householdID,
                name: " ",
                createdBy: alex,
                createdAt: date(2026, 3, 1)
            )
        }
    }

    @Test("Archiving a list is reversible")
    func listArchivingIsReversible() throws {
        let list = try ShoppingList(
            householdID: householdID,
            name: "Groceries",
            createdBy: alex,
            createdAt: date(2026, 3, 1)
        )
        #expect(list.isActive)

        let archived = list.archived(at: date(2026, 3, 10))
        #expect(!archived.isActive)
        #expect(archived.unarchived().isActive)
    }

    @Test("List emoji is clamped to a single grapheme")
    func listEmojiIsClamped() throws {
        let list = try ShoppingList(
            householdID: householdID,
            name: "Groceries",
            emoji: "🛒🥕",
            createdBy: alex,
            createdAt: date(2026, 3, 1)
        )
        #expect(list.emoji == "🛒")
    }
}
