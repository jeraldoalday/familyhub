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

    // MARK: - Chores

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
}
