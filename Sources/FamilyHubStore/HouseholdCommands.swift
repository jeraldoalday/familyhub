import FamilyHubCore
import Foundation

/// The operations a household actually performs, with every rule applied.
///
/// This is the only layer allowed to write. Views call these; they do not
/// assemble records and save them directly. That matters because almost every
/// interesting operation here is really two or three writes that must agree —
/// completing a chore records a completion *and* moves points, redeeming a
/// reward debits a balance *and* consumes stock — and scattering those pairs
/// across view models is how a points total ends up disagreeing with its own
/// history.
///
/// Each command reloads a snapshot, validates against it, and writes. Reloading
/// rather than trusting what the caller holds is what makes the commands safe
/// against a stale view: a chore ticked off on another device thirty seconds
/// ago is seen here, not overwritten.
public struct HouseholdCommands: Sendable {

    private let store: any HouseholdStore
    private let dateProvider: any DateProvider

    /// Creates a command layer over a store.
    ///
    /// - Parameters:
    ///   - store: Where records are read from and written to.
    ///   - dateProvider: Injected so tests can drive time. Defaults to the
    ///     system clock.
    public init(store: any HouseholdStore, dateProvider: any DateProvider = SystemDateProvider()) {
        self.store = store
        self.dateProvider = dateProvider
    }

    // MARK: - Members

    /// Adds a member, enforcing the tier's seat limit.
    ///
    /// - Throws: ``DomainError/householdFull(limit:)`` when the plan is at
    ///   capacity, or ``DomainError/notPermitted(action:role:)`` if the actor
    ///   may not invite.
    @discardableResult
    public func addMember(
        to householdID: Identifier<Household>,
        name: String,
        role: MemberRole,
        by actorID: Identifier<Member>?
    ) async throws -> Member {
        let snapshot = try await store.snapshot(of: householdID)

        // The first member of a brand-new household has nobody to authorise
        // them, which is the one legitimate case for an absent actor.
        if let actorID {
            let actor = try snapshot.requireMember(actorID)
            try Permissions.check(.inviteMember, for: actor.role)
            guard actor.role.assignableRoles.contains(role) else {
                throw DomainError.notPermitted(action: .inviteMember, role: actor.role)
            }
        }

        try snapshot.household.validateCanAddMember(
            currentCount: snapshot.activeMembers.count
        )

        let member = try Member(
            householdID: householdID,
            name: name,
            role: role,
            avatar: Avatar.distinct(from: snapshot.activeMembers),
            joinedAt: dateProvider.now
        )
        try await store.save(member)
        return member
    }

    /// Removes a member, refusing to strand the household without an adult.
    ///
    /// - Throws: ``DomainError/wouldLeaveHouseholdWithoutAdult`` or
    ///   ``DomainError/notPermitted(action:role:)``.
    public func removeMember(
        _ memberID: Identifier<Member>,
        from householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireMember(actorID)
        let target = try snapshot.requireMember(memberID)

        try Permissions.check(.removeMember, for: actor.role)
        try Permissions.checkRemoval(of: target, from: snapshot.members)

        try await store.save(target.removed(at: dateProvider.now))
    }

