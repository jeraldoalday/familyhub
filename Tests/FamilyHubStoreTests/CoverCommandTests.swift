import FamilyHubCore
import Foundation
import Testing

@testable import FamilyHubStore

/// Covers the commands a household runs when somebody cannot do their chore:
/// asking, answering, taking it back, and what an accepted cover changes about
/// completing the work.
@Suite("Cover commands")
struct CoverCommandTests {

    // MARK: Fixture

    private let calendar = Calendar.testDefault
    /// 2 March 2026, a Monday.
    private let clock = FixedDateProvider(
        year: 2026, month: 3, day: 2, hour: 9, calendar: .testDefault
    )

    private struct Fixture {
        let store: InMemoryHouseholdStore
        let commands: HouseholdCommands
        let household: Household
        let mary: Member
        let alex: Member
        let sam: Member
        /// Daily, and Sam's every day.
        let bins: Chore
        /// Open to whoever gets to it first.
        let dishes: Chore
    }

    private func makeFixture(requiresApproval: Bool = false) async throws -> Fixture {
        let household = try Household(
            name: "The Aldays",
            tier: .plus,
            timeZone: .gmt,
            requiresApproval: requiresApproval,
            createdAt: clock.now
        )
        let mary = try Member(
            householdID: household.id, name: "Mary", role: .adult,
            avatar: Avatar(color: .purple), joinedAt: clock.now
        )
        let alex = try Member(
            householdID: household.id, name: "Alex", role: .teen,
            avatar: Avatar(color: .teal), joinedAt: clock.now
        )
        let sam = try Member(
            householdID: household.id, name: "Sam", role: .child,
            avatar: Avatar(color: .amber), joinedAt: clock.now
        )
        let bins = try Chore(
            householdID: household.id,
            title: "Take out the bins",
            assignment: .member(sam.id),
            points: 15,
            startDate: clock.day(offsetFromToday: -7),
            recurrence: .daily,
            createdBy: mary.id,
            createdAt: clock.day(offsetFromToday: -7)
        )
        let dishes = try Chore(
            householdID: household.id,
            title: "Empty the dishwasher",
            assignment: .anyone,
            points: 10,
            startDate: clock.day(offsetFromToday: -7),
            recurrence: .daily,
            createdBy: mary.id,
            createdAt: clock.day(offsetFromToday: -7)
        )
        let store = InMemoryHouseholdStore(
            seed: HouseholdSnapshot(
                household: household,
                members: [mary, alex, sam],
                chores: [bins, dishes]
            )
        )
        return Fixture(
            store: store,
            commands: HouseholdCommands(store: store, dateProvider: clock),
            household: household,
            mary: mary,
            alex: alex,
            sam: sam,
            bins: bins,
            dishes: dishes
        )
    }

    // MARK: Asking

