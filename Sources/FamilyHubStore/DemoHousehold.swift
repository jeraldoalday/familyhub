import FamilyHubCore
import Foundation

/// A fully populated household, for previews, screenshots, and the guided tour.
///
/// Built deterministically from an injected clock rather than from `Date()`, so
/// the same call produces the same household every time. That matters more than
/// it sounds: App Store screenshots have to be reproducible across locales and
/// device sizes, and a preview that shuffles its data on every rebuild is a
/// preview nobody trusts.
///
/// The data is chosen to exercise the awkward cases rather than to look tidy —
/// a rotating chore mid-rotation, a completion awaiting approval, a reward the
/// child cannot yet afford. A demo where everything is finished and everyone is
/// even shows none of the product.
public enum DemoHousehold {

    /// Builds the demo household as of the given clock.
    ///
    /// - Parameter clock: The moment to build around. The demo's "today" is
    ///   this clock's day, so the agenda always has work on it.
    /// - Returns: A snapshot ready to seed ``InMemoryHouseholdStore``.
    /// - Throws: ``DomainError`` only if these literals stop validating, which
    ///   would mean a limit was tightened without the demo being updated —
    ///   worth failing a test over rather than silently shipping a broken tour.
    public static func snapshot(asOf clock: any DateProvider) throws -> HouseholdSnapshot {
        let today = clock.today
        let calendar = clock.calendar
        let monthAgo = calendar.date(byAdding: .day, value: -30, to: today) ?? today

        let household = try Household(
            name: "The Aldays",
            tier: .plus,
            firstWeekday: calendar.firstWeekday,
            timeZone: calendar.timeZone,
            requiresApproval: true,
            createdAt: monthAgo
        )

        // MARK: Members

        let jerald = try Member(
            householdID: household.id,
            name: "Jerald",
            role: .owner,
            avatar: Avatar(color: .indigo, emoji: "👨"),
            joinedAt: monthAgo
        )
        let mary = try Member(
            householdID: household.id,
            name: "Mary",
            role: .adult,
            avatar: Avatar(color: .purple, emoji: "👩"),
            joinedAt: monthAgo
        )
        let alex = try Member(
            householdID: household.id,
            name: "Alex",
            role: .teen,
            avatar: Avatar(color: .teal, emoji: "🧑"),
            joinedAt: monthAgo
        )
        let sam = try Member(
            householdID: household.id,
            name: "Sam",
            role: .child,
            avatar: Avatar(color: .amber, emoji: "🧒"),
            joinedAt: monthAgo
        )
        let members = [jerald, mary, alex, sam]

        // MARK: Chores

        // Rotating between the two children, which is the feature that stops
        // the weekly argument and so is worth showing mid-rotation.
        let bins = try Chore(
            householdID: household.id,
            title: "Take out the bins",
            notes: "Recycling goes out on alternate weeks",
            assignment: .rotating([alex.id, sam.id]),
            points: 15,
            startDate: monthAgo,
            recurrence: try .weekly(on: [.tuesday, .friday]),
            category: .cleaning,
            createdBy: jerald.id,
            createdAt: monthAgo
        )
        let dishes = try Chore(
            householdID: household.id,
            title: "Empty the dishwasher",
            assignment: .anyone,
            points: 10,
            startDate: monthAgo,
            recurrence: .daily,
            category: .kitchen,
            createdBy: mary.id,
            createdAt: monthAgo
        )
        let room = try Chore(
            householdID: household.id,
            title: "Tidy your room",
            assignment: .member(sam.id),
            points: 20,
            startDate: monthAgo,
            recurrence: try .weekly(on: [.saturday]),
            category: .cleaning,
            createdBy: mary.id,
            createdAt: monthAgo
        )
        let homework = try Chore(
            householdID: household.id,
            title: "Homework",
            assignment: .member(alex.id),
            points: 25,
            startDate: monthAgo,
            recurrence: try .weekly(on: Weekday.weekdays),
            category: .homework,
            createdBy: jerald.id,
            createdAt: monthAgo
        )
        let plants = try Chore(
            householdID: household.id,
            title: "Water the plants",
            assignment: .anyone,
            points: 5,
            startDate: monthAgo,
            recurrence: .everyDays(3),
            category: .outdoor,
            createdBy: mary.id,
            createdAt: monthAgo
        )
        let bills = try Chore(
            householdID: household.id,
            title: "Pay the utilities",
            assignment: .member(jerald.id),
            points: 0,
            startDate: monthAgo,
            recurrence: .lastDayOfEveryMonth,
            category: .other,
            createdBy: jerald.id,
            createdAt: monthAgo
        )
        let chores = [bins, dishes, room, homework, plants, bills]

        // MARK: History

        // A month of completed work, so the stats and history screens have
        // something real to draw. Every third day is left undone, because a
        // perfect record makes the streak and the nudge look identical.
        var completions: [ChoreCompletion] = []
        var ledgerEntries: [LedgerEntry] = []

        for daysAgo in stride(from: 28, through: 1, by: -1) {
            guard daysAgo % 3 != 0 else { continue }
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: today) else {
                continue
            }
            let doer = daysAgo % 2 == 0 ? alex : sam
            let completion = ChoreCompletion(
                householdID: household.id,
                choreID: dishes.id,
                occurrenceDay: day,
                completedBy: doer.id,
                completedAt: calendar.date(byAdding: .hour, value: 18, to: day) ?? day,
                approval: .approved(by: mary.id, at: day),
                pointsAwarded: dishes.points,
                calendar: calendar
            )
            completions.append(completion)
            ledgerEntries.append(.earned(completion, note: dishes.title.value))
        }

