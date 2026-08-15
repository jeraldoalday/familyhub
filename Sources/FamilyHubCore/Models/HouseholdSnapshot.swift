import Foundation

/// Everything about one household, in a single immutable value.
///
/// A household's entire dataset is small — a dozen members at most, a few dozen
/// chores, a year of completions. Loading it whole and deriving every screen
/// from it is both simpler and faster than issuing a query per view: there are
/// no partial loading states to design, no per-screen fetch to keep in sync,
/// and rendering a screen becomes a pure function of a value the caller already
/// holds.
///
/// This is what makes the app feel instant offline. It is also what would stop
/// scaling if FamilyHub were a team product with ten thousand records — which
/// is precisely why it is not one.
public struct HouseholdSnapshot: Sendable, Codable {

    /// The household itself.
    public var household: Household

    /// Everyone who has ever been in it, including removed members, whose
    /// records must survive so historical completions still name a real person.
    public var members: [Member]

    /// Every chore, including archived ones.
    public var chores: [Chore]

    /// Completion records.
    public var completions: [ChoreCompletion]

    /// The points ledger, append-only.
    public var ledgerEntries: [LedgerEntry]

    /// Rewards on offer, including withdrawn ones.
    public var rewards: [Reward]

    /// Shopping lists, including archived ones.
    public var shoppingLists: [ShoppingList]

    /// Items across all lists.
    public var shoppingItems: [ShoppingItem]

    /// Creates a snapshot.
    public init(
        household: Household,
        members: [Member] = [],
        chores: [Chore] = [],
        completions: [ChoreCompletion] = [],
        ledgerEntries: [LedgerEntry] = [],
        rewards: [Reward] = [],
        shoppingLists: [ShoppingList] = [],
        shoppingItems: [ShoppingItem] = []
    ) {
        self.household = household
        self.members = members
        self.chores = chores
        self.completions = completions
        self.ledgerEntries = ledgerEntries
        self.rewards = rewards
        self.shoppingLists = shoppingLists
        self.shoppingItems = shoppingItems
    }
}

// MARK: - Lookups

extension HouseholdSnapshot {
    /// The members still in the household, in display order.
    public var activeMembers: [Member] {
        members.filter(\.isActive).sorted(by: Member.displayOrder)
    }

    /// The chores still in rotation.
    public var activeChores: [Chore] {
        chores.filter(\.isActive)
    }

    /// The ledger over this household's entries.
    public var ledger: PointsLedger {
        PointsLedger(entries: ledgerEntries)
    }

    /// A recurrence engine using the household's calendar.
    public var engine: RecurrenceEngine {
        RecurrenceEngine(household: household)
    }

    /// Finds a member by identifier.
    public func member(_ id: Identifier<Member>) -> Member? {
        members.first { $0.id == id }
    }

    /// Finds a chore by identifier.
    public func chore(_ id: Identifier<Chore>) -> Chore? {
        chores.first { $0.id == id }
    }

    /// Finds a reward by identifier.
    public func reward(_ id: Identifier<Reward>) -> Reward? {
        rewards.first { $0.id == id }
    }

    /// The items on one list.
    public func items(on listID: Identifier<ShoppingList>) -> [ShoppingItem] {
        shoppingItems.filter { $0.listID == listID }
    }

    /// Requires a member, throwing if they are gone.
    ///
    /// - Throws: ``DomainError/notFound(entity:id:)``.
    public func requireMember(_ id: Identifier<Member>) throws -> Member {
        guard let found = member(id) else {
            throw DomainError.notFound(entity: "Member", id: id.description)
        }
        return found
    }

    /// Requires a chore, throwing if it is gone.
    ///
    /// - Throws: ``DomainError/notFound(entity:id:)``.
    public func requireChore(_ id: Identifier<Chore>) throws -> Chore {
        guard let found = chore(id) else {
            throw DomainError.notFound(entity: "Chore", id: id.description)
        }
        return found
    }