    @Test("Asking writes an open request and leaves the chore alone")
    func askingWritesARequest() async throws {
        let f = try await makeFixture()

        let request = try await f.commands.requestCover(
            of: f.bins.id,
            on: clock.today,
            in: f.household.id,
            by: f.sam.id,
            askedOf: f.alex.id,
            note: "At football until seven"
        )

        #expect(request.resolution == .open)
        #expect(request.askedOf == f.alex.id)
        #expect(request.note?.value == "At football until seven")

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.coverRequests.count == 1)
        // The rota is untouched: moving one Tuesday by editing it would move
        // every Tuesday after it.
        #expect(snapshot.chore(f.bins.id)?.assignment == .member(f.sam.id))
    }

    @Test("Asking again for the same thing returns the request already open")
    func askingTwiceIsIdempotent() async throws {
        // A person tapping again because the screen has not updated is not
        // making a second ask.
        let f = try await makeFixture()
        let first = try await f.commands.requestCover(
            of: f.bins.id, on: clock.today, in: f.household.id, by: f.sam.id, askedOf: f.alex.id
        )
        let second = try await f.commands.requestCover(
            of: f.bins.id, on: clock.today, in: f.household.id, by: f.sam.id, askedOf: f.alex.id
        )

        #expect(first.id == second.id)
        #expect(try await f.store.snapshot(of: f.household.id).coverRequests.count == 1)
    }

    @Test("Asking somebody else after a decline is a new request")
    func askingSomebodyElseIsANewRequest() async throws {
        let f = try await makeFixture()
        let toAlex = try await f.commands.requestCover(
            of: f.bins.id, on: clock.today, in: f.household.id, by: f.sam.id, askedOf: f.alex.id
        )
        try await f.commands.declineCover(toAlex.id, in: f.household.id, by: f.alex.id)

        let toEveryone = try await f.commands.requestCover(
            of: f.bins.id, on: clock.today, in: f.household.id, by: f.sam.id
        )

        #expect(toEveryone.id != toAlex.id)
        #expect(try await f.store.snapshot(of: f.household.id).coverRequests.count == 2)
    }

    @Test("A day the chore does not fall on cannot be covered")
    func unscheduledDayIsRefused() async throws {
        let f = try await makeFixture()
        let weekly = try await f.commands.createChore(
            in: f.household.id,
            title: "Hoover the stairs",
            assignment: .member(f.sam.id),
            recurrence: .weekly(on: [.saturday]),
            by: f.mary.id
        )

        await #expect(throws: DomainError.notScheduled(on: clock.today)) {
            try await f.commands.requestCover(
                of: weekly.id, on: clock.today, in: f.household.id, by: f.sam.id
            )
        }
    }

    @Test("A chore open to the household cannot be covered")
    func openChoreCannotBeCovered() async throws {
        let f = try await makeFixture()

        await #expect(throws: DomainError.notAssignedToYou(on: clock.today)) {
            try await f.commands.requestCover(
                of: f.dishes.id, on: clock.today, in: f.household.id, by: f.sam.id
            )
        }
    }

    @Test("Work already done has nothing left to cover")
    func completedOccurrenceCannotBeCovered() async throws {
        let f = try await makeFixture()
        try await f.commands.completeChore(
            f.bins.id, on: clock.today, in: f.household.id, by: f.sam.id
        )

        await #expect(throws: DomainError.alreadyCompleted) {
            try await f.commands.requestCover(
                of: f.bins.id, on: clock.today, in: f.household.id, by: f.sam.id
            )
        }
    }

    @Test("Asking somebody who has left the household is refused")
    func askingADepartedMemberIsRefused() async throws {
        let f = try await makeFixture()
        try await f.commands.removeMember(f.alex.id, from: f.household.id, by: f.mary.id)

        await #expect(throws: DomainError.memberNotInHousehold(f.alex.id)) {
            try await f.commands.requestCover(
                of: f.bins.id,
                on: clock.today,
                in: f.household.id,
                by: f.sam.id,
                askedOf: f.alex.id
            )
        }
    }

    // MARK: Answering

    @Test("Accepting hands the occurrence over")
    func acceptingHandsTheOccurrenceOver() async throws {
        let f = try await makeFixture()
        let request = try await f.commands.requestCover(
            of: f.bins.id, on: clock.today, in: f.household.id, by: f.sam.id
        )

        let accepted = try await f.commands.acceptCover(
            request.id, in: f.household.id, by: f.alex.id
        )

        #expect(accepted.resolution.coveringMemberID == f.alex.id)

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.agenda(for: clock.today, memberID: f.alex.id).count == 2)
        #expect(
            snapshot.agenda(for: clock.today, memberID: f.sam.id)
                .contains { $0.chore.id == f.bins.id } == false
        )
    }

    @Test("The second person to accept is refused, not silently ignored")
    func secondAcceptanceIsRefused() async throws {
        let f = try await makeFixture()
        let toAlex = try await f.commands.requestCover(
            of: f.bins.id, on: clock.today, in: f.household.id, by: f.sam.id, askedOf: f.alex.id
        )
        let toEveryone = try await f.commands.requestCover(
            of: f.bins.id, on: clock.today, in: f.household.id, by: f.sam.id
        )
        try await f.commands.acceptCover(toAlex.id, in: f.household.id, by: f.alex.id)

        // Otherwise two people spend the evening believing they owe the same
        // chore, which is worse than nobody doing it.
        await #expect(throws: DomainError.coverAlreadySettled) {
            try await f.commands.acceptCover(toEveryone.id, in: f.household.id, by: f.mary.id)
        }
    }

    @Test("Declining is recorded so the person who asked knows to ask elsewhere")
    func decliningIsRecorded() async throws {
        let f = try await makeFixture()
        let request = try await f.commands.requestCover(
            of: f.bins.id, on: clock.today, in: f.household.id, by: f.sam.id, askedOf: f.alex.id
        )

        let declined = try await f.commands.declineCover(
            request.id, in: f.household.id, by: f.alex.id
        )

        #expect(declined.resolution == .declined(by: f.alex.id, at: clock.now))
        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.coverInbox(for: f.alex.id, on: clock.now).isEmpty)
        // The chore is Sam's again — nothing moved.
        #expect(snapshot.agenda(for: clock.today, memberID: f.sam.id).count == 2)
    }

    @Test("A request cannot be answered by the person who made it")
    func requesterCannotAnswerTheirOwn() async throws {
        let f = try await makeFixture()
        let request = try await f.commands.requestCover(
            of: f.bins.id, on: clock.today, in: f.household.id, by: f.sam.id
        )

        await #expect(throws: DomainError.cannotCoverForYourself) {
            try await f.commands.acceptCover(request.id, in: f.household.id, by: f.sam.id)
        }
    }

    @Test("A chore archived after the ask cannot be accepted")
    func archivedChoreCannotBeAccepted() async throws {
        // The world moves between asking and answering, and accepting would put
        // a chore on somebody's list that the agenda will never show.
        let f = try await makeFixture()
        let request = try await f.commands.requestCover(
            of: f.bins.id, on: clock.today, in: f.household.id, by: f.sam.id
        )
        try await f.commands.archiveChore(f.bins.id, in: f.household.id, by: f.mary.id)

        await #expect(throws: DomainError.notScheduled(on: clock.today)) {
            try await f.commands.acceptCover(request.id, in: f.household.id, by: f.alex.id)
        }
    }

    // MARK: Withdrawing

    @Test("The requester can take an unanswered request back")
    func requesterCanWithdraw() async throws {
        let f = try await makeFixture()
        let request = try await f.commands.requestCover(
            of: f.bins.id, on: clock.today, in: f.household.id, by: f.sam.id
        )

        let withdrawn = try await f.commands.withdrawCover(
            request.id, in: f.household.id, by: f.sam.id
        )

        #expect(withdrawn.resolution == .withdrawn(at: clock.now))
        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.liveCoverRequests(on: clock.now).isEmpty)
    }

    @Test("An accepted request cannot be withdrawn")
    func acceptedRequestCannotBeWithdrawn() async throws {
        let f = try await makeFixture()
        let request = try await f.commands.requestCover(
            of: f.bins.id, on: clock.today, in: f.household.id, by: f.sam.id
        )
        try await f.commands.acceptCover(request.id, in: f.household.id, by: f.alex.id)

        await #expect(throws: DomainError.coverAlreadySettled) {
            try await f.commands.withdrawCover(request.id, in: f.household.id, by: f.sam.id)
        }
    }

    // MARK: Completing a covered chore

    @Test("The person covering earns the points for the work they did")
    func coveringMemberEarnsThePoints() async throws {
        let f = try await makeFixture()
        let request = try await f.commands.requestCover(
            of: f.bins.id, on: clock.today, in: f.household.id, by: f.sam.id
        )
        try await f.commands.acceptCover(request.id, in: f.household.id, by: f.alex.id)

        try await f.commands.completeChore(
            f.bins.id, on: clock.today, in: f.household.id, by: f.alex.id
        )

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.ledger.balance(for: f.alex.id) == 15)
        #expect(snapshot.ledger.balance(for: f.sam.id) == 0)
    }

    @Test("A sibling cannot tick off a chore nobody handed them")
    func uncoveredSiblingIsStillRefused() async throws {
        // The permission the cover grants is granted by the cover, not by
        // wanting to help — otherwise a child could move points into their own
        // balance from anybody's rota.
        let f = try await makeFixture()

        await #expect(throws: DomainError.notPermitted(action: .completeOthersChore, role: .teen)) {
            try await f.commands.completeChore(
                f.bins.id, on: clock.today, in: f.household.id, by: f.alex.id
            )
        }
    }

    @Test("Doing your own chore anyway closes the request you left open")
    func completingWithdrawsOpenRequests() async throws {
        // Otherwise the ask sits on a sibling's list all evening about a chore
        // that is already finished.
        let f = try await makeFixture()
        let request = try await f.commands.requestCover(
            of: f.bins.id, on: clock.today, in: f.household.id, by: f.sam.id
        )

        try await f.commands.completeChore(
            f.bins.id, on: clock.today, in: f.household.id, by: f.sam.id
        )

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.coverRequest(request.id)?.resolution == .withdrawn(at: clock.now))
        #expect(snapshot.coverInbox(for: f.alex.id, on: clock.now).isEmpty)
    }

    @Test("An accepted cover survives the person who asked doing it anyway")
    func acceptedCoverIsNotWithdrawnByCompletion() async throws {
        // Withdrawing here would rewrite an arrangement two people made, and
        // the history of who covered what is what a parent reads back.
        let f = try await makeFixture()
        let request = try await f.commands.requestCover(
            of: f.bins.id, on: clock.today, in: f.household.id, by: f.sam.id
        )
        try await f.commands.acceptCover(request.id, in: f.household.id, by: f.alex.id)

        try await f.commands.completeChore(
            f.bins.id, on: clock.today, in: f.household.id, by: f.sam.id
        )

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.coverRequest(request.id)?.resolution.coveringMemberID == f.alex.id)
        #expect(snapshot.ledger.balance(for: f.sam.id) == 15)
    }
}