        // One completion still awaiting a parent, so the review queue is not
        // empty on first launch — it is the screen most people never find.
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let pending = ChoreCompletion(
            householdID: household.id,
            choreID: homework.id,
            occurrenceDay: yesterday,
            completedBy: alex.id,
            completedAt: yesterday,
            approval: .pending,
            pointsAwarded: homework.points,
            calendar: calendar
        )
        completions.append(pending)

        // A manual bonus, to show that the ledger explains itself.
        ledgerEntries.append(
            .adjustment(
                householdID: household.id,
                memberID: sam.id,
                amount: 30,
                by: jerald.id,
                at: yesterday,
                note: "Helped carry the shopping"
            )
        )

        // MARK: Rewards

        let rewards = [
            try Reward(
                householdID: household.id,
                name: "Pick movie night",
                cost: 100,
                emoji: "🍿",
                createdAt: monthAgo
            ),
            try Reward(
                householdID: household.id,
                name: "Stay up an hour late",
                cost: 150,
                emoji: "🌙",
                eligibleMemberIDs: [alex.id],
                cooldownDays: 7,
                createdAt: monthAgo
            ),
            try Reward(
                householdID: household.id,
                name: "Trip to the cinema",
                cost: 400,
                emoji: "🎬",
                remainingRedemptions: 1,
                createdAt: monthAgo
            ),
            try Reward(
                householdID: household.id,
                name: "Skip one chore",
                cost: 75,
                emoji: "🎟️",
                cooldownDays: 14,
                createdAt: monthAgo
            ),
        ]

        // MARK: Shopping

        let groceries = try ShoppingList(
            householdID: household.id,
            name: "Groceries",
            emoji: "🛒",
            isDefault: true,
            createdBy: mary.id,
            createdAt: monthAgo
        )
        let hardware = try ShoppingList(
            householdID: household.id,
            name: "Hardware store",
            emoji: "🔧",
            createdBy: jerald.id,
            createdAt: monthAgo
        )

        let items: [(String, Int, ShoppingItem.Category, Bool)] = [
            ("Milk", 2, .dairy, false),
            ("Bananas", 6, .produce, false),
            ("Sourdough", 1, .bakery, true),
            ("Chicken thighs", 1, .meat, false),
            ("Frozen peas", 2, .frozen, false),
            ("Olive oil", 1, .pantry, true),
            ("Washing-up liquid", 1, .household, false),
            ("Toothpaste", 2, .personal, false),
        ]
        let shoppingItems =
            try items.enumerated().map { index, entry in
                let (name, quantity, category, isPurchased) = entry
                let addedAt =
                    calendar.date(byAdding: .hour, value: -index, to: today) ?? today
                return try ShoppingItem(
                    listID: groceries.id,
                    householdID: household.id,
                    name: name,
                    quantity: quantity,
                    category: category,
                    addedBy: index % 2 == 0 ? mary.id : alex.id,
                    addedAt: addedAt,
                    purchase: isPurchased ? .init(by: mary.id, at: today) : nil
                )
            }

        return HouseholdSnapshot(
            household: household,
            members: members,
            chores: chores,
            completions: completions,
            ledgerEntries: ledgerEntries,
            rewards: rewards,
            shoppingLists: [groceries, hardware],
            shoppingItems: shoppingItems
        )
    }

    /// A store already seeded with the demo household.
    ///
    /// - Parameter clock: The moment to build around.
    /// - Returns: A ready-to-use store, for previews and the guided tour.
    /// - Throws: Whatever ``snapshot(asOf:)`` throws.
    public static func store(asOf clock: any DateProvider) throws -> InMemoryHouseholdStore {
        InMemoryHouseholdStore(seed: try snapshot(asOf: clock))
    }
}
