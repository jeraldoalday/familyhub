import Foundation
import Testing

@testable import FamilyHubCore

/// Covers who may confirm that a reward actually happened and who may call one
/// off — the two answers that decide whether the queue of promises means
/// anything.
@Suite("Redemption permissions")
struct RedemptionPermissionsTests {

    // MARK: Fixture

    /// 2 March 2026, a Monday.
    private let clock = FixedDateProvider(year: 2026, month: 3, day: 2, hour: 9)

    private let householdID = Identifier<Household>()
    private let rewardID = Identifier<Reward>()

    private func makeMember(
        _ name: String,
        role: MemberRole,
        isActive: Bool = true
    ) throws -> Member {
        let member = try Member(
            householdID: householdID,
            name: name,
            role: role,
            avatar: Avatar(color: .teal),
            joinedAt: clock.now
        )
        return isActive ? member : member.removed(at: clock.now)
    }

    private func makeRedemption(
        by memberID: Identifier<Member>,
        state: Redemption.State = .owed
    ) throws -> Redemption {
        try Redemption(
            householdID: householdID,
            rewardID: rewardID,
            memberID: memberID,
            cost: 25,
            redeemedAt: clock.now,
            state: state
        )
    }

    // MARK: The table

    @Test("Only adults may hand a reward over or cancel somebody else's")
    func adultsOnly() {
        for role in MemberRole.allCases {
            #expect(Permissions.allows(.handOverReward, for: role) == role.isAdult)
            #expect(Permissions.allows(.cancelRedemption, for: role) == role.isAdult)
        }
    }

    @Test("Both new actions read correctly inside a refusal")
    func actionsReadAsSentences() {
        let child = MemberRole.child
        let handOver = DomainError.notPermitted(action: .handOverReward, role: child)
        let cancel = DomainError.notPermitted(action: .cancelRedemption, role: child)

        #expect(handOver.errorDescription == "Childs can't hand a reward over.")
        #expect(cancel.errorDescription == "Childs can't cancel somebody else's reward.")
    }

    // MARK: Handing over

    @Test("A parent may confirm a child's reward happened")
    func adultMayHandOver() throws {
        let mary = try makeMember("Mary", role: .adult)
        let sam = try makeMember("Sam", role: .child)

        try Permissions.authorizeHandOver(of: try makeRedemption(by: sam.id), by: mary)
    }

    @Test("A child cannot mark their own reward as given")
    func childMayNotHandOver() throws {
        let sam = try makeMember("Sam", role: .child)

        #expect(throws: DomainError.notPermitted(action: .handOverReward, role: .child)) {
            try Permissions.authorizeHandOver(of: try makeRedemption(by: sam.id), by: sam)
        }
    }

    @Test("A parent may mark their own reward as given, unlike their own chore")
    func adultMayHandOverTheirOwn() throws {
        let mary = try makeMember("Mary", role: .adult)

        try Permissions.authorizeHandOver(of: try makeRedemption(by: mary.id), by: mary)
    }

    @Test("A parent who has left the household may not hand anything over")
    func removedAdultMayNotHandOver() throws {
        let formerAdult = try makeMember("Chris", role: .adult, isActive: false)
        let sam = try makeMember("Sam", role: .child)

        #expect(throws: DomainError.memberNotInHousehold(formerAdult.id)) {
            try Permissions.authorizeHandOver(
                of: try makeRedemption(by: sam.id), by: formerAdult
            )
        }
    }

    @Test("The second parent to tick off the same reward is told it is settled")
    func alreadyGivenIsRefused() throws {
        let mary = try makeMember("Mary", role: .adult)
        let jerald = try makeMember("Jerald", role: .owner)
        let sam = try makeMember("Sam", role: .child)
        let given = try makeRedemption(by: sam.id, state: .given(by: jerald.id, at: clock.now))

        #expect(throws: DomainError.redemptionAlreadySettled) {
            try Permissions.authorizeHandOver(of: given, by: mary)
        }
    }

    // MARK: Cancelling

    @Test("A child may put back a reward they redeemed by mistake")
    func ownerOfTheRedemptionMayCancel() throws {
        let sam = try makeMember("Sam", role: .child)

        try Permissions.authorizeCancellation(of: try makeRedemption(by: sam.id), by: sam)
    }

    @Test("A child may not cancel their sibling's reward")
    func childMayNotCancelSomebodyElses() throws {
        let sam = try makeMember("Sam", role: .child)
        let alex = try makeMember("Alex", role: .child)

        #expect(throws: DomainError.notPermitted(action: .cancelRedemption, role: .child)) {
            try Permissions.authorizeCancellation(of: try makeRedemption(by: alex.id), by: sam)
        }
    }

    @Test("A teenager may not cancel somebody else's either")
    func teenMayNotCancelSomebodyElses() throws {
        let alex = try makeMember("Alex", role: .teen)
        let sam = try makeMember("Sam", role: .child)

        #expect(throws: DomainError.notPermitted(action: .cancelRedemption, role: .teen)) {
            try Permissions.authorizeCancellation(of: try makeRedemption(by: sam.id), by: alex)
        }
    }

    @Test("A parent may call off a promise the household cannot keep")
    func adultMayCancelAnybodys() throws {
        let mary = try makeMember("Mary", role: .adult)
        let sam = try makeMember("Sam", role: .child)

        try Permissions.authorizeCancellation(of: try makeRedemption(by: sam.id), by: mary)
    }

    @Test("A reward that has already happened cannot be refunded by anybody")
    func givenCannotBeCancelled() throws {
        let mary = try makeMember("Mary", role: .adult)
        let sam = try makeMember("Sam", role: .child)
        let given = try makeRedemption(by: sam.id, state: .given(by: mary.id, at: clock.now))

        #expect(throws: DomainError.redemptionAlreadySettled) {
            try Permissions.authorizeCancellation(of: given, by: mary)
        }
        // Told the true reason rather than that their role forbids it: the
        // child owns this redemption, and the problem is that they have
        // already watched the film.
        #expect(throws: DomainError.redemptionAlreadySettled) {
            try Permissions.authorizeCancellation(of: given, by: sam)
        }
    }

    @Test("Somebody who has left cannot cancel their old redemptions")
    func removedMemberMayNotCancel() throws {
        let former = try makeMember("Chris", role: .teen, isActive: false)

        #expect(throws: DomainError.memberNotInHousehold(former.id)) {
            try Permissions.authorizeCancellation(of: try makeRedemption(by: former.id), by: former)
        }
    }
}
