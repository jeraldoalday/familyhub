import FamilyHubCore
import Foundation
import Testing

@testable import FamilyHubStore

/// Covers the commands for saying who is away: who may record one, what a
/// second identical one does, and what cancelling gives back.
@Suite("Away commands")
struct AwayCommandTests {

    // MARK: Fixture

    private let calendar = Calendar.testDefault
    /// 2 March 2026, a Monday.
    private let clock = FixedDateProvider(year: 2026, month: 3, day: 2, hour: 9)

    private struct Fixture {
        let store: InMemoryHouseholdStore
        let commands: HouseholdCommands
        let household: Household
        let mary: Member
        let alex: Member
        let sam: Member
        let bins: Chore
    }

    private func makeFixture() async throws -> Fixture {
        let household = try Household(
            name: "The Aldays",
            tier: .plus,
            timeZone: .gmt,
            requiresApproval: false,
            createdAt: clock.now
        )
        let mary = try Member(
            householdID: household.id, name: "Mary", role: .adult, joinedAt: clock.now
        )
        let alex = try Member(
            householdID: household.id, name: "Alex", role: .teen, joinedAt: clock.now
        )
        let sam = try Member(
            householdID: household.id, name: "Sam", role: .child, joinedAt: clock.now
        )
        let bins = try Chore(
            householdID: household.id,
            title: "Take out the bins",
            assignment: .member(sam.id),
            startDate: clock.today,
            recurrence: .daily,
            createdBy: mary.id,
            createdAt: clock.now
        )
        let store = InMemoryHouseholdStore(
            seed: HouseholdSnapshot(
                household: household, members: [mary, alex, sam], chores: [bins]
            )
        )
        return Fixture(
            store: store,
            commands: HouseholdCommands(store: store, dateProvider: clock),
            household: household,
            mary: mary,
            alex: alex,
            sam: sam,
            bins: bins
        )
    }

    // MARK: Recording one

