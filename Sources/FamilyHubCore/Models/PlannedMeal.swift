import Foundation

/// One meal, on one day, that the household has decided on.
///
/// Meal planning has been half-present in the domain since the beginning:
/// ``Household/Tier/includesMealPlanning`` sells it, ``DomainError/Feature``
/// names it, and ``DomainError/Action/manageMealPlan`` says who may change it.
/// This is the record those three have been referring to.
///
/// The unit is a *slot on a day* rather than a recipe. A household does not
/// plan "spaghetti bolognese" in the abstract; it plans Thursday's dinner, and
/// the interesting questions — what is left to decide, who is cooking, what has
/// to be bought — are all questions about slots. Modelling the slot as the
/// entity is what keeps "Thursday dinner" a single row that two devices can
/// both edit and converge on, rather than two competing suggestions the family
/// has to reconcile in the kitchen at six o'clock.
public struct PlannedMeal: Entity {
    public let id: Identifier<PlannedMeal>

    /// The household whose week this belongs to.
    public let householdID: Identifier<Household>

    /// The day it is planned for, normalised to the start of the day.
    public private(set) var day: Date

    /// Which meal of the day.
    public private(set) var slot: Slot

    /// What is being eaten — "Spaghetti bolognese", "Leftovers", "Out".
    public private(set) var title: ValidatedText

    /// Anything the cook needs to know: "start the sauce at 5", "Sam is at
    /// football until 7".
    public private(set) var notes: ValidatedText?

    /// Who is cooking, when the household has decided.
    ///
    /// Optional rather than defaulted to whoever planned it. In most households
    /// the answer is obvious and does not need recording, and a field that
    /// guesses would put a name against every meal — which turns an unanswered
    /// question into a wrong answer somebody has to correct.
    public private(set) var cookID: Identifier<Member>?

    /// What has to be in the house for it, in the order the cook would read
    /// them.
    ///
    /// Kept on the meal rather than in a recipe entity of its own. The whole
    /// value of planning a week is knowing what to buy, and a plan that cannot
    /// answer that is a calendar with food written on it.
    public private(set) var ingredients: [ValidatedText]

    /// How many people it is for, when that is worth saying — a Sunday roast
    /// with grandparents coming is a different shopping list from a Tuesday.
    public private(set) var servings: Int?

    /// Who planned it.
    public let plannedBy: Identifier<Member>

    /// When it was planned.
    public let createdAt: Date

    /// Creates a planned meal.
    ///
    /// - Throws: ``DomainError/blank(field:)``,
    ///   ``DomainError/tooLong(field:limit:)``, or
    ///   ``DomainError/outOfRange(field:allowed:)`` if the servings are not
    ///   plausible.
    public init(
        id: Identifier<PlannedMeal> = Identifier(),
        householdID: Identifier<Household>,
        day: Date,
        slot: Slot,
        title: String,
        notes: String? = nil,
        cookID: Identifier<Member>? = nil,
        ingredients: [String] = [],
        servings: Int? = nil,
        plannedBy: Identifier<Member>,
        createdAt: Date,
        calendar: Calendar
    ) throws {
        self.id = id
        self.householdID = householdID
        // Normalised on the way in for the same reason a completion's
        // occurrence day is: two devices planning Thursday's dinner at
        // different times of day must produce the same key, or the week ends up
        // with two Thursdays.
        self.day = calendar.startOfDay(for: day)
        self.slot = slot
        self.title = try ValidatedText(title, field: .mealTitle, limit: Limits.mealTitleLength)
        self.notes = try ValidatedText.optional(
            notes, field: .mealNotes, limit: Limits.notesLength
        )
        self.cookID = cookID
        self.ingredients = try Self.validate(ingredients)
        self.servings = try servings.map { try $0.validated(in: Limits.servings, field: .quantity) }
        self.plannedBy = plannedBy
        self.createdAt = createdAt
    }