    /// Requires a reward, throwing if it is gone.
    ///
    /// - Throws: ``DomainError/notFound(entity:id:)``.
    public func requireReward(_ id: Identifier<Reward>) throws -> Reward {
        guard let found = reward(id) else {
            throw DomainError.notFound(entity: "Reward", id: id.description)
        }
        return found
    }
}

// MARK: - The day's agenda

extension HouseholdSnapshot {
    /// One chore, on one day, with everything a row needs to render itself.
    ///
    /// Assembled here rather than in the view so that "is this mine, is it
    /// done, is it late" is answered once, by the layer that owns those rules,
    /// and cannot be re-derived differently on each screen that shows a chore.
    public struct AgendaEntry: Sendable, Identifiable {
        /// The chore template.
        public let chore: Chore

        /// The day this occurrence falls on.
        public let day: Date

        /// Its zero-based position in the chore's sequence, which resolves a
        /// rotating assignment.
        public let occurrenceIndex: Int

        /// Who it belongs to, or `nil` when anyone may claim it.
        public let assignee: Member?

        /// The completion record, if it has been done.
        public let completion: ChoreCompletion?

        /// Whether it is done, whether or not the points are approved yet.
        public var isDone: Bool { completion != nil }

        /// Whether it is waiting on an adult.
        public var needsApproval: Bool { completion?.approval.needsReview ?? false }

        /// A stable identity across reloads: the same chore on the same day is
        /// the same row, so list animations behave.
        public var id: ChoreCompletion.OccurrenceKey {
            ChoreCompletion.OccurrenceKey(choreID: chore.id, day: day)
        }
    }

    /// The chores due on a given day, in the order the home screen shows them.
    ///
    /// - Parameters:
    ///   - day: The day of interest.
    ///   - memberID: When supplied, limits the agenda to that person's chores
    ///     plus the unassigned ones anybody can pick up.
    public func agenda(
        for day: Date,
        memberID: Identifier<Member>? = nil
    ) -> [AgendaEntry] {
        let engine = self.engine
        let normalizedDay = engine.calendar.startOfDay(for: day)

        // Indexed once rather than searched per chore: a household with a
        // year of history has thousands of completions, and a linear scan
        // inside the loop would make the home screen quadratic.
        let completionsByOccurrence = Dictionary(
            completions.deduplicatedByOccurrence().map { ($0.occurrenceKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var entries: [AgendaEntry] = []
        for chore in activeChores {
            guard chore.occurs(on: normalizedDay, using: engine) else { continue }
            let index = chore.occurrenceIndex(of: normalizedDay, using: engine) ?? 0
            let assigneeID = chore.assignee(forOccurrenceIndex: index)

            if let memberID {
                // An unassigned chore stays on everyone's list — it is open for
                // whoever gets to it first, which is the point of leaving it
                // unassigned.
                let isMine = assigneeID == nil || assigneeID == memberID
                guard isMine else { continue }
            }

            let key = ChoreCompletion.OccurrenceKey(choreID: chore.id, day: normalizedDay)
            entries.append(
                AgendaEntry(
                    chore: chore,
                    day: normalizedDay,
                    occurrenceIndex: index,
                    assignee: assigneeID.flatMap(member),
                    completion: completionsByOccurrence[key]
                )
            )
        }

        return entries.sorted { lhs, rhs in
            // Outstanding work first — a list that opens on a wall of ticks
            // buries the thing the person actually came to do.
            if lhs.isDone != rhs.isDone { return !lhs.isDone }
            let comparison = lhs.chore.title.value
                .localizedCaseInsensitiveCompare(rhs.chore.title.value)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.chore.id < rhs.chore.id
        }
    }

    /// Completions across the household still waiting on an adult.
    public var reviewQueue: [ChoreCompletion] {
        completions.awaitingReview
    }
}