    @Test("An adult records a trip and the agenda stops asking")
    func recordingATrip() async throws {
        let f = try await makeFixture()

        let trip = try await f.commands.goAway(
            from: clock.today,
            to: clock.day(offsetFromToday: 6),
            in: f.household.id,
            by: f.mary.id,
            members: [f.sam.id],
            reason: "Nan's"
        )

        #expect(trip.covers(f.sam.id))
        #expect(trip.reason?.value == "Nan's")
        #expect(trip.createdBy == f.mary.id)

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.agenda(for: clock.today, memberID: f.sam.id).isEmpty)
        #expect(snapshot.agenda(for: clock.today).allSatisfy { $0.isAway })
    }

    @Test("A child cannot record their own way out of the rota")
    func childrenMayNotRecordATrip() async throws {
        let f = try await makeFixture()

        await #expect(
            throws: DomainError.notPermitted(action: .manageAwayPeriod, role: .child)
        ) {
            try await f.commands.goAway(
                from: clock.today, to: clock.day(offsetFromToday: 6),
                in: f.household.id, by: f.sam.id
            )
        }
        await #expect(
            throws: DomainError.notPermitted(action: .manageAwayPeriod, role: .teen)
        ) {
            try await f.commands.goAway(
                from: clock.today, to: clock.day(offsetFromToday: 6),
                in: f.household.id, by: f.alex.id
            )
        }
        #expect(try await f.store.snapshot(of: f.household.id).awayPeriods.isEmpty)
    }

    @Test("Recording the same trip twice records it once")
    func recordingTwiceIsIdempotent() async throws {
        let f = try await makeFixture()

        let first = try await f.commands.goAway(
            from: clock.today, to: clock.day(offsetFromToday: 6),
            in: f.household.id, by: f.mary.id, members: [f.sam.id]
        )
        let second = try await f.commands.goAway(
            from: clock.today, to: clock.day(offsetFromToday: 6),
            in: f.household.id, by: f.mary.id, members: [f.sam.id]
        )

        #expect(first.id == second.id)
        #expect(try await f.store.snapshot(of: f.household.id).awayPeriods.count == 1)

        // A different stretch of days is a different trip.
        let later = try await f.commands.goAway(
            from: clock.day(offsetFromToday: 20), to: clock.day(offsetFromToday: 22),
            in: f.household.id, by: f.mary.id, members: [f.sam.id]
        )
        #expect(later.id != first.id)
    }

    @Test("Naming everybody is the family holiday, and behaves like one")
    func namingEverybodyCollapsesToTheHousehold() async throws {
        let f = try await makeFixture()
        let dishwasher = try Chore(
            householdID: f.household.id,
            title: "Empty the dishwasher",
            assignment: .anyone,
            startDate: clock.today,
            recurrence: .daily,
            createdBy: f.mary.id,
            createdAt: clock.now
        )
        try await f.store.save(dishwasher)

        let trip = try await f.commands.goAway(
            from: clock.today, to: clock.day(offsetFromToday: 6),
            in: f.household.id, by: f.mary.id,
            members: [f.mary.id, f.alex.id, f.sam.id]
        )

        // Listed by name, the open chore would still be on the agenda of a
        // household that is in Spain.
        #expect(trip.isWholeHousehold)
        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.isHouseholdAway(on: clock.today))
        #expect(snapshot.agenda(for: clock.today).allSatisfy { $0.isAway })
    }

    @Test("Somebody who has left the household cannot go away")
    func namingAStrangerIsRefused() async throws {
        let f = try await makeFixture()

        await #expect(throws: DomainError.self) {
            try await f.commands.goAway(
                from: clock.today, to: clock.day(offsetFromToday: 2),
                in: f.household.id, by: f.mary.id, members: [Identifier<Member>()]
            )
        }
    }

    @Test("Dates that cannot be honoured are refused before anything is written")
    func impossibleDatesAreRefused() async throws {
        let f = try await makeFixture()

        await #expect(throws: DomainError.self) {
            try await f.commands.goAway(
                from: clock.day(offsetFromToday: 6), to: clock.today,
                in: f.household.id, by: f.mary.id
            )
        }
        #expect(try await f.store.snapshot(of: f.household.id).awayPeriods.isEmpty)
    }

    // MARK: Editing one

    @Test("A trip can be moved, renamed, and handed to different people")
    func editingATrip() async throws {
        let f = try await makeFixture()
        let trip = try await f.commands.goAway(
            from: clock.today, to: clock.day(offsetFromToday: 3),
            in: f.household.id, by: f.mary.id, members: [f.sam.id], reason: "Nan's"
        )

        let moved = try await f.commands.updateAwayPeriod(
            trip.id,
            in: f.household.id,
            by: f.mary.id,
            lastDay: clock.day(offsetFromToday: 6),
            members: [f.sam.id, f.alex.id],
            reason: .some("Spain")
        )

        #expect(moved.id == trip.id)
        #expect(moved.lastDay == clock.day(offsetFromToday: 6))
        #expect(moved.covers(f.alex.id))
        #expect(moved.reason?.value == "Spain")

        // Omitting the reason leaves it alone; passing nil clears it.
        let untouched = try await f.commands.updateAwayPeriod(
            trip.id, in: f.household.id, by: f.mary.id, firstDay: clock.day(offsetFromToday: 1)
        )
        #expect(untouched.reason?.value == "Spain")
        let cleared = try await f.commands.updateAwayPeriod(
            trip.id, in: f.household.id, by: f.mary.id, reason: .some(nil)
        )
        #expect(cleared.reason == nil)
    }

    @Test("A teen cannot edit a trip either")
    func editingIsAlsoAnAdultAction() async throws {
        let f = try await makeFixture()
        let trip = try await f.commands.goAway(
            from: clock.today, to: clock.day(offsetFromToday: 3),
            in: f.household.id, by: f.mary.id
        )

        await #expect(throws: DomainError.notPermitted(action: .manageAwayPeriod, role: .teen)) {
            try await f.commands.cancelAwayPeriod(trip.id, in: f.household.id, by: f.alex.id)
        }
    }

    @Test("A trip that does not exist is a clear refusal")
    func editingAMissingTrip() async throws {
        let f = try await makeFixture()

        await #expect(throws: DomainError.self) {
            try await f.commands.cancelAwayPeriod(
                Identifier<AwayPeriod>(), in: f.household.id, by: f.mary.id
            )
        }
    }

    // MARK: Cancelling one

    @Test("Cancelling a holiday puts the fortnight back on the rota")
    func cancellingGivesTheDaysBack() async throws {
        let f = try await makeFixture()
        let trip = try await f.commands.goAway(
            from: clock.today, to: clock.day(offsetFromToday: 6),
            in: f.household.id, by: f.mary.id, members: [f.sam.id]
        )

        let cancelled = try await f.commands.cancelAwayPeriod(
            trip.id, in: f.household.id, by: f.mary.id
        )
        #expect(cancelled.cancelledAt == clock.now)

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(!snapshot.isAway(f.sam.id, on: clock.today))
        #expect(snapshot.agenda(for: clock.today, memberID: f.sam.id).count == 1)
        // Kept rather than erased, so the household can see what happened.
        #expect(snapshot.awayPeriods.count == 1)

        let back = try await f.commands.reinstateAwayPeriod(
            trip.id, in: f.household.id, by: f.mary.id
        )
        #expect(back.isActive)
        #expect(try await f.store.snapshot(of: f.household.id).isAway(f.sam.id, on: clock.today))
    }
}
