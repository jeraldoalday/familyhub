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

    /// Rewards somebody has spent points on, in every state — owed, handed
    /// over, and called off.
    public var redemptions: [Redemption]

    /// Shopping lists, including archived ones.
    public var shoppingLists: [ShoppingList]

    /// Items across all lists.
    public var shoppingItems: [ShoppingItem]

    /// The meal plan, one record per decided slot.
    public var plannedMeals: [PlannedMeal]

    /// The family calendar, including events that have been called off.
    public var events: [CalendarEvent]

    /// Requests to swap a single occurrence of a chore, answered or not.
    public var coverRequests: [CoverRequest]

    /// Creates a snapshot.
    public init(
        household: Household,
        members: [Member] = [],
        chores: [Chore] = [],
        completions: [ChoreCompletion] = [],
        ledgerEntries: [LedgerEntry] = [],
        rewards: [Reward] = [],
        redemptions: [Redemption] = [],
        shoppingLists: [ShoppingList] = [],
        shoppingItems: [ShoppingItem] = [],
        plannedMeals: [PlannedMeal] = [],
        events: [CalendarEvent] = [],
        coverRequests: [CoverRequest] = []
    ) {
        self.household = household
        self.members = members
        self.chores = chores
        self.completions = completions
        self.ledgerEntries = ledgerEntries
        self.rewards = rewards
        self.redemptions = redemptions
        self.shoppingLists = shoppingLists
        self.shoppingItems = shoppingItems
        self.plannedMeals = plannedMeals
        self.events = events
        self.coverRequests = coverRequests
    }

    /// Decodes a snapshot, tolerating collections a previous build never wrote.
    ///
    /// Synthesised decoding treats a missing array as a failure, which would
    /// make every backup taken before a feature existed unreadable by the build
    /// that adds it — the family's file would still be on disk and the app
    /// would simply refuse it. Absent is read as empty instead, which is what
    /// it means: that household had no meal plan because there was no meal plan
    /// to have.
    ///
    /// The other collections are decoded the same way for the same reason,
    /// including the ones that have always been written. A restore that fails
    /// because a hand-edited file omits `rewards: []` helps nobody, and the
    /// household is still refused if the parts that identify it are missing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.household = try container.decode(Household.self, forKey: .household)
        self.members = try container.decodeIfPresent([Member].self, forKey: .members) ?? []
        self.chores = try container.decodeIfPresent([Chore].self, forKey: .chores) ?? []
        self.completions =
            try container.decodeIfPresent([ChoreCompletion].self, forKey: .completions) ?? []
        self.ledgerEntries =
            try container.decodeIfPresent([LedgerEntry].self, forKey: .ledgerEntries) ?? []
        self.rewards = try container.decodeIfPresent([Reward].self, forKey: .rewards) ?? []
        self.redemptions =
            try container.decodeIfPresent([Redemption].self, forKey: .redemptions) ?? []
        self.shoppingLists =
            try container.decodeIfPresent([ShoppingList].self, forKey: .shoppingLists) ?? []
        self.shoppingItems =
            try container.decodeIfPresent([ShoppingItem].self, forKey: .shoppingItems) ?? []
        self.plannedMeals =
            try container.decodeIfPresent([PlannedMeal].self, forKey: .plannedMeals) ?? []
        self.events = try container.decodeIfPresent([CalendarEvent].self, forKey: .events) ?? []
        self.coverRequests =
            try container.decodeIfPresent([CoverRequest].self, forKey: .coverRequests) ?? []
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

    /// The events still on the calendar.
    public var activeEvents: [CalendarEvent] {
        events.active
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

    /// Finds a redemption by identifier.
    public func redemption(_ id: Identifier<Redemption>) -> Redemption? {
        redemptions.first { $0.id == id }
    }

    /// Finds a calendar event by identifier.
    public func event(_ id: Identifier<CalendarEvent>) -> CalendarEvent? {
        events.first { $0.id == id }
    }

    /// Finds a cover request by identifier.
    public func coverRequest(_ id: Identifier<CoverRequest>) -> CoverRequest? {
        coverRequests.first { $0.id == id }
    }

    /// A chore's schedule as a phrase, in this household's week order.
    ///
    /// The rule can render itself, but only a caller holding the household
    /// knows which day its week starts on — and a row that asks the rule
    /// directly gets the device's locale, which is not the same thing for a
    /// family that has chosen otherwise. Answering it here is what stops each
    /// screen having to remember.
    public func scheduleSummary(of chore: Chore) -> String {
        chore.recurrence.summary(firstWeekday: household.firstWeekday)
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

    /// Requires a member who is still in the household.
    ///
    /// The distinction from ``requireMember(_:)`` is the whole point of keeping
    /// removed members on file. Their record has to survive, because a year of
    /// completions and ledger entries names them and history that points at
    /// nobody is worse than no history. What must not survive is their
    /// authority: a teenager who has moved out still resolves by identifier, so
    /// a command that only asks whether the record exists will happily let them
    /// spend points, add chores, or change settings from a device nobody
    /// remembered to sign out.
    ///
    /// - Throws: ``DomainError/notFound(entity:id:)`` when there is no such
    ///   record at all, or ``DomainError/memberNotInHousehold(_:)`` when they
    ///   have been removed.
    public func requireActiveMember(_ id: Identifier<Member>) throws -> Member {
        let found = try requireMember(id)
        guard found.isActive else {
            throw DomainError.memberNotInHousehold(id)
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

    /// Requires a redemption, throwing if it is gone.
    ///
    /// - Throws: ``DomainError/notFound(entity:id:)``.
    public func requireRedemption(_ id: Identifier<Redemption>) throws -> Redemption {
        guard let found = redemption(id) else {
            throw DomainError.notFound(entity: "Redemption", id: id.description)
        }
        return found
    }

    /// Requires a calendar event, throwing if it is gone.
    ///
    /// - Throws: ``DomainError/notFound(entity:id:)``.
    public func requireEvent(_ id: Identifier<CalendarEvent>) throws -> CalendarEvent {
        guard let found = event(id) else {
            throw DomainError.notFound(entity: "Event", id: id.description)
        }
        return found
    }

    /// Requires a cover request, throwing if it is gone.
    ///
    /// - Throws: ``DomainError/notFound(entity:id:)``.
    public func requireCoverRequest(_ id: Identifier<CoverRequest>) throws -> CoverRequest {
        guard let found = coverRequest(id) else {
            throw DomainError.notFound(entity: "Cover request", id: id.description)
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

        /// The accepted request that handed this occurrence to somebody else,
        /// when one exists.
        public let cover: CoverRequest?

        /// Who took the occurrence on, when somebody did.
        public let coveringMember: Member?

        /// Whether somebody else has taken this occurrence on.
        public var isCovered: Bool { coveringMember != nil }

        /// Who the row is actually waiting on: whoever is covering, or the
        /// person the rota named.
        ///
        /// Every screen that shows a chore has to answer this, and answering it
        /// per screen is how one of them ends up naming the person who asked to
        /// be let off.
        public var responsible: Member? { coveringMember ?? assignee }

        /// Whether it is done, whether or not the points are approved yet.
        ///
        /// A completion an adult sent back does not count. The row it produces
        /// carries that record so it can say *why* it is outstanding again,
        /// which is the difference between a chore that reappeared for no
        /// visible reason and one that reappeared with "you missed under the
        /// table" attached.
        public var isDone: Bool { completion?.approval.countsAsDone ?? false }

        /// Whether it is waiting on an adult.
        public var needsApproval: Bool { completion?.approval.needsReview ?? false }

        /// Whether an adult sent it back, so it is due again today.
        public var wasRejected: Bool { completion?.approval.isRejected ?? false }

        /// Why it was sent back, when a reason was given.
        public var rejectionReason: String? { completion?.approval.rejectionReason }

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
    /// - Returns: Rows with outstanding work first, then finished work.
    public func agenda(
        for day: Date,
        memberID: Identifier<Member>? = nil
    ) -> [AgendaEntry] {
        let engine = self.engine
        let normalizedDay = engine.calendar.startOfDay(for: day)

        // Indexed once, for the same reason the completions are: a household
        // that swaps chores often accumulates requests, and searching them per
        // chore would put a second linear scan inside the loop.
        let coverByOccurrence = coverRequests.acceptedCoversByOccurrence()

        // Indexed once rather than searched per chore: a household with a
        // year of history has thousands of completions, and a linear scan
        // inside the loop would make the home screen quadratic.
        let completionsByOccurrence = Dictionary(
            completions.deduplicatedByOccurrence().map { ($0.occurrenceKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var entries: [AgendaEntry] = []
        for chore in activeChores {
            // One walk of the schedule per chore, answering both "does it fall
            // today" and "whose turn is it" — asking those separately walks
            // from the chore's start twice for every row on the screen.
            guard
                let occurrence =
                    chore
                    .indexedOccurrences(
                        in: normalizedDay...normalizedDay, using: engine, maximum: 1
                    )
                    .first
            else { continue }
            let index = occurrence.index
            let assigneeID = chore.assignee(forOccurrenceIndex: index)
            let key = ChoreCompletion.OccurrenceKey(choreID: chore.id, day: normalizedDay)
            let cover = coverByOccurrence[key]
            let coveringMemberID = cover?.resolution.coveringMemberID

            if let memberID {
                // An unassigned chore stays on everyone's list — it is open for
                // whoever gets to it first, which is the point of leaving it
                // unassigned.
                //
                // A covered one moves wholesale: it appears for whoever took it
                // on and disappears for the person they took it from. Leaving
                // it on both lists would make the morning digest count a chore
                // that has been dealt with, which is the thing the swap was
                // for — and the person who asked can still tick it off if their
                // evening frees up, they simply are not being asked to.
                let isMine =
                    coveringMemberID.map { $0 == memberID }
                    ?? (assigneeID == nil || assigneeID == memberID)
                guard isMine else { continue }
            }

            entries.append(
                AgendaEntry(
                    chore: chore,
                    day: normalizedDay,
                    occurrenceIndex: index,
                    assignee: assigneeID.flatMap(member),
                    completion: completionsByOccurrence[key],
                    cover: cover,
                    coveringMember: coveringMemberID.flatMap(member)
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

// MARK: - Rewards

extension HouseholdSnapshot {
    /// The rewards the household has been paid for and not yet handed over,
    /// oldest promise first.
    ///
    /// The rewards equivalent of ``reviewQueue``, and the more important of the
    /// two. A completion nobody approves is a child waiting for points; a
    /// reward nobody hands over is a child who has already paid for something
    /// and learned that paying does not work.
    public var owedRedemptions: [Redemption] { redemptions.owed }

    /// The promises that have gone unkept long enough to be worth chasing.
    ///
    /// - Parameter date: The moment being asked about.
    /// - Returns: The overdue redemptions, oldest first.
    public func overdueRedemptions(on date: Date) -> [Redemption] {
        redemptions.overdue(on: date, calendar: household.calendar())
    }

    /// One member's redemptions, newest first.
    ///
    /// - Parameter memberID: Whose history is wanted.
    /// - Returns: Everything they have redeemed, in any state.
    public func redemptions(by memberID: Identifier<Member>) -> [Redemption] {
        redemptions.redeemed(by: memberID)
    }

    /// What the household still owes one member, in points.
    ///
    /// Not the same number as their balance and not a substitute for it: these
    /// points have already left the balance. It is what a rewards screen shows
    /// beside it so a child can see that the twenty-five points which vanished
    /// last Tuesday turned into something, and are still owed.
    ///
    /// - Parameter memberID: Whose promises are being totalled.
    /// - Returns: The value of what they are still waiting for.
    public func owedPoints(to memberID: Identifier<Member>) -> Int {
        redemptions.reduce(into: 0) { total, redemption in
            guard redemption.isOwed, redemption.memberID == memberID else { return }
            total += redemption.cost
        }
    }

    /// Whether a member may redeem a reward right now, and why not when they
    /// may not.
    ///
    /// Assembled here because it is the one question that needs three things at
    /// once — the reward, the balance, and the member's own redemption history
    /// — and a screen that gathers them itself is a screen that will eventually
    /// gather them slightly differently from the command that refuses the tap.
    ///
    /// The cooldown is answered from the redemption records rather than from
    /// the ledger, so a reward somebody redeemed and then changed their mind
    /// about does not lock them out of it for a week.
    ///
    /// - Parameters:
    ///   - reward: The reward being considered.
    ///   - memberID: Who wants it.
    ///   - date: The current moment.
    /// - Returns: Why it can or cannot be redeemed now.
    public func availability(
        of reward: Reward,
        for memberID: Identifier<Member>,
        on date: Date
    ) -> Reward.Availability {
        reward.availability(
            forBalance: ledger.balance(for: memberID),
            lastRedemption: redemptions.lastKeptRedemption(of: reward.id, by: memberID),
            on: date,
            calendar: household.calendar()
        )
    }
}

// MARK: - Cover

extension HouseholdSnapshot {
    /// Who has taken on a given occurrence, if anybody has.
    ///
    /// - Parameter key: The occurrence being asked about.
    /// - Returns: The member covering it, or `nil`.
    public func cover(for key: ChoreCompletion.OccurrenceKey) -> Identifier<Member>? {
        coverRequests.coverFor(key)
    }

    /// The cover requests `memberID` could answer right now, oldest first.
    ///
    /// - Parameters:
    ///   - memberID: Whose list is being built.
    ///   - date: The moment being asked about, so a request for a day that has
    ///     gone by drops off rather than accumulating on a screen forever.
    /// - Returns: The live requests addressed to them.
    public func coverInbox(
        for memberID: Identifier<Member>,
        on date: Date
    ) -> [CoverRequest] {
        coverRequests.addressedTo(memberID, on: date, calendar: household.calendar())
    }

    /// Every request still waiting for an answer as of `date`, oldest first.
    ///
    /// - Parameter date: The moment being asked about.
    /// - Returns: The household's outstanding asks.
    public func liveCoverRequests(on date: Date) -> [CoverRequest] {
        let calendar = household.calendar()
        return coverRequests.open.filter { $0.isLive(on: date, calendar: calendar) }
    }
}
