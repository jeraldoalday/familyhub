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
    /// go through ``authorizeCompletion(of:on:by:engine:coveringMemberID:)``, which
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

        // Confirming that a reward actually happened is an adult's word, for
        // the same reason approving a chore is: a child who could mark their
        // own movie night as given is a child who has bought nothing, and the
        // queue of things the household still owes — the only thing standing
        // between this feature and a currency worth nothing — would empty
        // itself. Cancelling somebody *else's* is an adult action on the same
        // grounds; cancelling your own is not, and is allowed below.
        case .handOverReward, .cancelRedemption:
            return role.isAdult

        // Creating chores is open to teens, who are old enough to add their own
        // commitments and are more likely to keep to a schedule they wrote.
        case .createChore, .manageCalendar, .manageMealPlan:
            return role >= .teen

        // Everyone does their own chores and spends what they earned.
        case .completeOwnChore, .redeemReward, .manageShoppingList:
            return true

        // Asking to be covered, and covering for somebody who asked, are open
        // to everyone including the youngest child. Restricting either would
        // remove the point: the swap a family already does across the kitchen
        // would go back to happening across the kitchen, and the app would
        // carry on insisting that the wrong person owes the bins.
        case .requestCover, .coverForSomeone:
            return true

        // Ticking off someone else's chore is an adult action, because it moves
        // points into another person's balance.
        case .completeOthersChore:
            return role.isAdult

        // Saying who is away is an adult action, and this is the one place in
        // the app where that rule is about the child rather than about the
        // money. An away period excuses every chore it covers, which makes it
        // the only switch in the product that turns the rota off — and the
        // first thing a nine year old does with a rota is look for one. A
        // family that genuinely needs a child to record their own trip has an
        // adult two taps away; a family whose rota can be dismissed from the
        // inside has no rota.
        case .manageAwayPeriod:
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
    /// - Parameters:
    ///   - chore: The chore being ticked off.
    ///   - day: The occurrence's day.
    ///   - member: The person ticking it off.
    ///   - engine: The household's recurrence engine, for resolving a rota.
    ///   - coveringMemberID: Who has taken the occurrence on, when somebody
    ///     has. An accepted cover *adds* a person entitled to do the work; it
    ///     does not take the right away from whoever the rota named. A child
    ///     whose plans freed up and who does their own chore anyway must not be
    ///     told they are not allowed to, and the points follow whoever actually
    ///     records it either way.
    /// - Throws: ``DomainError/notPermitted(action:role:)`` when the member's
    ///   role forbids it, or ``DomainError/memberNotInHousehold(_:)`` when they
    ///   have been removed.
    public static func authorizeCompletion(
        of chore: Chore,
        on day: Date,
        by member: Member,
        engine: RecurrenceEngine,
        coveringMemberID: Identifier<Member>? = nil
    ) throws {
        guard member.isActive else {
            throw DomainError.memberNotInHousehold(member.id)
        }

        let index = chore.occurrenceIndex(of: day, using: engine) ?? 0
        let isTheirs =
            chore.isAssigned(member.id, occurrenceIndex: index)
            || coveringMemberID == member.id

        // An open chore is anyone's to claim, so completing it is never
        // 'someone else's chore' even though nobody is named on it.
        let action: DomainError.Action = isTheirs ? .completeOwnChore : .completeOthersChore
        try check(action, for: member.role)
    }

    /// Whether `member` may put an event concerning `participants` on the
    /// calendar.
    ///
    /// Changing the calendar at all is a teen-and-above action, because an
    /// older child is old enough to keep their own commitments on it and more
    /// likely to keep to a schedule they wrote. Putting something on *somebody
    /// else's* day is not the same act: a teenager who can book their sibling
    /// into a dentist appointment, or declare a whole-household half term, is
    /// a family argument the app started.
    ///
    /// The same distinction the chore commands draw between assigning work to
    /// yourself and assigning it to somebody else, and drawn here rather than
    /// in the command layer so a view asking "should I offer this?" and a
    /// command asking "may I do this?" cannot answer differently.
    ///
    /// - Parameters:
    ///   - participants: Who the event would concern.
    ///   - member: The person trying to save it.
    ///   - members: The household's members, for checking the named ones are
    ///     still in it.
    /// - Throws: ``DomainError/notPermitted(action:role:)`` when the member may
    ///   not change the calendar or may not name the people they have named, or
    ///   ``DomainError/memberNotInHousehold(_:)`` when one of them has left.
    public static func authorizeEvent(
        for participants: CalendarEvent.Participants,
        by member: Member,
        in members: some Collection<Member>
    ) throws {
        try check(.manageCalendar, for: member.role)

        // An event naming only yourself is yours to book whatever your role.
        // Anything wider — another person, or the whole household — is an
        // adult's to declare.
        let named = participants.namedMemberIDs
        for memberID in named {
            guard let found = members.first(where: { $0.id == memberID }) else {
                throw DomainError.notFound(entity: "Member", id: memberID.description)
            }
            // Active, not merely on file. An event that still names somebody
            // who has moved out shows a name on a week nobody can act on.
            guard found.isActive else {
                throw DomainError.memberNotInHousehold(memberID)
            }
        }

        let concernsOnlyThemselves = named == [member.id]
        guard !concernsOnlyThemselves, !member.role.isAdult else { return }
        throw DomainError.notPermitted(action: .manageCalendar, role: member.role)
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

// MARK: - Cover authorization

extension Permissions {

    /// Whether `member` may ask the household to cover the given occurrence.
    ///
    /// Two rules, and the second is the one that matters. Anybody may ask —
    /// restricting it by role would put the swap back across the kitchen,
    /// which is where it already happens — but only the person the occurrence
    /// actually falls to may ask for it, because a favour nobody owed is not a
    /// favour. That rules out two cases that arrive looking the same: asking to
    /// be covered for somebody else's turn, and asking to be covered for a
    /// chore that is open to the household, where nobody is on the hook and
    /// whoever gets to it first was always the arrangement.
    ///
    /// - Parameters:
    ///   - chore: The chore the request would be about.
    ///   - day: The occurrence's day.
    ///   - member: The person asking.
    ///   - engine: The household's recurrence engine, for resolving a rota.
    /// - Throws: ``DomainError/memberNotInHousehold(_:)`` when they have left,
    ///   ``DomainError/notPermitted(action:role:)`` when their role forbids it,
    ///   or ``DomainError/notAssignedToYou(on:)`` when the day was never theirs.
    public static func authorizeCoverRequest(
        of chore: Chore,
        on day: Date,
        by member: Member,
        engine: RecurrenceEngine
    ) throws {
        guard member.isActive else {
            throw DomainError.memberNotInHousehold(member.id)
        }
        try check(.requestCover, for: member.role)

        let index = chore.occurrenceIndex(of: day, using: engine) ?? 0
        guard chore.assignee(forOccurrenceIndex: index) == member.id else {
            throw DomainError.notAssignedToYou(on: day)
        }
    }

    /// Whether `member` may answer a cover request — accept it or turn it down.
    ///
    /// One check for both answers, deliberately. Accepting and declining are
    /// the same permission viewed from two sides: a person who may say yes is
    /// exactly the person whose no is worth recording, and splitting them would
    /// eventually let somebody decline a request that was never addressed to
    /// them and close it under the person who was asked.
    ///
    /// - Parameters:
    ///   - request: The request being answered.
    ///   - member: The person answering.
    /// - Throws: ``DomainError/memberNotInHousehold(_:)`` when they have left,
    ///   ``DomainError/coverAlreadySettled`` when somebody already answered,
    ///   ``DomainError/cannotCoverForYourself`` when they are the one who
    ///   asked, or ``DomainError/notPermitted(action:role:)`` when the request
    ///   named somebody else.
    public static func authorizeCoverAnswer(
        to request: CoverRequest,
        by member: Member
    ) throws {
        guard member.isActive else {
            throw DomainError.memberNotInHousehold(member.id)
        }
        try check(.coverForSomeone, for: member.role)

        guard request.resolution.isOpen else {
            throw DomainError.coverAlreadySettled
        }
        // Checked before the addressing rule so the person who asked is told
        // the true reason. Falling through would tell them their role forbids
        // it, which is both wrong and unfixable.
        guard member.id != request.requestedBy else {
            throw DomainError.cannotCoverForYourself
        }
        guard request.isAddressed(to: member.id) else {
            throw DomainError.notPermitted(action: .coverForSomeone, role: member.role)
        }
    }

    /// Whether `member` may take a cover request back.
    ///
    /// The person who asked, or any adult. The adult case is not
    /// administrative tidying: an open request sits on somebody's list asking
    /// to be answered, and a child who has gone to bed cannot clear one that
    /// has stopped making sense.
    ///
    /// - Parameters:
    ///   - request: The request being withdrawn.
    ///   - member: The person withdrawing it.
    /// - Throws: ``DomainError/memberNotInHousehold(_:)`` when they have left,
    ///   ``DomainError/coverAlreadySettled`` once somebody has answered — an
    ///   accepted request is an arrangement between two people, and unpicking
    ///   it silently hands the chore back to somebody who believes it is no
    ///   longer theirs — or ``DomainError/notPermitted(action:role:)``.
    public static func authorizeCoverWithdrawal(
        of request: CoverRequest,
        by member: Member
    ) throws {
        guard member.isActive else {
            throw DomainError.memberNotInHousehold(member.id)
        }
        guard request.resolution.isOpen else {
            throw DomainError.coverAlreadySettled
        }
        guard member.id == request.requestedBy || member.role.isAdult else {
            throw DomainError.notPermitted(action: .requestCover, role: member.role)
        }
    }
}

// MARK: - Redemption authorization

extension Permissions {

    /// Whether `member` may confirm that a redeemed reward actually happened.
    ///
    /// Adults only, and their own redemptions included. That is the one place
    /// this rule departs from the approval rule it otherwise mirrors, and the
    /// departure is deliberate: approving your own chore pays you points, while
    /// marking your own reward given only records something that is either true
    /// or not. Forbidding it would leave the single parent who redeemed a night
    /// off cooking with a promise the app will insist is outstanding forever.
    ///
    /// - Parameters:
    ///   - redemption: The redemption being handed over.
    ///   - member: The person confirming it.
    /// - Throws: ``DomainError/memberNotInHousehold(_:)`` when they have left,
    ///   ``DomainError/redemptionAlreadySettled`` when it has already been
    ///   given or called off, or ``DomainError/notPermitted(action:role:)``.
    public static func authorizeHandOver(
        of redemption: Redemption,
        by member: Member
    ) throws {
        guard member.isActive else {
            throw DomainError.memberNotInHousehold(member.id)
        }
        try check(.handOverReward, for: member.role)
        guard redemption.isOwed else {
            throw DomainError.redemptionAlreadySettled
        }
    }

    /// Whether `member` may call a redemption off and send the points back.
    ///
    /// The person who redeemed it, or any adult. The first half is what makes
    /// the rewards screen safe to browse: a child who spends thirty points on
    /// the wrong thing by mistake can put it back themselves, and a currency
    /// you cannot un-spend is one children learn to hoard rather than use.
    ///
    /// The adult half is not administrative tidying either. Some promises
    /// genuinely cannot be kept — the cinema closed, the reward was withdrawn —
    /// and the alternative to a parent cancelling is a row that sits in the
    /// queue accusing the household forever.
    ///
    /// - Parameters:
    ///   - redemption: The redemption being called off.
    ///   - member: The person calling it off.
    /// - Throws: ``DomainError/memberNotInHousehold(_:)`` when they have left,
    ///   ``DomainError/redemptionAlreadySettled`` once it has been given — a
    ///   reward that has happened cannot be un-happened, and refunding one
    ///   would let a household watch the film and keep the points — or
    ///   ``DomainError/notPermitted(action:role:)``.
    public static func authorizeCancellation(
        of redemption: Redemption,
        by member: Member
    ) throws {
        guard member.isActive else {
            throw DomainError.memberNotInHousehold(member.id)
        }
        // Checked before the ownership rule so the person who redeemed it is
        // told the true reason. Falling through would tell a child their role
        // forbids cancelling a film they have already watched, which is both
        // wrong and unfixable.
        guard redemption.isOwed else {
            throw DomainError.redemptionAlreadySettled
        }
        guard member.id != redemption.memberID else { return }
        try check(.cancelRedemption, for: member.role)
    }
}