    /// Trims, validates, deduplicates, and bounds a list of ingredients.
    ///
    /// Duplicates collapse case- and accent-insensitively, keeping the first
    /// spelling. Somebody typing a recipe out twice should not put two lots of
    /// onions on the shopping list, and the first spelling is the one they
    /// meant — the second is nearly always the typo.
    ///
    /// - Throws: ``DomainError/blank(field:)``,
    ///   ``DomainError/tooLong(field:limit:)``, or
    ///   ``DomainError/outOfRange(field:allowed:)`` when there are more
    ///   ingredients than a meal plausibly has.
    private static func validate(_ raw: [String]) throws -> [ValidatedText] {
        var seen: Set<String> = []
        var validated: [ValidatedText] = []
        for entry in raw {
            // Blank lines are dropped rather than refused. Ingredients arrive
            // from a multi-line text field, and rejecting the whole meal
            // because somebody left a trailing newline would be absurd.
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Validated against the shopping item's field and limit because
            // that is precisely what an ingredient becomes.
            let text = try ValidatedText(
                trimmed, field: .itemName, limit: Limits.choreTitleLength
            )
            guard seen.insert(text.searchKey).inserted else { continue }
            validated.append(text)
        }
        guard validated.count <= Limits.ingredientsPerMeal else {
            throw DomainError.outOfRange(
                field: .itemName,
                allowed: 0...Limits.ingredientsPerMeal
            )
        }
        return validated
    }
}

// MARK: - Slot

extension PlannedMeal {
    /// Which meal of the day.
    ///
    /// Four fixed slots rather than free text. A household that can invent its
    /// own meal names cannot be asked "what is missing this week", because
    /// nothing is ever missing — and that question is the one the whole feature
    /// exists to answer.
    public enum Slot: String, Codable, Sendable, CaseIterable, Identifiable, Comparable {
        case breakfast
        case lunch
        case dinner
        case snack

        public var id: String { rawValue }

        /// Position through the day, used to sort a day's meals.
        public var order: Int {
            Slot.allCases.firstIndex(of: self) ?? Slot.allCases.count
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.order < rhs.order
        }

        public var label: String {
            switch self {
            case .breakfast: "Breakfast"
            case .lunch: "Lunch"
            case .dinner: "Dinner"
            case .snack: "Snack"
            }
        }

        public var symbolName: String {
            switch self {
            case .breakfast: "sunrise"
            case .lunch: "sun.max"
            case .dinner: "moon.stars"
            case .snack: "takeoutbag.and.cup.and.straw"
            }
        }

        /// The slots a week view shows a row for.
        ///
        /// Snacks are excluded deliberately. Planning every snack is a level of
        /// household administration nobody sustains past the first fortnight,
        /// and a grid with a permanently empty fourth row makes the plan look
        /// unfinished when it is not. The slot still exists for the households
        /// that want it, and a snack that has been planned is shown.
        public static let planned: [Slot] = [.breakfast, .lunch, .dinner]

        /// Whether an empty slot of this kind counts as a gap worth mentioning.
        public var isWorthPlanning: Bool { Slot.planned.contains(self) }
    }

    /// The day-and-slot pair that identifies what this record decides.
    ///
    /// Two meals sharing a key are the same decision made twice — the offline
    /// case where two parents both plan Thursday. The store resolves them by
    /// identifier; this is what lets the domain notice they collide at all.
    public struct SlotKey: Hashable, Sendable, Codable, Comparable {
        public let day: Date
        public let slot: Slot

        public init(day: Date, slot: Slot) {
            self.day = day
            self.slot = slot
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.day != rhs.day { return lhs.day < rhs.day }
            return lhs.slot < rhs.slot
        }
    }

    /// This meal's day-and-slot key.
    public var slotKey: SlotKey { SlotKey(day: day, slot: slot) }
}

// MARK: - Derived values

extension PlannedMeal {
    /// Whether anybody has been named as cook.
    public var hasCook: Bool { cookID != nil }

    /// Whether the meal needs anything bought for it.
    public var hasIngredients: Bool { !ingredients.isEmpty }

    /// The ingredients as plain strings, for handing to the shopping list.
    public var ingredientNames: [String] { ingredients.map(\.value) }

