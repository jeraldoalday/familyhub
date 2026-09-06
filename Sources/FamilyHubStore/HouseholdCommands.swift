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
            let actor = try snapshot.requireActiveMember(actorID)
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
        let actor = try snapshot.requireActiveMember(actorID)
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
        let actor = try snapshot.requireActiveMember(actorID)
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
        let actor = try snapshot.requireActiveMember(actorID)
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
        let actor = try snapshot.requireActiveMember(actorID)
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

    /// Adds a pack of ready-made chores to a household.
    ///
    /// The command behind the "pick your first chores" step of onboarding, and
    /// behind the "add more" button that step leaves behind. It exists rather
    /// than the screen calling ``createChore(in:title:notes:assignment:points:startingOn:recurrence:category:by:)``
    /// in a loop for the reason every command here exists: the loop version has
    /// to decide what to do about a chore the household already has, and two
    /// screens deciding that differently is how a family ends up with "Bins"
    /// twice.
    ///
    /// Chores the household already has, by name, are skipped rather than
    /// refused. A pack is an offer, and a family that has already written down
    /// half of it should get the other half rather than an error telling them
    /// to go and find which one clashed.
    ///
    /// Everything installed is left unassigned. Choosing the rota is a decision
    /// about a particular family that a catalogue cannot make, and guessing it
    /// — round-robin over whoever happens to be in the household — produces a
    /// rota a parent has to unpick before the first Monday.
    ///
    /// - Parameters:
    ///   - pack: The pack to install.
    ///   - householdID: The household to add it to.
    ///   - startDate: The first day the chores can occur. Today by default.
    ///   - actorID: Who is installing it.
    /// - Returns: The chores created, in the pack's own order. Empty when the
    ///   household already had all of them.
    /// - Throws: ``DomainError/notPermitted(action:role:)`` when the actor may
    ///   not create chores.
    @discardableResult
    public func installChorePack(
        _ pack: ChorePack,
        in householdID: Identifier<Household>,
        startingOn startDate: Date? = nil,
        by actorID: Identifier<Member>
    ) async throws -> [Chore] {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireActiveMember(actorID)
        try Permissions.check(.createChore, for: actor.role)

        // Measured against archived chores too. A household that retired
        // "Hoover downstairs" in March decided something about that chore, and
        // handing it back as new the next time they open a pack overrules them
        // — the archive is where they put it, not a bin the app may empty.
        let existing = Set(
            snapshot.chores.map { chore in
                chore.title.value
                    .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            }
        )

        // Filtered by who is actually in the household, so a house of small
        // children is not handed "Take the bins out" as a starting point.
        let roles = snapshot.activeMembers.map(\.role)
        let calendar = snapshot.household.calendar()
        let day = calendar.startOfDay(for: startDate ?? dateProvider.now)

        var created: [Chore] = []
        for template in pack.templates(for: roles) {
            guard !existing.contains(template.duplicateKey) else { continue }
            let chore = try Chore(
                householdID: householdID,
                title: template.title,
                notes: template.notes,
                points: template.points,
                startDate: day,
                recurrence: template.recurrence,
                category: template.category,
                createdBy: actorID,
                createdAt: dateProvider.now
            )
            try await store.save(chore)
            created.append(chore)
        }
        return created
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
        let actor = try snapshot.requireActiveMember(actorID)
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
        let now = dateProvider.now
        return try await updatingChore(choreID, in: householdID, by: actorID) { chore, _ in
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
        try await updatingChore(choreID, in: householdID, by: actorID) { chore, snapshot in
            chore.skipping(day, calendar: snapshot.household.calendar())
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
        try await updatingChore(choreID, in: householdID, by: actorID) { chore, snapshot in
            chore.unskipping(day, calendar: snapshot.household.calendar())
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
        let actor = try snapshot.requireActiveMember(actorID)
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
    /// An occurrence an adult sent back may be completed again; the new record
    /// replaces the rejected one in place.
    ///
    /// - Throws: ``DomainError/notScheduled(on:)`` if the chore does not fall
    ///   on that day, ``DomainError/alreadyCompleted`` if the occurrence is
    ///   already recorded and was not rejected,
    ///   ``DomainError/notPermitted(action:role:)``, or
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
        let member = try snapshot.requireActiveMember(memberID)
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

        let key = ChoreCompletion.OccurrenceKey(choreID: choreID, day: normalizedDay)
        let coveringMemberID = snapshot.coverRequests.coverFor(key)

        try Permissions.authorizeCompletion(
            of: chore,
            on: normalizedDay,
            by: member,
            engine: snapshot.engine,
            coveringMemberID: coveringMemberID
        )

        // Guards the double-tap and the two-devices case alike. Without it the
        // same Tuesday pays out twice.
        //
        // A rejected record is the one exception: it is an instruction to do
        // the work again, so it does not block the second attempt. The redo
        // reuses its identifier rather than adding a record beside it, because
        // every store here writes by identifier — one occurrence stays one row,
        // the rejection is superseded rather than left to argue with its own
        // replacement, and a redo replayed by a sync retry still converges.
        let existing = snapshot.completions.first { $0.occurrenceKey == key }
        if let existing, !existing.approval.isRejected {
            throw DomainError.alreadyCompleted
        }

        let needsApproval = snapshot.household.requiresApproval && !member.role.isAdult
        let completion = ChoreCompletion(
            id: existing?.id ?? Identifier(),
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

        // The work is done, so nobody needs to be asked to do it. An open
        // request left standing would sit on a sibling's list all evening
        // asking about a chore that is finished, and answering it would hand
        // them an occurrence that no longer exists.
        for request in snapshot.coverRequests.about(key) where request.resolution.isOpen {
            try await store.save(try request.withdrawn(at: dateProvider.now))
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
        let actor = try snapshot.requireActiveMember(actorID)
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

    /// Sends a completion back, taking its points with it.
    ///
    /// Usually there are none to take: in a household that requires approval a
    /// child's work is pending until an adult signs it off, so rejecting it
    /// simply leaves it unpaid. But approval is off by default and never
    /// applies to an adult's own chores, which means the common case is work
    /// that has *already* been paid for — and sending it back has to undo that,
    /// or the household pays for a chore it has just declared undone and then
    /// pays again when somebody redoes it.
    ///
    /// The reversal is an entry rather than an erasure, because the ledger is
    /// append-only and because a child whose balance drops needs to see why. It
    /// carries the reason the adult gave, so the history row explains itself.
    ///
    /// - Throws: ``DomainError/notPermitted(action:role:)`` or
    ///   ``DomainError/notFound(entity:id:)``.
    @discardableResult
    public func rejectCompletion(
        _ completionID: Identifier<ChoreCompletion>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>,
        reason: String? = nil
    ) async throws -> ChoreCompletion {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireActiveMember(actorID)
        guard let completion = snapshot.completions.first(where: { $0.id == completionID }) else {
            throw DomainError.notFound(entity: "Completion", id: completionID.description)
        }

        try Permissions.authorizeApproval(of: completion, by: actor)

        // Rejecting twice would reverse twice. Worth guarding for the reason
        // approving twice is: a slow network makes a parent tap the button
        // again, and the second tap must not cost the child another ten points.
        guard !completion.approval.isRejected else { return completion }
        let wasPaid = completion.approval.countsTowardBalance

        let rejected = completion.rejected(by: actorID, at: dateProvider.now, reason: reason)
        try await store.save(rejected)

        if wasPaid, completion.pointsAwarded > 0 {
            try await store.append(
                .sentBack(completion, at: dateProvider.now, note: reason)
            )
        }
        return rejected
    }

    // MARK: - Rewards

    /// Redeems a reward: debits the points, consumes the stock, and records
    /// what the household now owes.
    ///
    /// The third of those is the one that makes the feature work. Points and
    /// stock alone leave the app believing the matter is closed at the moment a
    /// child has actually bought a promise — a film somebody has to find an
    /// evening for — and a promise nothing is tracking is a promise a busy
    /// household forgets. By the third forgotten one the currency is worth
    /// nothing and the chore rota goes with it.
    ///
    /// - Parameters:
    ///   - rewardID: What they want.
    ///   - householdID: The household it belongs to.
    ///   - memberID: Who is redeeming it.
    ///   - note: Anything they want to say with it — "can we watch it Friday?".
    /// - Returns: The redemption the household now owes.
    /// - Throws: ``DomainError/insufficientPoints(balance:required:)`` with the
    ///   shortfall attached, or ``DomainError/rewardUnavailable(reason:)``.
    @discardableResult
    public func redeemReward(
        _ rewardID: Identifier<Reward>,
        in householdID: Identifier<Household>,
        by memberID: Identifier<Member>,
        note: String? = nil
    ) async throws -> Redemption {
        let snapshot = try await store.snapshot(of: householdID)
        let member = try snapshot.requireActiveMember(memberID)
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
        // Judged on the records rather than on the ledger, so a reward somebody
        // redeemed this morning and changed their mind about does not lock them
        // out of it for the length of its cooldown.
        try snapshot.ledger.authorizeRedemption(
            of: reward,
            by: memberID,
            on: dateProvider.now,
            calendar: calendar,
            redemptions: snapshot.redemptions
        )

        let redemption = try Redemption(
            householdID: householdID,
            rewardID: rewardID,
            memberID: memberID,
            // Copied off the reward as it stands now, so re-pricing it later
            // cannot change what this redemption is worth refunding.
            cost: reward.cost,
            redeemedAt: dateProvider.now,
            note: note
        )

        // The store has no transaction, so the order is chosen for the least
        // harmful half-write. Debiting first can strand a child who paid and
        // has no promise to show for it, which an adult can put right with an
        // adjustment. Recording the promise first can strand a promise nobody
        // paid for — and cancelling that one would refund points that were
        // never taken, minting currency out of a crash.
        let entry = LedgerEntry.spent(on: reward, by: memberID, at: dateProvider.now)
        try await store.append(entry)
        try await store.save(reward.consumingRedemption())
        try await store.save(redemption)
        return redemption
    }

    /// Confirms that a redeemed reward actually happened.
    ///
    /// The point of the whole record. A queue of promises nobody can close is
    /// a queue that stops being read, and a reward that was handed over on
    /// Friday but still sits in a parent's list on Monday teaches them to
    /// ignore the list rather than the reward.
    ///
    /// - Parameters:
    ///   - redemptionID: The promise being kept.
    ///   - householdID: The household it belongs to.
    ///   - actorID: The adult confirming it.
    /// - Returns: The redemption, now given.
    /// - Throws: Whatever ``Permissions/authorizeHandOver(of:by:)`` throws.
    @discardableResult
    public func handOverReward(
        _ redemptionID: Identifier<Redemption>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws -> Redemption {
        let snapshot = try await store.snapshot(of: householdID)
        let redemption = try snapshot.requireRedemption(redemptionID)
        let actor = try snapshot.requireActiveMember(actorID)

        try Permissions.authorizeHandOver(of: redemption, by: actor)

        let given = try redemption.given(by: actorID, at: dateProvider.now)
        try await store.save(given)
        return given
    }

    /// Calls a redemption off, refunds the points, and puts the stock back.
    ///
    /// Three writes that have to agree, which is exactly why this is a command
    /// rather than three taps on a view. A cancellation that refunded without
    /// restocking would quietly destroy the last cinema ticket; one that
    /// restocked without refunding would take a child's points for a film that
    /// never happened.
    ///
    /// - Parameters:
    ///   - redemptionID: The promise being called off.
    ///   - householdID: The household it belongs to.
    ///   - actorID: Who is calling it off — the person who redeemed it, or an
    ///     adult.
    ///   - reason: Why, in their words. Carried onto the refund so the child's
    ///     history says "cinema was closed" rather than showing points that
    ///     moved for no stated reason.
    /// - Returns: The redemption, now cancelled.
    /// - Throws: Whatever ``Permissions/authorizeCancellation(of:by:)`` throws.
    @discardableResult
    public func cancelRedemption(
        _ redemptionID: Identifier<Redemption>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>,
        reason: String? = nil
    ) async throws -> Redemption {
        let snapshot = try await store.snapshot(of: householdID)
        let redemption = try snapshot.requireRedemption(redemptionID)
        let actor = try snapshot.requireActiveMember(actorID)

        try Permissions.authorizeCancellation(of: redemption, by: actor)

        // The record is settled before the points move, and that order is not
        // arbitrary: it is what stops a retry after a half-written cancellation
        // refunding the same redemption twice. A record that says cancelled
        // with the points still gone is visible and fixable; a child paid twice
        // over for a film nobody watched is not.
        let cancelled = try redemption.cancelled(by: actorID, at: dateProvider.now)
        try await store.save(cancelled)
        try await store.append(
            LedgerEntry.refunded(cancelled, at: dateProvider.now, note: reason)
        )

        // The reward may have been deleted from under the redemption, which is
        // not a reason to refuse the refund — the points matter more than the
        // stock count of something that no longer exists.
        if let reward = snapshot.reward(redemption.rewardID) {
            try await store.save(reward.returningRedemption())
        }
        return cancelled
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
        let actor = try snapshot.requireActiveMember(actorID)
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
    /// - Parameters:
    ///   - name: What to buy.
    ///   - quantity: How many.
    ///   - category: Which aisle it belongs to. Worked out from the name when
    ///     it is not given, so the fast path — type "milk", press return —
    ///     still produces a list that groups.
    ///   - listID: The list to add it to.
    ///   - householdID: The household the list belongs to.
    ///   - memberID: Who is adding it.
    /// - Returns: The item as it now stands, whether newly created or merged.
    /// - Throws: ``DomainError/notFound(entity:id:)`` when there is no such
    ///   list, ``DomainError/notPermitted(action:role:)``, or a validation
    ///   error from ``ShoppingItem``.
    @discardableResult
    public func addShoppingItem(
        _ name: String,
        quantity: Int = 1,
        category: ShoppingItem.Category? = nil,
        to listID: Identifier<ShoppingList>,
        in householdID: Identifier<Household>,
        by memberID: Identifier<Member>
    ) async throws -> ShoppingItem {
        let snapshot = try await store.snapshot(of: householdID)
        let member = try snapshot.requireActiveMember(memberID)
        try Permissions.check(.manageShoppingList, for: member.role)

        // Checked before writing, the same way `addMealIngredients` checks it.
        // An item written against a list that is not there is a record no
        // screen can render and nobody can delete: it belongs to the household,
        // so it survives every cleanup, and it belongs to no list, so it never
        // appears on one. The person who typed it watches it vanish and types
        // it again.
        guard snapshot.shoppingLists.contains(where: { $0.id == listID }) else {
            throw DomainError.notFound(entity: "List", id: listID.description)
        }

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
            // An explicit choice always wins. The guess only fills the silence,
            // because a caller that passed `.other` on purpose has said where
            // the item goes and being overruled by a lexicon is worse than
            // being unhelpful.
            category: category ?? ShoppingItem.Category.inferred(from: name),
            addedBy: memberID,
            addedAt: dateProvider.now
        )
        try await store.save(item)
        return item
    }

    /// Adds a whole pasted list at once.
    ///
    /// The bulk form of ``addShoppingItem(_:quantity:category:to:in:by:)`` and,
    /// importantly, the same rules: each line merges with a matching pending
    /// item rather than producing a second row, and each gets its aisle guessed
    /// from its name. A screen that parsed the text itself and then called the
    /// single-item command per line would work, and would be one refactor away
    /// from quietly not doing either.
    ///
    /// Quantities from the paste are added to what is already on the list,
    /// unlike the meal plan's ingredients, which are skipped when the item is
    /// already there. The difference is what the number means: a person who
    /// typed "2 milk" while the list says milk has counted something, whereas
    /// three recipes mentioning milk have not.
    ///
    /// - Parameters:
    ///   - text: What was pasted or typed.
    ///   - listID: The list to add to.
    ///   - householdID: The household the list belongs to.
    ///   - memberID: Who is adding it.
    /// - Returns: The items as they now stand, whether created or merged, in
    ///   the order the text first mentions them. Empty when the text held
    ///   nothing to buy.
    /// - Throws: ``DomainError/notFound(entity:id:)`` when there is no such
    ///   list, or ``DomainError/notPermitted(action:role:)``.
    @discardableResult
    public func addShoppingItems(
        from text: String,
        to listID: Identifier<ShoppingList>,
        in householdID: Identifier<Household>,
        by memberID: Identifier<Member>
    ) async throws -> [ShoppingItem] {
        let snapshot = try await store.snapshot(of: householdID)
        let member = try snapshot.requireActiveMember(memberID)
        try Permissions.check(.manageShoppingList, for: member.role)

        guard snapshot.shoppingLists.contains(where: { $0.id == listID }) else {
            throw DomainError.notFound(entity: "List", id: listID.description)
        }

        // Read once against the snapshot loaded at the top, then updated as the
        // paste is worked through. Reloading per line would be twenty snapshots
        // for one paste, and trusting the snapshot throughout would mean each
        // line merging only against rows that existed before the paste began.
        // The parser already collapses repeats using the same folding the list
        // does, so today nothing reaches here that needs the second half of
        // that — which is precisely why it is written down: the day the two
        // foldings drift apart, this stays correct.
        var pending = snapshot.items(on: listID)
        var saved: [ShoppingItem] = []

        for draft in ShoppingListParser.drafts(from: text) {
            if let existing = pending.pendingMatch(for: draft.name) {
                let merged = existing.incremented(by: draft.quantity)
                try await store.save(merged)
                pending.removeAll { $0.id == merged.id }
                pending.append(merged)
                saved.append(merged)
                continue
            }

            let item = try ShoppingItem(
                listID: listID,
                householdID: householdID,
                name: draft.name,
                quantity: draft.quantity,
                unit: draft.unit,
                category: draft.category,
                addedBy: memberID,
                addedAt: dateProvider.now
            )
            try await store.save(item)
            pending.append(item)
            saved.append(item)
        }
        return saved
    }

    /// Edits an item, leaving anything not named alone.
    ///
    /// One command rather than five, for the same reason ``updateChore(_:in:by:title:notes:assignment:points:startingOn:recurrence:category:)``
    /// is one: an item editor saves every field at once, and five commands
    /// would mean five writes, five change notifications, and a window in which
    /// the row is half-edited on somebody else's phone mid-shop.
    ///
    /// `unit` and `note` are double optionals so that "leave it alone" and
    /// "clear it" stay distinguishable: omit the parameter for the former, pass
    /// `.some(nil)` for the latter.
    ///
    /// An item can be edited after it has been bought. That is deliberate:
    /// correcting the quantity on something already in the trolley is exactly
    /// when somebody notices it was wrong.
    ///
    /// - Parameters:
    ///   - itemID: The item to edit.
    ///   - householdID: The household it belongs to.
    ///   - memberID: Who is editing it.
    ///   - name: A new name, if it is being renamed.
    ///   - quantity: A new quantity.
    ///   - unit: A new unit, or `.some(nil)` to clear it.
    ///   - category: A different aisle. This is the one-tap correction that
    ///     makes guessing the aisle defensible in the first place.
    ///   - note: A new note, or `.some(nil)` to clear it.
    /// - Returns: The item as it now stands.
    /// - Throws: ``DomainError/notFound(entity:id:)`` when the item is gone,
    ///   ``DomainError/notPermitted(action:role:)``, or a validation error from
    ///   the new values.
    @discardableResult
    public func updateShoppingItem(
        _ itemID: Identifier<ShoppingItem>,
        in householdID: Identifier<Household>,
        by memberID: Identifier<Member>,
        name: String? = nil,
        quantity: Int? = nil,
        unit: String?? = nil,
        category: ShoppingItem.Category? = nil,
        note: String?? = nil
    ) async throws -> ShoppingItem {
        let snapshot = try await store.snapshot(of: householdID)
        let member = try snapshot.requireActiveMember(memberID)
        try Permissions.check(.manageShoppingList, for: member.role)

        guard var item = snapshot.shoppingItems.first(where: { $0.id == itemID }) else {
            throw DomainError.notFound(entity: "Item", id: itemID.description)
        }

        if let name { item = try item.renamed(to: name) }
        if let quantity { item = try item.withQuantity(quantity) }
        if let unit { item = item.withUnit(unit) }
        if let category { item = item.inCategory(category) }
        if let note { item = try item.withNote(note) }

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
        let member = try snapshot.requireActiveMember(memberID)
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
        let actor = try snapshot.requireActiveMember(actorID)
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
        let actor = try snapshot.requireActiveMember(actorID)
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
        let actor = try snapshot.requireActiveMember(actorID)
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
    /// - Parameters:
    ///   - listID: The list to clear.
    ///   - householdID: The household the list belongs to.
    ///   - actorID: Who is clearing it.
    /// - Returns: How many items were removed.
    /// - Throws: ``DomainError/notFound(entity:id:)`` when there is no such
    ///   list, or ``DomainError/notPermitted(action:role:)``.
    @discardableResult
    public func clearPurchasedItems(
        from listID: Identifier<ShoppingList>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws -> Int {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireActiveMember(actorID)
        try Permissions.check(.manageShoppingList, for: actor.role)

        // A list that is not there clears no items, which is indistinguishable
        // from a list that was already clear — so the caller is told, rather
        // than being handed a zero that means something else entirely.
        guard snapshot.shoppingLists.contains(where: { $0.id == listID }) else {
            throw DomainError.notFound(entity: "List", id: listID.description)
        }

        let bought = snapshot.items(on: listID).purchased
        for item in bought {
            try await store.deleteShoppingItem(item.id)
        }
        return bought.count
    }

    // MARK: - Meals

    /// Plans a meal, replacing whatever the household had decided for that slot.
    ///
    /// Planning is an upsert on the day-and-slot pair rather than an insert.
    /// Deciding on Thursday's dinner twice is a household changing its mind,
    /// not a household eating twice, and a command that appended would leave
    /// the week grid holding two answers with no way to tell which one the
    /// family meant. The replacement keeps the original record's identifier and
    /// the moment it was first planned, so the slot stays one row and the
    /// conflict resolution the domain applies to a genuine offline collision
    /// still has a stable ordering to work with.
    ///
    /// - Throws: ``DomainError/requiresUpgrade(feature:tier:)`` on a plan
    ///   without meal planning, ``DomainError/notPermitted(action:role:)`` when
    ///   the actor may not change the plan, or
    ///   ``DomainError/memberNotInHousehold(_:)`` when the named cook has left.
    @discardableResult
    public func planMeal(
        in householdID: Identifier<Household>,
        on day: Date,
        slot: PlannedMeal.Slot,
        title: String,
        notes: String? = nil,
        cookID: Identifier<Member>? = nil,
        ingredients: [String] = [],
        servings: Int? = nil,
        by actorID: Identifier<Member>
    ) async throws -> PlannedMeal {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireActiveMember(actorID)
        try requireMealPlanning(in: snapshot)
        try Permissions.check(.manageMealPlan, for: actor.role)
        if let cookID {
            _ = try snapshot.requireActiveMember(cookID)
        }

        let calendar = snapshot.household.calendar()
        let existing = snapshot.mealPlan.meal(on: day, slot: slot)
        let meal = try PlannedMeal(
            id: existing?.id ?? Identifier(),
            householdID: householdID,
            day: day,
            slot: slot,
            title: title,
            notes: notes,
            cookID: cookID,
            ingredients: ingredients,
            servings: servings,
            plannedBy: existing?.plannedBy ?? actorID,
            createdAt: existing?.createdAt ?? dateProvider.now,
            calendar: calendar
        )
        try await store.save(meal)
        return meal
    }

    /// Names who is cooking, or takes the name off again.
    ///
    /// - Throws: ``DomainError/notPermitted(action:role:)``,
    ///   ``DomainError/memberNotInHousehold(_:)``, or
    ///   ``DomainError/notFound(entity:id:)``.
    @discardableResult
    public func setMealCook(
        _ mealID: Identifier<PlannedMeal>,
        to cookID: Identifier<Member>?,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws -> PlannedMeal {
        try await updatingMeal(mealID, in: householdID, by: actorID) { meal, snapshot in
            if let cookID {
                _ = try snapshot.requireActiveMember(cookID)
            }
            return meal.cookedBy(cookID)
        }
    }

    /// Changes what is planned for a slot without moving it.
    @discardableResult
    public func updateMeal(
        _ mealID: Identifier<PlannedMeal>,
        in householdID: Identifier<Household>,
        title: String? = nil,
        notes: String?? = nil,
        ingredients: [String]? = nil,
        servings: Int?? = nil,
        by actorID: Identifier<Member>
    ) async throws -> PlannedMeal {
        try await updatingMeal(mealID, in: householdID, by: actorID) { meal, _ in
            var updated = meal
            if let title {
                updated = try updated.retitled(to: title)
            }
            if let notes {
                updated = try updated.withNotes(notes)
            }
            if let ingredients {
                updated = try updated.withIngredients(ingredients)
            }
            if let servings {
                updated = try updated.serving(servings)
            }
            return updated
        }
    }

    /// Moves a meal to another day or slot, swapping with whatever was there.
    ///
    /// Swapping rather than refusing or overwriting. Dragging Thursday's dinner
    /// onto Friday when Friday has one too is a household reordering its week,
    /// and both of the alternatives lose something the family typed: a refusal
    /// makes them delete one first, and an overwrite silently discards it.
    ///
    /// - Returns: The meal in its new slot.
    @discardableResult
    public func moveMeal(
        _ mealID: Identifier<PlannedMeal>,
        to day: Date,
        slot: PlannedMeal.Slot,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws -> PlannedMeal {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireActiveMember(actorID)
        try requireMealPlanning(in: snapshot)
        try Permissions.check(.manageMealPlan, for: actor.role)

        guard let meal = snapshot.plannedMeals.first(where: { $0.id == mealID }) else {
            throw DomainError.notFound(entity: "Meal", id: mealID.description)
        }
        let calendar = snapshot.household.calendar()
        let displaced = snapshot.mealPlan.meal(on: day, slot: slot)

        let moved = meal.moved(to: day, slot: slot, calendar: calendar)
        // The displaced meal goes back to where this one came from, and is
        // written first so the destination slot is never briefly held by two
        // records for a subscriber reloading in between.
        if let displaced, displaced.id != meal.id {
            try await store.save(
                displaced.moved(to: meal.day, slot: meal.slot, calendar: calendar)
            )
        }
        try await store.save(moved)
        return moved
    }

    /// Takes a meal off the plan.
    public func unplanMeal(
        _ mealID: Identifier<PlannedMeal>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireActiveMember(actorID)
        try Permissions.check(.manageMealPlan, for: actor.role)
        guard snapshot.plannedMeals.contains(where: { $0.id == mealID }) else {
            throw DomainError.notFound(entity: "Meal", id: mealID.description)
        }
        try await store.deletePlannedMeal(mealID)
    }

    /// Adds everything the plan calls for over a period to a shopping list.
    ///
    /// The reason the ingredients are on the meal at all. A week planned on
    /// Sunday becomes a shopping list on Sunday, in one tap rather than by
    /// re-reading seven recipes — and a family that has to do the second thing
    /// does it once and then stops planning.
    ///
    /// Ingredients already waiting on a list are skipped rather than merged
    /// upward, because the count of meals wanting an ingredient is a guess at a
    /// quantity and not a measurement: quietly turning "milk" into "milk ×3"
    /// because three meals mention it is worse than leaving the one somebody
    /// already added alone.
    ///
    /// Each ingredient is filed into an aisle on the way in. This is the list
    /// nobody typed, so it is the one that arrives entirely in "Other" if
    /// nothing guesses — twenty unsorted lines being exactly what the aisle
    /// grouping exists to prevent.
    ///
    /// - Returns: The items added, in the order the plan first mentions them.
    @discardableResult
    public func addMealIngredients(
        from start: Date,
        to end: Date,
        in householdID: Identifier<Household>,
        toList listID: Identifier<ShoppingList>,
        by actorID: Identifier<Member>
    ) async throws -> [ShoppingItem] {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireActiveMember(actorID)
        try requireMealPlanning(in: snapshot)
        try Permissions.check(.manageShoppingList, for: actor.role)

        guard snapshot.shoppingLists.contains(where: { $0.id == listID }) else {
            throw DomainError.notFound(entity: "List", id: listID.description)
        }

        // Measured against every list in the household rather than the target
        // one. Somebody who put the mince on the hardware list by mistake has
        // still put the mince on a list, and a second copy on another one is
        // the failure this is meant to avoid.
        let wanted = snapshot.mealPlan.ingredientsToBuy(
            from: start,
            to: end,
            excluding: snapshot.shoppingItems
        )

        var added: [ShoppingItem] = []
        for ingredient in wanted {
            let item = try ShoppingItem(
                listID: listID,
                householdID: householdID,
                name: ingredient.name,
                category: ShoppingItem.Category.inferred(from: ingredient.name),
                addedBy: actorID,
                addedAt: dateProvider.now
            )
            try await store.save(item)
            added.append(item)
        }
        return added
    }

    // MARK: - The calendar

    /// Puts something on the family calendar.
    ///
    /// - Parameters:
    ///   - householdID: Whose calendar to put it on.
    ///   - title: What is happening.
    ///   - notes: Anything worth knowing.
    ///   - location: Where it is.
    ///   - kind: The grouping it belongs to.
    ///   - day: The first day it happens. Defaults to today.
    ///   - timing: When in the day. All day unless said otherwise.
    ///   - recurrence: How often it comes around. Once unless said otherwise.
    ///   - participants: Who it concerns. Everybody unless said otherwise.
    ///   - reminderMinutesBefore: How far ahead to speak up, if at all.
    ///   - actorID: Who is putting it on.
    /// - Returns: The event.
    /// - Throws: ``DomainError/notPermitted(action:role:)`` when the actor may
    ///   not change the calendar or may not name the people they have named,
    ///   ``DomainError/memberNotInHousehold(_:)`` when one of them has left, or
    ///   a validation error from ``CalendarEvent``.
    @discardableResult
    public func scheduleEvent(
        in householdID: Identifier<Household>,
        title: String,
        notes: String? = nil,
        location: String? = nil,
        kind: CalendarEvent.Kind = .other,
        on day: Date? = nil,
        timing: CalendarEvent.Timing = .allDay,
        recurrence: RecurrenceRule = .once,
        participants: CalendarEvent.Participants = .everyone,
        reminderMinutesBefore: Int? = nil,
        by actorID: Identifier<Member>
    ) async throws -> CalendarEvent {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireActiveMember(actorID)
        try Permissions.authorizeEvent(for: participants, by: actor, in: snapshot.members)

        let event = try CalendarEvent(
            householdID: householdID,
            title: title,
            notes: notes,
            location: location,
            kind: kind,
            startDate: day ?? dateProvider.now,
            timing: timing,
            recurrence: recurrence,
            participants: participants,
            reminderMinutesBefore: reminderMinutesBefore,
            createdBy: actorID,
            createdAt: dateProvider.now,
            calendar: snapshot.household.calendar()
        )
        try await store.save(event)
        return event
    }

    /// Edits an event, leaving anything not named alone.
    ///
    /// One command rather than eight, for the reason ``updateChore`` is one
    /// rather than six: an event editor saves every field at once, and eight
    /// commands would mean eight writes, eight change notifications, and a
    /// window in which half the edit is live.
    ///
    /// The optional fields — notes, location, and the reminder lead — take a
    /// double optional so that "leave this alone" and "clear it" stay
    /// distinguishable: omit the parameter for the former, pass `.some(nil)`
    /// for the latter.
    ///
    /// - Parameters:
    ///   - eventID: The event to edit.
    ///   - householdID: Whose calendar it is on.
    ///   - actorID: Who is editing it.
    ///   - title: A new title.
    ///   - notes: New notes, or `.some(nil)` to clear them.
    ///   - location: A new location, or `.some(nil)` to clear it.
    ///   - kind: A new grouping.
    ///   - timing: A new time of day.
    ///   - participants: New people.
    ///   - reminderMinutesBefore: A new lead, or `.some(nil)` for silence.
    /// - Returns: The edited event.
    /// - Throws: ``DomainError/notPermitted(action:role:)``,
    ///   ``DomainError/notFound(entity:id:)``, or a validation error from the
    ///   new values.
    @discardableResult
    public func updateEvent(
        _ eventID: Identifier<CalendarEvent>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>,
        title: String? = nil,
        notes: String?? = nil,
        location: String?? = nil,
        kind: CalendarEvent.Kind? = nil,
        timing: CalendarEvent.Timing? = nil,
        participants: CalendarEvent.Participants? = nil,
        reminderMinutesBefore: Int?? = nil
    ) async throws -> CalendarEvent {
        try await updatingEvent(eventID, in: householdID, by: actorID) { event, actor, snapshot in
            // Checked against the people the event *would* concern, not the
            // ones it does. A teen widening their own swimming lesson into a
            // household-wide entry is the same act as creating one, and the
            // check that stops the second has to stop the first.
            if let participants {
                try Permissions.authorizeEvent(for: participants, by: actor, in: snapshot.members)
            }

            var updated = event
            if let title { updated = try updated.retitled(to: title) }
            if let notes { updated = try updated.withNotes(notes) }
            if let location { updated = try updated.at(location) }
            if let kind { updated = updated.ofKind(kind) }
            if let timing { updated = try updated.timed(timing) }
            if let participants { updated = updated.attendedBy(participants) }
            if let reminderMinutesBefore {
                updated = try updated.reminding(minutesBefore: reminderMinutesBefore)
            }
            return updated
        }
    }

    /// Moves an event to another day, or changes how often it comes around.
    ///
    /// - Parameters:
    ///   - eventID: The event to move.
    ///   - day: The day it now starts on, if it is moving.
    ///   - recurrence: How often it now comes around, if that is changing.
    ///   - householdID: Whose calendar it is on.
    ///   - actorID: Who is moving it.
    /// - Returns: The moved event.
    /// - Throws: ``DomainError/notPermitted(action:role:)`` or
    ///   ``DomainError/notFound(entity:id:)``.
    @discardableResult
    public func rescheduleEvent(
        _ eventID: Identifier<CalendarEvent>,
        to day: Date? = nil,
        recurrence: RecurrenceRule? = nil,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws -> CalendarEvent {
        try await updatingEvent(eventID, in: householdID, by: actorID) { event, _, snapshot in
            event.rescheduled(
                startingOn: day,
                recurrence: recurrence,
                calendar: snapshot.household.calendar()
            )
        }
    }

    /// Drops one day of a recurring event — a cancelled lesson, a week away.
    ///
    /// Recorded as an exception rather than by editing the schedule, so
    /// "swimming was off that week" does not permanently move swimming.
    ///
    /// - Parameters:
    ///   - eventID: The event to drop a day of.
    ///   - day: The day to drop.
    ///   - householdID: Whose calendar it is on.
    ///   - actorID: Who is dropping it.
    /// - Returns: The event.
    /// - Throws: ``DomainError/notPermitted(action:role:)`` or
    ///   ``DomainError/notFound(entity:id:)``.
    @discardableResult
    public func skipEvent(
        _ eventID: Identifier<CalendarEvent>,
        on day: Date,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws -> CalendarEvent {
        try await updatingEvent(eventID, in: householdID, by: actorID) { event, _, snapshot in
            event.skipping(day, calendar: snapshot.household.calendar())
        }
    }

    /// Puts a dropped day back on the schedule.
    ///
    /// - Parameters:
    ///   - eventID: The event to restore a day of.
    ///   - day: The day to restore.
    ///   - householdID: Whose calendar it is on.
    ///   - actorID: Who is restoring it.
    /// - Returns: The event.
    /// - Throws: ``DomainError/notPermitted(action:role:)`` or
    ///   ``DomainError/notFound(entity:id:)``.
    @discardableResult
    public func unskipEvent(
        _ eventID: Identifier<CalendarEvent>,
        on day: Date,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws -> CalendarEvent {
        try await updatingEvent(eventID, in: householdID, by: actorID) { event, _, snapshot in
            event.unskipping(day, calendar: snapshot.household.calendar())
        }
    }

    /// Calls an event off without erasing it.
    ///
    /// Cancelling rather than deleting is what the UI offers, for the reason
    /// archiving a chore is: a family that cancels the dentist wants it off
    /// the week, not off the record.
    ///
    /// - Parameters:
    ///   - eventID: The event to call off.
    ///   - householdID: Whose calendar it is on.
    ///   - actorID: Who is calling it off.
    /// - Returns: The cancelled event.
    /// - Throws: ``DomainError/notPermitted(action:role:)`` or
    ///   ``DomainError/notFound(entity:id:)``.
    @discardableResult
    public func cancelEvent(
        _ eventID: Identifier<CalendarEvent>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws -> CalendarEvent {
        let now = dateProvider.now
        return try await updatingEvent(eventID, in: householdID, by: actorID) { event, _, _ in
            event.cancelled(at: now)
        }
    }

    /// Puts a cancelled event back on the calendar.
    ///
    /// - Parameters:
    ///   - eventID: The event to put back.
    ///   - householdID: Whose calendar it is on.
    ///   - actorID: Who is putting it back.
    /// - Returns: The reinstated event.
    /// - Throws: ``DomainError/notPermitted(action:role:)`` or
    ///   ``DomainError/notFound(entity:id:)``.
    @discardableResult
    public func reinstateEvent(
        _ eventID: Identifier<CalendarEvent>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws -> CalendarEvent {
        try await updatingEvent(eventID, in: householdID, by: actorID) { event, _, _ in
            event.reinstated()
        }
    }

    /// Erases an event and every trace of it.
    ///
    /// Restricted to whoever can manage the household, and separate from
    /// cancelling on purpose. This is the destructive one, and it exists
    /// because an event created by mistake should be removable and because
    /// privacy law requires a genuine delete to be possible.
    ///
    /// - Parameters:
    ///   - eventID: The event to erase.
    ///   - householdID: Whose calendar it is on.
    ///   - actorID: Who is erasing it.
    /// - Throws: ``DomainError/notPermitted(action:role:)`` or
    ///   ``DomainError/notFound(entity:id:)``.
    public func deleteEvent(
        _ eventID: Identifier<CalendarEvent>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireActiveMember(actorID)
        _ = try snapshot.requireEvent(eventID)
        try Permissions.check(.manageHousehold, for: actor.role)
        try await store.deleteEvent(eventID)
    }

    // MARK: - Cover

    /// Asks the household — or one person in it — to take an occurrence off the
    /// requester.
    ///
    /// The chore is untouched. What is written is an exception for one day, in
    /// the same spirit as a skipped day, because moving one Tuesday by editing
    /// the rota would move every Tuesday after it.
    ///
    /// Asking twice for the same thing returns the request that already exists
    /// rather than adding a second one. A person tapping again because the
    /// screen has not updated is not making a second ask, and two open requests
    /// for one square are two people's lists asking about the same chore.
    ///
    /// - Parameters:
    ///   - choreID: The chore to be covered.
    ///   - day: The occurrence's day.
    ///   - householdID: The household it belongs to.
    ///   - memberID: Who is asking.
    ///   - askedOf: Who is being asked, or `nil` to ask the household.
    ///   - note: An optional reason, in the requester's words.
    /// - Returns: The open request.
    /// - Throws: ``DomainError/notScheduled(on:)`` when the chore does not fall
    ///   on that day, ``DomainError/alreadyCompleted`` when there is nothing
    ///   left to cover, ``DomainError/coverAlreadySettled`` when somebody has
    ///   already taken it on, ``DomainError/cannotCoverForYourself`` when the
    ///   requester asks themselves, or whatever
    ///   ``Permissions/authorizeCoverRequest(of:on:by:engine:)`` throws.
    @discardableResult
    public func requestCover(
        of choreID: Identifier<Chore>,
        on day: Date,
        in householdID: Identifier<Household>,
        by memberID: Identifier<Member>,
        askedOf: Identifier<Member>? = nil,
        note: String? = nil
    ) async throws -> CoverRequest {
        let snapshot = try await store.snapshot(of: householdID)
        let chore = try snapshot.requireChore(choreID)
        let member = try snapshot.requireActiveMember(memberID)
        let calendar = snapshot.household.calendar()
        let normalizedDay = calendar.startOfDay(for: day)

        // Asked first, for the reason completing a chore asks it first: a day
        // the schedule never produced is not a permission question, and an
        // archived chore has no occurrences for anybody to cover.
        guard chore.occurs(on: normalizedDay, using: snapshot.engine) else {
            throw DomainError.notScheduled(on: normalizedDay)
        }

        try Permissions.authorizeCoverRequest(
            of: chore,
            on: normalizedDay,
            by: member,
            engine: snapshot.engine
        )

        if let askedOf {
            // Active, not merely on file. A request addressed to somebody who
            // has moved out is a question nobody will ever answer, sitting on
            // the requester's screen looking like it might be.
            _ = try snapshot.requireActiveMember(askedOf)
            guard askedOf != memberID else {
                throw DomainError.cannotCoverForYourself
            }
        }

        let key = ChoreCompletion.OccurrenceKey(choreID: choreID, day: normalizedDay)
        if let completion = snapshot.completions.first(where: { $0.occurrenceKey == key }),
            completion.approval.countsAsDone
        {
            throw DomainError.alreadyCompleted
        }
        guard snapshot.coverRequests.coverFor(key) == nil else {
            throw DomainError.coverAlreadySettled
        }

        let existing = snapshot.coverRequests.about(key).first {
            $0.resolution.isOpen && $0.requestedBy == memberID && $0.askedOf == askedOf
        }
        if let existing { return existing }

        let request = try CoverRequest(
            householdID: householdID,
            choreID: choreID,
            day: normalizedDay,
            requestedBy: memberID,
            askedOf: askedOf,
            note: note,
            createdAt: dateProvider.now,
            calendar: calendar
        )
        try await store.save(request)
        return request
    }

    /// Takes on the occurrence a request is about.
    ///
    /// - Parameters:
    ///   - requestID: The request being accepted.
    ///   - householdID: The household it belongs to.
    ///   - actorID: Who is covering.
    /// - Returns: The accepted request.
    /// - Throws: ``DomainError/coverAlreadySettled`` when somebody answered
    ///   first, ``DomainError/notScheduled(on:)`` when the chore has since been
    ///   archived or the day skipped, or whatever
    ///   ``Permissions/authorizeCoverAnswer(to:by:)`` throws.
    @discardableResult
    public func acceptCover(
        _ requestID: Identifier<CoverRequest>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws -> CoverRequest {
        let snapshot = try await store.snapshot(of: householdID)
        let request = try snapshot.requireCoverRequest(requestID)
        let actor = try snapshot.requireActiveMember(actorID)
        let chore = try snapshot.requireChore(request.choreID)

        try Permissions.authorizeCoverAnswer(to: request, by: actor)

        // The world moves between asking and answering. A chore archived, or a
        // day the family has since skipped, leaves an occurrence nobody can do
        // — and accepting it would put a chore on somebody's list that the
        // agenda will never show.
        guard chore.occurs(on: request.day, using: snapshot.engine) else {
            throw DomainError.notScheduled(on: request.day)
        }

        // Two requests for one square is an ordinary thing to produce: ask a
        // sibling, hear nothing, ask the household. Only one of them can be
        // accepted, or two people spend the evening believing they owe the
        // same chore.
        guard snapshot.coverRequests.coverFor(request.occurrenceKey) == nil else {
            throw DomainError.coverAlreadySettled
        }

        let accepted = try request.accepted(by: actorID, at: dateProvider.now)
        try await store.save(accepted)
        return accepted
    }

    /// Turns a request down.
    ///
    /// Recorded rather than discarded. "Alex said no" is what tells the person
    /// who asked to go and ask somebody else, and a request that quietly
    /// vanished would leave them waiting on an answer that already came.
    ///
    /// - Parameters:
    ///   - requestID: The request being declined.
    ///   - householdID: The household it belongs to.
    ///   - actorID: Who is saying no.
    /// - Returns: The declined request.
    /// - Throws: Whatever ``Permissions/authorizeCoverAnswer(to:by:)`` throws.
    @discardableResult
    public func declineCover(
        _ requestID: Identifier<CoverRequest>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws -> CoverRequest {
        let snapshot = try await store.snapshot(of: householdID)
        let request = try snapshot.requireCoverRequest(requestID)
        let actor = try snapshot.requireActiveMember(actorID)

        try Permissions.authorizeCoverAnswer(to: request, by: actor)

        let declined = try request.declined(by: actorID, at: dateProvider.now)
        try await store.save(declined)
        return declined
    }

    /// Takes a request back.
    ///
    /// - Parameters:
    ///   - requestID: The request being withdrawn.
    ///   - householdID: The household it belongs to.
    ///   - actorID: Who is withdrawing it — the person who asked, or an adult.
    /// - Returns: The withdrawn request.
    /// - Throws: Whatever ``Permissions/authorizeCoverWithdrawal(of:by:)``
    ///   throws.
    @discardableResult
    public func withdrawCover(
        _ requestID: Identifier<CoverRequest>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws -> CoverRequest {
        let snapshot = try await store.snapshot(of: householdID)
        let request = try snapshot.requireCoverRequest(requestID)
        let actor = try snapshot.requireActiveMember(actorID)

        try Permissions.authorizeCoverWithdrawal(of: request, by: actor)

        let withdrawn = try request.withdrawn(at: dateProvider.now)
        try await store.save(withdrawn)
        return withdrawn
    }

    // MARK: - Away

    /// Records that the household, or some of it, is not here for a stretch of
    /// days.
    ///
    /// Nothing about the chores changes. The schedule, the rota, and the
    /// skipped days are all untouched; what is written is a record of who was
    /// not here, which the agenda, the streak calculator, the recap, and the
    /// reminder planner each read for themselves.
    ///
    /// Recording the same trip twice returns the one that already exists. A
    /// parent tapping again because the screen has not updated has not booked a
    /// second holiday, and two overlapping records excusing the same fortnight
    /// is a household that cannot cancel one of them without wondering why
    /// nothing changed.
    ///
    /// - Parameters:
    ///   - firstDay: The first day away, inclusive.
    ///   - lastDay: The last day away, inclusive.
    ///   - householdID: The household going away.
    ///   - actorID: Who is recording it.
    ///   - members: Who is away. Empty means the whole household.
    ///   - reason: Where they have gone, in the family's words.
    /// - Returns: The recorded trip.
    /// - Throws: ``DomainError/notPermitted(action:role:)`` unless the actor is
    ///   an adult, ``DomainError/memberNotInHousehold(_:)`` for somebody who is
    ///   not here to leave, or ``DomainError/impossibleDateRange(reason:)`` for
    ///   dates that cannot be honoured.
    @discardableResult
    public func goAway(
        from firstDay: Date,
        to lastDay: Date,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>,
        members: Set<Identifier<Member>> = [],
        reason: String? = nil
    ) async throws -> AwayPeriod {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireActiveMember(actorID)
        try Permissions.check(.manageAwayPeriod, for: actor.role)

        let calendar = snapshot.household.calendar()
        let named = try resolvedMembers(members, in: snapshot)

        let start = calendar.startOfDay(for: firstDay)
        let end = calendar.startOfDay(for: lastDay)
        let existing = snapshot.awayPeriods.active.first {
            $0.firstDay == start && $0.lastDay == end && $0.memberIDs == named
        }
        if let existing { return existing }

        let period = try AwayPeriod(
            householdID: householdID,
            firstDay: start,
            lastDay: end,
            memberIDs: named,
            reason: reason,
            createdBy: actorID,
            createdAt: dateProvider.now,
            calendar: calendar
        )
        try await store.save(period)
        return period
    }

    /// Changes when a trip runs, who it covers, or what it is called.
    ///
    /// - Parameters:
    ///   - periodID: The trip being edited.
    ///   - householdID: The household it belongs to.
    ///   - actorID: Who is editing it.
    ///   - firstDay: A new first day, or `nil` to keep the one it has.
    ///   - lastDay: A new last day, or `nil` to keep the one it has.
    ///   - members: A new set of people, or `nil` to keep the ones it names.
    ///   - reason: A new reason. Passing `.some(nil)` clears it; omitting the
    ///     argument leaves it alone.
    /// - Returns: The edited trip.
    /// - Throws: Whatever the initialiser refuses, plus
    ///   ``DomainError/notPermitted(action:role:)``.
    @discardableResult
    public func updateAwayPeriod(
        _ periodID: Identifier<AwayPeriod>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>,
        firstDay: Date? = nil,
        lastDay: Date? = nil,
        members: Set<Identifier<Member>>? = nil,
        reason: String?? = nil
    ) async throws -> AwayPeriod {
        try await updatingAwayPeriod(periodID, in: householdID, by: actorID) { period, snapshot in
            var updated = try period.rescheduled(
                firstDay: firstDay,
                lastDay: lastDay,
                calendar: snapshot.household.calendar()
            )
            if let members {
                updated = updated.covering(try resolvedMembers(members, in: snapshot))
            }
            if let reason {
                updated = try updated.withReason(reason)
            }
            return updated
        }
    }

    /// Calls a trip off, so its days count again.
    ///
    /// Cancelled rather than deleted. A household that cancels a holiday wants
    /// the fortnight back on the rota, and it also wants to be able to say what
    /// happened — a record that vanished would leave the family looking at a
    /// week of chores that were excused yesterday and are not today, with
    /// nothing on any screen to explain it.
    ///
    /// - Returns: The cancelled trip.
    @discardableResult
    public func cancelAwayPeriod(
        _ periodID: Identifier<AwayPeriod>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws -> AwayPeriod {
        try await updatingAwayPeriod(periodID, in: householdID, by: actorID) { period, _ in
            period.cancelled(at: dateProvider.now)
        }
    }

    /// Puts a cancelled trip back on.
    ///
    /// - Returns: The reinstated trip.
    @discardableResult
    public func reinstateAwayPeriod(
        _ periodID: Identifier<AwayPeriod>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>
    ) async throws -> AwayPeriod {
        try await updatingAwayPeriod(periodID, in: householdID, by: actorID) { period, _ in
            period.reinstated()
        }
    }

    // MARK: - Shared plumbing

    /// Loads a trip, applies a transform, and saves the result.
    ///
    /// The three editing commands differ only in the transform, and sharing the
    /// load-check-save is what keeps the permission check from being present on
    /// two of them and missing from the third.
    private func updatingAwayPeriod(
        _ periodID: Identifier<AwayPeriod>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>,
        _ transform: (AwayPeriod, HouseholdSnapshot) throws -> AwayPeriod
    ) async throws -> AwayPeriod {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireActiveMember(actorID)
        try Permissions.check(.manageAwayPeriod, for: actor.role)

        let period = try snapshot.requireAwayPeriod(periodID)
        let updated = try transform(period, snapshot)
        try await store.save(updated)
        return updated
    }

    /// Checks that everybody named on a trip is somebody who could go on one,
    /// and collapses "all of them" into the family holiday it is.
    ///
    /// The collapse matters because the two are not the same record downstream:
    /// a chore open to anybody is excused by an empty house and by nothing
    /// else, so a trip that listed every member by name would leave the
    /// dishwasher on the agenda of a household that is in Spain. Naming
    /// everybody is how a person says "all of us" to a picker, and the record
    /// should mean what they said.
    private func resolvedMembers(
        _ members: Set<Identifier<Member>>,
        in snapshot: HouseholdSnapshot
    ) throws -> Set<Identifier<Member>> {
        guard !members.isEmpty else { return [] }
        for memberID in members {
            // Active, not merely on file. A trip naming somebody who has moved
            // out excuses chores that are nobody's, for a person who is not
            // coming back.
            _ = try snapshot.requireActiveMember(memberID)
        }
        let everybody = Set(snapshot.activeMembers.map(\.id))
        return members == everybody ? [] : members
    }

    /// Refuses an operation the household's plan does not include.
    ///
    /// - Throws: ``DomainError/requiresUpgrade(feature:tier:)``, carrying the
    ///   tier so the paywall can say what is being asked for rather than
    ///   showing a generic upgrade screen.
    private func requireMealPlanning(in snapshot: HouseholdSnapshot) throws {
        guard snapshot.household.tier.includesMealPlanning else {
            throw DomainError.requiresUpgrade(
                feature: .mealPlanning, tier: snapshot.household.tier
            )
        }
    }

    /// Loads a meal, applies a transform, and saves the result.
    ///
    /// The meal-editing commands differ only in the transform, and sharing the
    /// load-check-save keeps the tier gate and the permission check from being
    /// present on three of them and missing from the fourth.
    private func updatingMeal(
        _ mealID: Identifier<PlannedMeal>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>,
        _ transform: (PlannedMeal, HouseholdSnapshot) throws -> PlannedMeal
    ) async throws -> PlannedMeal {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireActiveMember(actorID)
        try requireMealPlanning(in: snapshot)
        try Permissions.check(.manageMealPlan, for: actor.role)

        guard let meal = snapshot.plannedMeals.first(where: { $0.id == mealID }) else {
            throw DomainError.notFound(entity: "Meal", id: mealID.description)
        }
        let updated = try transform(meal, snapshot)
        try await store.save(updated)
        return updated
    }

    /// Loads an event, applies a transform, and saves the result.
    ///
    /// Every calendar edit is load, check, transform, save, and the seven of
    /// them differ only in the transform. Sharing the rest is what keeps the
    /// permission check from being present on six and missing from the
    /// seventh.
    ///
    /// The transform receives the actor as well as the snapshot, because the
    /// one edit that needs a second check — changing who an event concerns —
    /// needs to know who is asking.
    private func updatingEvent(
        _ eventID: Identifier<CalendarEvent>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>,
        _ transform: (CalendarEvent, Member, HouseholdSnapshot) throws -> CalendarEvent
    ) async throws -> CalendarEvent {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireActiveMember(actorID)
        let event = try snapshot.requireEvent(eventID)
        // Checked against the people the event already concerns, so a teen
        // cannot edit their sibling's dentist appointment merely because they
        // are not touching the participant list.
        try Permissions.authorizeEvent(
            for: event.participants, by: actor, in: snapshot.members
        )

        let updated = try transform(event, actor, snapshot)
        try await store.save(updated)
        return updated
    }

    /// Loads a chore, applies a transform, and saves the result.
    ///
    /// The four schedule-editing commands differ only in the transform. Sharing
    /// the load-check-save around them is what keeps the permission check from
    /// being present on three of them and missing from the fourth.
    ///
    /// The transform receives the snapshot rather than only the clock, so that
    /// a command needing the household's calendar reads it from the load this
    /// helper has already done. The two that do were loading it separately
    /// first, which is a whole second read of every record in the household to
    /// answer "which timezone" — and, worse, a read of a *different* household
    /// state than the one the write is based on.
    private func updatingChore(
        _ choreID: Identifier<Chore>,
        in householdID: Identifier<Household>,
        by actorID: Identifier<Member>,
        _ transform: (Chore, HouseholdSnapshot) throws -> Chore
    ) async throws -> Chore {
        let snapshot = try await store.snapshot(of: householdID)
        let actor = try snapshot.requireActiveMember(actorID)
        let chore = try snapshot.requireChore(choreID)
        try Permissions.check(.createChore, for: actor.role)

        let updated = try transform(chore, snapshot)
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
        let actor = try snapshot.requireActiveMember(actorID)
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
            // Active, not merely on file. A rota that includes somebody who has
            // left silently hands every second turn to nobody, and the chore
            // reads as unassigned on the days it is theirs.
            _ = try snapshot.requireActiveMember(memberID)
        }
        guard !others.isEmpty else { return }
        try Permissions.check(.assignChore, for: actor.role)
    }
}
