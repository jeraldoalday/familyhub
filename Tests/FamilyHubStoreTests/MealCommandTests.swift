import FamilyHubCore
import Foundation
import Testing

@testable import FamilyHubStore

/// Covers the commands that decide what a household is eating, including the
/// bridge from the plan to the shopping list, which is the part of the feature
/// a family actually uses on a Sunday.
@Suite("Meal commands")
struct MealCommandTests {

    // MARK: Fixture

    private let calendar = Calendar.testDefault
    /// 2 March 2026, a Monday.
    private let clock = FixedDateProvider(
        year: 2026, month: 3, day: 2, hour: 9, calendar: .testDefault
    )

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: clock.today) ?? clock.today
    }

    private struct Fixture {
        let store: InMemoryHouseholdStore
        let commands: HouseholdCommands
        let household: Household
        let owner: Member
        let teen: Member
        let child: Member
        let list: ShoppingList
    }

    private func makeFixture(tier: Household.Tier = .plus) async throws -> Fixture {
        let household = try Household(
            name: "The Aldays",
            tier: tier,
            timeZone: .gmt,
            requiresApproval: false,
            createdAt: clock.now
        )
        let owner = try Member(
            householdID: household.id, name: "Jerald", role: .owner,
            avatar: Avatar(color: .blue), joinedAt: clock.now
        )
        let teen = try Member(
            householdID: household.id, name: "Alex", role: .teen,
            avatar: Avatar(color: .teal), joinedAt: clock.now
        )
        let child = try Member(
            householdID: household.id, name: "Sam", role: .child,
            avatar: Avatar(color: .amber), joinedAt: clock.now
        )
        let list = try ShoppingList(
            householdID: household.id, name: "Groceries", isDefault: true,
            createdBy: owner.id, createdAt: clock.now
        )
        let store = InMemoryHouseholdStore(
            seed: HouseholdSnapshot(
                household: household,
                members: [owner, teen, child],
                shoppingLists: [list]
            )
        )
        return Fixture(
            store: store,
            commands: HouseholdCommands(store: store, dateProvider: clock),
            household: household,
            owner: owner,
            teen: teen,
            child: child,
            list: list
        )
    }

    // MARK: Planning

    @Test("Planning a meal records it against the day and the slot")
    func planMealRecordsTheSlot() async throws {
        let f = try await makeFixture()
        let meal = try await f.commands.planMeal(
            in: f.household.id,
            on: day(3).addingTimeInterval(60 * 60 * 19),
            slot: .dinner,
            title: "  Chilli  ",
            notes: "Mild for Sam",
            cookID: f.teen.id,
            ingredients: ["Mince", "Kidney beans"],
            servings: 4,
            by: f.owner.id
        )

        #expect(meal.title.value == "Chilli")
        #expect(meal.day == day(3))
        #expect(meal.cookID == f.teen.id)
        #expect(meal.servings == 4)
        #expect(meal.plannedBy == f.owner.id)

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.mealPlan.meal(on: day(3), slot: .dinner)?.id == meal.id)
    }

    @Test("Changing your mind about a slot replaces it rather than doubling it")
    func planningTwiceReplacesTheSlot() async throws {
        let f = try await makeFixture()
        let first = try await f.commands.planMeal(
            in: f.household.id, on: day(3), slot: .dinner, title: "Chilli", by: f.owner.id
        )
        let second = try await f.commands.planMeal(
            in: f.household.id, on: day(3), slot: .dinner, title: "Curry", by: f.teen.id
        )

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.plannedMeals.count == 1)
        #expect(second.id == first.id)
        #expect(snapshot.mealPlan.meal(on: day(3), slot: .dinner)?.title.value == "Curry")
        // The slot keeps the moment it was first planned, so the domain's
        // conflict resolution still has a stable ordering to work with.
        #expect(second.createdAt == first.createdAt)
        #expect(second.plannedBy == f.owner.id)
    }

    @Test("A cook who has left cannot be put on the rota")
    func cookMustBeInTheHousehold() async throws {
        let f = try await makeFixture()
        try await f.commands.removeMember(f.teen.id, from: f.household.id, by: f.owner.id)

        await #expect(throws: DomainError.memberNotInHousehold(f.teen.id)) {
            try await f.commands.planMeal(
                in: f.household.id, on: day(3), slot: .dinner, title: "Chilli",
                cookID: f.teen.id, by: f.owner.id
            )
        }
    }

    // MARK: Permissions and plan

    @Test("Meal planning is refused on a plan that does not include it")
    func freeTierIsRefused() async throws {
        let f = try await makeFixture(tier: .free)

        await #expect(
            throws: DomainError.requiresUpgrade(feature: .mealPlanning, tier: .free)
        ) {
            try await f.commands.planMeal(
                in: f.household.id, on: day(3), slot: .dinner, title: "Chilli", by: f.owner.id
            )
        }
    }

    @Test("A teen may plan the week; a child may not")
    func onlyTeensAndAboveCanPlan() async throws {
        let f = try await makeFixture()
        let meal = try await f.commands.planMeal(
            in: f.household.id, on: day(3), slot: .dinner, title: "Pasta", by: f.teen.id
        )
        #expect(meal.plannedBy == f.teen.id)

        await #expect(
            throws: DomainError.notPermitted(action: .manageMealPlan, role: .child)
        ) {
            try await f.commands.planMeal(
                in: f.household.id, on: day(4), slot: .dinner, title: "Pizza", by: f.child.id
            )
        }
    }

    // MARK: Editing

    @Test("An edit changes only the fields it names")
    func updateChangesOnlyWhatItNames() async throws {
        let f = try await makeFixture()
        let meal = try await f.commands.planMeal(
            in: f.household.id, on: day(3), slot: .dinner, title: "Chilli",
            notes: "Mild for Sam", cookID: f.teen.id, ingredients: ["Mince"], servings: 4,
            by: f.owner.id
        )

        let updated = try await f.commands.updateMeal(
            meal.id, in: f.household.id, ingredients: ["Mince", "Rice"], by: f.owner.id
        )

        #expect(updated.title.value == "Chilli")
        #expect(updated.notes?.value == "Mild for Sam")
        #expect(updated.cookID == f.teen.id)
        #expect(updated.servings == 4)
        #expect(updated.ingredientNames == ["Mince", "Rice"])
    }

    @Test("The cook can be named and taken off again")
    func cookCanBeCleared() async throws {
        let f = try await makeFixture()
        let meal = try await f.commands.planMeal(
            in: f.household.id, on: day(3), slot: .dinner, title: "Chilli", by: f.owner.id
        )

        let named = try await f.commands.setMealCook(
            meal.id, to: f.teen.id, in: f.household.id, by: f.owner.id
        )
        #expect(named.cookID == f.teen.id)

        let cleared = try await f.commands.setMealCook(
            meal.id, to: nil, in: f.household.id, by: f.owner.id
        )
        #expect(cleared.cookID == nil)
    }

    @Test("Taking a meal off the plan removes it outright")
    func unplanRemovesTheRecord() async throws {
        let f = try await makeFixture()
        let meal = try await f.commands.planMeal(
            in: f.household.id, on: day(3), slot: .dinner, title: "Chilli", by: f.owner.id
        )
        try await f.commands.unplanMeal(meal.id, in: f.household.id, by: f.owner.id)

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.plannedMeals.isEmpty)

        await #expect(throws: DomainError.self) {
            try await f.commands.unplanMeal(meal.id, in: f.household.id, by: f.owner.id)
        }
    }

    // MARK: Moving

    @Test("Moving a meal to an empty slot takes its cook and shopping with it")
    func moveToEmptySlot() async throws {
        let f = try await makeFixture()
        let meal = try await f.commands.planMeal(
            in: f.household.id, on: day(3), slot: .dinner, title: "Chilli",
            cookID: f.teen.id, ingredients: ["Mince"], by: f.owner.id
        )

        let moved = try await f.commands.moveMeal(
            meal.id, to: day(4), slot: .lunch, in: f.household.id, by: f.owner.id
        )

        #expect(moved.day == day(4))
        #expect(moved.slot == .lunch)
        #expect(moved.cookID == f.teen.id)
        #expect(moved.ingredientNames == ["Mince"])

        let plan = try await f.store.snapshot(of: f.household.id).mealPlan
        #expect(plan.meal(on: day(3), slot: .dinner) == nil)
    }

    @Test("Moving onto an occupied slot swaps the two meals")
    func moveOntoOccupiedSlotSwaps() async throws {
        let f = try await makeFixture()
        let thursday = try await f.commands.planMeal(
            in: f.household.id, on: day(3), slot: .dinner, title: "Chilli", by: f.owner.id
        )
        let friday = try await f.commands.planMeal(
            in: f.household.id, on: day(4), slot: .dinner, title: "Fish pie", by: f.owner.id
        )

        try await f.commands.moveMeal(
            thursday.id, to: day(4), slot: .dinner, in: f.household.id, by: f.owner.id
        )

        let plan = try await f.store.snapshot(of: f.household.id).mealPlan
        #expect(plan.meal(on: day(4), slot: .dinner)?.title.value == "Chilli")
        // Nothing the family typed is lost: the fish pie moves to where the
        // chilli was rather than being overwritten.
        #expect(plan.meal(on: day(3), slot: .dinner)?.title.value == "Fish pie")
        #expect(plan.meal(on: day(3), slot: .dinner)?.id == friday.id)
        #expect(plan.meals.count == 2)
    }

    // MARK: Shopping

    @Test("A planned week becomes a shopping list in one call")
    func ingredientsBecomeShoppingItems() async throws {
        let f = try await makeFixture()
        try await f.commands.planMeal(
            in: f.household.id, on: day(1), slot: .dinner, title: "Chilli",
            ingredients: ["Mince", "Kidney beans"], by: f.owner.id
        )
        try await f.commands.planMeal(
            in: f.household.id, on: day(2), slot: .dinner, title: "Bolognese",
            ingredients: ["Mince", "Passata"], by: f.owner.id
        )

        let added = try await f.commands.addMealIngredients(
            from: clock.today, to: day(6), in: f.household.id,
            toList: f.list.id, by: f.owner.id
        )

        #expect(added.map(\.name.value) == ["Mince", "Kidney beans", "Passata"])
        #expect(added.allSatisfy { $0.addedBy == f.owner.id })

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.items(on: f.list.id).count == 3)
    }

    @Test("A generated shopping list arrives sorted into aisles")
    func generatedIngredientsAreCategorised() async throws {
        // The list nobody typed is the one that would otherwise arrive entirely
        // in "Other" — twenty unsorted lines being exactly what the aisle
        // grouping exists to prevent.
        let f = try await makeFixture()
        try await f.commands.planMeal(
            in: f.household.id, on: day(1), slot: .dinner, title: "Chilli",
            ingredients: ["Beef mince", "Tinned tomatoes", "Sourdough", "Cheddar"],
            by: f.owner.id
        )

        let added = try await f.commands.addMealIngredients(
            from: clock.today, to: day(6), in: f.household.id,
            toList: f.list.id, by: f.owner.id
        )

        let aisles = Dictionary(
            uniqueKeysWithValues: added.map { ($0.name.value, $0.category) }
        )
        #expect(aisles["Beef mince"] == .meat)
        #expect(aisles["Tinned tomatoes"] == .produce)
        #expect(aisles["Sourdough"] == .bakery)
        #expect(aisles["Cheddar"] == .dairy)
    }

    @Test("An ingredient nothing recognises stays in Other")
    func unrecognisedIngredientsStayInOther() async throws {
        let f = try await makeFixture()
        try await f.commands.planMeal(
            in: f.household.id, on: day(1), slot: .dinner, title: "Sam's invention",
            ingredients: ["Whatever Sam wants"], by: f.owner.id
        )

        let added = try await f.commands.addMealIngredients(
            from: clock.today, to: day(6), in: f.household.id,
            toList: f.list.id, by: f.owner.id
        )
        #expect(added.first?.category == .other)
    }

    @Test("Running the same week twice does not double the list")
    func ingredientsAreNotAddedTwice() async throws {
        let f = try await makeFixture()
        try await f.commands.planMeal(
            in: f.household.id, on: day(1), slot: .dinner, title: "Chilli",
            ingredients: ["Mince"], by: f.owner.id
        )

        try await f.commands.addMealIngredients(
            from: clock.today, to: day(6), in: f.household.id,
            toList: f.list.id, by: f.owner.id
        )
        let second = try await f.commands.addMealIngredients(
            from: clock.today, to: day(6), in: f.household.id,
            toList: f.list.id, by: f.owner.id
        )

        #expect(second.isEmpty)
        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.items(on: f.list.id).count == 1)
        // Left at one rather than bumped to two: the number of meals wanting an
        // ingredient is a guess at a quantity, not a measurement.
        #expect(snapshot.items(on: f.list.id).first?.quantity == 1)
    }

    @Test("An ingredient already on another list is not added again")
    func otherListsCount() async throws {
        let f = try await makeFixture()
        let hardware = try await f.commands.createShoppingList(
            in: f.household.id, name: "Hardware", by: f.owner.id
        )
        try await f.commands.addShoppingItem(
            "mince", to: hardware.id, in: f.household.id, by: f.owner.id
        )
        try await f.commands.planMeal(
            in: f.household.id, on: day(1), slot: .dinner, title: "Chilli",
            ingredients: ["Mince", "Rice"], by: f.owner.id
        )

        let added = try await f.commands.addMealIngredients(
            from: clock.today, to: day(6), in: f.household.id,
            toList: f.list.id, by: f.owner.id
        )

        #expect(added.map(\.name.value) == ["Rice"])
    }

    @Test("Even a child can turn the plan into a shopping list")
    func childrenCanShopFromThePlan() async throws {
        let f = try await makeFixture()
        try await f.commands.planMeal(
            in: f.household.id, on: day(1), slot: .dinner, title: "Chilli",
            ingredients: ["Mince"], by: f.owner.id
        )

        let added = try await f.commands.addMealIngredients(
            from: clock.today, to: day(6), in: f.household.id,
            toList: f.list.id, by: f.child.id
        )

        #expect(added.count == 1)
        #expect(added.first?.addedBy == f.child.id)
    }

    @Test("Shopping for a list that is not there is reported, not guessed at")
    func unknownListIsReported() async throws {
        let f = try await makeFixture()
        let stranger = Identifier<ShoppingList>()

        await #expect(throws: DomainError.notFound(entity: "List", id: stranger.description)) {
            try await f.commands.addMealIngredients(
                from: clock.today, to: day(6), in: f.household.id,
                toList: stranger, by: f.owner.id
            )
        }
    }
}
