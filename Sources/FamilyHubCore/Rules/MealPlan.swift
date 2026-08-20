import Foundation

/// Reads a household's week of meals the way its kitchen does.
///
/// A value type over the meals the caller already holds, in the same spirit as
/// ``PointsLedger``: nothing is stored, everything is derived, and the week
/// grid is a pure function of a snapshot. The questions it answers are the ones
/// a family actually asks — what is for dinner, what is still undecided, whose
/// turn it is to cook, and what has to be bought — and answering them here
/// rather than in a view is what keeps the answers the same on the meal plan
/// screen, in the shopping list, and in a notification.
///
/// Duplicate slots are resolved once, in the initialiser. Every query below can
/// then assume one meal per slot, which is the assumption a week grid makes
/// anyway and the one that quietly breaks when two devices plan Thursday.
public struct MealPlan: Sendable {

    /// The meals under consideration, deduplicated by slot and in the order
    /// they are eaten.
    public let meals: [PlannedMeal]

    /// The household's calendar, which decides where its weeks begin.
    public let calendar: Calendar

    /// Meals indexed by slot, so answering "what is Thursday's dinner" is a
    /// lookup rather than a scan of the whole plan.
    private let bySlot: [PlannedMeal.SlotKey: PlannedMeal]

    /// Creates a plan over a household's meals.
    public init(meals: some Collection<PlannedMeal>, calendar: Calendar) {
        let resolved = meals.deduplicatedBySlot()
        self.meals = resolved
        self.calendar = calendar
        self.bySlot = Dictionary(
            resolved.map { ($0.slotKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: - Single meals

    /// What is planned for one slot, if anything.
    public func meal(on day: Date, slot: PlannedMeal.Slot) -> PlannedMeal? {
        bySlot[PlannedMeal.SlotKey(day: calendar.startOfDay(for: day), slot: slot)]
    }

    /// Everything planned for one day, in the order it is eaten.
    ///
    /// Answered from the slot index rather than by filtering the whole plan.
    /// There are four slots in a day and there is no bound at all on how many
    /// meals a household has planned over its lifetime, so filtering makes
    /// rendering a week cost seven passes over years of history — the same
    /// shape of mistake the agenda made before every caller shared one walk of
    /// each chore's schedule.
    public func meals(on day: Date) -> [PlannedMeal] {
        let normalized = calendar.startOfDay(for: day)
        return PlannedMeal.Slot.allCases
            .sorted()
            .compactMap { bySlot[PlannedMeal.SlotKey(day: normalized, slot: $0)] }
    }

    /// The next meal from a given moment onwards, looking at today's remaining
    /// slots first and then forward through the plan.
    ///
    /// Takes a moment rather than a day precisely so that "what's next" stops
    /// saying breakfast at eight in the evening. The boundaries are the times a
    /// meal stops being the next one rather than the times it is eaten, which
    /// is why lunch runs until the middle of the afternoon.
    ///
    /// - Parameters:
    ///   - moment: The current time.
    ///   - horizonDays: How far ahead to look before giving up.
    /// - Returns: The next planned meal, or `nil` if nothing is planned inside
    ///   the horizon.
    public func nextMeal(after moment: Date, horizonDays: Int = 14) -> PlannedMeal? {
        let today = calendar.startOfDay(for: moment)
        let hour = calendar.component(.hour, from: moment)
        let remainingToday = PlannedMeal.Slot.allCases
            .filter { hour < $0.passesAfterHour }
            .sorted()

        for slot in remainingToday {
            if let meal = meal(on: today, slot: slot) { return meal }
        }
        for offset in 1...max(1, horizonDays) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else {
                break
            }
            if let first = meals(on: day).first { return first }
        }
        return nil
    }

    // MARK: - Days and weeks

    /// One day of the plan, with the slots that are still empty named.
    public struct DayPlan: Sendable, Identifiable {
        /// The day itself, at the start of the day.
        public let day: Date

        /// What is planned, in the order it is eaten.
        public let meals: [PlannedMeal]

        /// The slots a week grid plans for that nothing has been decided on.
        public let gaps: [PlannedMeal.Slot]

        public var id: Date { day }

        /// Whether every slot worth planning has something in it.
        public var isComplete: Bool { gaps.isEmpty }

        /// What is for dinner, the question the plan is usually opened to
        /// answer.
        public var dinner: PlannedMeal? { meals.first { $0.slot == .dinner } }
    }

    /// The plan across a range of days, one entry per day whether or not
    /// anything is planned.
    ///
    /// Empty days are included rather than omitted. A grid that renders only
    /// the days with meals on them is a grid a family cannot tap to fill the
    /// days without.
    public func days(from start: Date, to end: Date) -> [DayPlan] {
        let firstDay = calendar.startOfDay(for: start)
        let lastDay = max(firstDay, calendar.startOfDay(for: end))

        var result: [DayPlan] = []
        var cursor = firstDay
        while cursor <= lastDay {
            let onDay = meals(on: cursor)
            let filled = Set(onDay.map(\.slot))
            result.append(
                DayPlan(
                    day: cursor,
                    meals: onDay,
                    gaps: PlannedMeal.Slot.planned.filter { !filled.contains($0) }
                )
            )
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    /// A household's planning week, bounded by the day it starts its week on.
    public struct Week: Sendable {
        /// The first day of the week, in the household's own convention.
        public let start: Date

        /// The last day of the week.
        public let end: Date

        /// Seven days, always, whether or not anything is planned on them.
        public let days: [DayPlan]

        /// How many meals are planned across the week.
        public var plannedCount: Int { days.reduce(0) { $0 + $1.meals.count } }

        /// How many plannable slots are still empty.
        public var gapCount: Int { days.reduce(0) { $0 + $1.gaps.count } }

        /// Whether every slot worth planning is decided.
        public var isComplete: Bool { gapCount == 0 }

        /// Whether the family has started planning this week at all.
        ///
        /// Distinguished from an incomplete week because the two want opposite
        /// screens: an untouched week wants an invitation to plan, and a
        /// half-planned one wants its holes pointed at.
        public var isEmpty: Bool { plannedCount == 0 }

        /// The days that still have something to decide.
        public var daysWithGaps: [DayPlan] { days.filter { !$0.isComplete } }
    }

    /// The week containing `day`, starting on whichever day the household
    /// considers the start of its week.
    public func week(containing day: Date) -> Week {
        let anchor = calendar.startOfDay(for: day)
        let start = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start ?? anchor
        let startDay = calendar.startOfDay(for: start)
        let end = calendar.date(byAdding: .day, value: 6, to: startDay) ?? startDay
        return Week(start: startDay, end: end, days: days(from: startDay, to: end))
    }

    /// The slots inside a range that nothing has been planned for.
    ///
    /// This is what a "3 dinners still to decide" prompt counts, and what an
    /// empty-state screen offers to fill.
    public func gaps(from start: Date, to end: Date) -> [PlannedMeal.SlotKey] {
        days(from: start, to: end).flatMap { day in
            day.gaps.map { PlannedMeal.SlotKey(day: day.day, slot: $0) }
        }
    }

    // MARK: - Who is cooking

    /// One member's share of the cooking.
    public struct CookShare: Sendable, Identifiable {
        public let member: Member

        /// Meals they are named on in the period.
        public let meals: Int

        /// Their proportion of the meals somebody is named on, `0...1`.
        public let share: Double

        /// The proportion they would carry if the cooking were split evenly.
        public let evenShare: Double

        public var id: Identifier<Member> { member.id }

        /// How far above or below an even split they are. Positive means they
        /// are cooking more than their share.
        public var deviation: Double { share - evenShare }
    }

    /// How the cooking in a period is divided.
    ///
    /// Counted in meals rather than weighted by effort. The domain has no way
    /// to know that a roast is harder than beans on toast, and inventing a
    /// weight would produce a fairness number the family could argue with —
    /// which is worse than a plain count they can see for themselves.
    ///
    /// Meals with nobody named are reported separately rather than shared out,
    /// for the same reason an unassigned chore is: guessing who "would have"
    /// cooked is exactly the invented number that makes a fairness screen
    /// untrustworthy.
    public struct CookBalance: Sendable {
        /// One row per active member, most meals first.
        public let shares: [CookShare]

        /// Meals in the period with nobody named as cook.
        public let unassignedMeals: Int

        /// The largest gap between any member's share and an even split.
        public let widestGap: Double

        /// Whether the split is close enough to even to leave alone. The same
        /// deliberately loose tolerance the chore workload uses.
        public var isBalanced: Bool { widestGap <= CookBalance.tolerance }

        /// How far from an even split counts as uneven.
        public static let tolerance = 0.15

        /// Who is doing most of the cooking, when there is a real imbalance.
        public var cookingMost: Member? {
            guard !isBalanced else { return nil }
            return shares.first?.member
        }
    }

    /// How the cooking is shared out over a period.
    public func cookBalance(
        among members: some Collection<Member>,
        from start: Date,
        to end: Date
    ) -> CookBalance {
        let firstDay = calendar.startOfDay(for: start)
        let lastDay = max(firstDay, calendar.startOfDay(for: end))
        let inRange = meals.inDays(firstDay...lastDay, calendar: calendar)

        var countByMember: [Identifier<Member>: Int] = [:]
        var unassigned = 0
        for meal in inRange {
            guard let cookID = meal.cookID else {
                unassigned += 1
                continue
            }
            countByMember[cookID, default: 0] += 1
        }

        let candidates = members.filter(\.isActive).sorted(by: Member.displayOrder)
        let total = countByMember.values.reduce(0, +)
        let evenShare = candidates.isEmpty ? 0 : 1 / Double(candidates.count)

        let shares =
            candidates
            .map { member -> CookShare in
                let count = countByMember[member.id] ?? 0
                return CookShare(
                    member: member,
                    meals: count,
                    share: total > 0 ? Double(count) / Double(total) : evenShare,
                    evenShare: evenShare
                )
            }
            .sorted { lhs, rhs in
                if lhs.meals != rhs.meals { return lhs.meals > rhs.meals }
                return Member.displayOrder(lhs.member, rhs.member)
            }

        return CookBalance(
            shares: shares,
            unassignedMeals: unassigned,
            widestGap: shares.map { abs($0.deviation) }.max() ?? 0
        )
    }

    // MARK: - What has to be bought

    /// One thing the plan needs bought, and what needs it.
    public struct Ingredient: Sendable, Identifiable {
        /// The ingredient as the first meal to mention it spelled it.
        public let name: String

        /// The meals that call for it, earliest first.
        public let meals: [PlannedMeal]

        /// Its folded form, which is what matching against a shopping list
        /// compares.
        public let key: String

        public var id: String { key }

        /// How many meals need it, which is a reasonable first guess at the
        /// quantity to buy.
        public var mealCount: Int { meals.count }
    }

    /// Everything the plan calls for over a period that is not already on a
    /// shopping list.
    ///
    /// The point of the whole feature. A week planned on Sunday should turn
    /// into a shopping list on Sunday, and a family that has to re-read seven
    /// recipes to write that list will do it once and then stop planning.
    ///
    /// Matching against the list is case- and accent-insensitive and considers
    /// only items still to buy, so an ingredient bought last week reappears for
    /// this week's plan rather than being silently assumed to be in the
    /// cupboard.
    ///
    /// - Parameters:
    ///   - start: The first day to shop for.
    ///   - end: The last day to shop for.
    ///   - existingItems: Items already on the household's lists.
    /// - Returns: Ingredients in the order the plan first mentions them.
    public func ingredientsToBuy(
        from start: Date,
        to end: Date,
        excluding existingItems: some Collection<ShoppingItem> = [ShoppingItem]()
    ) -> [Ingredient] {
        let firstDay = calendar.startOfDay(for: start)
        let lastDay = max(firstDay, calendar.startOfDay(for: end))
        let alreadyListed = Set(existingItems.pending.map(\.duplicateKey))

        var order: [String] = []
        var names: [String: String] = [:]
        var mealsByKey: [String: [PlannedMeal]] = [:]

        for meal in meals.inDays(firstDay...lastDay, calendar: calendar) {
            for ingredient in meal.ingredients {
                let key = ingredient.searchKey
                guard !alreadyListed.contains(key) else { continue }
                if names[key] == nil {
                    names[key] = ingredient.value
                    order.append(key)
                }
                mealsByKey[key, default: []].append(meal)
            }
        }

        return order.compactMap { key in
            guard let name = names[key] else { return nil }
            return Ingredient(name: name, meals: mealsByKey[key] ?? [], key: key)
        }
    }
}

// MARK: - When a slot has passed

extension PlannedMeal.Slot {
    /// The hour after which this slot is no longer the next meal.
    ///
    /// Boundaries rather than mealtimes: lunch stops being what is coming next
    /// in the middle of the afternoon, not at one o'clock, and dinner holds the
    /// answer until the day is genuinely over. A snack is never the answer to
    /// "what's next" and so passes immediately.
    fileprivate var passesAfterHour: Int {
        switch self {
        case .breakfast: 10
        case .lunch: 15
        case .dinner: 23
        case .snack: 0
        }
    }
}

// MARK: - Snapshot convenience

extension HouseholdSnapshot {
    /// The meal plan over this household, ready to query.
    public var mealPlan: MealPlan {
        MealPlan(meals: plannedMeals, calendar: household.calendar())
    }
}
