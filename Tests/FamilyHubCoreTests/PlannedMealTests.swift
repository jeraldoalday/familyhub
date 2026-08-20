import Foundation
import Testing

@testable import FamilyHubCore

@Suite("Planned meals")
struct PlannedMealTests {

    private let calendar = Calendar.testDefault
    private let householdID = Identifier<Household>()
    private let parent = Identifier<Member>()
    private let teen = Identifier<Member>()

    /// 2 March 2026, a Monday.
    private func date(_ day: Int, hour: Int = 0) -> Date {
        FixedDateProvider(year: 2026, month: 3, day: day, hour: hour, calendar: .testDefault).now
    }

    private func meal(
        day: Int = 2,
        hour: Int = 0,
        slot: PlannedMeal.Slot = .dinner,
        title: String = "Spaghetti bolognese",
        notes: String? = nil,
        cookID: Identifier<Member>? = nil,
        ingredients: [String] = [],
        servings: Int? = nil,
        id: Identifier<PlannedMeal> = Identifier(),
        createdAt: Date? = nil
    ) throws -> PlannedMeal {
        try PlannedMeal(
            id: id,
            householdID: householdID,
            day: date(day, hour: hour),
            slot: slot,
            title: title,
            notes: notes,
            cookID: cookID,
            ingredients: ingredients,
            servings: servings,
            plannedBy: parent,
            createdAt: createdAt ?? date(1),
            calendar: calendar
        )
    }

    // MARK: Construction

    @Test("A meal is pinned to the start of its day whatever time it was planned")
    func dayIsNormalised() throws {
        let evening = try meal(hour: 19)
        #expect(evening.day == date(2))
        #expect(evening.slotKey == PlannedMeal.SlotKey(day: date(2), slot: .dinner))
    }

    @Test("A meal needs something to call it")
    func blankTitleIsRefused() {
        #expect(throws: DomainError.blank(field: .mealTitle)) {
            _ = try meal(title: "   ")
        }
    }

    @Test("Servings outside the plausible range are refused")
    func servingsAreBounded() {
        #expect(throws: DomainError.outOfRange(field: .quantity, allowed: Limits.servings)) {
            _ = try meal(servings: 0)
        }
        #expect(throws: DomainError.outOfRange(field: .quantity, allowed: Limits.servings)) {
            _ = try meal(servings: 500)
        }
    }

    // MARK: Ingredients

    @Test("Ingredients are trimmed, and blank lines are dropped rather than refused")
    func ingredientsAreTrimmed() throws {
        let planned = try meal(ingredients: ["  Mince  ", "", "   ", "Passata"])
        #expect(planned.ingredientNames == ["Mince", "Passata"])
        #expect(planned.hasIngredients)
    }

    @Test("The same ingredient typed twice is listed once, in its first spelling")
    func ingredientsDeduplicate() throws {
        let planned = try meal(ingredients: ["Onions", "Mince", "ONIONS", "onions"])
        #expect(planned.ingredientNames == ["Onions", "Mince"])
    }

    @Test("Accents do not make two ingredients out of one")
    func ingredientsFoldDiacritics() throws {
        let planned = try meal(ingredients: ["Crème fraîche", "Creme fraiche"])
        #expect(planned.ingredientNames == ["Crème fraîche"])
    }

    @Test("A cookbook pasted into the ingredients field is refused")
    func ingredientsAreBounded() {
        let tooMany = (1...Limits.ingredientsPerMeal + 1).map { "Ingredient \($0)" }
        #expect(
            throws: DomainError.outOfRange(
                field: .itemName, allowed: 0...Limits.ingredientsPerMeal
            )
        ) {
            _ = try meal(ingredients: tooMany)
        }
    }

    // MARK: Slots

    @Test("Slots sort through the day")
    func slotsAreOrdered() {
        #expect(PlannedMeal.Slot.allCases.sorted() == [.breakfast, .lunch, .dinner, .snack])
        #expect(PlannedMeal.Slot.dinner > PlannedMeal.Slot.breakfast)
    }

    @Test("Only the three meals a week grid plans count as gaps")
    func snacksAreNotGaps() {
        #expect(PlannedMeal.Slot.dinner.isWorthPlanning)
        #expect(!PlannedMeal.Slot.snack.isWorthPlanning)
        #expect(PlannedMeal.Slot.planned.count == 3)
    }

    // MARK: Mutation

    @Test("Moving a meal keeps its cook and its shopping")
    func movingKeepsTheDetails() throws {
        let thursday = try meal(day: 5, cookID: teen, ingredients: ["Mince"])
        let friday = thursday.moved(to: date(6, hour: 22), slot: .lunch, calendar: calendar)

        #expect(friday.day == date(6))
        #expect(friday.slot == .lunch)
        #expect(friday.cookID == teen)
        #expect(friday.ingredientNames == ["Mince"])
        #expect(friday.id == thursday.id)
    }

    @Test("A cook can be named and unnamed")
    func cookIsOptional() throws {
        let planned = try meal()
        #expect(!planned.hasCook)
        #expect(planned.cookedBy(teen).cookID == teen)
        #expect(planned.cookedBy(teen).cookedBy(nil).cookID == nil)
    }

    @Test("Edits revalidate rather than trusting the caller")
    func editsRevalidate() throws {
        let planned = try meal()
        #expect(throws: DomainError.blank(field: .mealTitle)) {
            _ = try planned.retitled(to: " ")
        }
        #expect(try planned.withNotes("  ").notes == nil)
        #expect(try planned.serving(4).servings == 4)
    }

    // MARK: Collections

    @Test("A day's meals come back in the order they are eaten")
    func aDaySortsBySlot() throws {
        let meals = [
            try meal(slot: .dinner, title: "Chilli"),
            try meal(slot: .breakfast, title: "Porridge"),
            try meal(day: 3, slot: .lunch, title: "Soup"),
        ]
        #expect(
            meals.onDay(date(2, hour: 15), calendar: calendar).map(\.title.value)
                == ["Porridge", "Chilli"])
    }

    @Test("A range of days comes back earliest first")
    func rangeIsOrdered() throws {
        let meals = [
            try meal(day: 6, title: "Fish"),
            try meal(day: 2, title: "Chilli"),
            try meal(day: 9, title: "Roast"),
        ]
        let week = meals.inDays(date(2)...date(8), calendar: calendar)
        #expect(week.map(\.title.value) == ["Chilli", "Fish"])
    }

    @Test("Two devices planning the same dinner converge on one meal")
    func duplicateSlotsCollapse() throws {
        let first = try meal(title: "Chilli", createdAt: date(1, hour: 9))
        let second = try meal(title: "Curry", createdAt: date(1, hour: 11))
        let resolved = [second, first].deduplicatedBySlot()

        #expect(resolved.count == 1)
        #expect(resolved.first?.title.value == "Chilli")
    }

    @Test("An exact tie is broken by identifier, so every device agrees")
    func identicalTimestampsResolveStably() throws {
        let stamp = date(1, hour: 9)
        let a = try meal(title: "Chilli", id: Identifier(), createdAt: stamp)
        let b = try meal(title: "Curry", id: Identifier(), createdAt: stamp)
        let expected = a.id < b.id ? "Chilli" : "Curry"

        #expect([a, b].deduplicatedBySlot().first?.title.value == expected)
        #expect([b, a].deduplicatedBySlot().first?.title.value == expected)
    }
}
