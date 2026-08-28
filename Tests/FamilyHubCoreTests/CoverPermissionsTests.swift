import Foundation
import Testing

@testable import FamilyHubCore

/// Covers who may ask to be covered, who may answer, and what an accepted
/// cover changes about who is allowed to tick the chore off.
@Suite("Cover permissions")
struct CoverPermissionsTests {

    // MARK: Fixture

    private let calendar = Calendar.testDefault
    private var engine: RecurrenceEngine { RecurrenceEngine(calendar: calendar) }
    private let householdID = Identifier<Household>()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        FixedDateProvider(year: year, month: month, day: day, calendar: calendar).now
    }

    private func member(_ role: MemberRole, name: String = "Person") throws -> Member {
        try Member(householdID: householdID, name: name, role: role, joinedAt: date(2026, 1, 1))
    }

    private func chore(
        assignment: Chore.Assignment,
        by creator: Identifier<Member>
    ) throws -> Chore {
        try Chore(
            householdID: householdID,
            title: "Take out the bins",
            assignment: assignment,
            startDate: date(2026, 3, 2),
            createdBy: creator,
            createdAt: date(2026, 3, 1)
        )
    }

    private func request(
        chore: Chore,
        by requester: Identifier<Member>,
        askedOf: Identifier<Member>? = nil
    ) throws -> CoverRequest {
        try CoverRequest(
            householdID: householdID,
            choreID: chore.id,
            day: date(2026, 3, 2),
            requestedBy: requester,
            askedOf: askedOf,
            createdAt: date(2026, 3, 1),
            calendar: calendar
        )
    }

    // MARK: The table

    @Test("Every role may ask for cover and may cover for somebody")
    func coverIsOpenToEveryone() {
        // Restricting either would put the swap back across the kitchen, which
        // is exactly where it already happens.
        for role in MemberRole.allCases {
            #expect(Permissions.allows(.requestCover, for: role))
            #expect(Permissions.allows(.coverForSomeone, for: role))
        }
    }

    // MARK: Asking

    @Test("The person the day falls to may ask to be covered")
    func assigneeMayAsk() throws {
        let sam = try member(.child, name: "Sam")
        let chore = try chore(assignment: .member(sam.id), by: sam.id)

        try Permissions.authorizeCoverRequest(
            of: chore, on: date(2026, 3, 2), by: sam, engine: engine
        )
    }

    @Test("Asking to be covered for somebody else's turn is refused")
    func nonAssigneeMayNotAsk() throws {
        let sam = try member(.child, name: "Sam")
        let alex = try member(.teen, name: "Alex")
        let chore = try chore(assignment: .member(sam.id), by: sam.id)

        #expect(throws: DomainError.notAssignedToYou(on: date(2026, 3, 2))) {
            try Permissions.authorizeCoverRequest(
                of: chore, on: date(2026, 3, 2), by: alex, engine: engine
            )
        }
    }

    @Test("An adult cannot ask to be covered for a child's turn either")
    func adultMayNotAskOnSomebodyElsesBehalf() throws {
        // Deliberately not an adult override. A parent who wants the bins done
        // by somebody else changes the rota; a cover request is a favour, and a
        // favour asked on your behalf without you is an instruction.
        let sam = try member(.child, name: "Sam")
        let mary = try member(.adult, name: "Mary")
        let chore = try chore(assignment: .member(sam.id), by: mary.id)

        #expect(throws: DomainError.notAssignedToYou(on: date(2026, 3, 2))) {
            try Permissions.authorizeCoverRequest(
                of: chore, on: date(2026, 3, 2), by: mary, engine: engine
            )
        }
    }

    @Test("A chore open to the household cannot be covered — nobody owes it")
    func openChoreCannotBeCovered() throws {
        let sam = try member(.child, name: "Sam")
        let chore = try chore(assignment: .anyone, by: sam.id)

        #expect(throws: DomainError.notAssignedToYou(on: date(2026, 3, 2))) {
            try Permissions.authorizeCoverRequest(
                of: chore, on: date(2026, 3, 2), by: sam, engine: engine
            )
        }
    }

    @Test("A rota resolves to whoever's turn the day actually is")
    func rotaDecidesWhoMayAsk() throws {
        let sam = try member(.child, name: "Sam")
        let alex = try member(.teen, name: "Alex")
        // Daily from Monday: Monday is Sam's, Tuesday is Alex's.
        let chore = try chore(assignment: .rotating([sam.id, alex.id]), by: sam.id)

        try Permissions.authorizeCoverRequest(
            of: chore, on: date(2026, 3, 2), by: sam, engine: engine
        )
        try Permissions.authorizeCoverRequest(
            of: chore, on: date(2026, 3, 3), by: alex, engine: engine
        )
        #expect(throws: DomainError.notAssignedToYou(on: date(2026, 3, 3))) {
            try Permissions.authorizeCoverRequest(
                of: chore, on: date(2026, 3, 3), by: sam, engine: engine
            )
        }
    }

    @Test("A member who has left cannot ask")
    func removedMemberMayNotAsk() throws {
        let departed = try member(.teen, name: "Alex").removed(at: date(2026, 2, 1))
        let chore = try chore(assignment: .member(departed.id), by: departed.id)

        #expect(throws: DomainError.memberNotInHousehold(departed.id)) {
            try Permissions.authorizeCoverRequest(
                of: chore, on: date(2026, 3, 2), by: departed, engine: engine
            )
        }
    }

    // MARK: Answering

    @Test("Anybody in the household may answer an open request")
    func anybodyMayAnswerAnOpenRequest() throws {
        let sam = try member(.child, name: "Sam")
        let alex = try member(.teen, name: "Alex")
        let chore = try chore(assignment: .member(sam.id), by: sam.id)
        let request = try request(chore: chore, by: sam.id)

        try Permissions.authorizeCoverAnswer(to: request, by: alex)
    }

    @Test("Only the person named may answer a request that named somebody")
    func namedRequestIsAnsweredByTheNamedPerson() throws {
        let sam = try member(.child, name: "Sam")
        let alex = try member(.teen, name: "Alex")
        let mary = try member(.adult, name: "Mary")
        let chore = try chore(assignment: .member(sam.id), by: sam.id)
        let request = try request(chore: chore, by: sam.id, askedOf: alex.id)

        try Permissions.authorizeCoverAnswer(to: request, by: alex)
        #expect(throws: DomainError.notPermitted(action: .coverForSomeone, role: .adult)) {
            try Permissions.authorizeCoverAnswer(to: request, by: mary)
        }
    }

    @Test("The person who asked is told why they cannot answer their own request")
    func requesterCannotAnswerTheirOwn() throws {
        // The reason matters: falling through to a role check would tell a
        // child their role forbids it, which is wrong and unfixable.
        let sam = try member(.child, name: "Sam")
        let chore = try chore(assignment: .member(sam.id), by: sam.id)
        let request = try request(chore: chore, by: sam.id)

        #expect(throws: DomainError.cannotCoverForYourself) {
            try Permissions.authorizeCoverAnswer(to: request, by: sam)
        }
    }

    @Test("An answered request cannot be answered again")
    func answeredRequestIsClosed() throws {
        let sam = try member(.child, name: "Sam")
        let alex = try member(.teen, name: "Alex")
        let mary = try member(.adult, name: "Mary")
        let chore = try chore(assignment: .member(sam.id), by: sam.id)
        let settled = try request(chore: chore, by: sam.id)
            .accepted(by: alex.id, at: date(2026, 3, 1))

        #expect(throws: DomainError.coverAlreadySettled) {
            try Permissions.authorizeCoverAnswer(to: settled, by: mary)
        }
    }

    // MARK: Withdrawing

    @Test("The requester may take their request back")
    func requesterMayWithdraw() throws {
        let sam = try member(.child, name: "Sam")
        let chore = try chore(assignment: .member(sam.id), by: sam.id)
        let request = try request(chore: chore, by: sam.id)

        try Permissions.authorizeCoverWithdrawal(of: request, by: sam)
    }

    @Test("An adult may clear a request that has stopped making sense")
    func adultMayWithdraw() throws {
        let sam = try member(.child, name: "Sam")
        let mary = try member(.adult, name: "Mary")
        let chore = try chore(assignment: .member(sam.id), by: sam.id)
        let request = try request(chore: chore, by: sam.id)

        try Permissions.authorizeCoverWithdrawal(of: request, by: mary)
    }

    @Test("A sibling cannot withdraw somebody else's request")
    func siblingMayNotWithdraw() throws {
        let sam = try member(.child, name: "Sam")
        let alex = try member(.teen, name: "Alex")
        let chore = try chore(assignment: .member(sam.id), by: sam.id)
        let request = try request(chore: chore, by: sam.id)

        #expect(throws: DomainError.notPermitted(action: .requestCover, role: .teen)) {
            try Permissions.authorizeCoverWithdrawal(of: request, by: alex)
        }
    }

    @Test("An accepted request cannot be withdrawn, even by an adult")
    func acceptedRequestCannotBeWithdrawn() throws {
        // It is an arrangement between two people by then, and unpicking it
        // silently hands the chore back to somebody who believes it is gone.
        let sam = try member(.child, name: "Sam")
        let alex = try member(.teen, name: "Alex")
        let mary = try member(.adult, name: "Mary")
        let chore = try chore(assignment: .member(sam.id), by: sam.id)
        let settled = try request(chore: chore, by: sam.id)
            .accepted(by: alex.id, at: date(2026, 3, 1))

        #expect(throws: DomainError.coverAlreadySettled) {
            try Permissions.authorizeCoverWithdrawal(of: settled, by: mary)
        }
    }

    // MARK: What a cover changes about completing

    @Test("The person covering may tick off a chore that was never theirs")
    func coveringMemberMayComplete() throws {
        let sam = try member(.child, name: "Sam")
        let alex = try member(.child, name: "Alex")
        let chore = try chore(assignment: .member(sam.id), by: sam.id)

        // Without the cover this is a child completing a sibling's chore.
        #expect(throws: DomainError.notPermitted(action: .completeOthersChore, role: .child)) {
            try Permissions.authorizeCompletion(
                of: chore, on: date(2026, 3, 2), by: alex, engine: engine
            )
        }

        try Permissions.authorizeCompletion(
            of: chore,
            on: date(2026, 3, 2),
            by: alex,
            engine: engine,
            coveringMemberID: alex.id
        )
    }

    @Test("A cover does not stop the original assignee doing their own chore")
    func coverDoesNotRevokeTheAssignee() throws {
        // A child whose plans freed up and who does the bins anyway must not be
        // told they are not allowed to.
        let sam = try member(.child, name: "Sam")
        let alex = try member(.child, name: "Alex")
        let chore = try chore(assignment: .member(sam.id), by: sam.id)

        try Permissions.authorizeCompletion(
            of: chore,
            on: date(2026, 3, 2),
            by: sam,
            engine: engine,
            coveringMemberID: alex.id
        )
    }

    @Test("A cover does not open the chore to the rest of the household")
    func coverDoesNotOpenTheChore() throws {
        let sam = try member(.child, name: "Sam")
        let alex = try member(.child, name: "Alex")
        let jo = try member(.child, name: "Jo")
        let chore = try chore(assignment: .member(sam.id), by: sam.id)

        #expect(throws: DomainError.notPermitted(action: .completeOthersChore, role: .child)) {
            try Permissions.authorizeCompletion(
                of: chore,
                on: date(2026, 3, 2),
                by: jo,
                engine: engine,
                coveringMemberID: alex.id
            )
        }
    }
}