    /// A one-line description for a compact row: "Dinner — Chilli (Mary)".
    public var summary: String {
        var line = "\(slot.label) — \(title.value)"
        if let servings {
            line += " ×\(servings)"
        }
        return line
    }
}

// MARK: - Mutation

extension PlannedMeal {
    /// Returns a copy with a different title.
    public func retitled(to newTitle: String) throws -> PlannedMeal {
        var copy = self
        copy.title = try ValidatedText(
            newTitle, field: .mealTitle, limit: Limits.mealTitleLength
        )
        return copy
    }

    /// Returns a copy with different notes, or none.
    public func withNotes(_ newNotes: String?) throws -> PlannedMeal {
        var copy = self
        copy.notes = try ValidatedText.optional(
            newNotes, field: .mealNotes, limit: Limits.notesLength
        )
        return copy
    }

    /// Returns a copy with a different cook, or nobody named.
    public func cookedBy(_ memberID: Identifier<Member>?) -> PlannedMeal {
        var copy = self
        copy.cookID = memberID
        return copy
    }

    /// Returns a copy with a different ingredient list.
    ///
    /// - Throws: the same validation errors as the initialiser.
    public func withIngredients(_ newIngredients: [String]) throws -> PlannedMeal {
        var copy = self
        copy.ingredients = try Self.validate(newIngredients)
        return copy
    }

    /// Returns a copy for a different number of people.
    public func serving(_ count: Int?) throws -> PlannedMeal {
        var copy = self
        copy.servings = try count.map { try $0.validated(in: Limits.servings, field: .quantity) }
        return copy
    }

    /// Returns a copy moved to another day or slot.
    ///
    /// Moving rather than deleting and re-planning keeps the ingredients and
    /// the cook attached, which is what dragging a meal across a week grid
    /// means to the person doing it.
    public func moved(to newDay: Date, slot newSlot: Slot, calendar: Calendar) -> PlannedMeal {
        var copy = self
        copy.day = calendar.startOfDay(for: newDay)
        copy.slot = newSlot
        return copy
    }
}

// MARK: - Collections

extension Collection where Element == PlannedMeal {
    /// The meals on one day, in the order they are eaten.
    public func onDay(_ day: Date, calendar: Calendar) -> [PlannedMeal] {
        let normalized = calendar.startOfDay(for: day)
        return filter { $0.day == normalized }.sortedForDisplay()
    }

    /// The meals inside a range of days, earliest first.
    public func inDays(_ range: ClosedRange<Date>, calendar: Calendar) -> [PlannedMeal] {
        let lower = calendar.startOfDay(for: range.lowerBound)
        let upper = calendar.startOfDay(for: range.upperBound)
        return filter { $0.day >= lower && $0.day <= upper }.sortedForDisplay()
    }

    /// Day order, then slot order, with the identifier as a final tiebreaker so
    /// a week grid does not reshuffle between reads.
    public func sortedForDisplay() -> [PlannedMeal] {
        sorted { lhs, rhs in
            if lhs.slotKey != rhs.slotKey { return lhs.slotKey < rhs.slotKey }
            return lhs.id < rhs.id
        }
    }

    /// Collapses meals that decide the same slot, keeping the one planned
    /// first.
    ///
    /// The same resolution ``ChoreCompletion`` uses for a doubly-recorded
    /// occurrence, and for the same reason: two devices offline at once both
    /// plan Thursday, neither is wrong, and every device has to converge on the
    /// same winner without negotiating. Wall-clock order decides, and the
    /// identifier breaks an exact tie.
    public func deduplicatedBySlot() -> [PlannedMeal] {
        var winners: [PlannedMeal.SlotKey: PlannedMeal] = [:]
        for meal in self {
            guard let existing = winners[meal.slotKey] else {
                winners[meal.slotKey] = meal
                continue
            }
            if meal.createdAt < existing.createdAt
                || (meal.createdAt == existing.createdAt && meal.id < existing.id)
            {
                winners[meal.slotKey] = meal
            }
        }
        return Array(winners.values).sortedForDisplay()
    }
}
