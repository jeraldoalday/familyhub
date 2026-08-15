import Foundation

/// Who may do what.
///
/// One table, consulted from one place. The temptation in an app like this is
/// to scatter `if member.role == .child` through the views, and the result is
/// always the same: a screen that hides a button but an action path that still
/// performs it. Every guarded operation is named in ``DomainError/Action`` and
/// resolved here, so a view asking "should I show this?" and a command asking
/// "may I do this?" cannot answer differently.
public enum Permissions {

    /// Whether `role` may perform `action` in general.
    ///
    /// Context-sensitive questions — may *this* member complete *this* chore —
    /// go through ``authorizeCompletion(of:on:by:household:engine:)``, which
    /// consults this table and then applies the specifics.
    public static func allows(_ action: DomainError.Action, for role: MemberRole) -> Bool {
        switch action {
        // Only the owner touches billing or destroys the household.
        case .manageHousehold:
            return role == .owner

        // Adults administer membership. A teen inviting their friends into the
        // family's calendar is a support ticket waiting to happen.
        case .inviteMember, .removeMember, .assignChore:
            return role.isAdult

        // Adults define the reward economy. If a child could mint rewards or
        // adjust points, the entire mechanic is worth nothing.
        case .createReward, .adjustPoints, .approveCompletion:
            return role.isAdult

        // Creating chores is open to teens, who are old enough to add their own
        // commitments and are more likely to keep to a schedule they wrote.
        case .createChore, .manageCalendar, .manageMealPlan:
            return role >= .teen

        // Everyone does their own chores and spends what they earned.
        case .completeOwnChore, .redeemReward, .manageShoppingList:
            return true

        // Ticking off someone else's chore is an adult action, because it moves
        // points into another person's balance.
        case .completeOthersChore:
            return role.isAdult
        }
    }

    /// Throws unless `role` may perform `action`.
    ///
    /// - Throws: ``DomainError/notPermitted(action:role:)``.
    public static func check(_ action: DomainError.Action, for role: MemberRole) throws {
        guard allows(action, for: role) else {
            throw DomainError.notPermitted(action: action, role: role)
        }
    }

    /// The actions `role` may perform, for building a settings screen that
    /// explains a role rather than listing it.
    public static func actions(for role: MemberRole) -> [DomainError.Action] {
        DomainError.Action.allCases.filter { allows($0, for: role) }
    }

    // MARK: - Membership invariants

    /// Checks that removing `member` leaves the household governable.
    ///
    /// - Throws: ``DomainError/wouldLeaveHouseholdWithoutAdult`` when they are
    ///   the last adult. Without this a family can lock itself out of its own
    ///   settings, billing, and approval queue with two taps and no way back
    ///   that does not involve support.
    public static func checkRemoval(
        of member: Member,
        from members: some Collection<Member>
    ) throws {
        guard member.role.isAdult else { return }
        let remainingAdults =
            members
            .filter { $0.id != member.id && $0.isActive && $0.role.isAdult }
        guard !remainingAdults.isEmpty else {
            throw DomainError.wouldLeaveHouseholdWithoutAdult
        }
    }

    /// Checks that demoting `member` to `newRole` leaves an adult in place.
    ///
    /// - Throws: ``DomainError/wouldLeaveHouseholdWithoutAdult``.
    public static func checkRoleChange(
        of member: Member,
        to newRole: MemberRole,
        in members: some Collection<Member>
    ) throws {
        // Promotions and lateral moves between adult roles are always fine.
        guard member.role.isAdult, !newRole.isAdult else { return }
        try checkRemoval(of: member, from: members)
    }
}

// MARK: - Chore authorization

extension Permissions {

    /// Whether `member` may mark the given occurrence of `chore` as done, and
    /// which action that would be.
    ///
    /// - Throws: ``DomainError/notPermitted(action:role:)`` when the member's
    ///   role forbids it, or ``DomainError/memberNotInHousehold(_:)`` when they
    ///   have been removed.
    public static func authorizeCompletion(
        of chore: Chore,
        on day: Date,
        by member: Member,
        engine: RecurrenceEngine
    ) throws {
        guard member.isActive else {
            throw DomainError.memberNotInHousehold(member.id)
        }

        let index = chore.occurrenceIndex(of: day, using: engine) ?? 0
        let isTheirs = chore.isAssigned(member.id, occurrenceIndex: index)

        // An open chore is anyone's to claim, so completing it is never
        // 'someone else's chore' even though nobody is named on it.
        let action: DomainError.Action = isTheirs ? .completeOwnChore : .completeOthersChore
        try check(action, for: member.role)
    }

    /// Whether `member` may approve a completion.
    ///
    /// - Throws: ``DomainError/notPermitted(action:role:)`` for a non-adult, or
    ///   ``DomainError/notPermitted(action:role:)`` when they are approving
    ///   their own work.
    public static func authorizeApproval(
        of completion: ChoreCompletion,
        by member: Member
    ) throws {
        try check(.approveCompletion, for: member.role)

        // Self-approval would make the review step ceremonial. An adult's own
        // chores are better configured not to need approval at all.
        guard completion.completedBy != member.id else {
            throw DomainError.notPermitted(action: .approveCompletion, role: member.role)
        }
    }
}
