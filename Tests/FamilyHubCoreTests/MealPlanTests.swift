import Foundation
import Testing

@testable import FamilyHubCore

@Suite("Meal plan")
struct MealPlanTests {

    // MARK: Fixture

    private let calendar = Calendar.testDefault
    private let householdID = Identifier<Household>()

    /// 2 March 2026 is a Monday, and the test calendar starts its weeks there.
    private func date(_ day: Int, hour: Int = 0) -> Date {
        FixedDateProvider(year: 2026, month: 3, day: day, hour: hour, calendar: .testDefault).now
    }

    private func member(_ name: String, role: MemberRole = .adult) throws -> Member {
        try Member(
            householdID: householdID,
            name: name,
            role: role,
            joinedAt: date(1)
        )
    }

    private func meal(
        _ title: String,
        day: Int,
        slot: PlannedMeal.Slot = .dinner,
        cook: Member? = nil,
        ingredients: [String] = [],
        createdAt: Date? = nil
    ) throws -> PlannedMeal {
        try PlannedMeal(
            householdID: householdID,
            day: date(day),
            slot: slot,
            title: title,
            cookID: cook?.id,
            ingredients: ingredients,
            plannedBy: Identifier(),
            createdAt: createdAt ?? date(1),
            calendar: calendar
        )
    }

    private func plan(_ meals: [PlannedMeal]) -> MealPlan {
        MealPlan(meals: meals, calendar: calendar)
    }

    // MARK: Lookups

    @Test("A slot is a lookup, not a search")
    func slotLookup() throws {
        let chilli = try meal("Chilli", day: 4)
        let plan = plan([chilli, try meal("Porridge", day: 4, slot: .breakfast)])

        #expect(plan.meal(on: date(4, hour: 20), slot: .dinner)?.title.value == "Chilli")
        #expect(plan.meal(on: date(5), slot: .dinner) == nil)
        #expect(plan.meals(on: date(4)).map(\.slot) == [.breakfast, .dinner])
    }

    @Test("Two devices planning the same dinner produce one row, not two")
    func duplicateSlotsResolveOnce() throws {
        let first = try meal("Chilli", day: 4, createdAt: date(1, hour: 9))
        let second = try meal("Curry", day: 4, createdAt: date(1, hour: 10))
        let plan = plan([second, first])

        #expect(plan.meals.count == 1)
        #expect(plan.meal(on: date(4), slot: .dinner)?.title.value == "Chilli")
    }

    // MARK: What is next

    @Test("What's next moves through the day rather than restarting it")
    func nextMealFollowsTheClock() throws {
        let meals = [
            try meal("Porridge", day: 2, slot: .breakfast),
            try meal("Soup", day: 2, slot: .lunch),
            try meal("Chilli", day: 2, slot: .dinner),
        ]
        let plan = plan(meals)

        #expect(plan.nextMeal(after: date(2, hour: 7))?.title.value == "Porridge")
        #expect(plan.nextMeal(after: date(2, hour: 11))?.title.value == "Soup")
        // Eight in the evening is not breakfast time, which is the whole
        // reason this takes a moment rather than a day.
        #expect(plan.nextMeal(after: date(2, hour: 20))?.title.value == "Chilli")
    }

    @Test("What's next rolls on to the following days when today is over")
    func nextMealRollsForward() throws {
        let plan = plan([try meal("Fish pie", day: 5)])
        #expect(plan.nextMeal(after: date(2, hour: 23))?.title.value == "Fish pie")
    }

    @Test("Nothing planned inside the horizon is reported as nothing")
    func nextMealCanBeNothing() throws {
        let plan = plan([try meal("Roast", day: 29)])
        #expect(plan.nextMeal(after: date(2), horizonDays: 7) == nil)
    }

    // MARK: Days and weeks

    @Test("A week is seven days whether or not anything is planned on them")
    func weekIsAlwaysSevenDays() throws {
        let week = plan([try meal("Chilli", day: 4)]).week(containing: date(6))

        #expect(week.days.count == 7)
        #expect(week.start == date(2))
        #expect(week.end == date(8))
        #expect(week.plannedCount == 1)
        #expect(!week.isEmpty)
        #expect(!week.isComplete)
    }

    @Test("An untouched week is distinguished from a half-planned one")
    func emptyWeekIsNotMerelyIncomplete() throws {
        let untouched = plan([]).week(containing: date(2))
        #expect(untouched.isEmpty)
        #expect(untouched.gapCount == 21)

        let started = plan([try meal("Chilli", day: 4)]).week(containing: date(2))
        #expect(!started.isEmpty)
        #expect(started.gapCount == 20)
    }

    @Test("A day with every plannable slot filled has no gaps")
    func fullDayHasNoGaps() throws {
        let meals = [
            try meal("Porridge", day: 2, slot: .breakfast),
            try meal("Soup", day: 2, slot: .lunch),
            try meal("Chilli", day: 2, slot: .dinner),
        ]
        let day = try #require(plan(meals).days(from: date(2), to: date(2)).first)

        #expect(day.isComplete)
        #expect(day.dinner?.title.value == "Chilli")
    }

    @Test("A planned snack does not turn an unplanned day into a full one")
    func snacksDoNotFillTheGrid() throws {
        let day = try #require(
            plan([try meal("Flapjack", day: 2, slot: .snack)])
                .days(from: date(2), to: date(2)).first
        )