    /// Changes a member's role.
    ///
    /// Guarded twice over. An actor may only assign roles their own role
    /// permits — an adult can promote a teen but cannot mint another owner,
    /// which is why ownership transfers through its own flow — and a demotion
    /// that would leave nobody able to reach settings, billing, or the approval
    /// queue is refused outright.
    ///
    /// - Throws: ``DomainError/notPermitted(action:role:)`` or
    ///   ``DomainError/wouldLeaveHouseholdWithoutAdult``.
    @discardableResult
    public func changeRole(
        of memberID: Identifier<Member>,
        to newRole: MemberRole,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws -> Member {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireMember(actorID)
        let target = try snapshot.requireMember(memberID)

        try Permissions.check(.removeMember, for: actor.role)
        guard actor.role.assignableRoles.contains(newRole) else {
            throw DomainError.notPermitted(action: .removeMember, role: actor.role)
        }
        try Permissions.checkRoleChange(of: target, to: newRole, in: snapshot.members)

        let updated = target.withRole(newRole)
        try await store.save(updated)
        return updated
    }

    /// Puts a removed member back in the household.
    ///
    /// Counts against the tier's seat limit exactly as a new member would, so a
    /// household cannot get a fourth seat on the free plan by removing somebody
    /// and reinstating them.
    ///
    /// - Throws: ``DomainError/householdFull(limit:)`` or
    ///   ``DomainError/notPermitted(action:role:)``.
    @discardableResult
    public func reinstateMember(
        _ memberID: Identifier<Member>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws -> Member {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireMember(actorID)
        let target = try snapshot.requireMember(memberID)

        try Permissions.check(.inviteMember, for: actor.role)
        guard !target.isActive else { return target }
        try snapshot.household.validateCanAddMember(currentCount: snapshot.activeMembers.count)

        let restored = target.reinstated()
        try await store.save(restored)
        return restored
    }

    // MARK: - Chores

    /// Creates a chore.
    ///
    /// - Throws: ``DomainError/notPermitted(action:role:)`` when the actor may
    ///   not create chores or may not assign them to somebody else, or a
    ///   validation error from ``Chore``.
    @discardableResult
    public func createChore(
        in householdID: Identifier<Household>,
        title: String,
        notes: String? = nil,
        assignment: Chore.Assignment = .anyone,
        points: Int = 10,
        startingOn startDate: Date? = nil,
        recurrence: RecurrenceRule = .daily,
        category: Chore.Category = .other,
        by actorID: Identifier<Member>
    ) async throws -> Chore {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireMember(actorID)
        try Permissions.check(.createChore, for: actor.role)
        try authorize(assignment, by: actor, in: snapshot)

        let calendar = snapshot.household.calendar()
        let chore = try Chore(
            householdID: householdID,
            title: title,
            notes: notes,
            assignment: assignment,
            points: points,
            // Normalised on the way in. A chore is a thing that belongs to a
            // day, and a start date carrying the afternoon it was created at
            // would make the first occurrence land a day late for anyone in a
            // timezone behind the household's.
            startDate: calendar.startOfDay(for: startDate ?? dateProvider.now),
            recurrence: recurrence,
            category: category,
            createdBy: actorID,
            createdAt: dateProvider.now
        )
        try await store.save(chore)
        return chore
    }

    /// Edits a chore, leaving anything not named alone.
    ///
    /// One command rather than six, because a chore editor saves every field at
    /// once and six commands would mean six writes, six change notifications,
    /// and a window in which the chore is half-edited.
    ///
    /// `notes` uses a double optional so that "leave the notes alone" and
    /// "clear the notes" stay distinguishable: omit the parameter for the
    /// former, pass `.some(nil)` for the latter.
    ///
    /// - Throws: ``DomainError/notPermitted(action:role:)`` or a validation
    ///   error from the new values.
    @discardableResult
    public func updateChore(
        _ choreID: Identifier<Chore>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>,
        title: String? = nil,
        notes: String?? = nil,
        assignment: Chore.Assignment? = nil,
        points: Int? = nil,
        category: Chore.Category? = nil,
        startingOn startDate: Date? = nil,
        recurrence: RecurrenceRule? = nil
    ) async throws -> Chore {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireMember(actorID)
        var chore = try snapshot.requireChore(choreID)

        try Permissions.check(.createChore, for: actor.role)
        if let assignment {
            try authorize(assignment, by: actor, in: snapshot)
        }

        if let title { chore = try chore.retitled(to: title) }
        if let notes { chore = try chore.withNotes(notes) }
        if let assignment { chore = chore.assigned(assignment) }
        if let points { chore = try chore.worth(points) }
        if let category { chore = chore.inCategory(category) }
        if startDate != nil || recurrence != nil {
            let calendar = snapshot.household.calendar()
            chore = chore.rescheduled(
                startingOn: startDate.map { calendar.startOfDay(for: $0) },
                recurrence: recurrence
            )
        }

        try await store.save(chore)
        return chore
    }

    /// Retires a chore without destroying its history.
    ///
    /// Archiving rather than deleting is what the UI offers, because
    /// completions reference the chore and a family's record of what they did
    /// should survive a spring clean of the chore list.
    @discardableResult
    public func archiveChore(
        _ choreID: Identifier<Chore>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws -> Chore {
        try await updatingChore(choreID, in: householdID, by: actorID) { chore, now in
            chore.archived(at: now)
        }
    }

    /// Returns an archived chore to the rotation.
    @discardableResult
    public func restoreChore(
        _ choreID: Identifier<Chore>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws -> Chore {
        try await updatingChore(choreID, in: householdID, by: actorID) { chore, _ in
            chore.unarchived()
        }
    }

    /// Skips one day of a chore — a holiday, a week away.
    ///
    /// Recorded as an exception rather than by editing the schedule, so "we
    /// skipped bin day that once" does not permanently move bin day.
    @discardableResult
    public func skipChore(
        _ choreID: Identifier<Chore>,
        on day: Date,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws -> Chore {
        let calendar = try await store.snapshot(of: householdID).household.calendar()
        return try await updatingChore(choreID, in: householdID, by: actorID) { chore, _ in
            chore.skipping(day, calendar: calendar)
        }
    }

    /// Puts a skipped day back on the schedule.
    @discardableResult
    public func unskipChore(
        _ choreID: Identifier<Chore>,
        on day: Date,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws -> Chore {
        let calendar = try await store.snapshot(of: householdID).household.calendar()
        return try await updatingChore(choreID, in: householdID, by: actorID) { chore, _ in
            chore.unskipping(day, calendar: calendar)
        }
    }

    /// Erases a chore and everything recorded against it.
    ///
    /// Restricted to whoever can manage the household, and separate from
    /// archiving on purpose. This is the destructive one — it takes the
    /// completions with it, which changes what the history screen shows — and
    /// it exists because a chore created by mistake should be removable and
    /// because privacy law requires a genuine delete to be possible.
    ///
    /// - Throws: ``DomainError/notPermitted(action:role:)``.
    public func deleteChore(
        _ choreID: Identifier<Chore>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireMember(actorID)
        _ = try snapshot.requireChore(choreID)
        try Permissions.check(.manageHousehold, for: actor.role)
        try await store.deleteChore(choreID)
    }

    /// Marks an occurrence of a chore as done.
    ///
    /// Writes a completion and, when the household does not require approval,
    /// the ledger entry that pays for it. The two are written together here so
    /// they cannot come apart.
    ///
    /// - Throws: ``DomainError/notScheduled(on:)`` if the chore does not fall
    ///   on that day, ``DomainError/alreadyCompleted`` if the occurrence is
    ///   already recorded, ``DomainError/notPermitted(action:role:)``, or
    ///   ``DomainError/notFound(entity:id:)``.
    @discardableResult
    public func completeChore(
        _ choreID: Identifier<Chore>,
        on day: Date,
        in householdID: Identifier<Household>,
        by memberID: Identifier<Member>
    ) async throws -> ChoreCompletion {
        let snapshot = try await store.snapshot(of: householdID)
        let chore = try snapshot.requireChore(choreID)
        let member = try snapshot.requireMember(memberID)
        let calendar = snapshot.household.calendar()
        let normalizedDay = calendar.startOfDay(for: day)

        // Asked before anything else, because a day the schedule never
        // produced is not a permission question — nobody is authorised to
        // complete an occurrence that does not exist. This catches three cases
        // that all arrive as the same mistake: a day outside the recurrence, a
        // day the family explicitly skipped, and any day at all once the chore
        // has been archived. Without it a stale view, a widget holding
        // yesterday's agenda, or a replayed sync write pays out points for a
        // Tuesday the chore was never due on.
        guard chore.occurs(on: normalizedDay, using: snapshot.engine) else {
            throw DomainError.notScheduled(on: normalizedDay)
        }

        try Permissions.authorizeCompletion(
            of: chore,
            on: normalizedDay,
            by: member,
            engine: snapshot.engine
        )

        // Guards the double-tap and the two-devices case alike. Without it the
        // same Tuesday pays out twice.
        let key = ChoreCompletion.OccurrenceKey(choreID: choreID, day: normalizedDay)
        guard !snapshot.completions.contains(where: { $0.occurrenceKey == key }) else {
            throw DomainError.alreadyCompleted
        }

        let needsApproval = snapshot.household.requiresApproval && !member.role.isAdult
        let completion = ChoreCompletion(
            householdID: householdID,
            choreID: choreID,
            occurrenceDay: normalizedDay,
            completedBy: memberID,
            completedAt: dateProvider.now,
            approval: needsApproval ? .pending : .notRequired,
            pointsAwarded: chore.points,
            calendar: calendar
        )
        try await store.save(completion)

        // Points move only once the completion counts. Paying out on a pending
        // completion and clawing back on rejection would show a child a number
        // that goes down for reasons they cannot see.
        if completion.approval.countsTowardBalance, chore.points > 0 {
            try await store.append(.earned(completion, note: chore.title.value))
        }

        return completion
    }

    /// Approves a pending completion and banks its points.
    ///
    /// - Throws: ``DomainError/notPermitted(action:role:)``.
    @discardableResult
    public func approveCompletion(
        _ completionID: Identifier<ChoreCompletion>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws -> ChoreCompletion {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireMember(actorID)
        guard let completion = snapshot.completions.first(where: { $0.id == completionID }) else {
            throw DomainError.notFound(entity: "Completion", id: completionID.description)
        }

        try Permissions.authorizeApproval(of: completion, by: actor)

        // Approving twice would append a second ledger entry and pay the chore
        // out again — worth guarding, because a slow network makes a parent tap
        // approve more than once.
        guard !completion.approval.countsTowardBalance else {
            return completion
        }

        let approved = completion.approved(by: actorID, at: dateProvider.now)
        try await store.save(approved)

        if approved.pointsAwarded > 0 {
            let title = snapshot.chore(approved.choreID)?.title.value
            try await store.append(.earned(approved, note: title))
        }
        return approved
    }

    /// Sends a completion back, leaving the points unbanked.
    @discardableResult
    public func rejectCompletion(
        _ completionID: Identifier<ChoreCompletion>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>,
        reason: String? = nil
    ) async throws -> ChoreCompletion {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireMember(actorID)
        guard let completion = snapshot.completions.first(where: { $0.id == completionID }) else {
            throw DomainError.notFound(entity: "Completion", id: completionID.description)
        }

        try Permissions.authorizeApproval(of: completion, by: actor)

        let rejected = completion.rejected(by: actorID, at: dateProvider.now, reason: reason)
        try await store.save(rejected)
        return rejected
    }

    // MARK: - Rewards

    /// Redeems a reward, debiting points and consuming stock together.
    ///
    /// - Throws: ``DomainError/insufficientPoints(balance:required:)`` with the
    ///   shortfall attached, or ``DomainError/rewardUnavailable(reason:)``.
    @discardableResult
    public func redeemReward(
        _ rewardID: Identifier<Reward>,
        in householdID: Identifier<Household>,
        by memberID: Identifier<Member>
    ) async throws -> LedgerEntry {
        let snapshot = try await store.snapshot(of: householdID)
        let member = try snapshot.requireMember(memberID)
        let reward = try snapshot.requireReward(rewardID)
        let calendar = snapshot.household.calendar()

        try Permissions.check(.redeemReward, for: member.role)
        // Eligibility only. Stock, cooldown, and whether a parent switched the
        // reward off are all reported by the ledger check below with their own
        // specific reason — telling a child a sold-out reward "isn't offered to
        // you" is both wrong and needlessly deflating.
        guard reward.isEligible(memberID) else {
            throw DomainError.rewardUnavailable(reason: "it isn't offered to you")
        }
        try snapshot.ledger.authorizeRedemption(
            of: reward,
            by: memberID,
            on: dateProvider.now,
            calendar: calendar
        )

        let entry = LedgerEntry.spent(on: reward, by: memberID, at: dateProvider.now)
        try await store.append(entry)
        try await store.save(reward.consumingRedemption())
        return entry
    }

    /// Grants or removes points by hand.
    ///
    /// - Throws: ``DomainError/notPermitted(action:role:)`` for a non-adult.
    @discardableResult
    public func adjustPoints(
        for memberID: Identifier<Member>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>,
        amount: Int,
        note: String? = nil
    ) async throws -> LedgerEntry {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireMember(actorID)
        _ = try snapshot.requireMember(memberID)

        try Permissions.check(.adjustPoints, for: actor.role)

        let entry = LedgerEntry.adjustment(
            householdID: householdID,
            memberID: memberID,
            amount: amount,
            by: actorID,
            at: dateProvider.now,
            note: note
        )
        try await store.append(entry)
        return entry
    }

    // MARK: - Shopping

    /// Adds an item to a list, merging with a matching pending item rather than
    /// creating a duplicate row.
    ///
    /// - Returns: The item as it now stands, whether newly created or merged.
    @discardableResult
    public func addShoppingItem(
        _ name: String,
        quantity: Int = 1,
        category: ShoppingItem.Category = .other,
        to listID: Identifier<ShoppingList>,
        in householdID: Identifier<Household>,
        by memberID: Identifier<Member>
    ) async throws -> ShoppingItem {
        let snapshot = try await store.snapshot(of: householdID)
        let member = try snapshot.requireMember(memberID)
        try Permissions.check(.manageShoppingList, for: member.role)

        // Merging rather than appending is what the person standing in the shop
        // wants: one line reading 'Milk ×2', not two lines they have to notice
        // are the same thing.
        if let existing = snapshot.items(on: listID).pendingMatch(for: name) {
            let merged = existing.incremented(by: quantity)
            try await store.save(merged)
            return merged
        }

        let item = try ShoppingItem(
            listID: listID,
            householdID: householdID,
            name: name,
            quantity: quantity,
            category: category,
            addedBy: memberID,
            addedAt: dateProvider.now
        )
        try await store.save(item)
        return item
    }

    /// Ticks an item off, or puts it back on the list.
    @discardableResult
    public func setShoppingItem(
        _ itemID: Identifier<ShoppingItem>,
        purchased: Bool,
        in householdID: Identifier<Household>,
        by memberID: Identifier<Member>
    ) async throws -> ShoppingItem {
        let snapshot = try await store.snapshot(of: householdID)
        let member = try snapshot.requireMember(memberID)
        try Permissions.check(.manageShoppingList, for: member.role)

        guard let item = snapshot.shoppingItems.first(where: { $0.id == itemID }) else {
            throw DomainError.notFound(entity: "Item", id: itemID.description)
        }

        let updated =
            purchased
            ? item.purchased(by: memberID, at: dateProvider.now)
            : item.unpurchased()
        try await store.save(updated)
        return updated
    }

    // MARK: - Household settings

    /// Renames the household.
    ///
    /// - Throws: ``DomainError/notPermitted(action:role:)``.
    @discardableResult
    public func renameHousehold(
        _ householdID: Identifier<Household>,
        to name: String,
        by actorID: Identifier<Member>
    ) async throws -> Household {
        try await updatingHousehold(householdID, by: actorID) { household in
            try household.renamed(to: name)
        }
    }

    /// Turns the approval queue on or off.
    ///
    /// Switching it off does not retrospectively bank anything already pending.
    /// Those completions stay in the queue for an adult to settle, because
    /// silently paying out work a parent had deliberately held back would
    /// undo a decision they made on purpose.
    @discardableResult
    public func setApprovalRequired(
        _ required: Bool,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws -> Household {
        try await updatingHousehold(householdID, by: actorID) { household in
            household.withApprovalRequired(required)
        }
    }

    /// Changes which day the household's week starts on.
    @discardableResult
    public func setFirstWeekday(
        _ weekday: Int,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws -> Household {
        try await updatingHousehold(householdID, by: actorID) { household in
            household.withFirstWeekday(weekday)
        }
    }

    // MARK: - Rewards

    /// Creates a reward.
    ///
    /// - Throws: ``DomainError/requiresUpgrade(feature:tier:)`` on a plan
    ///   without rewards, or ``DomainError/notPermitted(action:role:)``.
    @discardableResult
    public func createReward(
        in householdID: Identifier<Household>,
        name: String,
        cost: Int,
        emoji: String? = nil,
        eligibleMemberIDs: Set<Identifier<Member>> = [],
        remainingRedemptions: Int? = nil,
        cooldownDays: Int? = nil,
        by actorID: Identifier<Member>
    ) async throws -> Reward {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireMember(actorID)
        try Permissions.check(.createReward, for: actor.role)

        // Enforced here rather than only at the paywall. A tier check that
        // lives in a view is a tier check a second screen forgets.
        guard snapshot.household.tier.includesRewards else {
            throw DomainError.requiresUpgrade(feature: .rewards, tier: snapshot.household.tier)
        }

        // Every named member has to actually be in the household, or the reward
        // is offered to nobody and silently never appears.
        for memberID in eligibleMemberIDs {
            _ = try snapshot.requireMember(memberID)
        }

        let reward = try Reward(
            householdID: householdID,
            name: name,
            cost: cost,
            emoji: emoji,
            eligibleMemberIDs: eligibleMemberIDs,
            remainingRedemptions: remainingRedemptions,
            cooldownDays: cooldownDays,
            createdAt: dateProvider.now
        )
        try await store.save(reward)
        return reward
    }

    /// Switches a reward on or off without deleting it.
    ///
    /// Withdrawing rather than deleting keeps the redemptions in the ledger
    /// explicable — an entry naming a reward that no longer exists reads as a
    /// bug to the child who spent the points.
    @discardableResult
    public func setRewardActive(
        _ rewardID: Identifier<Reward>,
        _ isActive: Bool,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws -> Reward {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireMember(actorID)
        let reward = try snapshot.requireReward(rewardID)
        try Permissions.check(.createReward, for: actor.role)

        let updated = reward.active(isActive)
        try await store.save(updated)
        return updated
    }

    // MARK: - Shopping lists

    /// Creates a shopping list.
    ///
    /// The first list a household creates becomes its default, so adding an
    /// item from a widget or from Siri has somewhere to go without asking.
    @discardableResult
    public func createShoppingList(
        in householdID: Identifier<Household>,
        name: String,
        emoji: String? = nil,
        by actorID: Identifier<Member>
    ) async throws -> ShoppingList {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireMember(actorID)
        try Permissions.check(.manageShoppingList, for: actor.role)

        let list = try ShoppingList(
            householdID: householdID,
            name: name,
            emoji: emoji,
            isDefault: snapshot.shoppingLists.filter(\.isActive).isEmpty,
            createdBy: actorID,
            createdAt: dateProvider.now
        )
        try await store.save(list)
        return list
    }

    /// Removes everything already bought from a list.
    ///
    /// A genuine delete rather than an archive, because a shopping list is a
    /// working document rather than a record: nobody wants last week's
    /// groceries kept forever, and the ledger does not reference them.
    ///
    /// - Returns: How many items were removed.
    @discardableResult
    public func clearPurchasedItems(
        from listID: Identifier<ShoppingList>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws -> Int {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireMember(actorID)
        try Permissions.check(.manageShoppingList, for: actor.role)

        let bought = snapshot.items(on: listID).purchased
        for item in bought {
            try await store.deleteShoppingItem(item.id)
        }
        return bought.count
    }

    // MARK: - Shared plumbing

    /// Loads a chore, applies a transform, and saves the result.
    ///
    /// The four schedule-editing commands differ only in the transform. Sharing
    /// the load-check-save around them is what keeps the permission check from
    /// being present on three of them and missing from the fourth.
    private func updatingChore(
        _ choreID: Identifier<Chore>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>,
        _ transform: (Chore, Date) throws -> Chore
    ) async throws -> Chore {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireMember(actorID)
        let chore = try snapshot.requireChore(choreID)
        try Permissions.check(.createChore, for: actor.role)

        let updated = try transform(chore, dateProvider.now)
        try await store.save(updated)
        return updated
    }

    /// Loads the household, applies a transform, and saves the result.
    private func updatingHousehold(
        _ householdID: Identifier<Household>,
        by actorID: Identifier<Member>,
        _ transform: (Household) throws -> Household
    ) async throws -> Household {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireMember(actorID)
        try Permissions.check(.manageHousehold, for: actor.role)

        let updated = try transform(snapshot.household)
        try await store.save(updated)
        return updated
    }

    /// Checks that the actor may hand a chore to the people named on it.
    ///
    /// Assigning work to yourself is not the same act as assigning it to
    /// somebody else, and a teen who may create their own chores must not be
    /// able to create one for a sibling.
    private func authorize(
        _ assignment: Chore.Assignment,
        by actor: Member,
        in snapshot: HouseholdSnapshot
    ) throws {
        let others = assignment.candidateMemberIDs.filter { $0 != actor.id }
        for memberID in assignment.candidateMemberIDs {
            _ = try snapshot.requireMember(memberID)
        }
        guard !others.isEmpty else { return }
        try Permissions.check(.assignChore, for: actor.role)
    }
}