        #expect(!day.isComplete)
        #expect(day.gaps == [.breakfast, .lunch, .dinner])
        #expect(day.meals.count == 1)
    }

    @Test("Gaps name the slot and the day, so a prompt can offer to fill them")
    func gapsAreAddressable() throws {
        let meals = [
            try meal("Porridge", day: 2, slot: .breakfast),
            try meal("Soup", day: 2, slot: .lunch),
        ]
        let gaps = plan(meals).gaps(from: date(2), to: date(2))

        #expect(gaps == [PlannedMeal.SlotKey(day: date(2), slot: .dinner)])
    }

    // MARK: Cooking

    @Test("The cooking split names who is doing most of it")
    func cookBalanceFindsTheImbalance() throws {
        let mary = try member("Mary")
        let jerald = try member("Jerald", role: .owner)
        let meals = try (2...8).map { day in
            try meal("Dinner \(day)", day: day, cook: mary)
        }
        let balance = plan(meals).cookBalance(
            among: [mary, jerald], from: date(2), to: date(8)
        )

        #expect(balance.shares.first?.member.id == mary.id)
        #expect(balance.shares.first?.meals == 7)
        #expect(!balance.isBalanced)
        #expect(balance.cookingMost?.id == mary.id)
    }

    @Test("An even split is left alone")
    func evenCookingIsBalanced() throws {
        let mary = try member("Mary")
        let jerald = try member("Jerald", role: .owner)
        let meals = [
            try meal("Monday", day: 2, cook: mary),
            try meal("Tuesday", day: 3, cook: jerald),
            try meal("Wednesday", day: 4, cook: mary),
            try meal("Thursday", day: 5, cook: jerald),
        ]
        let balance = plan(meals).cookBalance(
            among: [mary, jerald], from: date(2), to: date(8)
        )

        #expect(balance.isBalanced)
        #expect(balance.cookingMost == nil)
        #expect(balance.unassignedMeals == 0)
    }

    @Test("Meals nobody is cooking are counted, not shared out")
    func unassignedMealsAreReportedSeparately() throws {
        let mary = try member("Mary")
        let meals = [
            try meal("Monday", day: 2, cook: mary),
            try meal("Tuesday", day: 3),
            try meal("Wednesday", day: 4),
        ]
        let balance = plan(meals).cookBalance(among: [mary], from: date(2), to: date(8))

        #expect(balance.unassignedMeals == 2)
        #expect(balance.shares.first?.meals == 1)
    }

    @Test("A member who has cooked nothing still appears on the fairness screen")
    func everyoneAppears() throws {
        let mary = try member("Mary")
        let jerald = try member("Jerald", role: .owner)
        let balance = plan([try meal("Monday", day: 2, cook: mary)])
            .cookBalance(among: [mary, jerald], from: date(2), to: date(8))

        #expect(balance.shares.count == 2)
        #expect(balance.shares.last?.meals == 0)
    }

    // MARK: Shopping

    @Test("The week's ingredients come back in the order the plan mentions them")
    func ingredientsFollowThePlan() throws {
        let meals = [
            try meal("Chilli", day: 2, ingredients: ["Mince", "Kidney beans"]),
            try meal("Bolognese", day: 4, ingredients: ["Mince", "Passata"]),
        ]
        let shopping = plan(meals).ingredientsToBuy(from: date(2), to: date(8))

        #expect(shopping.map(\.name) == ["Mince", "Kidney beans", "Passata"])
        // Mince is wanted twice, which is a reasonable first guess at how much
        // of it to buy.
        #expect(shopping.first?.mealCount == 2)
        #expect(shopping.first?.meals.map(\.title.value) == ["Chilli", "Bolognese"])
    }

    @Test("Ingredients already on the list are not suggested again")
    func listedIngredientsAreExcluded() throws {
        let listID = Identifier<ShoppingList>()
        let existing = try ShoppingItem(
            listID: listID,
            householdID: householdID,
            name: "mince",
            addedBy: Identifier(),
            addedAt: date(1)
        )
        let meals = [try meal("Chilli", day: 2, ingredients: ["Mince", "Kidney beans"])]
        let shopping = plan(meals).ingredientsToBuy(
            from: date(2), to: date(8), excluding: [existing]
        )

        #expect(shopping.map(\.name) == ["Kidney beans"])
    }

    @Test("An ingredient bought last week is wanted again this week")
    func purchasedItemsDoNotSuppressSuggestions() throws {
        let listID = Identifier<ShoppingList>()
        let bought = try ShoppingItem(
            listID: listID,
            householdID: householdID,
            name: "Mince",
            addedBy: Identifier(),
            addedAt: date(1)
        )
        .purchased(by: Identifier(), at: date(1))

        let meals = [try meal("Chilli", day: 2, ingredients: ["Mince"])]
        let shopping = plan(meals).ingredientsToBuy(
            from: date(2), to: date(8), excluding: [bought]
        )

        // The mince is in somebody's stomach, not the cupboard.
        #expect(shopping.map(\.name) == ["Mince"])
    }

    @Test("Only the days being shopped for are counted")
    func ingredientsRespectTheRange() throws {
        let meals = [
            try meal("Chilli", day: 2, ingredients: ["Mince"]),
            try meal("Roast", day: 9, ingredients: ["Chicken"]),
        ]
        let shopping = plan(meals).ingredientsToBuy(from: date(2), to: date(8))

        #expect(shopping.map(\.name) == ["Mince"])
    }
}
